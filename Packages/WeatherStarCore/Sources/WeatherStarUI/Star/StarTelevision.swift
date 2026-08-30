import SwiftUI
import WeatherStarKit

// The buttons are moulded plastic on every set, including the veneered one — nobody ever
// cut controls out of wood. At file scope because `StarTelevision` is generic over its
// picture, and a generic type cannot hold stored static properties.
private let televisionButtonTop = Color(red: 0.20, green: 0.195, blue: 0.20)
private let televisionButtonBottom = Color(red: 0.075, green: 0.07, blue: 0.078)

/// Where the cabinet's parts sit, all derived from one number: the picture's width.
///
/// A real set is built around its tube, so every moulding on it is a proportion of the
/// picture rather than of the room it stands in. Deriving the whole cabinet from
/// `screenSize.width` keeps it looking like the same television at any size instead of a
/// box whose trim grows and shrinks independently of the glass.
///
/// The one thing that is *not* proportional is the buttons' touch target, which has a
/// floor in real millimetres. See `controlTouchSize`.
///
/// Split out from the drawing because the fitting rule is the part that can be wrong in a
/// way nobody notices until a screenshot goes to Apple — `TelevisionGeometryTests` holds
/// it to fitting inside the space it was given, on every screen the app runs on.
public struct TelevisionGeometry: Equatable, Sendable {
    /// The picture itself, at the aspect ratio it was authored in.
    public let screenSize: CGSize
    /// The whole set, screen plus surrounding cabinet.
    public let cabinetSize: CGSize
    /// Moulding above and to either side of the glass.
    public let bezel: CGFloat
    /// The deeper band under the glass, carrying the speaker and the controls.
    public let controlStrip: CGFloat
    public let cabinetCornerRadius: CGFloat
    public let screenCornerRadius: CGFloat
    /// Edge of the square hit area behind each button.
    public let controlTouchSize: CGFloat
    /// Whether the chin has room for the speaker once the buttons have taken theirs.
    public let showsSpeaker: Bool
    /// Whether the chin has room for the maker's plate as well.
    public let showsPlate: Bool

    // Proportions of the picture width. These are what make it read as a portable set
    // from the early nineties rather than a generic rounded rectangle: a narrow surround
    // on three sides and a deep chin holding the speaker and the buttons.
    private static let bezelRatio: CGFloat = 0.075
    private static let controlStripRatio: CGFloat = 0.19
    /// How much of the container the cabinet is allowed to take, so the set sits *in* a
    /// room rather than being cropped by it.
    private static let fill: CGFloat = 0.94
    /// The smallest comfortable touch target, in points. Apple's own floor.
    ///
    /// This is why the buttons are not simply drawn at their proportional size: on a
    /// phone the chin is around 60pt tall, so a button scaled from it honestly would be
    /// roughly 7pt across — visually right and impossible to hit.
    private static let minimumTouch: CGFloat = 44

    /// Fit the largest cabinet that leaves the picture at `pictureAspect` and still fits
    /// inside `container` on both axes.
    public static func resolve(container: CGSize, pictureAspect: CGFloat) -> TelevisionGeometry {
        let aspect = max(pictureAspect, 0.01)

        // Cabinet width is the picture plus a bezel on each side.
        let widthPerScreenWidth = 1 + 2 * bezelRatio
        // Cabinet height is the picture, one bezel above it, and the chin below.
        let heightPerScreenWidth = 1 / aspect + bezelRatio + controlStripRatio

        // Whichever axis runs out first decides the size — the same `min` that keeps a
        // letterboxed picture in proportion, applied to the whole set.
        let screenWidth = max(
            min(
                container.width * fill / widthPerScreenWidth,
                container.height * fill / heightPerScreenWidth
            ),
            1
        )

        let screen = CGSize(width: screenWidth, height: screenWidth / aspect)
        let bezel = screenWidth * bezelRatio
        let strip = screenWidth * controlStripRatio

        // Never below the touch floor, and never taller than the chin it sits in.
        let touch = min(max(minimumTouch, strip * 0.34), strip)

        // What the four buttons and the gaps between them consume, and whether what is
        // left over is enough for a maker's plate and a speaker as well.
        let chin = screen.width - bezel * 1.2
        let buttonsWidth = touch * 4 + strip * 0.10 * 3
        // Seven slots and the gaps between them.
        let speakerWidth = strip * 0.55
        let showsSpeaker = chin - buttonsWidth > strip * 1.1
        // What the maker's mark needs to be set at full size. It is not allowed to merely
        // shrink into whatever is left: the letter-spacing is an absolute length, so
        // `minimumScaleFactor` cannot reclaim it, and the name came out as "WEATHER…" on a
        // phone. Better to leave it off a cabinet too small to carry it.
        let plateWidth = strip * 1.9

        return TelevisionGeometry(
            screenSize: screen,
            cabinetSize: CGSize(
                width: screen.width + bezel * 2,
                height: screen.height + bezel + strip
            ),
            bezel: bezel,
            controlStrip: strip,
            cabinetCornerRadius: screenWidth * 0.052,
            screenCornerRadius: screenWidth * 0.034,
            controlTouchSize: touch,
            showsSpeaker: showsSpeaker,
            showsPlate: chin - buttonsWidth - (showsSpeaker ? speakerWidth : 0) > plateWidth
        )
    }
}

