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

    func testExportsFolderIsCleared() throws {
        try FileManager.default.createDirectory(at: Exporter.exportsFolder, withIntermediateDirectories: true)
        let url = Exporter.exportsFolder.appendingPathComponent("test-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        Exporter.clearOldExports(olderThan: 0)
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
        XCTAssertEqual(ExportResolution.k2.title, "2K")
    }

    func testEveryToolHasTitleAndSymbol() {
        for tool in EditorTool.allCases {
            XCTAssertFalse(tool.title.isEmpty)
            XCTAssertNotNil(UIImage(systemName: tool.symbol), "Missing SF Symbol \(tool.symbol)")
        }
    }

    func testEverySymbolExists() {
        for kind in OverlayKind.allCases {
            XCTAssertNotNil(UIImage(systemName: Labels.overlaySymbol(kind)), "Missing SF Symbol \(Labels.overlaySymbol(kind))")
        }
        for kind in LivingEffectKind.allCases {
            XCTAssertNotNil(UIImage(systemName: Labels.effectSymbol(kind)), "Missing SF Symbol \(Labels.effectSymbol(kind))")
        }
        for direction in PanDirection.allCases {
            XCTAssertNotNil(UIImage(systemName: Labels.directionSymbol(direction)))
        }
    }

    @MainActor
    func testResolutionIsClampedToWhatIsOffered() {
        let coordinator = ExportCoordinator()
        coordinator.sourceLongSide = 900
        coordinator.choice.resolution = .k4
        coordinator.clampChoice()
        XCTAssertTrue(coordinator.offeredResolutions(for: .h264).contains(coordinator.choice.resolution))
        XCTAssertNotEqual(coordinator.choice.resolution, .p1080, "A small photo is not offered 1080p")
        XCTAssertFalse(coordinator.isBusy)
    }

    @MainActor
    func testPaintAreaIsOneUndoStepAndCoversTheArea() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 500), format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
        }.cgImage!
        let project = Project.new(title: "Test", kind: .still, fileName: "source.jpg", pixelWidth: 400, pixelHeight: 500)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LumotionTestStore-\(UUID().uuidString)", isDirectory: true)
        let model = EditorModel(project: project, assets: SourceAssets(still: image), store: ProjectStore(rootURL: folder))
        model.paintArea(.lower, target: .cinemagraph)
        XCTAssertEqual(model.project.cinemagraph.maskStrokes.count, 1)
        let points = model.project.cinemagraph.maskStrokes[0].points
        XCTAssertGreaterThan(points.count, 10)
        XCTAssertTrue(points.allSatisfy { $0.y >= 0.5 - 0.0001 && $0.y <= 1 && $0.x >= 0 && $0.x <= 1 }, "Points stay inside the lower half")
        model.undo()
        XCTAssertTrue(model.project.cinemagraph.maskStrokes.isEmpty)
    }

    @MainActor
    func testLargeExportsGetAWarning() {
        let project = Project.new(title: "Test", kind: .still, fileName: "source.jpg", pixelWidth: 400, pixelHeight: 500)
        let model = EditorModel(project: project, assets: SourceAssets(), store: ProjectStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("LumotionTestStore-\(UUID().uuidString)", isDirectory: true)))
        var choice = ExportChoice()
        choice.resolution = .p720
        XCTAssertNil(model.exportWarning(for: choice))
        choice.resolution = .k4
        XCTAssertNotNil(model.exportWarning(for: choice))
    }

    func testRewardedPolicyGrace() {
        var policy = RewardedPolicy()
        XCTAssertTrue(policy.shouldOffer(adReady: true))
        XCTAssertFalse(policy.shouldOffer(adReady: false))
        policy.didEarnReward()
        XCTAssertFalse(policy.shouldOffer(adReady: true))
    }
}
