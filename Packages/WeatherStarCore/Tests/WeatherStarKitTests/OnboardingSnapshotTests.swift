#if os(macOS)
import ImageIO
import SwiftUI
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

/// Renders the onboarding and settings screens to `/tmp/ws4k-ux` for review.
///
/// These are SwiftUI *system* views — Form, NavigationStack, Button — so macOS
/// renders them with macOS control styling rather than tvOS's or iOS's. That makes
/// them useful for checking content, structure, ordering and copy, but not for
/// judging platform chrome.
///
/// Since the forms adopted `.formStyle(.grouped)`, these renders come out **empty**: a
/// grouped form puts its rows inside a ScrollView, which `ImageRenderer` will not lay
/// out without a hosting window. The tests still catch a view that fails to build at
/// all, but the images are no longer a way to review settings layout — that has to be
/// done by running the app. The weather displays are custom-drawn and therefore
/// pixel-accurate anywhere, which is why they live in `DisplaySnapshotTests`.
@Suite("Onboarding and settings snapshots")
@MainActor
struct OnboardingSnapshotTests {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/ws4k-ux")

    /// Roughly a 16:9 TV pane and a phone, so both layouts get exercised.
    private static let tvSize = CGSize(width: 1280, height: 720)
    private static let phoneSize = CGSize(width: 402, height: 874)

    private func settings(configure: (AppSettings) -> Void = { _ in }) -> AppSettings {
        // Isolated domain so snapshots never disturb real preferences.
        let suite = "ws4k.ux.\(UUID().uuidString)"
        let store = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        configure(store)
        return store
    }

    @discardableResult
    private func render(_ view: some View, named name: String, size: CGSize) -> CGImage? {
        StarFontLoader.registerFonts()
        try? FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true
        )

        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height)
        )
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }

        if let destination = CGImageDestinationCreateWithURL(
            Self.outputDirectory.appendingPathComponent("\(name).png") as CFURL,
            "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return image
    }

    // MARK: - Onboarding

    @Test("Each onboarding step renders")
    func onboardingSteps() throws {
        for step in OnboardingView.Step.allCases {
            let store = settings()
            let view = OnboardingView(startingAt: step) {}
                .environment(store)
                .environment(LocationService.shared)

            let image = render(view, named: "onboarding-\(step.rawValue)-\(step)", size: Self.tvSize)
            #expect(image != nil, "step \(step) failed to render")
        }
    }

    // MARK: - Settings

    @Test("Settings renders with a location already chosen")
    func settingsConfigured() throws {
        let store = settings {
            $0.savedLocation = SavedLocation(
                name: "Orlando, FL", latitude: 28.5383, longitude: -81.3792
            )
            $0.locationMode = .manual
            $0.units = .us
            $0.musicEnabled = true
            $0.setEnabled(true, for: .hourly)
        }
        let library = MusicLibrary(settings: store)

        let view = SettingsView { _ in }
            .environment(store)
            .environment(LocationService.shared)
            .environment(library)

        #expect(render(view, named: "settings-tv", size: Self.tvSize) != nil)
        #expect(render(view, named: "settings-phone", size: Self.phoneSize) != nil)
    }

    @Test("Music settings renders for each source")
    func musicSettingsPerSource() throws {
        for source in MusicSourceKind.allCases {
            let store = settings {
                $0.musicSource = source
                $0.remoteMusicURLString = "http://nas.local:8080"
                $0.uploadPath = "/music/custom"
            }
            let view = MusicSettingsView()
                .environment(store)
                .environment(MusicLibrary(settings: store))
                .environment(MusicTransfer(settings: store))
                .environment(MusicPlayer())

            #expect(
                render(view, named: "music-\(source.rawValue)", size: Self.tvSize) != nil,
                "music source \(source) failed to render"
            )
        }
    }

    /// Mirrors `RootView.settingsScreen`: the panel is composited over a live display,
    /// so the backdrop has to be opaque enough for the options to read. A material
    /// alone resolved light on tvOS while the text stayed light, making it invisible.
    ///
    /// The one deliberate difference from production is how dark is asked for. Production
    /// uses `.preferredColorScheme(.dark)`, which sets the presentation's actual
    /// appearance so the platform's own chrome matches; there is no presentation here, and
    /// `ImageRenderer` ignores the modifier, so the environment value stands in for it.
    /// That makes this a test of the backdrop's contrast, not of the appearance plumbing —
    /// which only a running app can show.
    @Test("The settings panel is readable over a running display")
    func settingsPanelContrast() throws {
        let store = settings {
            $0.savedLocation = SavedLocation(
                name: "Orlando, FL", latitude: 28.5383, longitude: -81.3792
            )
        }

        let panel = ZStack {
            // Stand-in for the weather display showing through from behind.
            LinearGradient(
                colors: [.orange, .blue],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.10), Color(white: 0.04)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                SettingsView { _ in }
                    .environment(store)
                    .environment(LocationService.shared)
                    .environment(MusicLibrary(settings: store))
            }
            .environment(\.colorScheme, .dark)
        }

        let image = try #require(render(panel, named: "settings-over-display", size: Self.tvSize))

        // Sample the panel interior: it must be dark, or light text will not read.
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        )

        // Average luminance across the middle of the panel.
        var total = 0
        var samples = 0
        for row in stride(from: height / 3, to: height * 2 / 3, by: 8) {
            for column in stride(from: width / 3, to: width * 2 / 3, by: 8) {
                let index = (row * width + column) * 4
                total += (Int(data[index]) + Int(data[index + 1]) + Int(data[index + 2])) / 3
                samples += 1
            }
        }
        let average = samples > 0 ? total / samples : 255
        #expect(
            average < 110,
            "panel interior averages \(average)/255 — too light for the light text to read"
        )
    }

    @Test("The location picker renders with recents")
    func locationPicker() throws {
        let store = settings {
            $0.rememberRecent(SavedLocation(name: "Tampa, FL", latitude: 27.95, longitude: -82.46))
            $0.rememberRecent(SavedLocation(name: "Orlando, FL", latitude: 28.54, longitude: -81.38))
        }
        let view = NavigationStack {
            LocationPickerView { _ in }
                .environment(store)
                .environment(LocationService.shared)
        }
        #expect(render(view, named: "location-picker", size: Self.tvSize) != nil)
    }
}