/// What the four buttons on the chin are wired to.
///
/// Closures rather than a reference to the engine, so the cabinet stays a drawing and the
/// decisions about what a button *means* stay with the view that owns the state.
public struct TelevisionControls {
    /// Whether the tube is lit. Drives the indicator beside the power button.
    public var isPictureOn: Bool
    public var onSettings: () -> Void
    public var onPrevious: () -> Void
    public var onNext: () -> Void
    public var onPower: () -> Void

    public init(
        isPictureOn: Bool = true,
        onSettings: @escaping () -> Void = {},
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {},
        onPower: @escaping () -> Void = {}
    ) {
        self.isPictureOn = isPictureOn
        self.onSettings = onSettings
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onPower = onPower
    }
}

/// The app, shown as a television standing in a room.
///
/// This is what a portrait screen gets instead of the picture stretched up it. A 4:3
/// broadcast graphic has nowhere useful to go on a 3:4 screen — the previous behaviour
/// put it in a band across the top and left the rest of the display empty blue — so
/// rather than filling the space with more picture, the space becomes the room the set
/// stands in. It is also simply the truthful presentation: this *is* a channel on a CRT.
///
/// The glass effects are not drawn here. The picture arrives with the tube shader and the
/// scanlines already applied, so the curvature and bloom belong to the same tube the rest
/// of the app uses rather than being a second, differently-behaved imitation.
public struct StarTelevision<Picture: View>: View {
    private let geometry: TelevisionGeometry
    private let finish: TelevisionFinish
    private let controls: TelevisionControls
    private let picture: Picture

    public init(
        geometry: TelevisionGeometry,
        finish: TelevisionFinish = .monitor,
        controls: TelevisionControls = TelevisionControls(),
        @ViewBuilder picture: () -> Picture
    ) {
        self.geometry = geometry
        self.finish = finish
        self.controls = controls
        self.picture = picture()
    }

    // The cabinet's colours, lit from above the way a moulded case sits under room light.
    private var cabinetTop: Color {
        switch finish {
        case .monitor: Color(red: 0.24, green: 0.23, blue: 0.23)
        case .woodgrain: Color(red: 0.42, green: 0.25, blue: 0.13)
        case .black: Color(red: 0.15, green: 0.145, blue: 0.15)
        }
    }

    private var cabinetBottom: Color {
        switch finish {
        case .monitor: Color(red: 0.11, green: 0.105, blue: 0.11)
        case .woodgrain: Color(red: 0.16, green: 0.085, blue: 0.04)
        case .black: Color(red: 0.035, green: 0.033, blue: 0.038)
        }
    }

    /// How much light the maker's mark can carry, which depends what it is stamped into.
    private var plateInk: Color {
        finish == .woodgrain
            ? Color(red: 0.85, green: 0.72, blue: 0.45).opacity(0.55)
            : .white.opacity(0.20)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                room(container: proxy.size)

                cabinet
                    .frame(width: geometry.cabinetSize.width, height: geometry.cabinetSize.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: - Room

    /// Nothing but the set, on near-black.
    ///
    /// There was briefly a whole room here — a lit wall, a surface, coloured gels. It read
    /// as a purple gradient behind a television rather than as a photograph of one, and a
    /// scene competes with the picture instead of presenting it. The set on black is what
    /// the treatment is actually for.
    private func room(container: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.06, blue: 0.10), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            screenSpill
        }
    }

