import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import WeatherStarKit

/// Top-level view: runs onboarding on first launch, then the display rotation.
///
/// Owns the shared objects and injects them into the environment, so the app targets
/// stay as thin as `WindowGroup { RootView() }`.
public struct RootView: View {
    @State private var settings: AppSettings
    @State private var engine: DisplayEngine
    @State private var store: WeatherStore
    @State private var locationService: LocationService
    @State private var musicLibrary: MusicLibrary
    @State private var musicPlayer: MusicPlayer
    @State private var soundEffects = SoundEffects()
    @State private var transfer: MusicTransfer

    @Environment(\.scenePhase) private var scenePhase

    /// Whether the television is switched on.
    ///
    /// The power button on the cabinet blanks the picture and silences the music the way
    /// the one on a real set did, rather than quitting: an iOS app terminating itself is
    /// both discouraged and useless here, and the interesting thing to have is a set that
    /// can be switched off on a desk without losing where the rotation had got to.
    ///
    /// The rotation itself keeps running behind the dark glass, so switching back on shows
    /// current weather rather than a stale frame. That is the one way this differs from
    /// backgrounding the app, which stops the engine as well.
    @State private var isPictureOn = true

    /// Size of the weather screen, so `showsCabinet` can be answered anywhere.
    ///
    /// Reported by a zero-impact `GeometryReader` in the background rather than wrapping
    /// the screen in one: a `GeometryReader` in the layout path fills its parent and
    /// anchors top-leading, which would move the picture.
    @State private var containerSize: CGSize = .zero

    @State private var isShowingSettings = false
    @State private var isShowingControls = false
    /// Whether music was playing when the app went to the background, so it can be
    /// resumed on return.
    @State private var wasPlayingBeforeBackground = false
    /// Ensures the one-off controls reveal happens only on the first load.
    @State private var hasRevealedControlsOnce = false
    @State private var controlsHideTask: Task<Void, Never>?

    public init() {
        let settings = AppSettings.shared
        let engine = DisplayEngine()
        _settings = State(initialValue: settings)
        _engine = State(initialValue: engine)
        _store = State(initialValue: WeatherStore(settings: settings, engine: engine))
        _locationService = State(initialValue: LocationService.shared)
        _musicLibrary = State(initialValue: MusicLibrary(settings: settings))
        _musicPlayer = State(initialValue: MusicPlayer())
        _transfer = State(initialValue: MusicTransfer(settings: settings))
    }

    public var body: some View {
        content
            .environment(settings)
            .environment(engine)
            .environment(store)
            .environment(locationService)
            .environment(musicLibrary)
            .environment(musicPlayer)
            .environment(transfer)
            .task { await start() }
            // Keep the engine's copy of the user's preferences current.
            .onChange(of: settings.speed) { engine.speedMultiplier = settings.speed.multiplier }
            .onChange(of: settings.enabledDisplayIDs) { syncEnabledDisplays() }
            .onChange(of: settings.units) { reloadForSettingsChange() }
            .onChange(of: settings.musicEnabled) { applyMusicState() }
            // Changing source or playlist has to re-queue, not just toggle play state.
            .onChange(of: settings.musicSource) { Task { await loadMusic() } }
            .onChange(of: settings.appleMusicPlaylistID) { Task { await loadMusic() } }
            .onChange(of: settings.musicVolume) { musicPlayer.volume = settings.musicVolume }
            .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
    }

    @ViewBuilder
    private var content: some View {
        if settings.hasCompletedOnboarding {
            weatherScreen
        } else {
            OnboardingView {
                Task { await start() }
            }
            .environment(settings)
            .environment(locationService)
        }
    }

    // MARK: - Weather screen

