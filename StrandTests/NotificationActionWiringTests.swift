import XCTest

/// Structural guard over the two `@main` files: every launch step the hydration notification's
/// ACTION buttons depend on must exist in BOTH of them.
///
/// 260903, from the device: "I tried the notification trick — to add water by clicking on full cup,
/// and it did not add water to the app." The buttons rendered and the tap did nothing. The cause was
/// not the action, the category, the delegate or the sink — each was correct — but WHERE they were
/// installed: `setNotificationCategories` and `installHydrationReminderSink()` lived only in
/// `StrandApp.swift`, the macOS `@main`, which `project.yml` excludes from the iOS target. On iOS the
/// sink stayed nil, so `NotificationPresenter` dropped every response on its `guard`.
///
/// That class of bug — a wiring step present on one platform's launch path and absent on the other's
/// — is invisible to a behavioural test: both platforms compile, and the unit test for each PART
/// passes. Only reading the launch files catches it, so this test reads them. Same shape as
/// `LightPassNonDestructiveTests`' recovery-fold guard: assert over source text when the property is
/// about which code path a call sits on rather than about what the call returns.
///
/// Verified to fail as intended by deleting the iOS `installHydrationReminderSink()` line.
final class NotificationActionWiringTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The launch entry point for each platform, by the name it is known by in the failure message.
    private let mains = [
        ("macOS", "Strand/App/StrandApp.swift"),
        ("iOS", "StrandiOS/App/StrandiOSApp.swift"),
    ]

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Each step, with the reason its absence breaks the feature — so a future failure explains the
    /// consequence rather than just naming a missing string.
    func testBothPlatformsWireTheHydrationNotificationAction() throws {
        let required = [
            ("UNUserNotificationCenter.current().delegate = NotificationPresenter.shared",
             "without the delegate, no action response is ever delivered"),
            ("setNotificationCategories([HydrationReminder.category])",
             "without the category registered at launch, a reminder can post with its buttons dropped"),
            ("installHydrationReminderSink()",
             "without the sink, a tapped button reaches a nil handler and logs nothing"),
        ]
        for (platform, path) in mains {
            let src = try source(path)
            for (needle, why) in required {
                XCTAssertTrue(src.contains(needle),
                              "\(platform) launch (\(path)) is missing `\(needle)` — \(why).")
            }
        }
    }

    /// The install must not sit on a view-lifecycle hook on iOS.
    ///
    /// iOS delivers an action response to a COLD-LAUNCHED app before any view renders — that is the
    /// common case here, since tapping the button is itself what launches the app. A `.task { }` on
    /// the root view therefore races the very tap that started the launch, and loses it silently:
    /// the same "nothing happened" symptom as the original bug, but intermittent. So on iOS the call
    /// must be reachable from `init`, before the first scene.
    func testTheIOSSinkIsInstalledBeforeTheFirstScene() throws {
        let src = try source("StrandiOS/App/StrandiOSApp.swift")
        guard let install = src.range(of: "installHydrationReminderSink()"),
              let bodyDecl = src.range(of: "var body: some Scene") else {
            return XCTFail("Expected both `installHydrationReminderSink()` and the scene body in the iOS @main.")
        }
        XCTAssertTrue(install.lowerBound < bodyDecl.lowerBound,
                      """
                      The iOS hydration sink is installed at or after `var body: some Scene`, so it \
                      hangs off the view lifecycle. A notification action that cold-launches the app \
                      is delivered before any view renders and would be dropped. Install it in \
                      `init`, next to the delegate.
                      """)
    }
}
