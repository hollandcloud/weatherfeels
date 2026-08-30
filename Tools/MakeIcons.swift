#!/usr/bin/env swift
//
// Generates the app icon asset catalogs for iOS, tvOS and macOS.
//
// The icon is drawn programmatically rather than checked in as PNGs, so changing the
// palette or wordmark regenerates every size consistently. Written in Swift because
// CoreGraphics and Core Text are always present with Xcode, unlike Pillow or PyObjC.
//
// tvOS needs the most care: its app icon is a *layered* image stack for the parallax
// effect, so the field and the wordmark go in separate layers, and it additionally
// requires Top Shelf artwork. iOS and macOS take flat images.
//
//   swift Tools/MakeIcons.swift <repo-root>
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import AppKit

// MARK: - Palette
//
// The same colours the displays use, so the icon reads as part of the app.

let navyTop = CGColor(red: 0x10 / 255, green: 0x20 / 255, blue: 0x80 / 255, alpha: 1)
let navyBottom = CGColor(red: 0x00 / 255, green: 0x10 / 255, blue: 0x40 / 255, alpha: 1)
let stripeTop = CGColor(red: 0xC0 / 255, green: 0x5C / 255, blue: 0x03 / 255, alpha: 1)
let stripeBottom = CGColor(red: 0x8B / 255, green: 0x42 / 255, blue: 0x1D / 255, alpha: 1)
let plateBlue = CGColor(red: 0x1E / 255, green: 0x6F / 255, blue: 0xD6 / 255, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

let repoRoot: String = {
    let arguments = CommandLine.arguments
    return arguments.count > 1
        ? URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
        : FileManager.default.currentDirectoryPath
}()

// MARK: - Fonts

/// The face the wordmark is set in.
///
/// Deliberately *not* one of the bundled Star4000 faces. All four are the light,
/// wide-spaced letterforms of a 1990 character generator: they are right on screen, where
/// they are the picture, and wrong on an icon, where the mark has to hold together at
/// 40 points on a home screen. A bold condensed grotesque is what a broadcast logo of the
/// period was actually set in, and it matches the corner badge the app draws — see
/// `StarLogoBadge` in `StarBranding.swift`, which resolves the same list.
///
/// This also replaces a `registerFonts()` that pointed at
/// `WeatherStarResources/Resources/Fonts`, a directory that does not exist — the assets
/// live under `Assets/Fonts`. So the registration silently did nothing, `STAR4` never
/// resolved, and every icon shipped so far was drawn in whatever CoreText fell back to.
let wordmarkFont: String = {
    for name in ["HelveticaNeue-CondensedBold", "HelveticaNeue-Bold", "Helvetica-Bold"] {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        if (CTFontCopyPostScriptName(font) as String) == name { return name }
    }
    return "Helvetica-Bold"
}()

/// The lines on the plate. Two, since the rename.
let wordmarkLines = ["WEATHER", "FEELS"]

/// Width of `string` in the wordmark face at `size`.
func wordmarkWidth(_ string: String, size: CGFloat) -> CGFloat {
    let font = CTFontCreateWithName(wordmarkFont as CFString, size, nil)
    let attributed = NSAttributedString(
        string: string,
        attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
    )
    return CGFloat(CTLineGetTypographicBounds(
        CTLineCreateWithAttributedString(attributed), nil, nil, nil
    ))
}

// MARK: - Drawing

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func fillVerticalGradient(
    _ context: CGContext, _ rect: CGRect, _ bottom: CGColor, _ top: CGColor
) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [bottom, top] as CFArray,
        locations: [0, 1]
    )!
    context.saveGState()
    context.clip(to: rect)
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: rect.minY),
        end: CGPoint(x: 0, y: rect.maxY),
        options: []
    )
    context.restoreGState()
}

/// Draw a centred line of text with the given face.
func drawText(
    _ context: CGContext,
    _ string: String,
    centerX: CGFloat,
    centerY: CGFloat,
    size: CGFloat,
    font fontName: String,
    color: CGColor
) {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attributed = NSAttributedString(
        string: string,
        attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

    context.textPosition = CGPoint(
        x: centerX - CGFloat(width) / 2,
        y: centerY - (ascent - descent) / 2
    )
    CTLineDraw(line, context)
}

/// Navy field with the orange header stripe cut across it, echoing the display chrome.
func drawBackground(_ context: CGContext, _ width: CGFloat, _ height: CGFloat) {
    fillVerticalGradient(
        context, CGRect(x: 0, y: 0, width: width, height: height), navyBottom, navyTop
    )

    // The stripe slopes, as it does on screen.
    let top = height * 0.80
    let bottom = height * 0.58
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: top))
    path.addLine(to: CGPoint(x: width, y: top - height * 0.05))
    path.addLine(to: CGPoint(x: width, y: bottom - height * 0.05))
    path.addLine(to: CGPoint(x: 0, y: bottom))
    path.closeSubpath()

    context.saveGState()
    context.addPath(path)
    context.clip()
    fillVerticalGradient(
        context,
        CGRect(x: 0, y: bottom - height * 0.05, width: width, height: top - bottom + height * 0.05),
        stripeBottom, stripeTop
    )
    context.restoreGState()
}