    private var weatherScreen: some View {
        ZStack {
            #if os(tvOS)
            // The remote needs *something* focusable for Select and the d-pad to reach,
            // but it must not be a full-screen view. tvOS draws its own focus treatment
            // on whatever holds focus — a light rounded-rect wash with everything behind
            // it blurred — and `.focusEffectDisabled()` does not suppress it for a plain
            // Button. At full screen that treatment *was* the white overlay washing out
            // the display.
            //
            // So: one point across, and placed under the opaque display rather than over
            // it. It still receives every remote event while having nowhere to draw.
            //
            // The remote handlers hang off this button rather than off `WeatherStarView`
            // because tvOS delivers them to the focused view and its ancestors, and the
            // display is this button's *sibling* — handlers there would never fire. Its
            // `if` also gives them exactly the right lifetime: `onMoveCommand` consumes
            // the d-pad, and while the controls are up the focus engine needs the d-pad
            // to move between them, so the handlers must disappear along with the button.
            if !isShowingControls {
                Button { showControls() } label: {
                    Color.clear.frame(width: 1, height: 1)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .frame(width: 1, height: 1)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: engine.previousDisplay()
                    case .right: engine.nextDisplay()
                    case .up, .down: showControls()
                    default: break
                    }
                }
            }
            #endif

            WeatherStarView(
                isPictureOn: isPictureOn,
                onOpenSettings: { isShowingSettings = true },
                onPower: togglePower
            )

            if isShowingControls {
                ControlsOverlay(
                    isPlaying: engine.isPlaying,
                    trackTitle: musicPlayer.currentTrackTitle,
                    isMusicPlaying: musicPlayer.isPlaying,
                    isPictureOn: isPictureOn,
                    onPlayPause: { engine.isPlaying.toggle() },
                    onPrevious: { engine.previousDisplay() },
                    onNext: { engine.nextDisplay() },
                    onToggleMusic: toggleMusic,
                    onSettings: {
                        hideControls()
                        isShowingSettings = true
                    },
                    onPower: togglePower,
                    onDismiss: hideControls,
                    onInteraction: showControls
                )
                .transition(.opacity)
            }
        }
        #if os(tvOS)
        // On the container, not on the focusable button: Play/Pause is not a
        // focus-navigation event, so it is safe to handle at every level and should keep
        // working while the controls are on screen.
        .onPlayPauseCommand { engine.isPlaying.toggle() }
        #else
        .onTapGesture { isShowingControls ? hideControls() : showControls() }
        #endif
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in containerSize = size }
            }
        }
        // Rotating a phone into portrait brings the set up under an overlay that is already
        // showing; two sets of controls at once is exactly what this change exists to stop.
        .onChange(of: showsCabinet) { _, nowShowing in
            if nowShowing { hideControls() }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingControls)
        #if os(tvOS)
        .fullScreenCover(isPresented: $isShowingSettings) { settingsScreen }
        #else
        .sheet(isPresented: $isShowingSettings) { settingsScreen }
        #endif
        #if os(macOS)
        // Keyboard control on the Mac, where there is no remote and tapping is fiddly.
        .background {
            Group {
                Button("") { engine.nextDisplay() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { engine.previousDisplay() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { engine.isPlaying.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .opacity(0)
        }
        #endif
    }

    private var settingsScreen: some View {
        ZStack {
            // A Form draws no background of its own on tvOS, so the weather display
            // showed straight through and washed the options out.
            //
            // Fully opaque, and deliberately *no* material. Materials sample what is
            // behind them, so on tvOS both `.regularMaterial` and `.ultraThinMaterial`
            // lightened this panel back to near-white — and with the Form's text light
            // in dark mode the options vanished. A flat dark fill with a subtle
            // gradient gives depth without that risk.
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // tvOS has no sheet dismiss affordance and Menu does not close a
            // `fullScreenCover`, so the way out is a row inside the Form. It used to be a
            // button floated over the top-trailing corner, which worked on the root page
            // but not on a picker's option list: there the rows start at the very top, so
            // it landed on the first one — and the first row is the focused one. A focused
            // tvOS row is white, and the button's own background is a material, so it
            // sampled that white row and went white too. The result was white "Close" on
            // white, which is unreadable.
            SettingsView { location in
                store.load(location: location)
            }
            .environment(settings)
            .environment(locationService)
            .environment(musicLibrary)
            .environment(transfer)
            .environment(musicPlayer)
        }
        // Pinned dark at the *presentation* level rather than by overriding
        // `EnvironmentValues.colorScheme`.
        //
        // The panel's base is a dark gradient whatever the system appearance is, so the
        // text has to resolve light. Setting the environment value alone only tells
        // SwiftUI's own drawing: the platform still derives its chrome — a Form's row
        // fills, a focus highlight, an AppKit `Picker` menu — from the real UIKit/AppKit
        // appearance. In light mode that gave light rows with white labels on them.
        // `preferredColorScheme` sets the appearance itself, so the two agree.
        .preferredColorScheme(.dark)
    }

    // MARK: - Startup

    private func start() async {
        guard settings.hasCompletedOnboarding else { return }

        StarFontLoader.registerFonts()
        engine.speedMultiplier = settings.speed.multiplier
        musicPlayer.volume = settings.musicVolume
        syncEnabledDisplays()

        await loadMusic()
        await resolveLocationAndLoad()

        // Reveal the controls once on launch: without this there is no hint that a
        // Settings button exists at all.
        if !hasRevealedControlsOnce {
            hasRevealedControlsOnce = true
            showControls()
        }
    }

    /// Resolve which location to show, preferring a fresh device fix when the user
    /// has chosen to follow the device.
    private func resolveLocationAndLoad() async {
        if settings.locationMode == .device {
            // Draw the last known place immediately so the screen is not empty while
            // a new fix is acquired. Without a cached device location, do not ask for
            // permission here; the request belongs to the explicit onboarding/settings
            // action that selects device location.
            guard let cached = settings.savedLocation else { return }
            store.load(location: cached)

            if let fresh = try? await locationService.currentLocation() {
                // Only reload when the point moved enough to change the forecast grid.
                let moved = Calc.haversineKilometers(
                    lat1: cached.latitude, lon1: cached.longitude,
                    lat2: fresh.latitude, lon2: fresh.longitude
                ) > 2
                settings.savedLocation = fresh
                if moved { store.load(location: fresh) }
                return
            }
        }

        if let location = settings.savedLocation {
            store.load(location: location)
        }
    }

    private func reloadForSettingsChange() {
        guard let location = settings.savedLocation else { return }
        store.load(location: location)
    }

    private func syncEnabledDisplays() {
        engine.enabledDisplays = DisplayIdentifier.rotationOrder.filter { settings.isEnabled($0) }
    }

    // MARK: - Music

    private func loadMusic() async {
        await musicLibrary.reload()

        // Apple Music is queued by playlist rather than by track: its items have no file
        // URL for the app's own player to open, so MusicKit plays the playlist directly.
        if settings.musicSource == .appleMusic, let id = settings.appleMusicPlaylistID {
            musicPlayer.loadAppleMusicPlaylist(id: id)
        } else {
            musicPlayer.load(tracks: musicLibrary.tracks, shuffle: settings.musicShuffle)
        }
        applyMusicState()
    }

    private func applyMusicState() {
        if MusicGate.shouldPlay(musicEnabled: settings.musicEnabled, isSetOn: isPictureOn) {
            musicPlayer.play()
        } else {
            musicPlayer.pause()
        }
    }

    private func toggleMusic() {
        settings.musicEnabled.toggle()
    }

    /// The cabinet's power button: the picture and the sound together.
    ///
    /// `musicEnabled` is deliberately left alone. It is the user's standing preference, and
    /// standby is a gate on top of it — switching the set off must not read as switching
    /// music off, or switching it back on would leave the music silent while Settings still
    /// said it was enabled.
    private func togglePower() {
        isPictureOn.toggle()
        // Before the music state, so the thump lands with the picture rather than after
        // the music has already stopped.
        soundEffects.play(isPictureOn ? .powerOn : .powerOff)
        applyMusicState()
    }

    /// Stop the music and the rotation when the app is no longer on screen.
    ///
    /// The audio session is configured for playback so a track is not chopped off
    /// mid-transition, but ambient weather music has no business continuing after the
    /// user leaves — so it is paused explicitly here and resumed on return.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            engine.isPlaying = true
            setIdleTimerDisabled(true)
            // Through `applyMusicState` rather than `play()` directly, so returning to a
            // set that was switched off does not start the music up again.
            if wasPlayingBeforeBackground {
                applyMusicState()
            }
            wasPlayingBeforeBackground = false
        case .inactive, .background:
            wasPlayingBeforeBackground = musicPlayer.isPlaying
            musicPlayer.pause()
            // Also stop advancing displays; nothing is visible and it wastes power.
            engine.isPlaying = false
            setIdleTimerDisabled(false)
        @unknown default:
            break
        }
    }

    /// Keep the screen saver away while the displays are on show.
    ///
    /// Apple TV has no idea this app is doing anything: the rotation redraws without any
    /// user input, so tvOS counts the whole session as idle and the screen saver takes
    /// over mid-forecast. The same applies to a phone or iPad propped up as a weather
    /// display.
    ///
    /// Released whenever the app is not active, so nothing keeps a device awake in the
    /// background.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    // MARK: - Controls visibility

    /// Whether the cabinet is on screen, and therefore *is* the control surface.
    ///
    /// The same rule `WeatherStarView` draws by, so the two cannot disagree about whether
    /// there are buttons on screen — a disagreement here is not cosmetic, it is either two
    /// competing control surfaces or none at all.
    private var showsCabinet: Bool {
        TelevisionPresentation.isShowing(
            layoutMode: settings.layoutMode,
            showsInLandscape: settings.televisionInLandscape,
            container: containerSize
        )
    }

    private func showControls() {
        // When the set is on screen it is the control surface, and this floating overlay
        // would be a second one competing with a better one. The cabinet covers everything
        // it offered — settings, both directions, mute and power — with play/pause still on
        // the Apple TV remote's own button.
        //
        // Only while the cabinet is actually drawn. Without it this overlay is the only way
        // to reach anything, so it has to come back the moment the set does not.
        if showsCabinet { return }
        isShowingControls = true
        controlsHideTask?.cancel()
        // Idle timeout, restarted by any remote movement, so the controls stay up while
        // in use and fade once the remote goes quiet.
        #if os(tvOS)
        let timeout: Duration = .seconds(5)
        #else
        let timeout: Duration = .seconds(6)
        #endif
        controlsHideTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            isShowingControls = false
        }
    }

    private func hideControls() {
        controlsHideTask?.cancel()
        isShowingControls = false
    }
}

