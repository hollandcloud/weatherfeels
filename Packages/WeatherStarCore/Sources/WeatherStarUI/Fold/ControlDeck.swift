import SwiftUI
import WeatherStarKit

/// Where the parts of the control deck sit, from the size of the pane it is given.
///
/// Split out from the drawing for the reason `TelevisionGeometry` is: the part that can be
/// wrong without anybody noticing is arithmetic — whether every button still clears the touch
/// floor on the smallest pane the deck is given. `ControlDeckLayoutTests` holds it to that.
struct ControlDeckLayout: Equatable {
    /// Inset from the pane's edges.
    let margin: CGFloat
    /// Between the deck's rows, and between buttons in a row.
    let spacing: CGFloat
    let readoutHeight: CGFloat
    let channelColumns: Int
    let channelHeight: CGFloat
    /// Whether the channel rows cannot all fit at the touch floor, and so scroll.
    let channelsScroll: Bool
    /// Edge of each transport button's square hit area.
    let transportTouch: CGFloat
    /// One row when the six fit across; otherwise the channel pair and the rest on two.
    let transportRows: Int

    /// Apple's floor for a touch target, the same one `TelevisionGeometry` holds to.
    static let minimumTouch: CGFloat = 44
    /// Settings, previous, hold, next, sound, power.
    static let transportCount = 6
    /// The narrowest pane that gets four columns of channels rather than two.
    ///
    /// Always an even number: Apple asks for even column counts on a device that folds, so a
    /// grid that spills across a crease never has a column sitting on it, and a deck of two or
    /// four columns stays symmetrical in either posture.
    static let fourColumnWidth: CGFloat = 520

    static func resolve(size: CGSize, channelCount: Int) -> ControlDeckLayout {
        let short = min(size.width, size.height)
        let margin = min(max(short * 0.045, 12), 24)
        let spacing = min(max(short * 0.02, 6), 12)
        let inner = CGSize(
            width: max(0, size.width - margin * 2),
            height: max(0, size.height - margin * 2)
        )

        let readoutHeight = min(max(inner.height * 0.16, 58), 80)

        // As large as a thumb would like, never under the floor. When even the floor will not
        // fit six across, the row breaks in two rather than shrinking the targets.
        let gaps = CGFloat(transportCount - 1)
        let acrossOneRow = (inner.width - spacing * gaps) / CGFloat(transportCount)
        let transportRows = acrossOneRow >= minimumTouch ? 1 : 2
        let acrossRow = transportRows == 1
            ? acrossOneRow
            : (inner.width - spacing * 2) / 3
        let transportTouch = max(minimumTouch, min(inner.height * 0.13, 58, acrossRow))
        let transportHeight = transportTouch * CGFloat(transportRows)
            + spacing * CGFloat(transportRows - 1)

        let columns = inner.width >= fourColumnWidth ? 4 : 2
        let rows = max(1, Int((Double(channelCount) / Double(columns)).rounded(.up)))
        let gridHeight = inner.height - readoutHeight - transportHeight - spacing * 2
        let fitted = (gridHeight - spacing * CGFloat(rows - 1)) / CGFloat(rows)

        return ControlDeckLayout(
            margin: margin,
            spacing: spacing,
            readoutHeight: readoutHeight,
            channelColumns: columns,
            channelHeight: min(max(fitted, minimumTouch), 56),
            channelsScroll: fitted < minimumTouch,
            transportTouch: transportTouch,
            transportRows: transportRows
        )
    }
}

/// What the control deck shows and what its buttons do.
///
/// Values and closures rather than the engine and the store, for the reason
/// `TelevisionControls` gives: the deck stays a drawing, the decisions stay with the view that
/// owns the state, and a snapshot test can build one from nothing.
struct ControlDeckContent {
    struct Channel: Identifiable, Equatable, Sendable {
        let display: DisplayIdentifier
        /// Whether the display has data. A channel with nothing on it cannot be tuned to:
        /// `DisplayEngine.jump(to:)` ignores a display that is not ready, so a button that
        /// looked live would do nothing when pressed.
        let isReady: Bool
        var id: DisplayIdentifier { display }
    }

    /// The enabled displays, in rotation order.
    var channels: [Channel]
    var activeDisplay: DisplayIdentifier?
    /// The readout's second line: where, and what the weather is doing there.
    var conditions: String
    /// The track playing behind the displays, if one is.
    var nowPlaying: String?
    /// Whether the rotation is advancing, rather than holding on one display.
    var isRotating: Bool
    var isSoundOn: Bool
    var isPictureOn: Bool
    /// The time as the screen's own clock shows it, in the forecast location's zone.
    var clock: (Date) -> String
    /// How often the clock needs redrawing: every second when it shows seconds.
    var clockInterval: TimeInterval
    var onSelect: (DisplayIdentifier) -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onToggleRotation: () -> Void
    var onToggleSound: () -> Void
    var onSettings: () -> Void
    var onPower: () -> Void
}

