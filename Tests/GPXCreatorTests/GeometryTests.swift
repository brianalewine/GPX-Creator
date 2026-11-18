import XCTest
@testable import GPXCreator
final class GeometryTests: XCTestCase {
    func testFillPreservesAnchorsAndRecomputes() {
        let a=Point(lat:0,lng:0,time:0);var b=Point(lat:10,lng:10,time:10)
        let filled=Geometry.filled([a,b]);XCTAssertEqual(filled.count,11);XCTAssertEqual(filled[5].lat,5);XCTAssertTrue(filled.first!.manual)
        b.lat=20;XCTAssertEqual(Geometry.filled([a,b])[5].lat,10)
    }
    func testDateline() {let p=Geometry.interpolate([Point(lat:0,lng:179,time:0),Point(lat:0,lng:-179,time:2)],at:1)!;XCTAssertEqual(abs(p.lng),180,accuracy:0.001)}
    func testGPXTimestamp() throws {
        let xml="<gpx><trk><trkseg><trkpt lat=\"42\" lon=\"-71\"><time>2026-01-01T00:00:00Z</time></trkpt><trkpt lat=\"43\" lon=\"-72\"><time>2026-01-01T00:00:05Z</time></trkpt></trkseg></trk></gpx>"
        let p=try GPXParser.parse(Data(xml.utf8));XCTAssertEqual(p.count,2);XCTAssertEqual(p[1].time,5)
    }
    func testRejectEmpty() {XCTAssertThrowsError(try GPXParser.parse(Data("<gpx/>".utf8)))}
}
