import XCTest
import UIKit

/// Opens each screen on a device that has been rotated to landscape and saves a screenshot of it.
/// Each test fails when the app window does not end up wider than it is tall, so a rotation that silently
/// did not happen can never pass as a landscape check. Run by the `ipad-landscape` and `iphone-landscape` CI jobs.
final class LandscapeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// The simulator hands back its portrait frame buffer with a landscape picture lying on its side, so turn it upright.
    private func uprightScreenshot() -> UIImage {
        // Redraw first so the image's own orientation flag is applied to the pixels that get saved.
        let source: UIImage = XCUIScreen.main.screenshot().image
        let sourceFormat = UIGraphicsImageRendererFormat()
        sourceFormat.scale = source.scale
        let image: UIImage = UIGraphicsImageRenderer(size: source.size, format: sourceFormat).image { _ in source.draw(at: .zero) }
        guard image.size.height > image.size.width else { return image }
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.rotate(by: -.pi / 2)
            image.draw(at: .zero)
        }
    }

    private func check(_ screen: String, settle: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments = ["-lmScreen", screen]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "No app window for \(screen)", file: file, line: line)

        // Give the rotation a few seconds, then let the screen finish loading its sample content.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, window.frame.width <= window.frame.height {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(settle))

        let frame = window.frame
        let shot = XCTAttachment(image: uprightScreenshot())
        shot.name = "landscape-\(screen)"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertGreaterThan(frame.width, frame.height, "\(screen): window is \(Int(frame.width))x\(Int(frame.height)), not landscape", file: file, line: line)
        XCTAssertTrue(app.state == .runningForeground, "\(screen): app left the foreground", file: file, line: line)
        app.terminate()
    }

    func testOnboarding() { check("onboarding") }
    func testHome() { check("home") }
    func testHomeFilled() { check("home-filled") }
    func testSettings() { check("settings") }
    func testEditor() { check("editor") }
    func testEditorFlow() { check("editor-flow") }
    func testEditorVideo() { check("editor-video") }
    func testEditorLooks() { check("editor-looks") }
    func testEditorOverlays() { check("editor-overlays") }
    func testEditorText() { check("editor-text") }
    func testEditorLayers() { check("editor-layers") }
    func testExport() { check("export") }
}

/// Walks the real first-run path in portrait: welcome screen, Get started, Home with its actions.
final class FirstRunUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testWelcomeThenHome() {
        XCUIDevice.shared.orientation = .portrait
        // The tracking prompt can appear over Home once ads start. Decline it so it never blocks a tap.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Ask App Not to Track", "Don’t Allow", "Don't Allow", "Not Now", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let app = XCUIApplication()
        // The launch argument overrides the stored value, so every run starts on the welcome screen.
        app.launchArguments = ["-lm.hasOnboarded", "NO", "-lmNoAds", "YES"]
        app.launch()

        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 30), "Welcome screen has no Get started button")
        getStarted.tap()

        XCTAssertTrue(app.buttons["New from photo"].waitForExistence(timeout: 20), "Home has no New from photo button")
        XCTAssertTrue(app.buttons["New cinemagraph from video"].exists, "Home has no cinemagraph button")
        XCTAssertTrue(app.buttons["Settings"].exists, "Home has no Settings button")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10) || app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), "Settings has no Done button")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["New from photo"].waitForExistence(timeout: 10))
    }
}
