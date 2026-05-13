import XCTest

final class PermissionFlowUITests: PhotoSifterUITestCase {

    // MARK: - Permission screen appearance

    func testPermissionScreen_appearsOnFirstLaunch() {
        launchFresh()

        // The permission screen headline should be visible
        let title = app.staticTexts["PhotoSifter"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "App title should appear on the permission screen")
    }

    func testPermissionScreen_showsFeatureBullets() {
        launchFresh()

        let bullets = [
            "AI groups your near-duplicates",
            "Swipe right to keep, left to delete",
            "Deleted photos go to Recently Deleted",
        ]
        for text in bullets {
            XCTAssertTrue(
                app.staticTexts[text].waitForExistence(timeout: 3),
                "Feature bullet '\(text)' should be visible"
            )
        }
    }

    func testPermissionScreen_allowButton_exists() {
        launchFresh()

        let button = app.buttons["allowPhotoAccessButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Allow Photo Access button should exist")
        XCTAssertTrue(button.isEnabled)
    }

    func testPermissionScreen_allowButton_tappable() {
        launchFresh()

        let button = app.buttons["allowPhotoAccessButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))

        // Tapping triggers the system permission dialog — we can't assert past that in UI tests
        // without special entitlements. Just verify the button responds.
        XCTAssertTrue(button.isHittable)
    }

    // MARK: - Denied state

    func testDeniedView_showsSettingsButton() {
        app.launchArguments = ["UI_TESTING", "FORCE_DENIED"]
        app.launch()

        let settingsButton = app.buttons["Open Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Open Settings button should appear when access is denied")
    }
}
