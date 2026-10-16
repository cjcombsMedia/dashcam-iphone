import XCTest

/// End-to-end smoke flow that runs in the Simulator (no camera needed):
/// startup acknowledgment → debug sample clips → library (Loop/Saved/Tagged)
/// → player tag markers → full-disk simulation warning banner.
final class SmokeFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Form rows render lazily; swipe until the element enters the hierarchy.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    func testStartupModalSampleClipsLibraryAndFullDiskWarning() {
        let app = XCUIApplication()

        // Auto-dismiss the system location prompt if it appears.
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            let preferred = [
                "Change to Always Allow",
                "Allow While Using App",
                "Keep Only While Using",
                "Allow Once",
                "OK",
            ]
            for label in preferred where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        app.launch()

        // 1. Startup acknowledgment blocks until tapped (acceptance #8).
        let ack = app.buttons["OK, I understand"]
        XCTAssertTrue(ack.waitForExistence(timeout: 15), "Startup modal should appear on launch")
        ack.tap()

        // 2. Settings → generate one loop clip and one tagged clip.
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        let addSample = app.buttons["Add sample clip to Loop"]
        scrollTo(addSample, in: app)
        XCTAssertTrue(addSample.waitForExistence(timeout: 10))
        addSample.tap()
        XCTAssertTrue(
            addSample.waitForExistence(timeout: 60),
            "Sample clip generation should finish and re-enable the button"
        )

        let addTagged = app.buttons["Add tagged sample clip"]
        scrollTo(addTagged, in: app)
        XCTAssertTrue(addTagged.waitForExistence(timeout: 10))
        addTagged.tap()
        XCTAssertTrue(addTagged.waitForExistence(timeout: 60))

        app.buttons["Done"].tap()

        // 3. Library: Loop has the plain clip; Saved has the tagged clip
        //    (tagging moves segments to SAVED) and the Tagged filter works.
        let libraryButton = app.buttons["libraryButton"]
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 10))
        libraryButton.tap()

        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: 15),
            "Loop section should list the generated sample clip"
        )

        app.buttons["Saved"].tap()
        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: 10),
            "Tagged sample clip should have been moved to Saved"
        )

        app.buttons["Tagged"].tap()
        XCTAssertTrue(
            app.cells.firstMatch.waitForExistence(timeout: 10),
            "Tagged filter should still show the tagged clip"
        )

        // 4. Player: tag chip (timeline marker jump target) is present.
        app.cells.firstMatch.tap()
        let tagChip = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Manual @'")
        ).firstMatch
        XCTAssertTrue(tagChip.waitForExistence(timeout: 15), "Player should show the tag as a jump chip")

        app.navigationBars.buttons.firstMatch.tap() // back
        app.buttons["Done"].tap()

        // 5. Debug full disk → persistent low-loop-capacity warning banner.
        settingsButton.tap()
        let fullDisk = app.switches["Simulate full disk"]
        scrollTo(fullDisk, in: app)
        XCTAssertTrue(fullDisk.waitForExistence(timeout: 10))
        // The SwiftUI toggle's accessibility frame spans the whole row; tap
        // the embedded switch (or its trailing edge) so the flip registers.
        if fullDisk.switches.firstMatch.exists {
            fullDisk.switches.firstMatch.tap()
        } else {
            fullDisk.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let flipped = NSPredicate(format: "value == '1'")
        expectation(for: flipped, evaluatedWith: fullDisk)
        waitForExpectations(timeout: 10)
        app.buttons["Done"].tap()

        XCTAssertTrue(
            app.staticTexts["Loop space low — export or clean up Saved clips"]
                .waitForExistence(timeout: 10),
            "Full-disk simulation should surface the loop-capacity warning"
        )
    }
}