/// The set's front panel, for a screen folded so that half of it is free to be one.
///
/// Stand iPhone Duo on a table like a laptop and the lower half lies flat — the steadiest
/// surface a phone ever offers a finger, and the one Apple asks apps to put their controls on.
/// Rather than float the usual tap-to-show controls over the picture, that half becomes what
/// a set of the period had under its tube: a fluorescent readout, a bank of preset buttons, and
/// the transport. It is moulded in the cabinet's own finish, so it reads as the same set.
///
/// The presets are the useful part. Everywhere else the rotation can only be stepped through
/// one display at a time; here each display is a button, lit while it is on, so the radar is
/// one press away. Displays still loading are dimmed and cannot be pressed.
///
/// The same deck is the trailing page when the device is held like a book: there it is taller
/// than wide and lays its presets out in two columns.
struct ControlDeck: View {
    let content: ControlDeckContent
    let finish: TelevisionFinish
    /// Safe-area insets that fall on this pane. The panel's plastic runs under them; the
    /// buttons stay clear of them.
    var insets = EdgeInsets()

    /// Phosphor green-blue, the colour of a vacuum fluorescent display.
    private static let readoutInk = Color(red: 0.42, green: 0.96, blue: 0.86)
    private static let lampOn = Color(red: 0.95, green: 0.20, blue: 0.12)
    private static let lampOff = Color(red: 0.24, green: 0.09, blue: 0.08)

