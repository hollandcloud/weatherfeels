#if canImport(MapKit) && !os(tvOS)
import MapKit
import SwiftUI
import WeatherStarKit

/// A full-screen radar map: the NEXRAD reflectivity composite over Apple Maps, looping the
/// last hour, pannable and zoomable.
///
/// The WeatherStar "Local Radar" is the authentic display — a fixed window in the original's
/// palette, which is the point of the app. This is the useful one beside it: zoom in on a
/// storm cell over your street, or out to the line coming across the state, with the real
/// map underneath. Not on Apple TV, where there is nothing to pan or pinch with.
struct RadarMapScreen: View {
    let center: SavedLocation?
    let timeZone: TimeZone
    let onClose: () -> Void

    @Environment(\.foldPosture) private var fold
    @State private var model = RadarMapModel()
    /// Bumped to ask the map to fly back to the location.
    @State private var recentreRequest = 0

    var body: some View {
        ZStack {
            RadarMapView(
                image: model.visibleImage,
                box: model.box,
                center: center,
                recentreRequest: recentreRequest,
                onSettle: { box, size in model.request(box: box, pixelSize: size) }
            )
            .ignoresSafeArea()

            controlsLayer
        }
        .task {
            await model.load()
        }
        .onDisappear { model.stop() }
    }

    /// The controls, kept off the crease of a folded screen.
    ///
    /// Bent like a book they sit on the trailing page; stood like a laptop, on the lower half.
    /// Flat or on any other device, along the bottom as usual.
    ///
    /// Inset past the crease rather than laid out with `FoldSplit`: these are ordinary controls
    /// that should keep the safe area — on the inner display the status items stand up the
    /// trailing edge, and a split that ignores the safe area put the close button behind them.
    @ViewBuilder
    private var controlsLayer: some View {
        switch fold {
        case .book(let crease):
            controls.padding(.leading, crease.maxX)
        case .tabletop(let crease):
            controls.padding(.top, crease.maxY)
        case .flat:
            controls
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Circle())
                .accessibilityLabel("Close radar map")
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Spacer()

            VStack(spacing: 10) {
                transport
                RadarMapLegend()
            }
            .padding(14)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                model.isPlaying ? model.pause() : model.play()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "Pause the loop" : "Play the loop")
            .disabled(model.loadedCount < 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(timeText)
                    .font(.headline.monospacedDigit())
                if model.times.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(model.index) },
                            set: { model.scrub(to: Int($0.rounded())) }
                        ),
                        in: 0...Double(model.times.count - 1),
                        step: 1
                    )
                    .accessibilityLabel("Radar time")
                    .accessibilityValue(timeText)
                }
            }

            Button {
                recentreRequest += 1
            } label: {
                Image(systemName: "location.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to my location")
            .disabled(center == nil)
        }
    }

    private var timeText: String {
        if model.outsideCoverage { return "Radar covers the lower 48" }
        if model.failed { return "Radar unavailable" }
        guard model.times.indices.contains(model.index), model.visibleImage != nil else {
            return "Loading radar…"
        }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: model.times[model.index])
        return model.index == model.times.count - 1 ? "\(time) · latest" : time
    }
}

/// The loop: its frame times, the images fetched for the view on screen, and which is showing.
@MainActor
@Observable
final class RadarMapModel {
    /// An hour of frames at the composite's five-minute cadence.
    static let frameCount = 12
    /// How many frames are fetched at once. Enough to fill the loop in a few seconds, few
    /// enough that a pan never lands a burst on the server.
    static let concurrentRequests = 3

    private(set) var times: [Date] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var failed = false
    /// The view has panned somewhere the composite does not reach.
    private(set) var outsideCoverage = false
    /// The box the shown frames cover, and the frames for it so far.
    private(set) var box: MercatorBox?
    private(set) var images: [Date: CGImage] = [:]

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var fetch: Task<Void, Never>?