/// Transport controls shown over the display on demand.
struct ControlsOverlay: View {
    /// Focus is held by the first button rather than the container: applying
    /// `.focused()` to this full-screen view made tvOS paint its focus highlight over
    /// the entire screen.
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case previous, playPause, next, music, settings, power
    }

    let isPlaying: Bool
    let trackTitle: String
    let isMusicPlaying: Bool
    /// Whether the television is on, for the power control's icon.
    let isPictureOn: Bool
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToggleMusic: () -> Void
    let onSettings: () -> Void
    /// Switches the set off and on.
    ///
    /// The cabinet has a power button of its own, but it is unreachable on Apple TV: the
    /// focus engine never gets the d-pad, because `weatherScreen`'s one-point button
    /// consumes it to move between displays. Putting power here — the surface that is
    /// already focusable, and the only one the remote can reach — is what makes standby
    /// work on a television at all.
    let onPower: () -> Void
    let onDismiss: () -> Void
    /// Fired on any remote movement, so the host can restart its idle timer.
    var onInteraction: () -> Void = {}

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 28) {
                button("backward.end.fill", action: onPrevious)
                    .focused($focusedControl, equals: .previous)
                button(isPlaying ? "pause.fill" : "play.fill", action: onPlayPause)
                    .focused($focusedControl, equals: .playPause)
                button("forward.end.fill", action: onNext)
                    .focused($focusedControl, equals: .next)

                Divider().frame(height: 28).overlay(.white.opacity(0.4))

                button(isMusicPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill", action: onToggleMusic)
                    .focused($focusedControl, equals: .music)
                button("gearshape.fill", action: onSettings)
                    .focused($focusedControl, equals: .settings)
                button(isPictureOn ? "power" : "power.circle", action: onPower)
                    .focused($focusedControl, equals: .power)
            }
            #if os(tvOS)
            // Land focus on Settings, since that is what the overlay mostly exists for.
            .onAppear { focusedControl = .settings }
            // Moving between controls means the remote is in use; keep them visible.
            //
            // Only a move between two real controls counts. The initial assignment
            // (nil → settings) and focus dropping away (settings → nil) are the focus
            // engine settling, not the user — and tvOS emits those repeatedly, which
            // restarted the idle timer forever so the controls never faded at all.
            .onChange(of: focusedControl) { previous, current in
                guard let previous, let current, previous != current else { return }
                onInteraction()
            }
            #endif
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(.black.opacity(0.75), in: Capsule())

            if isMusicPlaying {
                Text(trackTitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 10)
            }
        }
        .padding(.bottom, 48)
    }

    private func button(_ systemName: String, action: @escaping () -> Void) -> some View {
        // tvOS needs the default button style so the focus engine draws a focus ring;
        // `.plain` renders no focus indication at all, leaving the user unable to tell
        // which control the remote is on.
        #if os(tvOS)
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .frame(width: 54, height: 54)
        }
        #else
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        #endif
    }
}