    /// The tube's own light landing on whatever is behind it.
    private var screenSpill: some View {
        RadialGradient(
            colors: [
                StarColor.backgroundTop.opacity(controls.isPictureOn ? 0.32 : 0),
                StarColor.backgroundTop.opacity(controls.isPictureOn ? 0.05 : 0),
                .clear,
            ],
            center: .center,
            startRadius: geometry.cabinetSize.width * 0.30,
            endRadius: max(geometry.cabinetSize.width, geometry.cabinetSize.height) * 1.05
        )
        .blendMode(.screen)
        .animation(.easeInOut(duration: 0.35), value: controls.isPictureOn)
    }

    // MARK: - Cabinet

    private var cabinet: some View {
        ZStack {
            RoundedRectangle(cornerRadius: geometry.cabinetCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [cabinetTop, cabinetBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    if finish == .woodgrain {
                        grain
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: geometry.cabinetCornerRadius,
                                    style: .continuous
                                )
                            )
                    }
                }
                // A moulded edge catches light along the top and loses it at the bottom.
                .overlay(
                    RoundedRectangle(
                        cornerRadius: geometry.cabinetCornerRadius, style: .continuous
                    )
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .clear, .black.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: max(1, geometry.bezel * 0.11)
                    )
                )
                .shadow(
                    color: .black.opacity(0.65),
                    radius: geometry.bezel * 1.5,
                    y: geometry.bezel * 0.6
                )