    var visibleImage: CGImage? {
        times.indices.contains(index) ? images[times[index]] : nil
    }

    var loadedCount: Int { images.count }

    func load() async {
        times = await RadarMapSource.shared.frameTimes(count: Self.frameCount)
        index = max(times.count - 1, 0)
    }

    /// Fetch every frame for a newly settled view.
    ///
    /// The newest comes first and replaces what is on screen only when it arrives, so a pan
    /// never flashes an empty map; the older ones follow a few at a time. A newer view
    /// cancels whatever is still outstanding for the old one.
    func request(box newBox: MercatorBox, pixelSize: CGSize) {
        guard newBox != box || images.isEmpty else { return }
        fetch?.cancel()
        outsideCoverage = !RadarMapSource.covers(newBox)
        guard !outsideCoverage else { return }
        let width = Int(pixelSize.width.rounded()), height = Int(pixelSize.height.rounded())
        fetch = Task { [weak self] in
            guard let self else { return }
            if times.isEmpty { await load() }
            let frames = times
            guard let newest = frames.last else {
                failed = true
                return
            }

            guard let first = await RadarMapSource.shared.image(
                box: newBox, width: width, height: height, time: newest
            ), !Task.isCancelled else {
                if !Task.isCancelled, images.isEmpty { failed = true }
                return
            }
            failed = false
            box = newBox
            images = [newest: first]
            index = frames.count - 1

            await withTaskGroup(of: (Date, CGImage?).self) { group in
                var pending = frames.dropLast().reversed().makeIterator()
                func next() {
                    guard let time = pending.next() else { return }
                    group.addTask {
                        (time, await RadarMapSource.shared.image(box: newBox, width: width, height: height, time: time))
                    }
                }
                for _ in 0..<Self.concurrentRequests { next() }
                for await (time, image) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let image { images[time] = image }
                    next()
                }
            }
            if !isPlaying, images.count > 1 { play() }
        }
    }

    func play() {
        guard images.count > 1 else { return }
        isPlaying = true
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Hold on the newest frame, the way the WeatherStar's loop does, so the
                // present is what the eye settles on.
                let hold: Duration = index == times.count - 1 ? .milliseconds(1600) : .milliseconds(450)
                try? await Task.sleep(for: hold)
                guard !Task.isCancelled else { return }
                index = nextLoadedIndex(after: index)
            }
        }
    }

    /// The next frame that has arrived, wrapping round; frames still in flight are skipped.
    private func nextLoadedIndex(after current: Int) -> Int {
        guard !times.isEmpty else { return 0 }
        for step in 1...times.count {
            let candidate = (current + step) % times.count
            if images[times[candidate]] != nil { return candidate }
        }
        return current
    }

    func pause() {
        isPlaying = false
        loop?.cancel()
        loop = nil
    }

    func scrub(to newIndex: Int) {
        pause()
        index = min(max(newIndex, 0), max(times.count - 1, 0))
    }

    func stop() {
        pause()
        fetch?.cancel()
    }
}

/// The reflectivity scale as IEM colours the composite, light to heavy.
///
/// IEM's own `n0q` palette at 10 to 75 dBZ in 5 dBZ steps, so the bar matches what is drawn.
private struct RadarMapLegend: View {
    private static let colours: [Color] = [
        0x4361A2, 0x5EADCF, 0x4BD690, 0x0FB714, 0x0B880F, 0x095E09, 0xEAD204,
        0xFFB100, 0xFF0000, 0xB10000, 0xFFF5FF, 0xFC6BFD, 0xAC00FC, 0x05EBF0,
    ].map { Color(hex: $0) }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(Self.colours.indices, id: \.self) { index in
                    Self.colours[index]
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())

            HStack {
                Text("Light")
                Spacer()
                Text("NEXRAD via Iowa Environmental Mesonet")
                Spacer()
                Text("Heavy")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Radar colour scale from light to heavy. NEXRAD radar via the Iowa Environmental Mesonet.")
    }
}
#endif