/// The "WEATHER FEELS" plate, matching the corner logo on the displays.
func drawWordmark(_ context: CGContext, _ width: CGFloat, _ height: CGFloat) {
    let plateWidth = width * 0.62
    let plateHeight = height * 0.40
    let x = (width - plateWidth) / 2
    let y = height * 0.17

    let rect = CGRect(x: x, y: y, width: plateWidth, height: plateHeight)
    let radius = plateHeight * 0.14
    let plate = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.setFillColor(plateBlue)
    context.addPath(plate)
    context.fillPath()

    context.setStrokeColor(white)
    context.setLineWidth(max(width * 0.014, 1))
    context.addPath(plate)
    context.strokePath()

    // One size for both lines, set by whichever constraint binds first — the longest line
    // against the plate's width, or the stack of cap heights against its height. The same
    // rule the on-screen badge uses, so the icon and the corner mark are the same object.
    let inset = plateWidth * 0.08
    let probe: CGFloat = 100
    let widest = wordmarkLines.map { wordmarkWidth($0, size: probe) }.max() ?? probe
    let capHeight = CTFontGetCapHeight(CTFontCreateWithName(wordmarkFont as CFString, probe, nil))

    let widthLimited = (plateWidth - inset * 2) / widest * probe
    let heightLimited = (plateHeight - inset * 1.6) / (capHeight * 1.25 * CGFloat(wordmarkLines.count)) * probe
    let size = min(widthLimited, heightLimited)

    let centerX = width / 2
    let step = capHeight / probe * size * 1.25
    // Centre the block, then step down through the lines from its top.
    let firstCenter = y + plateHeight / 2 + step * (CGFloat(wordmarkLines.count) - 1) / 2
    for (index, line) in wordmarkLines.enumerated() {
        drawText(
            context, line,
            centerX: centerX, centerY: firstCenter - step * CGFloat(index),
            size: size, font: wordmarkFont, color: white
        )
    }
}

func flatIcon(_ width: Int, _ height: Int) -> CGContext {
    let context = makeContext(width, height)
    drawBackground(context, CGFloat(width), CGFloat(height))
    drawWordmark(context, CGFloat(width), CGFloat(height))
    return context
}

// MARK: - Output helpers

func writePNG(_ context: CGContext, to path: String) {
    guard let image = context.makeImage() else { return }
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func makeDirectory(_ path: String) {
    try? FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true
    )
}

func writeJSON(_ object: Any, to path: String) {
    let data = try! JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
    )
    try? data.write(to: URL(fileURLWithPath: path))
}

let catalogInfo: [String: Any] = ["info": ["author": "xcode", "version": 1]]

// MARK: - iOS

func buildiOS() -> String {
    let assets = "\(repoRoot)/Apps/iOS/Assets.xcassets"
    let iconSet = "\(assets)/AppIcon.appiconset"
    makeDirectory(iconSet)

    // Modern iOS takes a single 1024pt image and derives the rest.
    writePNG(flatIcon(1024, 1024), to: "\(iconSet)/icon-1024.png")
    writeJSON([
        "images": [[
            "filename": "icon-1024.png", "idiom": "universal",
            "platform": "ios", "size": "1024x1024",
        ]],
        "info": ["author": "xcode", "version": 1],
    ], to: "\(iconSet)/Contents.json")
    writeJSON(catalogInfo, to: "\(assets)/Contents.json")

    // Launch background colour referenced from Info.plist's UILaunchScreen.
    let colorSet = "\(assets)/LaunchBackground.colorset"
    makeDirectory(colorSet)
    writeJSON([
        "colors": [[
            "color": [
                "color-space": "srgb",
                "components": [
                    "alpha": "1.000", "blue": "0.251", "green": "0.063", "red": "0.000",
                ],
            ],
            "idiom": "universal",
        ]],
        "info": ["author": "xcode", "version": 1],
    ], to: "\(colorSet)/Contents.json")

    return iconSet
}

// MARK: - macOS

func buildMacOS() -> String {
    let assets = "\(repoRoot)/Apps/macOS/Assets.xcassets"
    let iconSet = "\(assets)/AppIcon.appiconset"
    makeDirectory(iconSet)

    // macOS wants explicit 1x/2x pairs, so every pixel size in the pairs is rendered.
    let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]
    for size in pixelSizes {
        writePNG(flatIcon(size, size), to: "\(iconSet)/icon-\(size).png")
    }

    var images: [[String: String]] = []
    for base in [16, 32, 128, 256, 512] {
        images.append([
            "filename": "icon-\(base).png", "idiom": "mac",
            "scale": "1x", "size": "\(base)x\(base)",
        ])
        images.append([
            "filename": "icon-\(base * 2).png", "idiom": "mac",
            "scale": "2x", "size": "\(base)x\(base)",
        ])
    }
    writeJSON([
        "images": images,
        "info": ["author": "xcode", "version": 1],
    ], to: "\(iconSet)/Contents.json")
    writeJSON(catalogInfo, to: "\(assets)/Contents.json")

    return iconSet
}

