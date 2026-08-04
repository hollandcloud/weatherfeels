import SwiftUI
import WeatherStarKit

/// Puts the displays behind curved phosphor glass, using the `StarCRT.metal` shader.
///
/// The shader cannot live in this package: SwiftPM does not compile `.metal` files in a
/// package target, so it sits in `Shaders/StarCRT.metal` and is added to the sources of
/// all three app targets, which makes Xcode build it into each app's `default.metallib`.
/// `ShaderLibrary.default` reads that from the main bundle.
///
/// Which means the function is *absent* anywhere there is no app bundle — most importantly
/// the package's own snapshot tests — and a SwiftUI shader referencing a missing function
/// is a hard failure at render time, not a no-op. So nothing here is applied without
/// `isAvailable` confirming the metallib exists.
public enum CRTEffect {
    /// Whether the compiled shader is present in this process.
    ///
    /// Checked by looking for the metallib rather than by trying the shader and recovering:
    /// there is no recovering from a missing shader function.
    public static let isAvailable: Bool = {
        Bundle.main.url(forResource: "default", withExtension: "metallib") != nil
    }()

    /// How far the shader reads outside the pixel it is writing.
    ///
    /// Only the convergence and bloom taps need declaring. The barrel warp samples
    /// *inwards* from the destination — for any given output pixel the source is further
    /// from centre, and anything past the glass returns bezel black — so it never reaches
    /// beyond the layer.
    static let maxSampleOffset = CGSize(width: 8, height: 8)

    /// 30fps. The only motion is the scanline drift; the shader itself is a fixed cost per
    /// frame, and this covers the whole screen on a 4K set.
    static let frameInterval: Double = 1.0 / 30.0

    /// Time is fed to the shader as a small number.
    ///
    /// `timeIntervalSinceReferenceDate` is ~8×10⁸ by now, and at `float` precision that
    /// leaves far too little resolution for a smooth drift — the pattern would visibly
    /// step. Wrapping keeps it inside a range where a float still has fractions to spare.
    static let timeWrap: Double = 600
}

/// Tuning for the tube. Defaults are deliberately restrained — the displays have to stay
/// legible from across a room, and this sits over every one of them.
public struct CRTSettings: Equatable, Sendable {
    /// Barrel strength.
    ///
    /// Halved from 0.028 after bisecting a real artifact: at that value the ticker's small
    /// location label lost the top of every glyph, so "TAMPA" rendered as "|AMP/". Turning
    /// each stage off in isolation cleared curvature's neighbours — mask, convergence, bloom
    /// and vignette are all innocent — and the label survives intact at 0.014 and below.
    /// Filtering the warp along its axis of compression, which is in the shader and worth
    /// keeping, did not rescue it on its own, so the displacement itself is the limit.
    ///
    /// This is a mitigation rather than a full explanation: the exact boundary the label's
    /// top row crosses is not pinned down. `ws4k.debug.crt.curvature` dials it in a Debug
    /// build if you want a rounder tube and can live with that label.
    public var curvature: Double = 0.014
    public var scanlineDepth: Double = 0.22
    /// Points between scanline centres.
    ///
    /// Kept in points rather than output pixels. Dividing by `displayScale` put the period
    /// at 1.5 points on a 4K set, which is only three samples per cycle and produced a
    /// harsh moiré rather than lines.
    public var linePeriod: Double = 2
    /// Convergence error at the edges, in points.
    ///
    /// Deliberately tiny. `StarText` already draws each glyph as a black outline plus a
    /// drop shadow, so a fringe of even a point lands beside an existing dark edge and the
    /// letters read as doubled rather than as slightly misconverged — at 0.9 the ticker
    /// looked mangled. This is also multiplied by radius² in the shader, so the figure here
    /// is the value at the very corners.
    public var aberration: Double = 0.3
    public var bloom: Double = 0.22
    public var vignette: Double = 0.28

    public init() {
        #if DEBUG
        // Debug builds let each stage be dialled from the outside, so the tube can be
        // bisected and tuned on a real device without a rebuild per value:
        //
        //   defaults write net.hlnd.weatherstar ws4k.debug.crt.bloom -float 0
        //
        // Absent keys leave the defaults above untouched. Compiled out of Release, so a
        // shipped build cannot be reconfigured this way.
        applyDebugOverrides()
        #endif
    }

    #if DEBUG
    private mutating func applyDebugOverrides() {
        let defaults = UserDefaults.standard
        func override(_ name: String, into value: inout Double) {
            let key = "ws4k.debug.crt.\(name)"
            guard defaults.object(forKey: key) != nil else { return }
            value = defaults.double(forKey: key)
        }
        override("curvature", into: &curvature)
        override("scanlineDepth", into: &scanlineDepth)
        override("linePeriod", into: &linePeriod)
        override("aberration", into: &aberration)
        override("bloom", into: &bloom)
        override("vignette", into: &vignette)
    }
    #endif
}

private struct CRTModifier: ViewModifier {
    let settings: CRTSettings
    /// Taken from the caller rather than read with a `GeometryReader`, which places its
    /// child top-leading and would quietly re-align the canvas it wraps.
    let size: CGSize

    func body(content: Content) -> some View {
        TimelineView(
            .animation(minimumInterval: CRTEffect.frameInterval, paused: false)
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: CRTEffect.timeWrap)

            content
                // Pinned to exactly the size handed to the shader. Without this the layer
                // is sized by its children, and the shader's `position / size` no longer
                // spans 0...1 — which on a real Apple TV put every pixel outside the glass
                // and blacked out the screen while the simulator looked correct.
                .frame(width: size.width, height: size.height)
                .layerEffect(
                    ShaderLibrary.default.starCRT(
                        .float2(size.width, size.height),
                        .float(time),
                        .float(settings.curvature),
                        .float(settings.scanlineDepth),
                        .float(settings.linePeriod),
                        .float(settings.aberration),
                        .float(settings.bloom),
                        .float(settings.vignette)
                    ),
                    maxSampleOffset: CRTEffect.maxSampleOffset
                )
        }
    }
}

public extension View {
    /// Apply the CRT tube, when the shader is available and asked for.
    ///
    /// A no-op otherwise, so a caller never has to know whether the metallib shipped.
    @ViewBuilder
    func crtEffect(_ settings: CRTSettings?, size: CGSize) -> some View {
        if let settings, CRTEffect.isAvailable, size.width > 0, size.height > 0 {
            modifier(CRTModifier(settings: settings, size: size))
        } else {
            self
        }
    }
}
