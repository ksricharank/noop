import XCTest
@testable import Strand
import WhoopStore

/// The steps-source preference (260905): which device's count wins when both recorded one.
///
/// Maintainer request: a toggle between the strap and Apple Health whose effect is "consistent
/// everywhere — both the n in the steps n/t as well as the steps tile on the daily page".
///
/// The consistency comes from WHERE the override is applied, and that is the property worth pinning.
/// `Repository.days` merges the imported and computed sources only — Apple Health is NOT in it,
/// which is why both Today views reach for `appleDaily` separately as a fallback tier. Overriding
/// the field inside the merge means every reader of `row.steps` (the tile, the targets strip, the
/// pacing proration, the day-quality score, the coach) moves together without knowing the rule.
final class StepsSourcePreferenceTests: XCTestCase {

    private func day(_ d: String, steps: Int?, kcal: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 100,
                    lightMin: 230, disturbances: 3, restingHr: 58, avgHrv: 62, recovery: 70,
                    strain: 12, exerciseCount: 1, steps: steps, activeKcalEst: kcal)
    }

    /// The default is unchanged behaviour: the strap's count survives untouched.
    func testStrapPreferenceLeavesTheMergedRowsAlone() {
        let base = [day("2026-09-04", steps: 8_000)]
        let apple = [day("2026-09-04", steps: 11_500)]
        let out = Repository.mergeAppleSteps(into: base, apple, prefersApple: false)
        XCTAssertEqual(out.first?.steps, 8_000, "the default must not consult Apple at all")
        XCTAssertEqual(out, base, "a false preference must be a byte-identical no-op")
    }

    /// Preferring Apple replaces the count on a day BOTH cover — the reported case.
    func testApplePreferenceWinsWhenBothHaveACount() {
        let base = [day("2026-09-04", steps: 8_000)]
        let apple = [day("2026-09-04", steps: 11_500)]
        let out = Repository.mergeAppleSteps(into: base, apple, prefersApple: true)
        XCTAssertEqual(out.first?.steps, 11_500)
    }

    /// Switching source must never BLANK a day: a day Apple did not record keeps the strap's count.
    ///
    /// This is the failure that would be worst in use — a wearer flips the toggle and loses history
    /// on every day the Watch was off the wrist.
    func testADayAppleDidNotRecordKeepsTheStrapCount() {
        let base = [day("2026-09-03", steps: 7_100), day("2026-09-04", steps: 8_000)]
        let apple = [day("2026-09-04", steps: 11_500)]
        let out = Repository.mergeAppleSteps(into: base, apple, prefersApple: true).sorted { $0.day < $1.day }
        XCTAssertEqual(out.first?.steps, 7_100, "an uncovered day must fall back, not blank")
        XCTAssertEqual(out.last?.steps, 11_500)
    }

    /// A stored ZERO from Apple means "nothing recorded", not "you took no steps" — the same rule
    /// the activity-file fold above it uses. Without this, a day the Watch was charging would
    /// overwrite a real strap count with 0.
    func testAZeroAppleCountIsIgnored() {
        let base = [day("2026-09-04", steps: 8_000)]
        let apple = [day("2026-09-04", steps: 0)]
        let out = Repository.mergeAppleSteps(into: base, apple, prefersApple: true)
        XCTAssertEqual(out.first?.steps, 8_000)

        let nilApple = [day("2026-09-04", steps: nil)]
        XCTAssertEqual(Repository.mergeAppleSteps(into: base, nilApple, prefersApple: true).first?.steps,
                       8_000)
    }

    /// A day only Apple covers is added, matching the activity-file fold's `else` branch.
    func testADayOnlyAppleCoversIsAdded() {
        let apple = [day("2026-09-02", steps: 9_400)]
        let out = Repository.mergeAppleSteps(into: [], apple, prefersApple: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.steps, 9_400)
    }

    /// STEPS ONLY. Calories must survive the override untouched: `activeKcalEst` is NOOP's own
    /// HR-derived estimate and an input to strain, so swapping its source would silently re-base
    /// effort history — a separate decision, not a side effect of a steps toggle.
    func testOnlyStepsAreOverriddenNeverCalories() {
        let base = [day("2026-09-04", steps: 8_000, kcal: 640)]
        let apple = [day("2026-09-04", steps: 11_500, kcal: 999)]
        let out = Repository.mergeAppleSteps(into: base, apple, prefersApple: true)
        XCTAssertEqual(out.first?.steps, 11_500)
        XCTAssertEqual(out.first?.activeKcalEst, 640,
                       "calories must be untouched — they feed strain, and re-basing them is a "
                       + "different decision from choosing a pedometer")
    }

    /// Every other column must survive the rebuild. `replacingSteps` rebuilds the whole struct, so a
    /// column omitted there is silently dropped with no compile error — this is the guard for that.
    func testEveryOtherColumnSurvivesTheOverride() {
        let base = [day("2026-09-04", steps: 8_000, kcal: 640)]
        let apple = [day("2026-09-04", steps: 11_500)]
        let out = Repository.mergeAppleSteps(into: base, apple, prefersApple: true)
        let before = base[0], after = out[0]
        XCTAssertEqual(after.day, before.day)
        XCTAssertEqual(after.totalSleepMin, before.totalSleepMin)
        XCTAssertEqual(after.efficiency, before.efficiency)
        XCTAssertEqual(after.deepMin, before.deepMin)
        XCTAssertEqual(after.remMin, before.remMin)
        XCTAssertEqual(after.lightMin, before.lightMin)
        XCTAssertEqual(after.disturbances, before.disturbances)
        XCTAssertEqual(after.restingHr, before.restingHr)
        XCTAssertEqual(after.avgHrv, before.avgHrv)
        XCTAssertEqual(after.recovery, before.recovery)
        XCTAssertEqual(after.strain, before.strain)
        XCTAssertEqual(after.exerciseCount, before.exerciseCount)
        // The whole row, modulo the one field that is meant to change.
        XCTAssertEqual(after, before.replacingSteps(11_500))
    }

    /// The preference defaults to the strap, i.e. every prior build's behaviour.
    func testTheDefaultPreferenceIsTheStrap() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: StepsSourcePrefs.key)
        defer {
            saved == nil ? d.removeObject(forKey: StepsSourcePrefs.key)
                         : d.set(saved, forKey: StepsSourcePrefs.key)
        }
        d.removeObject(forKey: StepsSourcePrefs.key)
        XCTAssertEqual(StepsSourcePrefs.preferred, .strap)
        XCTAssertFalse(StepsSourcePrefs.prefersAppleHealth)

        StepsSourcePrefs.setPreferred(.appleHealth)
        XCTAssertTrue(StepsSourcePrefs.prefersAppleHealth)

        // A corrupt stored value falls back rather than trapping.
        d.set("nonsense", forKey: StepsSourcePrefs.key)
        XCTAssertEqual(StepsSourcePrefs.preferred, .strap)
    }
}

