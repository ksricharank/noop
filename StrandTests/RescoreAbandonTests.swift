import XCTest
@testable import Strand

/// The mid-pass abort that stops a full re-score grinding on after the app goes away.
///
/// 260906. The first full-day re-score attribution (the 16.13 instrumentation's first real read):
///
///     Re-score today: 73/76 done, 96 dropped — cpu bg=6946s fg=1706s · longest 4214s (forced)
///
/// 6946 s of background CPU, and decomposing it showed the shape is NOT death by a thousand cuts:
/// ONE pass was 4214 s — 82 % of all full-pass time — while the 56 light passes together were ~7 %
/// of the whole bill (median 8.4 s each). That one pass logged `trigger=forced where=foreground`: it
/// began while the app was open, the app went to the background, and it kept going, I/O-throttled,
/// for seventy minutes.
///
/// `RescoreBackgroundPolicy` could not prevent it. Its first line is
/// `guard isBackground else { return .run }` — a foreground start is waved through once and never
/// re-examined, and nothing inside the pass looked at the app state again except to LABEL the log.
///
/// These tests read the source, because the property is structural: the check must exist, be inside
/// the per-night loop, exempt the light pass, and — most importantly — an abandoned pass must not
/// advance the watermark. That last one is the dangerous half: marking eighteen unscored nights as
/// done would be silent data loss, not a saving.
@MainActor
final class RescoreAbandonTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    private func engine() throws -> String { try source("Strand/Data/IntelligenceEngine.swift") }

    /// The abort must sit INSIDE the per-night loop. Checked once before the loop it would be exactly
    /// the policy's existing (and insufficient) entry check, since the transition happens mid-pass by
    /// definition.
    func testTheAbortIsInsideThePerNightLoop() throws {
        let src = try engine()
        guard let loop = src.range(of: "for offset in 0..<maxDays {") else {
            return XCTFail("the per-night loop has moved; this guard needs re-pointing")
        }
        let body = String(src[loop.upperBound...].prefix(600))
        XCTAssertTrue(body.contains("isBackgroundedSnapshot"),
                      "the per-night loop must re-check the app state; a foreground start is "
                      + "otherwise waved through for the whole 21-night pass: \(body.prefix(200))")
    }

    /// The LIGHT pass is exempt. It is today-only, its median is 8.4 s, and it is what keeps the
    /// numerators moving in the background — aborting it would trade a real feature for ~7 % of the
    /// bill.
    func testTheLightPassIsExempt() throws {
        let src = try engine()
        XCTAssertTrue(src.contains("if !lightPass, offset > 0, RescoreBackgroundScheduler.isBackgroundedSnapshot"),
                      "the light pass must be exempt from the abort, and the abort must never fire on "
                      + "the first night (offset 0) — a pass that scores nothing is pure waste")
    }

    /// THE DANGEROUS HALF: an abandoned pass must not advance the watermark. The watermark is the
    /// record that the whole window is scored; writing it after stopping at night 3 would mark
    /// eighteen unscored nights as done, and no later trigger would revisit them.
    func testAnAbandonedPassDoesNotAdvanceTheWatermark() throws {
        let src = try engine()
        guard let abandonCheck = src.range(of: "let wasAbandoned = ") ,
              let watermarkWrite = src.range(of: "UserDefaults.standard.set(wmKey, forKey: Self.analyzeWatermarkKey)")
        else { return XCTFail("the abandonment check or the watermark write has moved") }
        XCTAssertLessThan(abandonCheck.lowerBound, watermarkWrite.lowerBound,
                          "the abandonment check must come BEFORE the watermark write")
        // And it must actually return, not merely log.
        let between = String(src[abandonCheck.lowerBound..<watermarkWrite.lowerBound])
        XCTAssertTrue(between.contains("return"),
                      "an abandoned pass must return before the watermark write, not fall through")
    }

    /// The abandonment is LOGGED, always-on. A silent give-up looks identical to a completed pass in
    /// a strap log, which would make "why is yesterday unscored" unanswerable — the exact failure the
    /// #1635 diagnostic rules exist to prevent.
    func testTheAbandonmentIsLogged() throws {
        let src = try engine()
        XCTAssertTrue(src.contains("abandonedLinePrefix"),
                      "the abandonment must carry a diagnostic out of the detached scan task")
        XCTAssertTrue(src.contains("RescoreStats.recordAbandoned()"),
                      "and must be counted, so the next log can show the fix working")
    }

    /// The abort reads a NONISOLATED mirror. `UIApplication.applicationState` is main-actor-isolated,
    /// and hopping to the main actor 21 times inside a detached background scan would both serialise
    /// against the UI and defeat the purpose.
    func testTheAbortReadsANonisolatedMirror() throws {
        let src = try source("Strand/System/RescoreBackgroundScheduler.swift")
        XCTAssertTrue(src.contains("nonisolated static var isBackgroundedSnapshot"),
                      "the snapshot must be reachable from off the main actor")
        XCTAssertTrue(src.contains("nonisolated static func noteScenePhase"),
                      "and must be updated by the scene-phase transition itself — the mirror would "
                      + "otherwise only be as fresh as the last main-actor read, and the case this "
                      + "exists for is 'the app went away and nothing else asked'")
    }

    /// The mirror is lock-guarded: a detached task reads it while the main actor writes it, which is a
    /// data race however benign the values look.
    func testTheMirrorIsLockGuarded() throws {
        let src = try source("Strand/System/RescoreBackgroundScheduler.swift")
        XCTAssertTrue(src.contains("mirrorLock"), "the cross-actor mirror needs a lock")
    }

    /// The scene-phase hook actually calls it, or the mirror never tracks the transition that matters.
    func testTheScenePhaseHookUpdatesTheMirror() throws {
        let src = try source("StrandiOS/App/StrandiOSApp.swift")
        XCTAssertTrue(src.contains("RescoreBackgroundScheduler.noteScenePhase(isActive:"),
                      "the scene-phase hook must keep the mirror in step")
    }
}
