import XCTest

/// Launch check of the application shell.
///
/// A Debug launch that names no stand — no `-paranoid-realm` / `-paranoid-pin`
/// and no `-paranoid-allow-hosted` — shows the stand guard and nothing else:
/// no identity is created and no connection is opened. That is what keeps
/// every simulator run on the local stand and off the hosted alpha, which has
/// exactly one account and no reserve; `clients/ios/test_ui_contract.py`
/// states the same rule about the source. The screen-level flows bring a
/// stand of their own.
final class ParanoIDUITests: XCTestCase {
    @MainActor
    func testApplicationLaunchesIntoTheStandGuard() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Стенд не задан. Запустите с параметрами локального сервера."]
                .waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["create-id"].exists)
    }
}