/// The strap double-tap "log a cup" action (260905).
///
/// Maintainer request: "a tap on the device adding a cup of water without me having to do anything
/// on the phone itself."
///
/// Structural, in the `NotificationActionWiringTests` idiom: the risk here is not arithmetic but
/// WIRING — an action that exists in the enum, is offered in the picker, and does nothing when the
/// gesture fires. That shape compiles and passes every unit test of its parts.
final class WaterDoubleTapWiringTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The action must exist AND be dispatched. An enum case with no arm in `runMacAction` is the
    /// exact silent-no-op this guards.
    func testTheActionIsDispatchedNotJustDeclared() throws {
        let actions = try source("Strand/System/MacActions.swift")
        XCTAssertTrue(actions.contains("case logWater"),
                      "the action must exist in MacActionKind")

        let model = try source("Strand/App/AppModel.swift")
        XCTAssertTrue(model.contains("case .logWater:"),
                      "runMacAction must handle .logWater — an unhandled case is a gesture that "
                      + "does nothing while the picker claims otherwise")
        XCTAssertTrue(model.contains("func logCupFromDoubleTap()"))
    }

    /// It must write through the SAME repository call the +Cup button and the notification action
    /// use, so the tap cannot disagree with the Today card about the day's cups — and so it inherits
    /// the 260904 serialisation that stops concurrent logs losing each other.
    func testItLogsThroughTheSharedRepositoryPath() throws {
        let model = try source("Strand/App/AppModel.swift")
        guard let start = model.range(of: "func logCupFromDoubleTap()"),
              let end = model.range(of: "\n    /// Buzz the strap alongside",
                                    range: start.upperBound..<model.endIndex) else {
            return XCTFail("could not isolate logCupFromDoubleTap")
        }
        let body = String(model[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("repo.logHydration(amountMl: HydrationGoal.cupML)"),
                      "must log a WHOLE cup through Repository.logHydration, the shared path")
        XCTAssertTrue(body.contains("buzzForNudgeIfEnabled(.water)"),
                      "a double-tap has no on-screen feedback, so the confirmation buzz is the only "
                      + "signal that the gesture registered")
        XCTAssertTrue(body.contains("HydrationStore.enabledKey"),
                      "must no-op when hydration tracking is off rather than silently creating a log")
    }

    /// The picker must offer it on iPhone — the platform the maintainer uses.
    func testTheActionIsOfferedOnIOS() throws {
        let view = try source("Strand/Screens/AutomationsView.swift")
        guard let start = view.range(of: "private var doubleTapOptions:"),
              let end = view.range(of: "\n    }", range: start.upperBound..<view.endIndex) else {
            return XCTFail("could not isolate doubleTapOptions")
        }
        let body = String(view[start.upperBound..<end.lowerBound])
        XCTAssertFalse(body.contains(".logWater"),
                       "logWater must NOT be filtered out of the iOS picker — the iOS branch only "
                       + "drops .lockScreen, and adding an exclusion here would hide the feature "
                       + "on the one platform it was requested for")
    }
}

