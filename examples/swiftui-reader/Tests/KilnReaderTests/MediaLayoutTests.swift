import KilnModels
@testable import KilnReader
import XCTest

final class MediaLayoutTests: XCTestCase {
    func hero() throws -> MediaSnapshot {
        let recipe = try JSONDecoder().decode(RecipeDocument.self, from: fixture("recipe-artifact"))
        return try XCTUnwrap(recipe.customFields.hero)
    }

    func testPicksTheSmallestUncroppedVariantWideEnoughPreferringFewerBytes() throws {
        let hero = try hero()
        let label = { (width: CGFloat) in hero.variants?.first { $0.url == MediaLayout.source(for: hero, pixelWidth: width) }?.label }

        XCTAssertEqual(label(128), "thumb.webp")
        XCTAssertEqual(label(400), "thumb.webp")
        XCTAssertEqual(label(401), "medium.webp")
        // The 800px card is cropped by the server, so it's never chosen.
        XCTAssertEqual(label(800), "medium.webp")
        XCTAssertEqual(label(1100), "full.webp")
        // Wider than any variant: the largest, which is the full size.
        XCTAssertEqual(label(4000), "full.webp")
    }

    func testFallsBackToTheOriginalWithoutVariants() {
        let bare = MediaSnapshot(id: "m", url: "/uploads/original.jpg")
        XCTAssertEqual(MediaLayout.source(for: bare, pixelWidth: 300), "/uploads/original.jpg")
        XCTAssertNil(MediaLayout.aspectRatio(of: bare))
    }

    func testAspectRatioFromTheSnapshotDimensions() throws {
        XCTAssertEqual(try XCTUnwrap(MediaLayout.aspectRatio(of: hero())), 1600 / 1067, accuracy: 0.0001)
    }

    func testFillCentresTheFocalPointWithinTheImageEdges() {
        // A 3:2 image in a square frame: drawn 150 wide, 50 to spare.
        let frame = CGSize(width: 100, height: 100)

        let centred = MediaLayout.fill(frame: frame, aspectRatio: 1.5, focal: nil)
        XCTAssertEqual(centred.size, CGSize(width: 150, height: 100))
        XCTAssertEqual(centred.offset, CGSize(width: -25, height: 0))

        // Focal at x = 0.6: 90 into the drawn image, moved to the centre (50).
        XCTAssertEqual(MediaLayout.fill(frame: frame, aspectRatio: 1.5, focal: CGPoint(x: 0.6, y: 0.5)).offset.width, -40, accuracy: 0.001)

        // Near an edge it stops at the edge rather than showing past it.
        XCTAssertEqual(MediaLayout.fill(frame: frame, aspectRatio: 1.5, focal: CGPoint(x: 0.95, y: 0.5)).offset.width, -50)
        XCTAssertEqual(MediaLayout.fill(frame: frame, aspectRatio: 1.5, focal: CGPoint(x: 0.05, y: 0.5)).offset.width, 0)

        // A wide banner from the same image crops vertically instead.
        let banner = MediaLayout.fill(frame: CGSize(width: 300, height: 100), aspectRatio: 1.5, focal: CGPoint(x: 0.5, y: 0.36))
        XCTAssertEqual(banner.size, CGSize(width: 300, height: 200))
        XCTAssertEqual(banner.offset.height, -22, accuracy: 0.001)
    }
}