/// The onboarding location step, against the rule App Review enforces on it.
///
/// The app was rejected under guideline 5.1.1(iv) for two things on one screen: a button
/// reading "Use this device's location", which argues for one answer, and a "Skip" that
/// let the permission request be put off indefinitely. Apple's remedy was explicit — a
/// neutral label like "Continue", and no way past the message except into the prompt.
@Suite("Onboarding location permission")
struct OnboardingLocationTests {
    @Test("Before the prompt is answered there is no way past it")
    func preRequestStageOffersNoEscape() {
        let stage = LocationStepStage(hasAnsweredAuthorization: false)
        #expect(stage == .permissionPrompt)
        // The Skip and Back buttons, and the search field that would let the user pick a
        // place without ever answering, are all gated on these.
        #expect(!stage.allowsDismissal)
        #expect(!stage.showsPlaceSearch)
    }

    @Test("Once answered the step is an ordinary place picker")
    func postRequestStageIsUnrestricted() {
        let stage = LocationStepStage(hasAnsweredAuthorization: true)
        #expect(stage == .placePicker)
        // Nothing is being deferred any more: the prompt has had its answer, so Skip and
        // search are just navigation.
        #expect(stage.allowsDismissal)
        #expect(stage.showsPlaceSearch)
    }

    @Test("Denial is an answer, so it opens the picker rather than re-asking")
    func denialCountsAsAnswered() {
        // `hasAnsweredAuthorization` is true for denied and restricted as well as
        // granted. A user who said no gets the search field, not the prompt screen again.
        #expect(LocationStepStage(hasAnsweredAuthorization: true).showsPlaceSearch)
    }
}