/// The step-count HealthKit observer is armed ONLY when Apple Health is the chosen source (260905).
///
/// Maintainer asked for step freshness "more frequent if possible", gated on the toggle. Structural,
/// because the property is about which code path a registration sits on: the wiring compiles and
/// every part works whether or not the gate is honoured.
final class StepsObserverGatingTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Steps must be gated on the preference, NOT added to the always-on list.
    ///
    /// `liveQuantityIds` is the unconditional set. Putting `.stepCount` there would wake the app
    /// hourly for every install including strap-preferring ones, on the battery path this fork
    /// exists to trim.
    func testStepCountIsGatedNotUnconditional() throws {
        let src = try source("StrandiOS/Health/HealthKitBridge.swift")
        guard let start = src.range(of: "private static let liveQuantityIds:"),
              let end = src.range(of: "]", range: start.upperBound..<src.endIndex) else {
            return XCTFail("could not isolate liveQuantityIds")
        }
        let always = String(src[start.upperBound..<end.lowerBound])
        XCTAssertFalse(always.contains("stepCount"),
                       "step count must not join the unconditional observer list — a strap-preferring "
                       + "install would pay hourly background wakes for data it never reads")
        XCTAssertTrue(src.contains("StepsSourcePrefs.prefersAppleHealth ? [.stepCount] : []"),
                      "the steps observer must be gated on the preference")
    }

    /// Flipping back to the strap must RETIRE the observer, not merely stop adding it.
    ///
    /// The registration loop only touches types that are in the list, so a dropped type would keep
    /// its observer and its hourly background delivery forever. Disabling background delivery is the
    /// part that actually stops the wakes; stopping the query alone does not.
    func testAnUnwantedObserverIsRetiredAndItsDeliveryDisabled() throws {
        let src = try source("StrandiOS/Health/HealthKitBridge.swift")
        XCTAssertTrue(src.contains("for (key, query) in observerQueries where !wanted.contains(key)"),
                      "must sweep observers whose type is no longer wanted")
        XCTAssertTrue(src.contains("store.disableBackgroundDelivery(for: t)"),
                      "stopping the query alone leaves hourly background delivery armed — the wakes "
                      + "would continue for a source the wearer switched away from")
    }

    /// The change must take effect immediately, not at the next launch.
    func testTheObserversReArmWhenThePreferenceChanges() throws {
        let prefs = try source("Strand/Data/StepsSourcePrefs.swift")
        XCTAssertTrue(prefs.contains("NotificationCenter.default.post(name: didChangeNotification"),
                      "setting the preference must announce the change")
        XCTAssertTrue(prefs.contains("guard s != preferred else { return }"),
                      "re-selecting the same source must not churn the observers")

        let bridge = try source("StrandiOS/Health/HealthKitBridge.swift")
        XCTAssertTrue(bridge.contains("forName: StepsSourcePrefs.didChangeNotification"),
                      "the bridge must observe the change and re-arm, or the new cadence would only "
                      + "begin after the app is quit and relaunched")
    }
}
