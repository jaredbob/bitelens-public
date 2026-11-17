import XCTest

@MainActor
final class CaptureSmokeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchWithoutUITestModeShowsSignIn() {
        let app = XCUIApplication()
        app.launchEnvironment["BITELENS_UI_TESTING"] = "0"
        app.launch()

        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 20))
        let isBeta = Bundle(for: Self.self).bundleIdentifier?.hasSuffix(".BetaUITests") == true
        let policy = app.descendants(matching: .any)
            .matching(identifier: "sign-in-privacy-policy").firstMatch
        if isBeta {
            XCTAssertTrue(app.staticTexts["BiteLens Beta"].exists)
            reveal(policy, in: app)
            XCTAssertTrue(policy.isHittable)
            XCTAssertEqual(policy.label, "Privacy Policy")
        } else {
            XCTAssertTrue(app.staticTexts["BiteLens is a private app for its approved owner."].exists)
            XCTAssertFalse(policy.exists)
        }
        XCTAssertFalse(app.buttons["enter-meal-manually"].exists)
        XCTAssertFalse(app.buttons["capture-meal"].exists)
    }

    func testUITestModeCanLogAMealAndCopyItFromHistory() {
        let app = launchUITestMode()

        let capture = app.buttons["capture-meal"]
        XCTAssertTrue(capture.waitForExistence(timeout: 20))
        XCTAssertFalse(capture.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["camera-not-used"].exists)
        let manual = app.buttons["enter-meal-manually"]
        XCTAssertTrue(waitForHittable(manual, timeout: 8))
        manual.tap()

        let notes = draftNotes(in: app)
        XCTAssertTrue(notes.exists, "The draft notes field should be a text field or text view")
        notes.tap()
        notes.typeText("2 scrambled eggs")
        dismissDraftKeyboard(in: app)

        let analyze = app.buttons["analyze-meal"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 8))
        reveal(analyze, in: app)
        analyze.tap()
        let analyzed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Analyze again"),
                                                 object: analyze)
        XCTAssertEqual(XCTWaiter().wait(for: [analyzed], timeout: 8), .completed)

        let confirm = app.buttons["confirm-meal"]
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        let history = app.buttons["meal-history"]
        XCTAssertTrue(waitForHittable(history, timeout: 20))
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Scrambled eggs"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["logged-meal"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["meal-sync-status"].exists)
        app.buttons["Done"].tap()

        app.buttons["pending-drafts"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["no-pending-drafts"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()

        app.buttons["meal-history"].tap()
        let mealRow = app.descendants(matching: .any)["logged-meal"].firstMatch
        XCTAssertTrue(waitForHittable(mealRow, timeout: 8))
        mealRow.swipeRight()
        let copyToDraft = app.buttons["Copy to Draft"]
        if copyToDraft.exists { copyToDraft.tap() }
        XCTAssertTrue(app.navigationBars["Meal draft"].waitForExistence(timeout: 8))
        XCTAssertEqual(draftNotes(in: app).value as? String, "2 scrambled eggs")
        let copiedItem = app.staticTexts["Scrambled eggs"]
        reveal(copiedItem, in: app)
        XCTAssertTrue(copiedItem.exists)

        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "logged-meal").count, 1)

        mealRow.tap()
        XCTAssertTrue(app.navigationBars["Logged meal"].waitForExistence(timeout: 8))
        for text in ["2 scrambled eggs", "2 eggs"] {
            let savedText = app.staticTexts[text]
            reveal(savedText, in: app, timeout: 30)
            XCTAssertTrue(savedText.exists && savedText.isHittable)
            savedText.press(forDuration: 1)
            let copyText = app.buttons["Copy"]
            XCTAssertTrue(waitForHittable(copyText, timeout: 20))
            copyText.tap()
            XCTAssertTrue(copyText.waitForNonExistence(timeout: 20))
        }
    }

    func testSymptomNoteIsVisibleFromHistoryChip() {
        let app = launchUITestMode()
        let actions = app.buttons["log-observation"]
        XCTAssertTrue(actions.waitForExistence(timeout: 20))
        actions.tap()
        XCTAssertTrue(app.navigationBars["Log symptom"].waitForExistence(timeout: 8))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("headache")
        app.buttons["Headache"].tap()

        let notes = textInput("observation-notes", in: app)
        XCTAssertTrue(notes.waitForExistence(timeout: 8))
        notes.tap()
        notes.typeText("Started after lunch")
        app.buttons["save-observation"].tap()

        let history = app.buttons["meal-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        history.tap()
        let chip = app.buttons["symptom-chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        XCTAssertTrue(chip.label.contains("Headache"))
        chip.tap()
        XCTAssertTrue(app.staticTexts["Started after lunch"].waitForExistence(timeout: 8))
    }

    func testDraftAndLoggedMealPhotosOpenFullScreenAndShare() {
        let app = launchUITestMode(arguments: ["-BiteLensUITestPhotoDraft"])
        let pendingDrafts = app.buttons["pending-drafts"]
        XCTAssertTrue(pendingDrafts.waitForExistence(timeout: 20))
        pendingDrafts.tap()
        app.staticTexts["Meal draft"].tap()

        let sharePreview = openMealPhotoShareSheet(in: app)
        dismissShareSheet(sharePreview, in: app)
        let closeImage = app.buttons["Close image"]
        XCTAssertTrue(waitForHittable(closeImage, timeout: 20), "Close image should be tappable after sharing")
        closeImage.tap()
        XCTAssertTrue(closeImage.waitForNonExistence(timeout: 20), "The photo viewer should dismiss")
        XCTAssertTrue(app.navigationBars["Meal draft"].waitForExistence(timeout: 8))

        let confirm = app.buttons["confirm-meal"]
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.exists && confirm.isHittable, "Confirm meal should be visible in the draft")
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Pending drafts"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()

        let history = app.buttons["meal-history"]
        XCTAssertTrue(waitForHittable(history, timeout: 20))
        history.tap()
        let loggedMeal = app.buttons["logged-meal"]
        XCTAssertTrue(waitForHittable(loggedMeal, timeout: 20))
        loggedMeal.tap()
        XCTAssertTrue(app.navigationBars["Logged meal"].waitForExistence(timeout: 8))
        openMealPhotoShareSheet(in: app)

        let saveToFiles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        if !saveToFiles.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForHittable(saveToFiles, timeout: 8))
        saveToFiles.tap()
        // Files opens its picker only after it receives a readable attachment.
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 8))
    }

    func testHistoryAddMenuOpensPhotoDraftAndSymptomFlows() {
        let app = launchUITestMode()
        let history = app.buttons["meal-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 20))
        history.tap()
        let historyBar = app.navigationBars["History"]
        XCTAssertTrue(historyBar.waitForExistence(timeout: 8))
        let add = app.buttons["history-add"]
        add.tap()
        app.buttons["Meal from Photo"].tap()
        XCTAssertTrue(app.navigationBars["Meal from Photo"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["capture-meal"].exists)
        XCTAssertTrue(app.buttons["choose-meal-image"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(waitForHittable(add, timeout: 20))

        add.tap()
        app.buttons["Enter Meal Manually"].tap()
        XCTAssertTrue(app.navigationBars["Meal draft"].waitForExistence(timeout: 8))
        XCTAssertTrue(draftNotes(in: app).exists)
        let back = app.buttons["BackButton"]
        XCTAssertTrue(waitForHittable(back, timeout: 20))
        back.tap()
        XCTAssertTrue(waitForHittable(add, timeout: 20))

        add.tap()
        app.buttons["Log Symptom"].tap()

        XCTAssertTrue(app.navigationBars["Log symptom"].waitForExistence(timeout: 8))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("binge")
        let urge = app.buttons["Binge Eating Urge"]
        XCTAssertTrue(urge.waitForExistence(timeout: 8))
        urge.tap()
        app.buttons["save-observation"].tap()
        XCTAssertTrue(app.buttons["Log a new meal"].waitForExistence(timeout: 8))
        app.buttons["finish-urge"].tap()
        XCTAssertTrue(app.buttons["urge-chip"].waitForExistence(timeout: 8))
    }

    @discardableResult
    private func openMealPhotoShareSheet(in app: XCUIApplication) -> XCUIElement {
        let photo = app.buttons["View meal image full screen"]
        XCTAssertTrue(waitForHittable(photo, timeout: 20))
        photo.tap()
        let share = app.buttons["Share photo"]
        XCTAssertTrue(waitForHittable(share, timeout: 20))
        XCTAssertTrue(app.buttons["Close image"].exists)
        share.tap()
        let sharePreview = app.descendants(matching: .any)["Meal photo"].firstMatch
        XCTAssertTrue(sharePreview.waitForExistence(timeout: 30), "The share preview should load")
        return sharePreview
    }

    private func dismissShareSheet(_ preview: XCUIElement, in app: XCUIApplication) {
        let titleBar = app.navigationBars["Meal photo"]
        let header = titleBar.exists ? titleBar : preview
        let spaceAboveSheet = header.frame.minY - app.frame.minY
        if spaceAboveSheet > 44 {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            top.withOffset(CGVector(dx: 0, dy: spaceAboveSheet / 2)).tap()
        }
        if !preview.waitForNonExistence(timeout: 5), header.exists {
            // A sheet that fills the screen can be pulled down by its header.
            let top = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            top.press(forDuration: 0.1, thenDragTo: bottom)
        }
        XCTAssertTrue(preview.waitForNonExistence(timeout: 20), "The share sheet should dismiss")
    }

    private func launchUITestMode(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [UITestLaunch.argument] + arguments
        app.launch()
        return app
    }

    private func draftNotes(in app: XCUIApplication) -> XCUIElement {
        textInput("draft-notes", in: app)
    }

    private func textInput(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let field = app.textFields[identifier]
        let view = app.textViews[identifier]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if field.exists { return field }
            if view.exists { return view }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return view
    }

    private func dismissDraftKeyboard(in app: XCUIApplication) {
        let hide = app.buttons["hide-keyboard"]
        if hide.waitForExistence(timeout: 2) {
            hide.tap()
            return
        }
        let header = app.staticTexts["Meal description"]
        if header.exists { header.tap() }
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Forms realize off-screen rows lazily, so scroll until the control can be tapped.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }
}

/// Mirrors the app's Debug launch argument without linking the app target.
private enum UITestLaunch {
    static let argument = "-BiteLensUITesting"
}
