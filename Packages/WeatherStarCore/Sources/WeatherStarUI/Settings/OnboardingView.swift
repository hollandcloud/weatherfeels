import SwiftUI
import WeatherStarKit

/// First-run flow: explain the app, get a location, optionally point at a music
/// source, then hand off to the displays.
///
/// Kept deliberately short — three steps, all skippable — because the app is usable
/// with nothing but a location, and that can come from the device.
public struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LocationService.self) private var locationService

    /// Called once onboarding is finished, so the host can start loading weather.
    private let onFinish: () -> Void

    @State private var step: Step
    @State private var isResolvingLocation = false
    @State private var locationError: String?
    @State private var searchText = ""
    @State private var searchResults: [SavedLocation] = []
    @State private var isSearching = false

    /// `startingAt` exists so a preview or snapshot test can render a later step
    /// directly; the app always starts at the beginning.
    public init(startingAt step: Step = .welcome, onFinish: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.onFinish = onFinish
    }

    public enum Step: Int, CaseIterable, Sendable {
        case welcome
        case location
        case music

        var title: String {
            switch self {
            case .welcome: "weatherfeels"
            case .location: "Choose a location"
            case .music: "Music (optional)"
            }
        }
    }

    public var body: some View {
        ZStack {
            // Fully opaque: onboarding can be re-entered from Settings while the
            // displays are running behind it, and a translucent backdrop made the
            // text unreadable. The gradient matches the displays' own palette.
            Color.black
                .ignoresSafeArea()
            LinearGradient(
                colors: [StarColor.backgroundTop, StarColor.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            content
                .frame(maxWidth: 820)
                .padding(.horizontal, 32)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .location: locationStep
        case .music: musicStep
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(Step.welcome.title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text(
                """
                A native recreation of The Weather Channel's WeatherStar 4000, \
                using live forecasts from the National Weather Service.
                """
            )
            .font(.title3)
            .foregroundStyle(.white.opacity(0.75))

            VStack(alignment: .leading, spacing: 12) {
                bullet("Local forecasts, radar, almanac and hazards on a rotating loop")
                bullet("Plays your own music in the background")
                bullet("No accounts, no tracking, no analytics")
            }

            Spacer()

            Button("Get Started") { step = .location }
                .buttonStyle(.borderedProminent)
                .font(.title3)
        }
        .padding(.vertical, 48)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text).foregroundStyle(.white)
        }
        .font(.body)
    }

    // MARK: - Location

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Step.location.title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("Forecasts come from the National Weather Service, so US locations only.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))

            Button {
                useDeviceLocation()
            } label: {
                HStack {
                    Image(systemName: "location.fill")
                    Text(isResolvingLocation ? "Locating…" : "Use this device's location")
                    if isResolvingLocation { ProgressView().padding(.leading, 4) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isResolvingLocation || locationService.isDenied)

            if locationService.isDenied {
                Text("Location access is off. Search for a place instead.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Divider().overlay(.white.opacity(0.3))

            Text("Or search for a place")
                .font(.headline)
                .foregroundStyle(.white)

            HStack {
                // tvOS has no bordered text field style; its fields already present
                // as focusable buttons that open the system keyboard.
                Group {
                    #if os(tvOS)
                    TextField("City, or ZIP code", text: $searchText)
                    #else
                    TextField("City, or ZIP code", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    #endif
                }
                .onSubmit(runSearch)

                Button("Search", action: runSearch)
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if isSearching {
                ProgressView()
            }

            if let locationError {
                Text(locationError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            // Results are tappable rows; picking one advances the flow.
            ForEach(searchResults) { result in
                Button {
                    select(result)
                } label: {
                    HStack {
                        Text(result.name)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            HStack {
                Button("Back") { step = .welcome }
                Spacer()
                Button("Skip") { skipLocation() }
            }
        }
        .padding(.vertical, 48)
    }

    private func useDeviceLocation() {
        isResolvingLocation = true
        locationError = nil
        Task {
            defer { isResolvingLocation = false }
            do {
                let location = try await locationService.currentLocation()
                settings.locationMode = .device
                settings.savedLocation = location
                settings.rememberRecent(location)
                step = .music
            } catch {
                locationError = error.localizedDescription
            }
        }
    }

    private func runSearch() {
        let query = searchText
        isSearching = true
        locationError = nil
        searchResults = []
        Task {
            defer { isSearching = false }
            do {
                searchResults = try await locationService.search(query)
            } catch {
                locationError = error.localizedDescription
            }
        }
    }

    private func select(_ location: SavedLocation) {
        settings.locationMode = .manual
        settings.savedLocation = location
        settings.rememberRecent(location)
        step = .music
    }

    private func skipLocation() {
        settings.locationMode = .manual
        step = .music
    }

    // MARK: - Music

    private var musicStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Step.music.title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text(
                """
                The app ships with four instrumental tracks. You can add your own \
                later in Settings — from this device, from a server you host, or \
                synced privately through iCloud.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            // `.switch` only reaches tvOS in 18.0; the default style is a switch on
            // every other platform anyway.
            #if os(tvOS)
            Toggle("Play music behind the displays", isOn: musicEnabledBinding)
            #else
            Toggle("Play music behind the displays", isOn: musicEnabledBinding)
                .toggleStyle(.switch)
            #endif

            Spacer()

            HStack {
                Button("Back") { step = .location }
                Spacer()
                Button("Start Watching") { finish() }
                    .buttonStyle(.borderedProminent)
                    .font(.title3)
            }
        }
        .padding(.vertical, 48)
    }

    private var musicEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.musicEnabled },
            set: { settings.musicEnabled = $0 }
        )
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        onFinish()
    }
}
