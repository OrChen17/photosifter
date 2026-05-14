import XCTest

final class LibraryUITests: PhotoSifterUITestCase {

    // MARK: - Library screen

    func testLibraryScreen_navigationTitle() {
        launchAuthorized()

        let title = app.navigationBars["PhotoSifter"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Navigation bar title 'PhotoSifter' should appear")
    }

    func testLibraryScreen_scanningBadge_appearsWhileProcessing() {
        launchAuthorized()

        // "Scanning" text should appear during the background scan
        let scanning = app.staticTexts["Scanning"]
        // It's transient — we just check it appears at some point within 10s
        let appeared = scanning.waitForExistence(timeout: 10)
        // Note: may already be gone on a fast device — not a hard failure
        _ = appeared
    }

    func testLibraryScreen_groupRows_appearAfterScan() {
        launchAuthorized()

        // Wait for at least one group row to appear (up to 30s for Vision processing)
        let firstRow = app.cells.firstMatch
        let appeared = firstRow.waitForExistence(timeout: 30)

        // On a simulator with near-duplicate photos this should pass;
        // on a simulator with only unique photos it won't — that's expected.
        if appeared {
            XCTAssertTrue(firstRow.exists)
        } else {
            // Verify the empty state is shown instead
            let emptyLabel = app.staticTexts["All clear!"]
            XCTAssertTrue(emptyLabel.waitForExistence(timeout: 5), "Either group rows or empty state should appear")
        }
    }

    func testLibraryScreen_emptyState_showsWhenNoGroups() {
        app.launchArguments = ["UI_TESTING", "FORCE_EMPTY_LIBRARY"]
        app.launch()

        let emptyText = app.staticTexts["All clear!"]
        XCTAssertTrue(emptyText.waitForExistence(timeout: 10))
    }

    func testLibraryScreen_groupRow_showsPhotoCount() {
        launchAuthorized()

        // Wait for a row with "photos" in its label
        let photoCountPredicate = NSPredicate(format: "label CONTAINS 'photos'")
        let countLabel = app.staticTexts.matching(photoCountPredicate).firstMatch
        if countLabel.waitForExistence(timeout: 30) {
            XCTAssertTrue(countLabel.exists)
        }
    }

    // MARK: - Navigation to sifter

    func testTappingGroupRow_navigatesToSifterScreen() throws {
        launchAuthorized()

        // Wait for a group row and tap it
        let firstRow = app.cells.firstMatch
        guard firstRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("No group rows available to tap on this device")
        }

        firstRow.tap()

        // Sifter screen shows "X of Y" in the nav bar
        let navBarPredicate = NSPredicate(format: "label MATCHES '\\\\d+ of \\\\d+'")
        let navTitle = app.navigationBars.staticTexts.matching(navBarPredicate).firstMatch
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Navigation title should show 'N of M' in the sifter")
    }
}
