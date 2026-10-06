//
//  Screen_NibblesUITests.swift
//  Screen NibblesUITests
//
//  Created by Chih Hao Lin on 8/19/26.
//

import XCTest

final class Screen_NibblesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordingGuideIsReachableAndUsesReplayKitPicker() throws {
        let app = XCUIApplication()
        app.launch()

        let directRecordButton = app.buttons["Record Screen"]
        if directRecordButton.waitForExistence(timeout: 2) {
            directRecordButton.tap()
        } else {
            let options = app.buttons["Gallery Options"]
            XCTAssertTrue(options.waitForExistence(timeout: 2), "Gallery actions should remain reachable")
            options.tap()
            let menuRecordButton = app.buttons["Record Screen"]
            XCTAssertTrue(menuRecordButton.waitForExistence(timeout: 2))
            menuRecordButton.tap()
        }

        XCTAssertTrue(app.navigationBars["Record Screen"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["replaykitQuickStart"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["replaykitBroadcastPicker"].exists)

        let holdInstruction = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "touch and hold Screen Recording")
        ).firstMatch
        XCTAssertTrue(holdInstruction.exists, "Control Center hold instructions should be present")

        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Record Screen"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testPrimaryGalleryActionsRemainReachable() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Captures"].waitForExistence(timeout: 2))
        let hasImport = app.buttons["Import Video"].exists || app.buttons["Select Video from Library"].exists
        XCTAssertTrue(hasImport, "Video import should be reachable without a gesture-only interaction")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
