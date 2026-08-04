//
//  StarCRT.metal
//  A CRT tube for the WeatherStar displays.
//
//  Lives outside the Swift package on purpose. SwiftPM does not compile `.metal` files in
//  a package target — it reports them as unhandled resources and produces no metallib — so
//  this is added to the sources of all three app targets in `project.yml`. Xcode compiles
//  it into the app bundle's `default.metallib`, which is what `ShaderLibrary.default`
//  reads at runtime.
//
//  One consequence: the package's snapshot tests render outside any app bundle, so the
//  function is absent there and a SwiftUI shader referencing a missing function traps.
//  `CRTEffect.isAvailable` checks for the metallib before applying the effect.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// Everything a curved phosphor tube does to a picture, in one pass.
///
/// Ordered the way the physical effects actually compose: geometry first (the glass bends
/// the image), then the beam (colour convergence and bloom), then the mask and the tube's
/// falloff. Doing the scanlines before the warp would bend the lines along with the
/// picture, when in reality they belong to the tube's face and stay straight.
///
/// - Parameters:
///   - position: destination point, in the view's own coordinate space (points).
///   - layer: the rendered content underneath, sampled in that same space.
///   - size: view size in points, so `position` can be normalised.
///   - time: seconds, for the scanline drift. Wrapped by the caller to stay small.
///   - curvature: barrel strength. 0 is a flat panel; 0.06 is a fairly round tube.
///   - scanline: depth of the dark lines, 0...1.
///   - linePeriod: points between line centres, in *output* space.
///   - aberration: how far the red and blue beams miss convergence, in points.
///   - bloom: how much bright phosphor bleeds into its neighbours.
///   - vignette: corner falloff.
[[ stitchable ]] half4 starCRT(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float time,
    float curvature,
    float scanline,
    float linePeriod,
    float aberration,
    float bloom,
    float vignette
) {
    // -1...1 with the origin at the centre of the tube.
    float2 centred = (position / size) * 2.0 - 1.0;

    // Barrel distortion. Sampling *outwards* for each destination pixel is what makes the
    // picture appear to bow towards the viewer.
    float radiusSquared = dot(centred, centred);
    float2 warped = centred * (1.0 + curvature * radiusSquared);

    // Past the edge of the glass there is no picture, only bezel.
    if (any(abs(warped) > 1.0)) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }

    float2 source = ((warped + 1.0) * 0.5) * size;

    // Convergence error grows towards the edges on a real tube, so scale it by radius
    // rather than applying it evenly. `1e-6` keeps `normalize` away from zero at the
    // exact centre, where the direction is undefined.
    float2 fringe = normalize(centred + 1e-6) * aberration * radiusSquared;
    half4 centre = layer.sample(source);
    half4 colour;
    colour.r = layer.sample(source + fringe).r;
    colour.g = centre.g;
    colour.b = layer.sample(source - fringe).b;
    // Carry the sampled alpha through. Forcing this to 1 turned every transparent pixel
    // into opaque black, which drew a black box around each run of text — the layer is
    // premultiplied, so its transparent regions are (0,0,0,0), and claiming they were
    // opaque made them ink.
    colour.a = centre.a;

    // Phosphor bloom: four diagonal taps, and only genuinely bright phosphor bleeds.
    //
    // Weighting purely by luminance made every mid-tone panel haze over, because the
    // display backgrounds are bright enough to bloom into themselves. Subtracting a floor
    // first means the blue panels stay flat and only the white and yellow type glows.
    if (bloom > 0.0) {
        const float spread = 1.75;
        half4 neighbourhood =
              layer.sample(source + float2( spread,  spread))
            + layer.sample(source + float2(-spread,  spread))
            + layer.sample(source + float2( spread, -spread))
            + layer.sample(source + float2(-spread, -spread));
        half3 glow = neighbourhood.rgb * 0.25h;
        half luminance = dot(glow, half3(0.299h, 0.587h, 0.114h));
        half excess = max(0.0h, luminance - 0.45h) * (1.0h / 0.55h);
        colour.rgb += glow * half(bloom) * excess;
    }

    // Scanline mask, drifting slowly. Keyed off `position`, not `source`, so the lines
    // belong to the face of the tube and stay straight while the picture bends.
    if (scanline > 0.0 && linePeriod > 0.0) {
        float phase = (position.y + time * 8.0) / linePeriod;
        float mask = 0.5 + 0.5 * cos(phase * 6.283185307);
        colour.rgb *= half(1.0 - scanline * mask);
    }

    // Tube falloff towards the corners.
    float falloff = 1.0 - vignette * radiusSquared * 0.5;
    colour.rgb *= half(clamp(falloff, 0.0, 1.0));

    return colour;
}
