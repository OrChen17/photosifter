import XCTest

/// Base class that every UI test file inherits from.
/// Handles app launch and common launch arguments.
class PhotoSifterUITestCase: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Launch the app as if it is the very first run (permission not yet granted).
    func launchFresh() {
        app.launchArguments = ["UI_TESTING", "RESET_AUTH"]
        app.launch()
    }

    /// Launch the app with photo library access already granted (uses simulator sample photos).
    func launchAuthorized() {
        app.launchArguments = ["UI_TESTING"]
        app.launch()
    }
}
