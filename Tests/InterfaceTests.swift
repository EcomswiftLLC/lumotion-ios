import XCTest
import UIKit
@testable import Lumotion

/// Tests for the pieces behind the screens (not the engine).
final class InterfaceTests: XCTestCase {
    func testSampleTitles() {
        XCTAssertEqual(SampleRef(name: "sample_golden-hour_02").title, "Golden hour")
        XCTAssertEqual(SampleRef(name: "harbour").title, "Harbour")
        XCTAssertEqual(SampleRef(name: "sample_01").title, "Sample")
    }

    func testFormatting() {
        XCTAssertEqual(LMFormat.seconds(4), "4.0 s")
        XCTAssertEqual(LMFormat.clock(65), "1:05")
        XCTAssertEqual(LMFormat.clock(-3), "0:00")
    }

    func testExportItemTypes() {
        let video = ExportItem(url: URL(fileURLWithPath: "/tmp/a.mp4"), kind: .video)
        XCTAssertTrue(video.utType.conforms(to: .movie))
        let gif = ExportItem(url: URL(fileURLWithPath: "/tmp/a.gif"), kind: .gif)
        XCTAssertEqual(gif.utType, .gif)
        let png = ExportItem(url: URL(fileURLWithPath: "/tmp/a.png"), kind: .still)
        XCTAssertEqual(png.utType, .png)
    }

    func testShareFolderIsCleared() throws {
        let url = ExportItem.makeURL(base: "test", ext: "txt")
        try Data("x".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        ExportItem.clearShareFolder()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDecodePhotoLimitsSizeAndKeepsSmallPhotos() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let data = try XCTUnwrap(big.jpegData(compressionQuality: 0.8))
        let reduced = try XCTUnwrap(MediaLoader.decodePhoto(data, name: "t", maxPixel: 1000))
        XCTAssertEqual(max(reduced.image.width, reduced.image.height), 1000)
        let kept = try XCTUnwrap(MediaLoader.decodePhoto(data, name: "t", maxPixel: 8000))
        XCTAssertEqual(kept.image.width, 3000)
        XCTAssertNil(MediaLoader.decodePhoto(Data([1, 2, 3]), name: "bad"))
    }

    func testExportChoiceDefaults() {
        let choice = ExportChoice()
        XCTAssertEqual(choice.format, .h264)
        XCTAssertEqual(choice.resolution, .p1080)
        XCTAssertEqual(ExportChoice.Resolution.p1440.title, "2K")
    }

    func testEveryToolHasTitleAndSymbol() {
        for tool in EditorTool.allCases {
            XCTAssertFalse(tool.title.isEmpty)
            XCTAssertNotNil(UIImage(systemName: tool.symbol), "Missing SF Symbol \(tool.symbol)")
        }
    }

    func testRewardedPolicyGrace() {
        var policy = RewardedPolicy()
        XCTAssertTrue(policy.shouldOffer(adReady: true))
        XCTAssertFalse(policy.shouldOffer(adReady: false))
        policy.didEarnReward()
        XCTAssertFalse(policy.shouldOffer(adReady: true))
    }
}
