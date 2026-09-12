import XCTest

/// Launch check of the application shell; screen-level UI tests arrive with
/// the screens themselves.
final class ParanoIDUITests: XCTestCase {
    @MainActor
    func testApplicationLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["ParanoID"].waitForExistence(timeout: 10))
    }
}
