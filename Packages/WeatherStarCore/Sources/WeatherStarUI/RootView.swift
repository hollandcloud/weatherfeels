import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS) && canImport(WidgetKit)
import WidgetKit
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
    @State private var ads = AdsLibrary()
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

    /// How the screen is folded, read once here for the whole window.
    ///
    /// The single reading of the fold: the picture, the control deck and onboarding all take
    /// it from here rather than asking the system themselves, so none of them can place the
    /// crease somewhere the others do not.
    @State private var foldPosture: FoldPosture = .flat
    /// The hinge's angle in degrees while it is partly open, for the glass's reflection.
    @State private var hingeAngle: Double?

    @State private var isShowingSettings = false
    /// The zoomable radar map, on the platforms that have one.
    @State private var isShowingRadarMap = false
    /// Set by Settings' "Radar map" row, so the map opens once the sheet has finished going
    /// away rather than trying to present over it.
    @State private var opensRadarMapAfterSettings = false
    /// The weather bulletin on screen, and when it went up.
    @State private var bulletin: (bulletin: WeatherBulletin, shownAt: Date)?
    @State private var bulletinDismissal: Task<Void, Never>?
    /// The Local on the 8s bumper is up, ahead of its segment.
    @State private var showsEightsBumper = false
    /// The ad card on screen in an ad break, with its image.
    @State private var adCard: (card: AdCard, image: CGImage?)?
    /// A clip from the reel playing in an ad break.
    @State private var clip: ClipPlayback?
    /// Deals each break's ads from the cards and clips together, shuffled.
    @State private var adShuffle = AdShuffle()
    /// The ads still to come in the break on screen.
    @State private var breakQueue: [AdSpot] = []
    /// Moves a card's break on when its time is up.
    @State private var adBreakEnd: Task<Void, Never>?
    /// Displays shown since the last ad break.
    @State private var displaysSinceBreak = 0
    /// Whether the scene is in front, kept as state.
    ///
    /// `scenePhase` is an environment value, and read from a long-running task it is the value
    /// from when the task began — `.inactive`, at launch — however long ago that was. State is
    /// read live, so the bulletin and Local on the 8s check this instead.
    @State private var isSceneActive = false
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
            .environment(\.foldPosture, foldPosture)
            // Read over the whole window, safe area included, so the crease's frame is in the
            // same coordinates as `FoldSplit`, which lays things out around it.
            //
            // Inside a `GeometryReader` that ignores the safe area, not on a background view
            // that does: on the Duo the plain view stayed 34pt short of the bottom edge, and a
            // crease measured against a different box from the one it is drawn in lands in the
            // wrong place as soon as an inset falls on a leading edge.
            .background {
                GeometryReader { _ in
                    Color.clear
                        .onFoldChange(
                            posture: { foldPosture = $0 },
                            hingeAngle: { hingeAngle = $0 }
                        )
                }
                .ignoresSafeArea()
            }
            .environment(settings)
            .environment(engine)
            .environment(store)
            .environment(locationService)
            .environment(musicLibrary)
            .environment(musicPlayer)
            .environment(transfer)
            .environment(ads)
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
            // Initially as well as on change: a Mac window can start active and never change,
            // which would leave `isSceneActive` false and the bulletin never shown.
            .onChange(of: scenePhase, initial: true) { _, phase in handleScenePhase(phase) }
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
                Button { bulletin != nil ? dismissBulletin() : showControls() } label: {
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

            if case .folded(let posture) = screenLayout {
                foldedScreen(posture)
            } else {
                WeatherStarView(
                    isPictureOn: isPictureOn,
                    bulletin: bulletin,
                    showsEightsBumper: showsEightsBumper,
                    adCard: adCard,
                    clipPlayer: clip?.player,
                    onOpenSettings: { isShowingSettings = true },
                    onPower: togglePower
                )
            }

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
                    onRadarMap: radarMapAction {
                        hideControls()
                        isShowingRadarMap = true
                    },
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
        .onTapGesture {
            if bulletin != nil {
                dismissBulletin()
            } else if adCard != nil || clip != nil {
                endAdBreak()
            } else {
                isShowingControls ? hideControls() : showControls()
            }
        }
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
        // Bending a Duo's screen brings the control deck up under it in the same way.
        .onChange(of: screenLayout.hasBuiltInControls) { _, nowBuiltIn in
            if nowBuiltIn { hideControls() }
        }
        .onChange(of: store.pendingBulletins.map(\.id)) { presentBulletinIfNeeded() }
        .task(id: settings.localOnTheEights) { await runLocalOnTheEights() }
        .task(id: AdsRefreshKey(settings: settings)) { await runAdsRefresh() }
        #if os(iOS) && canImport(WidgetKit)
        // The widget fetches its own weather; all it needs from the app is where, and in
        // which units. Shared whenever either changes, and the widget asked to catch up.
        .onChange(of: WidgetShare(location: settings.savedLocation, units: settings.units), initial: true) { _, share in
            SharedContainer.publish(location: share.location, units: share.units)
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
        .onChange(of: tickerAdLines, initial: true) { _, lines in store.setTickerAds(lines) }
        .onChange(of: engine.activeDisplay) { _, display in
            guard display != nil else { return }
            displaysSinceBreak += 1
            considerAdBreak()
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingControls)
        #if os(tvOS)
        .fullScreenCover(isPresented: $isShowingSettings) { settingsScreen }
        #else
        .sheet(isPresented: $isShowingSettings, onDismiss: {
            if opensRadarMapAfterSettings {
                opensRadarMapAfterSettings = false
                isShowingRadarMap = true
            }
        }) { settingsScreen }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $isShowingRadarMap) { radarMapScreen }
        #elseif os(macOS)
        .sheet(isPresented: $isShowingRadarMap) {
            radarMapScreen.frame(minWidth: 820, minHeight: 620)
        }
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
                Button("") { isShowingRadarMap = true }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .opacity(0)
        }
        #endif
    }

    // MARK: - Folded screen

    /// The picture on one side of the crease and the set's control deck on the other.
    ///
    /// The picture takes the first pane — the upper half of a tabletop, which is the half
    /// stood up to be looked at, or the leading page of a book — and the deck the second.
    /// Inside its pane the picture keeps every rule it has elsewhere, the canvas choice, the
    /// cabinet on a tall page and the screen effects included. Only the cabinet's buttons are
    /// left off, since the deck has them.
    private func foldedScreen(_ posture: FoldPosture) -> some View {
        FoldSplit(posture: posture) {
            WeatherStarView(
                isPictureOn: isPictureOn,
                showsCabinetControls: false,
                bulletin: bulletin,
                showsEightsBumper: showsEightsBumper,
                adCard: adCard,
                clipPlayer: clip?.player,
                onOpenSettings: { isShowingSettings = true },
                onPower: togglePower
            )
            .overlay {
                // Only on a tabletop, where the picture's half is the one that tilts towards
                // and away from the viewer. Held like a book, both pages turn about an axis
                // the viewer is looking along, and a reflection sliding sideways reads as a
                // smear rather than as light.
                if case .tabletop = posture {
                    GlassGlare(hingeAngle: hingeAngle)
                }
            }
        } second: { insets in
            ControlDeck(content: deckContent, finish: settings.televisionFinish, insets: insets)
        }
        // The band along the crease: black, like the room the cabinet stands in.
        .background(Color.black)
    }

    private var deckContent: ControlDeckContent {
        let conditions = store.currentConditions
        return ControlDeckContent(
            channels: DisplayIdentifier.rotationOrder
                .filter { settings.isEnabled($0) }
                .map { .init(display: $0, isReady: engine.state(for: $0).isReady) },
            activeDisplay: engine.activeDisplay,
            conditions: [
                settings.savedLocation?.name,
                conditions?.temperature,
                conditions?.condition,
            ]
            .compactMap { $0 }
            .joined(separator: "  ")
            .uppercased(),
            nowPlaying: musicPlayer.isPlaying ? musicPlayer.currentTrackTitle : nil,
            isRotating: engine.isPlaying,
            isSoundOn: settings.musicEnabled,
            isPictureOn: isPictureOn,
            clock: { store.clockText($0) },
            clockInterval: settings.clockSeconds ? 1 : 15,
            onSelect: { engine.jump(to: $0) },
            onPrevious: { engine.previousDisplay() },
            onNext: { engine.nextDisplay() },
            onToggleRotation: { engine.isPlaying.toggle() },
            onToggleSound: toggleMusic,
            onSettings: { isShowingSettings = true },
            onPower: togglePower,
            onRadarMap: radarMapAction { isShowingRadarMap = true }
        )
    }

    /// The radar map's button action, or `nil` where there is no radar map to open.
    ///
    /// A function rather than an `#if` at every call site, so the controls that offer the map
    /// simply leave the button out on Apple TV.
    private func radarMapAction(_ action: @escaping () -> Void) -> (() -> Void)? {
        #if os(tvOS)
        nil
        #else
        action
        #endif
    }

    #if !os(tvOS)
    private var radarMapScreen: some View {
        RadarMapScreen(
            center: settings.savedLocation,
            timeZone: store.timeZone,
            onClose: { isShowingRadarMap = false }
        )
        // A presentation starts a fresh environment on some platforms; the crease is the
        // window's, so the map's controls can stay off it.
        .environment(\.foldPosture, foldPosture)
    }
    #endif

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
            SettingsView(
                onLocationChange: { location in store.load(location: location) },
                onOpenRadarMap: radarMapAction {
                    opensRadarMapAfterSettings = true
                    isShowingSettings = false
                }
            )
            .environment(settings)
            .environment(locationService)
            .environment(musicLibrary)
            .environment(transfer)
            .environment(musicPlayer)
            .environment(ads)
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

        #if DEBUG
        if ProcessInfo.processInfo.environment["WS4K_TEST_BULLETIN"] != nil {
            store.queueSampleBulletin()
        }
        #endif

        #if !os(tvOS)
        // For `Tools/shoot.sh` and the like, which need the map on screen and cannot tap.
        if ProcessInfo.processInfo.environment["WS4K_OPEN_RADAR_MAP"] != nil {
            isShowingRadarMap = true
        }
        #endif

        // Reveal the controls once on launch: without this there is no hint that a
        // Settings button exists at all.
        if !hasRevealedControlsOnce {
            hasRevealedControlsOnce = true
            showControls()
        }

        // For `Tools/shoot.sh`, which needs one display on screen and held there, with the
        // rest still enabled so the Duo's control deck shows its full set of presets. It
        // waits for the display's data, since `jump` ignores a display with nothing to show.
        if let raw = ProcessInfo.processInfo.environment["WS4K_HOLD_DISPLAY"],
           let display = DisplayIdentifier(rawValue: raw) {
            var waited = 0
            while !engine.state(for: display).isReady, waited < 60 {
                try? await Task.sleep(for: .seconds(1))
                waited += 1
            }
            engine.jump(to: display)
            engine.isPlaying = false
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
        if MusicGate.shouldPlay(musicEnabled: settings.musicEnabled, isSetOn: isPictureOn, clipPlaying: clip != nil) {
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
        isSceneActive = phase == .active
        switch phase {
        case .active:
            engine.isPlaying = true
            setIdleTimerDisabled(true)
            // A warning that arrived in the background is shown on return.
            presentBulletinIfNeeded()
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

    // MARK: - Weather bulletins

    /// Put the next waiting warning on screen, if nothing is already showing one.
    ///
    /// A warning wakes a set left in standby. Standby is the user choosing not to watch the
    /// rotation; it is not a choice to miss a tornado warning, and an app left running on a
    /// desk or a television is exactly the one that should say so.
    private func presentBulletinIfNeeded() {
        guard bulletin == nil, isSceneActive, let next = store.takeBulletin() else { return }
        if !isPictureOn { togglePower() }
        hideControls()
        if adCard != nil || clip != nil { endAdBreak() }
        bulletin = (next, Date())
        if settings.bulletinTone { soundEffects.play(.bulletin) }

        bulletinDismissal?.cancel()
        bulletinDismissal = Task {
            try? await Task.sleep(for: .seconds(BulletinScreen.duration(for: next)))
            guard !Task.isCancelled else { return }
            dismissBulletin()
        }
    }

    /// Take the bulletin down and go to Hazards, where the warning stays listed; then show the
    /// next one waiting, if there is one.
    private func dismissBulletin() {
        bulletinDismissal?.cancel()
        bulletinDismissal = nil
        guard bulletin != nil else { return }
        bulletin = nil
        engine.jump(to: .hazards)
        presentBulletinIfNeeded()
    }

    /// What the widget is told: the place and the units.
    private struct WidgetShare: Equatable {
        let location: SavedLocation?
        let units: UnitSystem
    }

    // MARK: - Ads

    /// What the ads fetch depends on; a change to any of it fetches again.
    private struct AdsRefreshKey: Equatable {
        let needsServer: Bool
        let server: String
        let cards: Bool

        @MainActor
        init(settings: AppSettings) {
            needsServer = AdsLibrary.needsServer(settings)
            server = settings.remoteMusicURLString
            cards = settings.adCardsEnabled
        }
    }

    /// Fetch the ads now, and again at the weather's refresh interval while any are on.
    private func runAdsRefresh() async {
        await ads.refresh(settings: settings)
        while AdsLibrary.needsServer(settings), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(settings.refreshInterval))
            guard !Task.isCancelled else { return }
            await ads.refresh(settings: settings)
        }
    }

    /// The ticker's ad lines: the user's own, then the server's. None unless switched on.
    private var tickerAdLines: [String] {
        guard settings.tickerAdsEnabled else { return [] }
        return settings.tickerAdLines + ads.manifest.ticker.map(\.text)
    }

    /// Take an ad break if one is due, there is something to show, and nothing outranks it.
    private func considerAdBreak() {
        let spots = (settings.adCardsEnabled ? ads.manifest.cards.map(AdSpot.card) : [])
            + (settings.clipReelEnabled ? ads.manifest.clips.map(AdSpot.clip) : [])
        guard adCard == nil, clip == nil, !spots.isEmpty else { return }
        let conditions = AdBreaks.Conditions(
            sceneIsActive: isSceneActive,
            pictureIsOn: isPictureOn,
            rotationHeld: !engine.isPlaying,
            bulletinShowing: bulletin != nil,
            localSegmentPlaying: showsEightsBumper || engine.isPlayingSegment
        )
        guard AdBreaks.isDue(
            displaysSinceBreak: displaysSinceBreak, every: settings.adBreakEvery, conditions: conditions
        ) else { return }

        hideControls()
        engine.isSuspended = true
        breakQueue = adShuffle.nextBreak(from: spots)
        playNextAd()
    }

    /// Put the break's next ad up, or go back to the rotation when the break is over.
    private func playNextAd() {
        adBreakEnd?.cancel()
        adBreakEnd = nil
        guard !breakQueue.isEmpty else {
            endAdBreak()
            return
        }
        // The music is applied once, after the change, so it does not come up for an instant
        // between two clips.
        clip?.stop()
        clip = nil
        adCard = nil

        switch breakQueue.removeFirst() {
        case .card(let card):
            adCard = (card, ads.cardImages[card.id])
            adBreakEnd = Task {
                try? await Task.sleep(for: .seconds(card.seconds))
                guard !Task.isCancelled else { return }
                playNextAd()
            }
        case .clip(let next):
            // The clip has the floor: the music steps back through its gate, and comes
            // back the same way when the clip is done.
            clip = ClipPlayback(clip: next, volume: Float(settings.musicVolume)) {
                playNextAd()
            }
        }
        applyMusicState()
    }

    /// Back to the rotation, where it was, however much of the break was left.
    private func endAdBreak() {
        adBreakEnd?.cancel()
        adBreakEnd = nil
        breakQueue = []
        adCard = nil
        if let playing = clip {
            playing.stop()
            clip = nil
            applyMusicState()
        }
        displaysSinceBreak = 0
        engine.isSuspended = false
    }

    // MARK: - Local on the 8s

    /// Wait for each minute ending in 8, and cut to the local segment when it comes.
    ///
    /// Restarted whenever the setting changes, so turning it off stops it at once.
    private func runLocalOnTheEights() async {
        guard settings.localOnTheEights else { return }
        #if DEBUG
        // Cue once straight away, for checking the segment without waiting for the clock.
        if ProcessInfo.processInfo.environment["WS4K_TEST_EIGHTS"] != nil {
            try? await Task.sleep(for: .seconds(20))
            await cueLocalOnTheEights()
        }
        #endif
        while !Task.isCancelled {
            let cue = LocalOnTheEights.nextCue(after: Date())
            try? await Task.sleep(for: .seconds(max(cue.timeIntervalSinceNow, 1)))
            guard !Task.isCancelled else { return }
            await cueLocalOnTheEights()
        }
    }

    /// The bumper, then the segment.
    ///
    /// Only on a set that is on, in front, and not in the middle of a bulletin: a warning is
    /// the one thing that outranks the local forecast.
    private func cueLocalOnTheEights() async {
        guard isSceneActive, isPictureOn, bulletin == nil, engine.activeDisplay != nil else {
            return
        }
        hideControls()
        showsEightsBumper = true
        try? await Task.sleep(for: .seconds(LocalOnTheEights.bumperDuration))
        showsEightsBumper = false
        guard !Task.isCancelled, bulletin == nil else { return }
        engine.playSegment(LocalOnTheEights.segment)
    }

    // MARK: - Controls visibility

    /// What the weather screen is made of, and so what carries the controls.
    ///
    /// The same rule `WeatherStarView` draws by, so the two cannot disagree about whether
    /// there are buttons on screen — a disagreement here is not cosmetic, it is either two
    /// competing control surfaces or none at all.
    private var screenLayout: TelevisionPresentation.Layout {
        TelevisionPresentation.layout(
            layoutMode: settings.layoutMode,
            showsInLandscape: settings.televisionInLandscape,
            container: containerSize,
            fold: foldPosture
        )
    }

    private func showControls() {
        // When the set or its control deck is on screen it is the control surface, and this
        // floating overlay would be a second one competing with a better one. Both cover
        // everything it offered — settings, both directions, mute and power — with play/pause
        // on the deck, and on the Apple TV remote's own button.
        //
        // Only while one is actually drawn. Without them this overlay is the only way to
        // reach anything, so it has to come back the moment they are not.
        if screenLayout.hasBuiltInControls { return }
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
    /// Opens the zoomable radar map. `nil` on Apple TV, which has none.
    var onRadarMap: (() -> Void)?
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
                if let onRadarMap {
                    button("map", action: onRadarMap)
                        .accessibilityLabel("Radar map")
                }

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
