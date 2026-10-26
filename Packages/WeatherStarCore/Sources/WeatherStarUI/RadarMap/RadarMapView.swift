#if canImport(MapKit) && !os(tvOS)
import MapKit
import os
import SwiftUI
import WeatherStarKit

/// The radar frame on show, as one overlay covering the box it was requested for.
final class RadarImageOverlay: NSObject, MKOverlay {
    let boundingMapRect: MKMapRect

    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    init(box: MercatorBox) {
        boundingMapRect = MapGeometry.mapRect(for: box)
    }
}

/// Draws the frame image into its overlay.
///
/// MapKit calls `draw` on its own threads, so the image is swapped under a lock rather than
/// read straight from a property the main thread is writing.
final class RadarImageRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let current = OSAllocatedUnfairLock<CGImage?>(initialState: nil)

    func show(_ image: CGImage?) {
        current.withLock { $0 = image }
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let image = current.withLock({ $0 }) else { return }
        let rect = self.rect(for: overlay.boundingMapRect)
        // The renderer's space runs top-down, like the map's; an image draws bottom-up.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// Conversions between MapKit's map points and Web Mercator metres.
///
/// MapKit's map points are Web Mercator scaled to a 2²⁸-point world with the origin at the
/// north-west corner; the WMS wants metres from the centre with north up.
enum MapGeometry {
    private static var metresPerPoint: Double { 2 * MercatorBox.extent / MKMapSize.world.width }

    static func box(for rect: MKMapRect) -> MercatorBox {
        MercatorBox(
            minX: rect.minX * metresPerPoint - MercatorBox.extent,
            minY: MercatorBox.extent - rect.maxY * metresPerPoint,
            maxX: rect.maxX * metresPerPoint - MercatorBox.extent,
            maxY: MercatorBox.extent - rect.minY * metresPerPoint
        )
    }

    static func mapRect(for box: MercatorBox) -> MKMapRect {
        MKMapRect(
            x: (box.minX + MercatorBox.extent) / metresPerPoint,
            y: (MercatorBox.extent - box.maxY) / metresPerPoint,
            width: (box.maxX - box.minX) / metresPerPoint,
            height: (box.maxY - box.minY) / metresPerPoint
        )
    }
}

/// Apple Maps with the radar frame over it.
///
/// The map tells its owner when the view has settled after a pan or zoom, with the box to
/// fetch frames for; the owner hands back whichever frame is on show.
struct RadarMapView {
    let image: CGImage?
    let box: MercatorBox?
    let center: SavedLocation?
    let recentreRequest: Int
    /// A view has settled: fetch frames for this box at this pixel size.
    let onSettle: (MercatorBox, CGSize) -> Void

    /// About 650 km across: a region, like the WeatherStar window, to start from.
    private static let span = MKCoordinateSpan(latitudeDelta: 4.5, longitudeDelta: 5.5)
    /// Enough to read, not so much the towns under it vanish.
    static let opacity: CGFloat = 0.75

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator(onSettle: onSettle) }

    @MainActor
    private func makeMap(coordinator: Coordinator) -> MKMapView {
        let map = MKMapView()
        map.delegate = coordinator
        // Muted, so the radar's colours are the loudest thing on the map.
        map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        if let center {
            let coordinate = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
            map.setRegion(MKCoordinateRegion(center: coordinate, span: Self.span), animated: false)
            let pin = MKPointAnnotation()
            pin.coordinate = coordinate
            pin.title = center.name
            map.addAnnotation(pin)
        }
        return map
    }

    @MainActor
    private func update(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.onSettle = onSettle

        if coordinator.box != box {
            coordinator.box = box
            if let overlay = coordinator.overlay { map.removeOverlay(overlay) }
            coordinator.overlay = nil
            coordinator.renderer = nil
            if let box {
                let overlay = RadarImageOverlay(box: box)
                coordinator.overlay = overlay
                coordinator.pendingImage = image
                map.addOverlay(overlay, level: .aboveRoads)
            }
        }
        if let renderer = coordinator.renderer {
            renderer.show(image)
        } else {
            coordinator.pendingImage = image
        }

        if coordinator.recentreRequest != recentreRequest, let center {
            coordinator.recentreRequest = recentreRequest
            let coordinate = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
            map.setRegion(MKCoordinateRegion(center: coordinate, span: Self.span), animated: true)
        }

        // The first view never "changes", so ask for it once the map has a size.
        if !coordinator.hasRequested, map.bounds.width > 0 {
            coordinator.settle(map)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSettle: (MercatorBox, CGSize) -> Void
        var box: MercatorBox?
        var overlay: RadarImageOverlay?
        var renderer: RadarImageRenderer?
        /// The frame to show once the renderer exists: MapKit creates it on its own schedule.
        var pendingImage: CGImage?
        var recentreRequest = 0
        var hasRequested = false
        private var settleTask: Task<Void, Never>?

        init(onSettle: @escaping (MercatorBox, CGSize) -> Void) {
            self.onSettle = onSettle
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard overlay is RadarImageOverlay else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = RadarImageRenderer(overlay: overlay)
            renderer.alpha = RadarMapView.opacity
            renderer.show(pendingImage)
            self.renderer = renderer
            return renderer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Wait for the hand to stop: a pan is dozens of region changes, and each settled
            // view costs a dozen requests.
            settleTask?.cancel()
            settleTask = Task { [weak self, weak mapView] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, let mapView else { return }
                self.settle(mapView)
            }
        }

        /// Ask for frames covering the view, with a margin so a small pan stays covered.
        func settle(_ map: MKMapView) {
            hasRequested = true
            let visible = map.visibleMapRect
            let margin = 0.25
            let rect = visible.insetBy(dx: -visible.width * margin / 2, dy: -visible.height * margin / 2)

            #if os(macOS)
            let scale = map.window?.backingScaleFactor ?? 2
            #else
            let scale = map.traitCollection.displayScale
            #endif
            // Screen resolution with the margin, capped: past about 1600 pixels the composite's
            // half-kilometre cells are already finer than the screen can show.
            var size = CGSize(
                width: map.bounds.width * (1 + margin) * scale,
                height: map.bounds.height * (1 + margin) * scale
            )
            let longest = max(size.width, size.height)
            if longest > 1600 {
                size = CGSize(width: size.width * 1600 / longest, height: size.height * 1600 / longest)
            }
            onSettle(MapGeometry.box(for: rect), size)
        }
    }
}

#if os(macOS)
extension RadarMapView: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(coordinator: context.coordinator) }
    func updateNSView(_ map: MKMapView, context: Context) { update(map, coordinator: context.coordinator) }
}
#else
extension RadarMapView: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(coordinator: context.coordinator) }
    func updateUIView(_ map: MKMapView, context: Context) { update(map, coordinator: context.coordinator) }
}
#endif
#endif