// MARK: - tvOS
//
// The app icon is an image *stack*: layers composited back-to-front, which tvOS
// separates in 3D as the icon gains focus.

// Every tvOS image asset needs both scales. Shipping 1x alone builds and runs fine, but
// App Store Connect rejects the upload:
//
//   Invalid Image Asset. The image asset 'App Icon' is missing an image for the
//   background layer with a scale value of '2'.
//
// Each scale is drawn at its own pixel size rather than resampled up from the 1x render.
// Everything here is positioned proportionally to the canvas, so the 2x pass is a
// genuine high-resolution draw — which matters most for the wordmark, whose pixel type
// would otherwise be interpolated into mush.
func writeLayer(_ layerPath: String, _ oneX: CGContext, _ twoX: CGContext) {
    let content = "\(layerPath)/Content.imageset"
    makeDirectory(content)
    writeJSON(catalogInfo, to: "\(layerPath)/Contents.json")
    writePNG(oneX, to: "\(content)/layer.png")
    writePNG(twoX, to: "\(content)/layer@2x.png")
    writeJSON([
        "images": [
            ["filename": "layer.png", "idiom": "tv", "scale": "1x"],
            ["filename": "layer@2x.png", "idiom": "tv", "scale": "2x"],
        ],
        "info": ["author": "xcode", "version": 1],
    ], to: "\(content)/Contents.json")
}

func buildImageStack(_ path: String, _ width: Int, _ height: Int) {
    makeDirectory(path)
    // Front is listed first: layers are ordered front-to-back in Contents.json.
    writeJSON([
        "layers": [
            ["filename": "Front.imagestacklayer"],
            ["filename": "Back.imagestacklayer"],
        ],
        "info": ["author": "xcode", "version": 1],
    ], to: "\(path)/Contents.json")

    func render(_ scale: Int) -> (back: CGContext, front: CGContext) {
        let pixelWidth = width * scale
        let pixelHeight = height * scale
        let back = makeContext(pixelWidth, pixelHeight)
        drawBackground(back, CGFloat(pixelWidth), CGFloat(pixelHeight))
        // Transparent apart from the wordmark, so it floats above the field in parallax.
        let front = makeContext(pixelWidth, pixelHeight)
        drawWordmark(front, CGFloat(pixelWidth), CGFloat(pixelHeight))
        return (back, front)
    }

    let oneX = render(1)
    let twoX = render(2)
    writeLayer("\(path)/Back.imagestacklayer", oneX.back, twoX.back)
    writeLayer("\(path)/Front.imagestacklayer", oneX.front, twoX.front)
}

func buildTopShelf(_ path: String, _ width: Int, _ height: Int) {
    makeDirectory(path)

    func render(_ scale: Int) -> CGContext {
        let pixelWidth = width * scale
        let pixelHeight = height * scale
        let context = makeContext(pixelWidth, pixelHeight)
        drawBackground(context, CGFloat(pixelWidth), CGFloat(pixelHeight))
        drawText(
            context, wordmarkLines.joined(separator: " "),
            centerX: CGFloat(pixelWidth) / 2, centerY: CGFloat(pixelHeight) * 0.42,
            size: CGFloat(pixelHeight) * 0.17, font: wordmarkFont, color: white
        )
        return context
    }

    writePNG(render(1), to: "\(path)/shelf.png")
    writePNG(render(2), to: "\(path)/shelf@2x.png")
    writeJSON([
        "images": [
            ["filename": "shelf.png", "idiom": "tv", "scale": "1x"],
            ["filename": "shelf@2x.png", "idiom": "tv", "scale": "2x"],
        ],
        "info": ["author": "xcode", "version": 1],
    ], to: "\(path)/Contents.json")
}

func buildTVOS() -> String {
    let assets = "\(repoRoot)/Apps/tvOS/Assets.xcassets"
    let brand = "\(assets)/App Icon & Top Shelf Image.brandassets"
    makeDirectory(brand)
    writeJSON(catalogInfo, to: "\(assets)/Contents.json")

    writeJSON([
        "assets": [
            ["filename": "App Icon.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "400x240"],
            ["filename": "App Icon - App Store.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "1280x768"],
            ["filename": "Top Shelf Image.imageset", "idiom": "tv",
             "role": "top-shelf-image", "size": "1920x720"],
            ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv",
             "role": "top-shelf-image-wide", "size": "2320x720"],
        ],
        "info": ["author": "xcode", "version": 1],
    ], to: "\(brand)/Contents.json")

    buildImageStack("\(brand)/App Icon.imagestack", 400, 240)
    buildImageStack("\(brand)/App Icon - App Store.imagestack", 1280, 768)
    buildTopShelf("\(brand)/Top Shelf Image.imageset", 1920, 720)
    buildTopShelf("\(brand)/Top Shelf Image Wide.imageset", 2320, 720)

    return brand
}

// MARK: - Entry point

print("iOS   -> \(buildiOS())")
print("macOS -> \(buildMacOS())")
print("tvOS  -> \(buildTVOS())")
