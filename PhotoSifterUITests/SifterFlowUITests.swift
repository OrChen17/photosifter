import XCTest

final class SifterFlowUITests: PhotoSifterUITestCase {

    // MARK: - Helpers

    /// Navigate to the first available sifter session, or skip if none.
    private func openFirstSifterSession() throws {
        launchAuthorized()

        let firstRow = app.cells.firstMatch
        guard firstRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("No photo groups found on this device — run on a simulator with near-duplicate photos.")
        }
        firstRow.tap()

        let card = app.otherElements["photoCard"]
        guard card.waitForExistence(timeout: 5) else {
            throw XCTSkip("Sifter card did not appear.")
        }
    }

    // MARK: - Card appearance

    func testSifterScreen_photoCardAppears() throws {
        try openFirstSifterSession()

        let card = app.otherElements["photoCard"]
        XCTAssertTrue(card.exists)
        XCTAssertTrue(card.isHittable)
    }

    func testSifterScreen_undoButtonAppears() throws {
        try openFirstSifterSession()

        let undoButton = app.buttons["undoButton"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 3))
    }

    func testSifterScreen_undoButton_disabledInitially() throws {
        try openFirstSifterSession()

        let undoButton = app.buttons["undoButton"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 3))
        XCTAssertFalse(undoButton.isEnabled, "Undo button should be disabled before any swipe")
    }

    func testSifterScreen_navigationTitleShowsProgress() throws {
        try openFirstSifterSession()

        let navBarPredicate = NSPredicate(format: "label MATCHES '\\\\d+ of \\\\d+'")
        let navTitle = app.navigationBars.staticTexts.matching(navBarPredicate).firstMatch
        XCTAssertTrue(navTitle.waitForExistence(timeout: 3), "Navigation should show '1 of N'")
    }

    // MARK: - Swipe right (keep)

    func testSwipeRight_advancesCard() throws {
        try openFirstSifterSession()

        let card = app.otherElements["photoCard"]
        let initialNavTitle = app.navigationBars.staticTexts.firstMatch.label

        card.swipeRight()

        // Nav title should update
        let newNavPredicate = NSPredicate(format: "label != %@", initialNavTitle)
        let updatedTitle = app.navigationBars.staticTexts.matching(newNavPredicate).firstMatch
        XCTAssertTrue(
            updatedTitle.waitForExistence(timeout: 3),
            "Navigation title should update after swipe"
        )
    }

    func testSwipeRight_enablesUndoButton() throws {
        try openFirstSifterSession()

        let card = app.otherElements["photoCard"]
        let undoButton = app.buttons["undoButton"]

        card.swipeRight()

        XCTAssertTrue(undoButton.waitForExistence(timeout: 3))
        XCTAssertTrue(undoButton.isEnabled, "Undo should be enabled after a swipe")
    }

    // MARK: - Swipe left (delete)

    func testSwipeLeft_advancesCard() throws {
        try openFirstSifterSession()

        let card = app.otherElements["photoCard"]
        let initialNavTitle = app.navigationBars.staticTexts.firstMatch.label

        card.swipeLeft()

        let newNavPredicate = NSPredicate(format: "label != %@", initialNavTitle)
        let updatedTitle = app.navigationBars.staticTexts.matching(newNavPredicate).firstMatch
        XCTAssertTrue(updatedTitle.waitForExistence(timeout: 3))
    }

    // MARK: - Undo

    func testUndo_revertsNavigationTitle() throws {
        try openFirstSifterSession()

        let card = app.otherElements["photoCard"]
        let undoButton = app.buttons["undoButton"]

        let titleBefore = app.navigationBars.staticTexts.firstMatch.label
        card.swipeRight()

        // Wait for title to update
        let differentPredicate = NSPredicate(format: "label != %@", titleBefore)
        XCTAssertTrue(app.navigationBars.staticTexts.matching(differentPredicate).firstMatch.waitForExistence(timeout: 3))

        // Undo
        undoButton.tap()

        // Title should revert
        let originalPredicate = NSPredicate(format: "label == %@", titleBefore)
        XCTAssertTrue(
            app.navigationBars.staticTexts.matching(originalPredicate).firstMatch.waitForExistence(timeout: 3),
            "After undo, navigation title should revert to the original value"
        )
    }

    // MARK: - Complete a full group

    func testCompletingAllSwipes_showsBatchDoneScreen() throws {
        app.launchArguments = ["UI_TESTING", "SMALL_GROUP"]  // hint to use a 2-photo group
        app.launch()

        let firstRow = app.cells.firstMatch
        guard firstRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("No groups on this device.")
        }
        firstRow.tap()

        let card = app.otherElements["photoCard"]
        guard card.waitForExistence(timeout: 5) else {
            throw XCTSkip("Card did not appear.")
        }

        // Swipe through all cards
        var swiped = 0
        while app.otherElements["photoCard"].exists && swiped < 50 {
            app.otherElements["photoCard"].swipeRight()
            swiped += 1
            // Small delay for animation
            _ = app.otherElements["photoCard"].waitForExistence(timeout: 1)
        }

        // Summary sheet should appear
        let continueSifting = app.buttons["continueSiftingButton"]
        XCTAssertTrue(
            continueSifting.waitForExistence(timeout: 5),
            "Session summary with 'Continue Sifting' button should appear after completing all swipes"
        )
    }

    // MARK: - Summary screen

    func testSummaryScreen_continueButton_dismissesSheet() throws {
        app.launchArguments = ["UI_TESTING", "SMALL_GROUP"]
        app.launch()

        let firstRow = app.cells.firstMatch
        guard firstRow.waitForExistence(timeout: 30) else { throw XCTSkip("No groups.") }
        firstRow.tap()

        let card = app.otherElements["photoCard"]
        guard card.waitForExistence(timeout: 5) else { throw XCTSkip("Card did not appear.") }

        var swiped = 0
        while app.otherElements["photoCard"].exists && swiped < 50 {
            app.otherElements["photoCard"].swipeRight()
            swiped += 1
            _ = app.otherElements["photoCard"].waitForExistence(timeout: 1)
        }

        let continueButton = app.buttons["continueSiftingButton"]
        guard continueButton.waitForExistence(timeout: 5) else { throw XCTSkip("Summary not shown.") }

        continueButton.tap()

        // Should return to sifter or library
        let sifterOrLibrary = app.navigationBars.firstMatch
        XCTAssertTrue(sifterOrLibrary.waitForExistence(timeout: 3))
    }

    // MARK: - Back navigation

    func testBackNavigation_returnsToLibrary() throws {
        try openFirstSifterSession()

        app.navigationBars.buttons.firstMatch.tap()

        let libraryNav = app.navigationBars["PhotoSifter"]
        XCTAssertTrue(libraryNav.waitForExistence(timeout: 3), "Should return to library after tapping back")
    }
}
