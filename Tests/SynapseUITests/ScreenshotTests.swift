import UIKit
import XCTest

/// App Store screenshots, run by .github/workflows/screenshots.yml on iPhone and 13-inch iPad
/// simulators. It drives the real app on a fresh install, so what it shows is the sample workspace
/// every new user starts with; nothing is mocked. Full-screen PNGs go to $SCREENSHOT_DIR
/// (TEST_RUNNER_SCREENSHOT_DIR in the workflow) and into the result bundle. Skipped when
/// SCREENSHOT_DIR is unset.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var outDir: URL!

    override func setUpWithError() throws {
        let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? ""
        try XCTSkipIf(dir.isEmpty, "App Store screenshots run from screenshots.yml only (SCREENSHOT_DIR is unset)")
        outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Keep going after a failed step: every screen is captured, and the PNGs are checked by eye.
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        if UIDevice.current.userInterfaceIdiom == .pad { useFullScreenApps() }
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Allow", "OK", "Don\u{2019}t Allow", "Not Now"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app = XCUIApplication()
        app.launch()
    }

    func testAppStoreScreenshots() {
        XCTAssertTrue(anyText("Welcome to Synapse").waitForExistence(timeout: 90), "Home never showed the sample workspace\n\(app.debugDescription.prefix(6000))")
        pause(2)
        capture("01-home")

        open("Welcome to Synapse")
        capture("02-page")

        open("Tasks")
        capture("03-database")

        open("Linked thinking")
        capture("04-linked")

        tab("Graph")
        pause(8) // let the force layout settle
        capture("05-graph")

        tab("Agents")
        pause(2)
        capture("06-agents")

        tab("Settings")
        pause(2)
        capture("07-settings")
    }

    // MARK: helpers

    /// Opens a page by title through the app's own `synapse://open?title=` link (pushes it on the Home stack).
    private func open(_ title: String) {
        var c = URLComponents()
        c.scheme = "synapse"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "title", value: title)]
        app.open(c.url!)
        let shown = anyText(title).waitForExistence(timeout: 15)
        if !shown { print("SHOT| \(title) did not appear\n\(app.debugDescription.prefix(4000))") }
        pause(2.5)
    }

    /// iPhone: the bottom tab bar. iPad: the top tab bar, whose buttons are identified by their SF Symbol, so match the label.
    private func tab(_ name: String) {
        let label = NSPredicate(format: "label == %@", name)
        for query in [app.tabBars.buttons.matching(label), app.buttons.matching(label)] {
            _ = query.firstMatch.waitForExistence(timeout: 6)
            for i in 0..<query.count {
                let button = query.element(boundBy: i)
                if button.isHittable {
                    button.tap()
                    return
                }
            }
        }
        XCTFail("no tab \(name)\n\(app.debugDescription.prefix(6000))")
    }

    private func anyText(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }

    /// iPadOS 26 can show apps in windows; App Store screenshots need the app full screen.
    private func useFullScreenApps() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        defer { settings.terminate() }
        let row = settings.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Multitasking'")).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            print("SHOT| Settings: no Multitasking & Gestures row")
            return
        }
        for _ in 0..<4 where !row.isHittable {
            settings.collectionViews.firstMatch.swipeUp()
        }
        row.tap()
        let choice = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'full screen' OR label CONTAINS[c] 'full-screen'")).firstMatch
        guard choice.waitForExistence(timeout: 15) else {
            print("SHOT| Settings: no Full Screen Apps choice")
            return
        }
        choice.tap()
        pause(2)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ name: String) {
        pause(1)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let size = "\(Int(shot.image.size.width * shot.image.scale))x\(Int(shot.image.size.height * shot.image.scale))"
        let url = outDir.appendingPathComponent(name + ".png")
        do {
            try shot.pngRepresentation.write(to: url)
            print("SHOT| \(name) \(size) -> \(url.path)")
        } catch {
            print("SHOT| \(name) \(size): could not write \(url.path) (\(error.localizedDescription)); the result bundle has it")
        }
    }
}
