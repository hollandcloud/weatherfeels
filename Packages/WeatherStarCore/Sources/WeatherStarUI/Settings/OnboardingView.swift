import SwiftUI
import WeatherStarKit

/// First-run flow: explain the app, get a location, optionally point at a music
/// source, then hand off to the displays.
///
/// Kept deliberately short — three steps, all skippable — because the app is usable
/// with nothing but a location, and that can come from the device.
/// Which half of the onboarding location step is on screen.
///
/// Split out as its own type because the rule it encodes is one App Review enforces, and
/// a rule worth enforcing is worth testing. Guideline 5.1.1(iv): a custom message shown
/// ahead of a permission request must lead into that request and nowhere else — no Skip,
/// no Back, no button phrased to talk the user into saying yes. Once the prompt has been
/// answered, none of that applies any more and the step is an ordinary place picker.
enum LocationStepStage: Equatable {
    /// Nothing has been asked yet. One button, and it opens the system prompt.
    case permissionPrompt
    /// The prompt has been answered, either way. Search, results, Back and Skip.
    case placePicker

    init(hasAnsweredAuthorization: Bool) {
        self = hasAnsweredAuthorization ? .placePicker : .permissionPrompt
    }

    /// Whether the step may offer any way past it other than the permission prompt.
    ///
    /// This is the specific thing the app was rejected for: a "Skip" button on the
    /// pre-prompt screen let the user defer the request indefinitely.
    var allowsDismissal: Bool { self == .placePicker }

    /// Whether the step may talk about picking a place by hand.
    ///
    /// Also false before the prompt: offering a search field alongside the explanation
    /// is another way of making the request skippable.
    var showsPlaceSearch: Bool { self == .placePicker }
}

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

    private var stage: LocationStepStage {
        LocationStepStage(hasAnsweredAuthorization: locationService.hasAnsweredAuthorization)
    }

    private var locationStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Step.location.title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            switch stage {
            case .permissionPrompt: permissionPrompt
            case .placePicker: placePicker
            }
        }
        .padding(.vertical, 48)
    }

    /// Everything shown before the system location prompt has been answered.
    ///
    /// Deliberately one button, phrased neutrally, and no way around it. App Review
    /// rejected the previous version of this screen under guideline 5.1.1(iv) on two
    /// counts: the button read "Use this device's location", which is a nudge towards
    /// one answer, and a "Skip" button let the request be deferred for good. The text
    /// below explains what the prompt is for without arguing for a particular answer,
    /// and "Continue" leads straight into it.
    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                """
                Forecasts come from the US National Weather Service, so the app needs a \
                place to show them for — either where this device is, or a US city you \
                name yourself. Continue to choose.
                """
            )
            .font(.callout)
            .foregroundStyle(.white.opacity(0.75))

            Button {
                continueToPermissionPrompt()
            } label: {
                HStack {
                    Text(isResolvingLocation ? "Locating…" : "Continue")
                    if isResolvingLocation { ProgressView().padding(.leading, 4) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isResolvingLocation)

            if let locationError {
                Text(locationError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
    }

    /// Everything shown once the prompt has been answered, whichever way it went.
    private var placePicker: some View {
        VStack(alignment: .leading, spacing: 20) {
            if locationService.isDenied {
                Text("Location access is off. Search for a place instead.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Text("Search for a place")
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

                // Only a retry, and only once access is already granted, so it cannot
                // produce a permission prompt however it is labelled.
                if !locationService.isDenied {
                    Button("Try this device again") { resolveDeviceLocation() }
                        .disabled(isResolvingLocation)
                }
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

            if stage.allowsDismissal {
                HStack {
                    Button("Back") { step = .welcome }
                    Spacer()
                    Button("Skip") { skipLocation() }
                }
            }
        }
    }

    /// The only action available before the prompt: open it, then act on the answer.
    private func continueToPermissionPrompt() {
        isResolvingLocation = true
        locationError = nil
        Task {
            // Returns once the user has answered. Whatever they chose, the step moves on
            // to the place picker — the answer is what un-gates the rest of the screen.
            await locationService.requestAuthorization()
            guard !locationService.isDenied else {
                isResolvingLocation = false
                return
            }
            await resolveFix()
        }
    }

    private func resolveDeviceLocation() {
        isResolvingLocation = true
        locationError = nil
        Task { await resolveFix() }
    }

    private func resolveFix() async {
        defer { isResolvingLocation = false }
        do {
            let location = try await locationService.currentLocation()
            settings.locationMode = .device
            settings.savedLocation = location
            settings.rememberRecent(location)
            step = .music
        } catch {
            // Left on the place picker with the reason showing, rather than blocked.
            locationError = error.localizedDescription
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