/// Every onboarding foreground, measured against the gradient it is drawn on.
///
/// Onboarding is the one screen that paints its own background instead of sitting on a
/// system one, so nothing about its contrast is guaranteed by the platform. It was
/// shipped with `.secondary` body copy and a default-tinted Toggle label, both of which
/// resolve *dark* under a light system appearance and became near-invisible on the navy
/// gradient. The view now states every colour explicitly; this is what holds it there.
///
/// A render test could not catch it: `ImageRenderer` ignores `preferredColorScheme`, so
/// it cannot reproduce the light-appearance case that was broken. The colours themselves
/// are exact numbers, so they are checked as numbers.
@Suite("Onboarding contrast")
struct OnboardingPaletteTests {
    /// WCAG 2.1 relative luminance, from the sRGB components.
    private static func luminance(_ color: Color) -> Double {
        let resolved = NSColor(color).usingColorSpace(.sRGB)!
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(resolved.redComponent)
            + 0.7152 * channel(resolved.greenComponent)
            + 0.0722 * channel(resolved.blueComponent)
    }

    /// WCAG 2.1 contrast ratio, 1:1 to 21:1.
    private static func ratio(_ a: Color, _ b: Color) -> Double {
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Both ends of the gradient, because a foreground has to survive the whole run of
    /// it — the top is the lighter end and therefore the harder case for light text.
    private static let backgrounds: [(String, Color)] = [
        ("gradient top", StarColor.backgroundTop),
        ("gradient bottom", StarColor.backgroundBottom),
    ]

    @Test("Text colours clear 4.5:1 against the gradient")
    func textContrast() {
        let foregrounds: [(String, Color)] = [
            ("title", OnboardingPalette.title),
            ("body", OnboardingPalette.body),
            ("accent", OnboardingPalette.accent),
            ("warning", OnboardingPalette.warning),
        ]
        for (backgroundName, background) in Self.backgrounds {
            for (name, foreground) in foregrounds {
                let value = Self.ratio(foreground, background)
                #expect(
                    value >= 4.5,
                    "\(name) on \(backgroundName) is \(value):1 — under the 4.5:1 floor"
                )
            }
        }
    }

    /// The primary action is a filled shape, so it has two jobs: its label has to read on
    /// the fill, and the fill has to read as a control against the gradient. The accent
    /// blue it used to carry failed the first (3.65:1) and only scraped the second.
    @Test("The primary action reads both against its label and against the gradient")
    func actionContrast() {
        let label = Self.ratio(OnboardingPalette.actionLabel, OnboardingPalette.actionFill)
        #expect(label >= 4.5, "action label on its fill is \(label):1")

        for (backgroundName, background) in Self.backgrounds {
            let value = Self.ratio(OnboardingPalette.actionFill, background)
            // 3:1 is WCAG's floor for a non-text UI component boundary.
            #expect(
                value >= 3,
                "action fill on \(backgroundName) is \(value):1 — the button loses its edge"
            )
        }
    }

    /// The specific regression: a colour that changes with the system appearance cannot
    /// be reasoned about here at all, so the palette must not contain one. `.secondary`
    /// and `.primary` resolve differently per appearance; an opaque literal does not.
    @Test("Palette colours are appearance-independent")
    func palettePinsItsColours() {
        let all: [(String, Color)] = [
            ("title", OnboardingPalette.title),
            ("body", OnboardingPalette.body),
            ("accent", OnboardingPalette.accent),
            ("warning", OnboardingPalette.warning),
            ("actionFill", OnboardingPalette.actionFill),
            ("actionLabel", OnboardingPalette.actionLabel),
        ]
        for (name, color) in all {
            // `performAsCurrentDrawingAppearance` returns Void, so the resolved value has
            // to be carried out of the block rather than returned from it.
            var light: NSColor!
            var dark: NSColor!
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                light = NSColor(color).usingColorSpace(.sRGB)!
            }
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                dark = NSColor(color).usingColorSpace(.sRGB)!
            }
            #expect(
                abs(light.redComponent - dark.redComponent) < 0.001
                    && abs(light.greenComponent - dark.greenComponent) < 0.001
                    && abs(light.blueComponent - dark.blueComponent) < 0.001
                    && abs(light.alphaComponent - dark.alphaComponent) < 0.001,
                "\(name) changes with the system appearance: \(light!) vs \(dark!)"
            )
        }
    }
}
#endif
