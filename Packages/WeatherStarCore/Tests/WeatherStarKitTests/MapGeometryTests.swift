#if canImport(MapKit) && !os(tvOS)
import MapKit
import Testing
@testable import WeatherStarKit
@testable import WeatherStarUI

/// MapKit's map points against Web Mercator metres: the radar frame is requested in one and
/// drawn in the other, so a slip between them is a radar drawn in the wrong place.
@Suite("Radar map geometry")
@MainActor
struct MapGeometryTests {
    @Test("A box survives the trip through map points")
    func roundTrip() {
        let box = MercatorBox(minX: -9_480_000, minY: 3_000_000, maxX: -8_700_000, maxY: 3_600_000)
        let back = MapGeometry.box(for: MapGeometry.mapRect(for: box))
        #expect(abs(back.minX - box.minX) < 0.01)
        #expect(abs(back.minY - box.minY) < 0.01)
        #expect(abs(back.maxX - box.maxX) < 0.01)
        #expect(abs(back.maxY - box.maxY) < 0.01)
    }

    /// Against MapKit's own projection: Tampa's map point, converted, is Tampa's Mercator
    /// position as the WMS computes it.
    @Test("MapKit and the WMS agree where Tampa is")
    func agreesWithMapKit() {
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: 27.9506, longitude: -82.4572))
        let box = MapGeometry.box(for: MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        #expect(abs(box.minX - RadarMapSource.mercatorX(longitude: -82.4572)) < 1)
        #expect(abs(box.maxY - RadarMapSource.mercatorY(latitude: 27.9506)) < 1)
    }
}
#endif
