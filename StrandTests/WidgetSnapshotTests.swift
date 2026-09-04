import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testAltStoreProvisionedGroupWinsOverBuildTimeIdentifier() {
        let configured = "group.com.noopapp.noop.staging"
        let remapped = configured + ".TEAM123456"

        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": configured,
                "ALTAppGroups": [remapped]
            ]),
            remapped
        )
    }

    func testXcodeBuildFallsBackToConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop"
            ]),
            "group.example.noop"
        )
    }

    func testUnrelatedAltStoreGroupsDoNotOverrideConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop",
                "ALTAppGroups": [
                    "group.example.first",
                    "group.example.second"
                ]
            ]),
            "group.example.noop"
        )
    }

    func testSingleProvisionedGroupIsUsableWithoutConfiguredIdentifier() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "ALTAppGroups": ["group.example.noop.TEAM123456"]
            ]),
            "group.example.noop.TEAM123456"
        )
    }

    func testRuntimeUnavailableSnapshotContainsNoDemoValues() {
        let snapshot = WidgetSnapshot.unavailable

        XCTAssertNil(snapshot.recovery)
        XCTAssertNil(snapshot.bpm)
        XCTAssertNil(snapshot.batteryPct)
        XCTAssertFalse(snapshot.bonded)
    }

    private func renderedSnapshot(updated: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: updated,
                       effort: 38, rest: 81, hrv: 64, restingHr: 52,
                       effortDisplay: "38", effortWhoop: false,
                       effortTargetDisplay: "51", kcal: 1830, kcalTarget: 2650, sleepNeedMin: 495,
                       steps: 6_214, stepsTarget: 8_000,
                       waterHalfCups: 15, waterTargetCups: 19)
    }

    func testRenderedContentFirstPublishAlwaysChanges() {
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: nil, to: renderedSnapshot()))
    }

    func testRenderedContentIgnoresTimestampOnlyChange() {
        let previous = renderedSnapshot()
        let next = renderedSnapshot(updated: previous.updated.addingTimeInterval(900))

        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testRenderedContentDetectsLiveFieldChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.bpm = 59

        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testRenderedContentDetectsScoreFieldChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.rest = 82

        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    /// The targets-trio fields are RENDERED content (the NOOP Targets widget's whole payload), so a
    /// burst that only moved them must still republish — a dedup miss here would freeze the new
    /// widget at its first snapshot for the rest of the day.
    func testRenderedContentDetectsTargetsTrioChange() {
        let previous = renderedSnapshot()
        for mutate: (inout WidgetSnapshot) -> Void in [
            { $0.effortTargetDisplay = "62" }, { $0.kcal = 1900 }, { $0.kcalTarget = nil },
            { $0.sleepNeedMin = 510 }, { $0.steps = 7_000 }, { $0.stepsTarget = 10_000 }
        ] {
            var next = previous
            mutate(&next)
            XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
        }
    }

    /// Reload thrift (260831): Cal/Steps dedup at DISPLAY granularity. A raw change no widget face
    /// can render (1830→1839 kcal is "1.8k" either way; 6214→6260 steps is "6.2k" either way) must
    /// NOT request a WidgetKit reload — with the background light pass moving raw values every
    /// ~10-min sync, raw-int dedup burned the OS's background reload budget on invisible changes
    /// and got the VISIBLE ones deferred. A change that crosses a display boundary still reloads
    /// (covered by testRenderedContentDetectsTargetsTrioChange).
    func testSubDisplayValueChangesDoNotReload() {
        let previous = renderedSnapshot()
        for mutate: (inout WidgetSnapshot) -> Void in [
            { $0.kcal = 1_839 },      // "1.8k" → "1.8k"
            { $0.steps = 6_249 },     // "6.2k" → "6.2k" (kAbbrev ROUNDS: 6_260 would be "6.3k")
            { $0.kcalTarget = 2_649 } // "2.6k" → "2.6k"
        ] {
            var next = previous
            mutate(&next)
            XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: previous, to: next),
                           "sub-display change must dedup")
        }
    }

    /// A snapshot written by an OLDER app build (no targets-trio keys) must still decode — the widget
    /// extension can update ahead of the app's first fresh publish.
    func testOlderSnapshotWithoutTargetsFieldsStillDecodes() throws {
        var old = renderedSnapshot()
        old.effortTargetDisplay = nil; old.kcal = nil; old.kcalTarget = nil; old.sleepNeedMin = nil
        old.waterHalfCups = nil; old.waterTargetCups = nil
        let data = try JSONEncoder().encode(old)
        // Simulate the older writer by stripping the keys entirely, not just nulling them.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["effortTargetDisplay", "kcal", "kcalTarget", "sleepNeedMin",
                    "waterHalfCups", "waterTargetCups"] { json.removeValue(forKey: key) }
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: stripped)
        XCTAssertNil(decoded.effortTargetDisplay)
        XCTAssertNil(decoded.kcal)
        XCTAssertNil(decoded.kcalTarget)
        XCTAssertNil(decoded.sleepNeedMin)
        XCTAssertNil(decoded.waterHalfCups)
        XCTAssertNil(decoded.waterTargetCups)
        XCTAssertEqual(decoded.recovery, 72)
    }

    /// The display strings are the SAME vocabulary as the Live Activity card's Cal/Sleep columns —
    /// either Cal side degrades alone, and a missing count reads "0/target" (early morning honestly
    /// is zero); Sleep zero-pads minutes so the glyph count is stable across pushes.
    func testTargetsDisplayStrings() {
        var snap = renderedSnapshot()
        XCTAssertEqual(snap.calDisplay, "1830/2650")
        XCTAssertEqual(snap.effortNT, "38/51")
        XCTAssertEqual(snap.sleepDisplay, "8h15")

        snap.kcal = nil
        XCTAssertEqual(snap.calDisplay, "0/2650")
        snap.kcal = 1830; snap.kcalTarget = nil
        XCTAssertEqual(snap.calDisplay, "1830")
        snap.kcal = nil
        XCTAssertNil(snap.calDisplay)

        // The Effort pair degrades the same way, and a fresh day reads "0/target".
        snap.effortDisplay = nil
        XCTAssertEqual(snap.effortNT, "0/51")
        snap.effortTargetDisplay = nil
        XCTAssertNil(snap.effortNT)

        // Steps render as FULL counts on the full-width surfaces (strip, banner) with the same
        // degrade rules.
        snap = renderedSnapshot()
        XCTAssertEqual(snap.stepsDisplay, "6214/8000")
        snap.steps = nil
        XCTAssertEqual(snap.stepsDisplay, "0/8000")
        snap.stepsTarget = nil
        XCTAssertNil(snap.stepsDisplay)

        // The WIDGET faces abbreviate Steps AND Cal (a widget cell has no room for two four-digit
        // pairs); kAbbrev keeps sub-1k raw and drops a trailing ".0".
        snap = renderedSnapshot()
        XCTAssertEqual(snap.stepsAbbrev, "6.2k/8k")
        XCTAssertEqual(snap.calAbbrev, "1.8k/2.6k")
        XCTAssertEqual(WidgetSnapshot.kAbbrev(650), "650")
        XCTAssertEqual(WidgetSnapshot.kAbbrev(12_000), "12k")
        XCTAssertEqual(WidgetSnapshot.kAbbrev(10_500), "10.5k")

        snap.sleepNeedMin = 510
        XCTAssertEqual(snap.sleepDisplay, "8h30")
        snap.sleepNeedMin = 425
        XCTAssertEqual(snap.sleepDisplay, "7h05")
        snap.sleepNeedMin = 0
        XCTAssertNil(snap.sleepDisplay)
        snap.sleepNeedMin = nil
        XCTAssertNil(snap.sleepDisplay)
    }

    func testLiveUpdateReusesSnapshotWithinSameLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = renderedSnapshot(updated: Date(timeIntervalSince1970: 1_700_000_000))
        let oneHourLater = previous.updated.addingTimeInterval(3_600)

        XCTAssertFalse(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: previous, now: oneHourLater, calendar: calendar))
    }

    func testLiveUpdateRequiresFullBuildAfterLocalDayRollover() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = renderedSnapshot(updated: Date(timeIntervalSince1970: 1_700_000_000))
        let nextDay = previous.updated.addingTimeInterval(86_400)

        XCTAssertTrue(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: previous, now: nextDay, calendar: calendar))
        XCTAssertTrue(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: nil, now: nextDay, calendar: calendar))
    }

    /// The Water glance (260903), which took Sleep's fourth widget cell. Whole cups, rounded DOWN
    /// from the tracker's half-cup resolution: a half-cup in hand is not a cup drunk, and the same
    /// floor is what the reminder's "cups still to drink" counts with.
    func testWaterDisplayRendersWholeCupsRoundedDown() {
        var snap = renderedSnapshot()
        XCTAssertEqual(snap.waterDisplay, "7/19", "15 half-cups is 7.5 cups drunk — floors to 7")

        snap.waterHalfCups = 16
        XCTAssertEqual(snap.waterDisplay, "8/19")
        snap.waterHalfCups = 0
        XCTAssertEqual(snap.waterDisplay, "0/19", "a fresh day honestly is zero, like the other pairs")
        // No numerator yet still renders against a live target — same degrade rule as Cal/Steps.
        snap.waterHalfCups = nil
        XCTAssertEqual(snap.waterDisplay, "0/19")
    }

    /// Hydration tracking OFF publishes no target, and the face must then read a dash rather than a
    /// fabricated "0/0" — the target being nil is exactly how the widget learns the feature is off.
    func testWaterDisplayIsNilWithoutATarget() {
        var snap = renderedSnapshot()
        snap.waterTargetCups = nil
        XCTAssertNil(snap.waterDisplay)
        snap.waterTargetCups = 0
        XCTAssertNil(snap.waterDisplay, "a zero target is not a renderable denominator")
    }

    /// Water joins the reload dedup, and the whole-cup quantization is load-bearing for battery: a
    /// logged cup triggers a publish directly (the `hydrationSeq` hook), so without this a half-cup
    /// that moves nothing on screen would still spend one of the day's WidgetKit reload requests.
    func testHalfCupThatDoesNotMoveTheFaceDoesNotReload() {
        let previous = renderedSnapshot()          // 15 half-cups → "7/19"
        var next = previous
        next.waterHalfCups = 16                    // → "8/19": visible, must reload
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))

        var withinCup = previous
        withinCup.waterHalfCups = 14               // 7.0 cups → still "7/19"
        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: previous, to: withinCup),
                       "a half-cup that leaves the rendered pair unchanged must not request a reload")

        var targetMoved = previous
        targetMoved.waterTargetCups = 21           // the day's target can move with effort
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: targetMoved))
    }

}
