import XCTest

/// Structural guard: every surface that shows COACH-WRITTEN prose must render it as Markdown.
///
/// 260904, from the device: "the coach response format doesn't show bold text correctly." Two
/// separate causes, and only one of them was a styling choice:
///
///  1. `DayQualityCard`'s narrative used a plain `Text(narrative)`, so the `**bold**` the model
///     emits appeared as literal asterisks. The Today synthesis and the Q&A bubbles had used
///     MarkdownUI since they shipped; this card — added later — did not, so it was the one showing
///     raw syntax.
///  2. The theme rendered `strong` as `.semibold`, a ~100-weight step against a 15pt regular body
///     that is nearly invisible on the frosted bubble. A correctly-emphasised reply looked like one
///     with the bold dropped.
///
/// This is the same class of bug as `NotificationActionWiringTests`: a step present on one surface
/// and absent on another, invisible to a behavioural test because every part compiles and each
/// piece works in isolation. Only reading the source catches it, so this test reads it.
///
/// Verified to fail as intended by reverting the narrative to `Text(narrative)` and the weight to
/// `.semibold`.
final class CoachMarkdownRenderingTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Each surface that displays model-written prose, and the binding it renders.
    ///
    /// Kept as a LIST rather than a single check so that adding a coach surface without Markdown
    /// fails here — which is exactly how the day-quality card slipped through.
    private let coachProseSurfaces = [
        // 260919: the day-quality narrative moved OUT of DayQualityCard into the shared
        // `TabInsightCard`, which now backs the Recap, Trends and Sleep summaries. One surface
        // instead of three copies — so this entry covers all three, and a fourth tab adding a
        // summary inherits the guarantee rather than needing a new line here.
        ("the shared tab insight card", "Strand/Screens/TabInsightCard.swift", "Markdown(text)"),
        ("the coach Q&A reply", "Strand/Screens/CoachView.swift", "Markdown(message.text)"),
        ("the Today synthesis", "Strand/Screens/TodayView.swift", "Markdown(text)"),
        ("the Liquid Today synthesis", "Strand/Liquid/LiquidTodayView.swift", "Markdown(ai)"),
    ]

    func testEveryCoachProseSurfaceRendersMarkdown() throws {
        for (label, path, call) in coachProseSurfaces {
            let src = try source(path)
            XCTAssertTrue(src.contains(call),
                          "\(label) (\(path)) must render coach prose through MarkdownUI — a plain "
                          + "Text shows the model's **bold** as literal asterisks")
            XCTAssertTrue(src.contains("markdownTheme("),
                          "\(label) (\(path)) renders Markdown but applies no Strand theme, so it "
                          + "will not match the rest of the app")
        }
    }

    /// The original regression, restated for where the narrative lives now: assert the shared card
    /// does NOT fall back to a plain Text, which is a different statement from "it contains a
    /// Markdown call somewhere".
    func testTheTabInsightNarrativeIsNotPlainText() throws {
        let src = try source("Strand/Screens/TabInsightCard.swift")
        XCTAssertFalse(src.contains("Text(text)"),
                       "the narrative regressed to a plain Text — the model's bold will render as "
                       + "literal ** asterisks, which is the reported bug")
    }

    /// Bold must be unmistakably bold. LLM replies use bold as their primary structure, so this is
    /// the one weight in the theme that cannot be subtle.
    func testStrongRendersAsBoldNotSemibold() throws {
        let src = try source("Strand/Screens/CoachMarkdownTheme.swift")
        // Isolate the `.strong { … }` block: headings legitimately keep .semibold, so a naive
        // whole-file search for "semibold" would pass or fail for the wrong reason.
        guard let strongStart = src.range(of: ".strong {"),
              let strongEnd = src.range(of: "}", range: strongStart.upperBound..<src.endIndex) else {
            return XCTFail("could not find the .strong block in the coach theme")
        }
        let block = String(src[strongStart.upperBound..<strongEnd.lowerBound])
        XCTAssertTrue(block.contains("FontWeight(.bold)"),
                      "markdown `strong` must be .bold — .semibold against a 15pt regular body is "
                      + "nearly invisible on the frosted bubble, which is what was reported")
        XCTAssertFalse(block.contains(".semibold"), "found .semibold inside .strong: \(block)")
    }
}