            VStack(spacing: 0) {
                screen
                chin
            }
            .padding(.horizontal, geometry.bezel)
            .padding(.top, geometry.bezel)
        }
    }

    /// Veneer grain: fine horizontal streaks, deterministic so it never shimmers.
    ///
    /// Drawn in a `Canvas` rather than as stacked views because it is one rasterisation of
    /// ~70 lines instead of ~70 views the layout system has to carry around, and it never
    /// changes once drawn.
    private var grain: some View {
        Canvas { context, size in
            let lines = 70
            for index in 0..<lines {
                // A cheap deterministic hash, so the streaks look irregular but are
                // identical on every redraw and on every device.
                let noise = (sin(Double(index) * 12.9898) * 43758.5453).truncatingRemainder(
                    dividingBy: 1
                )
                let jitter = abs(noise)
                let y = size.height * (Double(index) + jitter) / Double(lines)
                let thickness = 0.4 + jitter * 1.6
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: thickness)),
                    with: .color(.black.opacity(0.05 + jitter * 0.16))
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Screen

    /// The glass, recessed into the cabinet.
    private var screen: some View {
        picture
            .frame(width: geometry.screenSize.width, height: geometry.screenSize.height)
            .clipShape(
                RoundedRectangle(cornerRadius: geometry.screenCornerRadius, style: .continuous)
            )
            // The tube sits *behind* the front moulding, so the surround casts onto it.
            //
            // Drawn just *outside* the glass rather than over it. Overlaid, this ring ate
            // the outermost points of the picture on every display — enough to clip the
            // last digit off the Hourly wind column, which is authentic CRT overscan and
            // completely unwanted when the picture is already only as big as a phone.
            .overlay(
                RoundedRectangle(
                    cornerRadius: geometry.screenCornerRadius + geometry.bezel * 0.30,
                    style: .continuous
                )
                .strokeBorder(
                    LinearGradient(
                        colors: [.black.opacity(0.75), .black.opacity(0.25)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(1, geometry.bezel * 0.30)
                )
                .padding(-max(1, geometry.bezel * 0.30))
                .allowsHitTesting(false)
            )
            // A single soft reflection across the upper-left of the glass. One is enough:
            // two reads as a graphic rather than as a room reflected in a curved surface.
            .overlay(
                RoundedRectangle(cornerRadius: geometry.screenCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.055), .white.opacity(0.012), .clear],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            // Light thrown forward by the picture, onto the moulding around it. Tight and
            // faint: a wide one reads as a purple halo stuck to the glass rather than as
            // spill onto the plastic.
            .shadow(
                color: StarColor.backgroundTop.opacity(controls.isPictureOn ? 0.40 : 0),
                radius: geometry.bezel * 0.45
            )
    }

    // MARK: - Chin

    /// The maker's plate, the speaker, and the row of buttons.
    private var chin: some View {
        HStack(alignment: .center, spacing: geometry.bezel * 0.5) {
            if geometry.showsPlate {
                StarBrandingPlate(height: geometry.controlStrip * 0.19, ink: plateInk)
            }

            Spacer(minLength: 0)

            if geometry.showsSpeaker {
                speakerGrille
            }
            buttons
        }
        .frame(height: geometry.controlStrip)
        .padding(.horizontal, geometry.bezel * 0.6)
    }

    private var speakerGrille: some View {
        let pitch = geometry.controlStrip * 0.085
        return HStack(spacing: pitch * 0.55) {
            ForEach(0..<7, id: \.self) { _ in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.black.opacity(0.85), .black.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: pitch * 0.45, height: geometry.controlStrip * 0.42)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Buttons

    /// The four controls, in the order a set of the period would have carried them:
    /// menu on the left, the channel pair in the middle, power on the right.
    private var buttons: some View {
        HStack(spacing: geometry.controlStrip * 0.10) {
            button("gearshape.fill", label: "Settings", action: controls.onSettings)
            button("backward.fill", label: "Previous display", action: controls.onPrevious)
            button("forward.fill", label: "Next display", action: controls.onNext)
            button(
                "power",
                label: controls.isPictureOn ? "Turn the picture off" : "Turn the picture on",
                showsIndicator: true,
                action: controls.onPower
            )
        }
    }

    private func button(
        _ symbol: String,
        label: String,
        showsIndicator: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: geometry.controlStrip * 0.035, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [televisionButtonTop, televisionButtonBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: geometry.controlStrip * 0.035, style: .continuous
                    )
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
                // Moulded into the plastic rather than printed on it: legible up close,
                // invisible from across the room, which is how these actually looked.
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: geometry.controlStrip * 0.115, weight: .bold))
                        .foregroundStyle(.white.opacity(0.38))
                        // The glyph decides nothing about the face's size, so it has to be
                        // told to stay inside it. `backward.fill` and `gearshape.fill` are
                        // both markedly wider than their point size and were spilling over
                        // the moulding on either side.
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, geometry.controlStrip * 0.03)
                )
                .frame(
                    width: geometry.controlStrip * 0.30,
                    height: geometry.controlStrip * 0.26
                )
                .overlay(alignment: .bottom) {
                    if showsIndicator {
                        indicator
                    }
                }
                // The face is drawn small so it stays in proportion with the cabinet; the
                // hit area around it is what the finger actually gets.
                .frame(
                    width: geometry.controlTouchSize,
                    height: geometry.controlTouchSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The power lamp: lit while the tube is, dark when it is not.
    private var indicator: some View {
        Circle()
            .fill(
                controls.isPictureOn
                    ? Color(red: 0.95, green: 0.20, blue: 0.12)
                    : Color(red: 0.30, green: 0.10, blue: 0.09)
            )
            .frame(width: geometry.controlStrip * 0.05)
            .shadow(
                color: Color(red: 1, green: 0.25, blue: 0.15)
                    .opacity(controls.isPictureOn ? 0.9 : 0),
                radius: geometry.controlStrip * 0.06
            )
            .offset(y: geometry.controlStrip * 0.17)
            .animation(.easeInOut(duration: 0.25), value: controls.isPictureOn)
    }
}

/// The moulded maker's mark on the chin.
///
/// Uses the app's own startup title rather than inventing a brand, so a build that has
/// been rebranded through `WS4KStartupTitle` carries its own name here too.
private struct StarBrandingPlate: View {
    let height: CGFloat
    let ink: Color

    var body: some View {
        Text(StarBranding.startupTitle.uppercased())
            .font(.system(size: height, weight: .semibold, design: .rounded))
            .tracking(height * 0.18)
            // Stamped into the plastic: a dark face with a light edge under it.
            .foregroundStyle(ink)
            .shadow(color: .white.opacity(0.10), radius: 0, y: max(1, height * 0.06))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .accessibilityHidden(true)
    }
}
