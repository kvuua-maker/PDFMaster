import XCTest

/// Captures real app screens from the simulator for the App Store listing.
/// Each screenshot is attached to the test result so CI can export it.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureScreens() throws {
        // 1. Home
        XCTAssertTrue(app.staticTexts["PDF MASTER"].waitForExistence(timeout: 20))
        sleep(1)
        capture("01-home")

        // 2. Workspace
        app.staticTexts["Створити"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        sleep(1)
        capture("02-tools")

        // 3. Photo source dialog
        app.buttons["PDF з фото"].firstMatch.tap()
        sleep(1)
        capture("03-photo-menu")
        app.buttons["Скасувати"].firstMatch.tap()
        sleep(1)

        // 4. Office conversion screen
        app.buttons["Word / Excel → PDF"].firstMatch.tap()
        sleep(1)
        capture("04-office")
        app.buttons["Готово"].firstMatch.tap()
        sleep(1)

        // 5. Signature canvas with a drawn stroke
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "підпис")).firstMatch.tap()
        sleep(2)
        let canvas = app.otherElements.firstMatch
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        let finish = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: finish)
        sleep(1)
        capture("05-signature")
    }
}