    var body: some View {
        GeometryReader { proxy in
            let layout = ControlDeckLayout.resolve(
                size: proxy.size, channelCount: content.channels.count
            )
            VStack(spacing: layout.spacing) {
                readout(layout)
                channels(layout)
                transport(layout)
            }
            .padding(layout.margin)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(insets)
        .background { panel }
    }

    // MARK: - Panel

    private var panel: some View {
        ZStack {
            LinearGradient(
                colors: [finish.cabinetTop, finish.cabinetBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            if finish == .woodgrain {
                VeneerGrain()
            }
        }
        // The moulded edge that faces the crease catches the light, the way the cabinet's
        // top edge does.
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.white.opacity(0.16), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 3)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Readout

    private var headline: String {
        guard content.isPictureOn else { return "STANDBY" }
        return content.activeDisplay?.name.uppercased() ?? "TUNING IN"
    }

    private func readout(_ layout: ControlDeckLayout) -> some View {
        let large = layout.readoutHeight * 0.25
        let small = layout.readoutHeight * 0.19

        return TimelineView(.periodic(from: .now, by: content.clockInterval)) { timeline in
            let time = content.clock(timeline.date)
            VStack(alignment: .leading, spacing: layout.readoutHeight * 0.07) {
                HStack(alignment: .firstTextBaseline) {
                    Text(headline)
                        .font(.system(size: large, weight: .semibold, design: .monospaced))
                    Spacer(minLength: 12)
                    Text(time)
                        .font(.system(size: large, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                }
                // A set in standby keeps its clock lit and nothing else — which is also what
                // tells someone glancing at it that it is off rather than broken.
                if content.isPictureOn {
                    HStack(alignment: .firstTextBaseline) {
                        Text(content.conditions)
                        Spacer(minLength: 12)
                        if let nowPlaying = content.nowPlaying {
                            Text("♪ \(nowPlaying)")
                                .truncationMode(.tail)
                        }
                    }
                    .font(.system(size: small, weight: .regular, design: .monospaced))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Self.readoutInk)
            .shadow(color: Self.readoutInk.opacity(0.6), radius: 3)
            .padding(.horizontal, layout.readoutHeight * 0.22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(readoutGlass)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                [headline.capitalized, time, content.isPictureOn ? content.conditions : nil]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
        }
        .frame(height: layout.readoutHeight)
    }

    /// Dark smoked glass set into the panel.
    private var readoutGlass: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(red: 0.015, green: 0.03, blue: 0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.black.opacity(0.7), .white.opacity(0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
            )
    }

    // MARK: - Presets

    @ViewBuilder
    private func channels(_ layout: ControlDeckLayout) -> some View {
        let grid = LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: layout.spacing),
                count: layout.channelColumns
            ),
            spacing: layout.spacing
        ) {
            ForEach(content.channels) { channel in
                channelButton(channel, height: layout.channelHeight)
            }
        }

        if layout.channelsScroll {
            ScrollView { grid }
                .frame(maxHeight: .infinity)
        } else {
            grid.frame(maxHeight: .infinity)
        }
    }

    private func channelButton(
        _ channel: ControlDeckContent.Channel, height: CGFloat
    ) -> some View {
        let isOn = content.isPictureOn && channel.display == content.activeDisplay

        return Button { content.onSelect(channel.display) } label: {
            VStack(spacing: height * 0.12) {
                lamp(isOn: isOn, size: 5)
                Text(channel.display.presetLabel)
                    .font(.system(size: min(13, height * 0.28), weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(channel.isReady ? 0.72 : 0.24))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(MouldedFace(cornerRadius: 6, isLit: isOn))
            .contentShape(Rectangle())
        }
        .buttonStyle(DeckButtonStyle())
        .disabled(!channel.isReady)
        .accessibilityLabel(channel.display.name)
        .accessibilityValue(channel.isReady ? "" : "Loading")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Transport

    @ViewBuilder
    private func transport(_ layout: ControlDeckLayout) -> some View {
        let touch = layout.transportTouch
        let settings = transportButton("gearshape.fill", label: "Settings", touch: touch, action: content.onSettings)
        let previous = transportButton("backward.fill", label: "Previous display", touch: touch, action: content.onPrevious)
        let hold = transportButton(
            content.isRotating ? "pause.fill" : "play.fill",
            label: content.isRotating ? "Hold this display" : "Resume the rotation",
            touch: touch,
            action: content.onToggleRotation
        )
        let next = transportButton("forward.fill", label: "Next display", touch: touch, action: content.onNext)
        let sound = transportButton(
            content.isSoundOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
            label: content.isSoundOn ? "Mute" : "Unmute",
            touch: touch,
            action: content.onToggleSound
        )
        let power = transportButton(
            "power",
            label: content.isPictureOn ? "Turn the picture off" : "Turn the picture on",
            touch: touch,
            showsLamp: true,
            action: content.onPower
        )

        if layout.transportRows == 1 {
            // Settings at one end and the set's own switches at the other, with the channel
            // controls between them, the way the cabinet's chin orders them.
            HStack(spacing: layout.spacing) {
                settings
                Spacer(minLength: 0)
                previous
                hold
                next
                Spacer(minLength: 0)
                sound
                power
            }
        } else {
            VStack(spacing: layout.spacing) {
                HStack(spacing: layout.spacing) { previous; hold; next }
                HStack(spacing: layout.spacing) { settings; sound; power }
            }
        }
    }

    private func transportButton(
        _ symbol: String,
        label: String,
        touch: CGFloat,
        showsLamp: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: touch * 0.34, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: touch, height: touch)
                .background(MouldedFace(cornerRadius: touch * 0.18, isLit: false))
                .overlay(alignment: .topTrailing) {
                    if showsLamp {
                        lamp(isOn: content.isPictureOn, size: 6)
                            .padding(touch * 0.12)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(DeckButtonStyle())
        .accessibilityLabel(label)
    }

    private func lamp(isOn: Bool, size: CGFloat) -> some View {
        Circle()
            .fill(isOn ? Self.lampOn : Self.lampOff)
            .frame(width: size, height: size)
            .shadow(color: Self.lampOn.opacity(isOn ? 0.9 : 0), radius: size * 0.7)
            .animation(.easeInOut(duration: 0.2), value: isOn)
    }
}

/// A button's face, moulded from the same plastic as the cabinet's.
private struct MouldedFace: View {
    let cornerRadius: CGFloat
    /// A preset that is on is backlit very slightly, as the lamp behind it spills.
    let isLit: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [televisionButtonTop, televisionButtonBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isLit ? 0.22 : 0.10), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
    }
}

/// Pressed buttons sink a little and darken, the way a moulded key does under a thumb.
private struct DeckButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension DisplayIdentifier {
    /// A name short enough to print on a preset button.
    ///
    /// The deck's own vocabulary rather than `header`, which is split for the two lines of the
    /// on-screen title and reads oddly on one ("Latest" alone says nothing).
    var presetLabel: String {
        switch self {
        case .hazards: "Hazards"
        case .currentWeather: "Current"
        case .latestObservations: "Latest Obs"
        case .hourly: "Hourly"
        case .hourlyGraph: "Hour Graph"
        case .travel: "Travel"
        case .regionalForecast: "Regional"
        case .localForecast: "Local"
        case .extendedForecast: "Extended"
        case .almanac: "Almanac"
        case .spcOutlook: "Outlook"
        case .radar: "Radar"
        }
    }
}
