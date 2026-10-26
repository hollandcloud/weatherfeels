import Foundation
import Testing
@testable import WeatherStarKit

/// The zoomable radar map's requests.
@Suite("Radar map requests")
struct RadarMapSourceTests {
    /// Tampa in Web Mercator, computed independently of the code under test.
    private let tampaX = -82.4572 * 20_037_508.342789244 / 180
    private let tampaY = log(tan((90 + 27.9506) * .pi / 360)) * 20_037_508.342789244 / .pi

    @Test("A frame is requested for exactly the box in view, in Web Mercator")
    func requestCarriesTheBox() throws {
        let box = MercatorBox(minX: tampaX - 300_000, minY: tampaY - 200_000, maxX: tampaX + 300_000, maxY: tampaY + 200_000)
        let time = Date(timeIntervalSince1970: 1_793_030_100)
        let url = try #require(RadarMapSource.imageURL(box: box, width: 1200, height: 800, time: time))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(url.host == "mesonet.agron.iastate.edu")
        #expect(value("SRS") == "EPSG:3857")
        #expect(value("LAYERS") == "nexrad-n0q-wmst")
        #expect(value("WIDTH") == "1200")
        #expect(value("HEIGHT") == "800")
        #expect(value("TIME") == "2026-10-26T15:55:00Z")
        let bbox = try #require(value("BBOX")).split(separator: ",").compactMap { Double($0) }
        #expect(bbox.count == 4)
        #expect(abs(bbox[0] - box.minX) < 0.1 && abs(bbox[3] - box.maxY) < 0.1)
    }

    @Test("Coverage is the lower 48: Tampa is in, Honolulu and Anchorage are out")
    func coverage() {
        func around(latitude: Double, longitude: Double) -> MercatorBox {
            let x = RadarMapSource.mercatorX(longitude: longitude)
            let y = RadarMapSource.mercatorY(latitude: latitude)
            return MercatorBox(minX: x - 50_000, minY: y - 50_000, maxX: x + 50_000, maxY: y + 50_000)
        }
        #expect(abs(RadarMapSource.mercatorX(longitude: -82.4572) - tampaX) < 0.01)
        #expect(abs(RadarMapSource.mercatorY(latitude: 27.9506) - tampaY) < 0.01)
        #expect(RadarMapSource.covers(around(latitude: 27.9506, longitude: -82.4572)))
        #expect(!RadarMapSource.covers(around(latitude: 21.3069, longitude: -157.8583)))
        #expect(!RadarMapSource.covers(around(latitude: 61.2181, longitude: -149.9003)))
    }

    @Test("Frame times fall on the composite's five-minute marks")
    func fiveMinuteMarks() {
        let date = Date(timeIntervalSince1970: 1_793_030_399)
        #expect(RadarMapSource.roundedDown(date).timeIntervalSince1970 == 1_793_030_100)
    }
}
