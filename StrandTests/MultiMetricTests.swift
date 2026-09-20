import XCTest
@testable import Strand

/// The unified Trends card (260920). The preferences and the per-metric resolution are pure, so
/// both are tested without a view.
final class MultiMetricTests: XCTestCase {

    // MARK: Preferences

    /// An unset selection yields the default set, never an empty card. A card drawing nothing reads
    /// as broken rather than as configured.
    /// `decode` defaults to the ROW stack's set since 260920, when overlay was retired and `.rows`
    /// became the parameter default.
    func testUnsetSelectionYieldsTheDefaultSet() {
        let rows = MultiMetricPrefs.defaultSelection(for: .rows)
        XCTAssertEqual(MultiMetricPrefs.decode(""), rows)
        XCTAssertEqual(MultiMetricPrefs.decode("nonsense,alsoNonsense"), rows)
    }

    // MARK: Per-style selections (260920)

    /// Each style defaults to a set sized for what it can draw legibly — five lines on one axis,
    /// a few more as rows, everything as a heatmap.
    func testEachStyleHasItsOwnDefault() {
        XCTAssertEqual(MultiMetricPrefs.defaultSelection(for: .heatmap), MultiMetric.allCases)
        XCTAssertLessThan(MultiMetricPrefs.defaultSelection(for: .rows).count,
                          MultiMetricPrefs.defaultSelection(for: .heatmap).count,
                          "a row costs ~38pt and a heatmap row 16pt, so rows start smaller")
    }

    /// The three keys must not collide, or configuring one style would silently rewrite another.
    func testStyleKeysAreDistinct() {
        let keys = MultiMetricStyle.allCases.map { MultiMetricPrefs.selectionKey(for: $0) }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertFalse(keys.contains(MultiMetricPrefs.legacySelectionKey),
                       "a style key colliding with the pre-per-style key would hijack the carry-over")
    }

    /// A style with its own stored set uses it; one without inherits the pre-per-style selection
    /// exactly once, so an existing choice is not reset by this change; and absent both, its own
    /// default applies.
    func testResolutionPrefersOwnThenLegacyThenDefault() {
        let d = UserDefaults(suiteName: "multi-metric-tests-\(UUID().uuidString)")!

        XCTAssertEqual(MultiMetricPrefs.resolved(style: .rows, defaults: d),
                       MultiMetricPrefs.defaultSelection(for: .rows))

        d.set(MultiMetricPrefs.encode([.water]), forKey: MultiMetricPrefs.legacySelectionKey)
        XCTAssertEqual(MultiMetricPrefs.resolved(style: .rows, defaults: d), [.water],
                       "an existing selection carries over rather than being reset")

        d.set(MultiMetricPrefs.encode([.steps, .hrv]),
              forKey: MultiMetricPrefs.selectionKey(for: .rows))
        XCTAssertEqual(MultiMetricPrefs.resolved(style: .rows, defaults: d), [.steps, .hrv])
        // ...and the OTHER styles are untouched by that write.
        XCTAssertEqual(MultiMetricPrefs.resolved(style: .heatmap, defaults: d), [.water])
    }

    func testSelectionRoundTripsAndDropsDuplicates() {
        let picked: [MultiMetric] = [.hrv, .steps, .charge]
        XCTAssertEqual(MultiMetricPrefs.decode(MultiMetricPrefs.encode(picked)), picked)
        XCTAssertEqual(MultiMetricPrefs.decode("hrv,hrv,steps"), [.hrv, .steps])
    }

    /// The order is the wearer's, not the enum's — the legend and the row stack read in the order
    /// they switched metrics on.
    func testSelectionPreservesOrder() {
        XCTAssertEqual(MultiMetricPrefs.decode("water,charge,hrv"), [.water, .charge, .hrv])
    }

    func testUnknownStyleFallsBackRatherThanCrashing() {
        XCTAssertEqual(MultiMetricPrefs.decodeStyle("heatmap"), .heatmap)
        // `overlay` was retired in 260920; a stored value naming it must fall back rather than
        // leave the card unable to resolve a style.
        XCTAssertEqual(MultiMetricPrefs.decodeStyle("overlay"), .rows)
        XCTAssertEqual(MultiMetricPrefs.decodeStyle("from-the-future"), .rows)
    }

    /// Resting HR and respiration are the two where a HIGHER reading is a worse day. The heatmap
    /// shades by this, so getting it wrong paints a bad day green.
    func testDirectionalityIsSetForTheInvertedMetrics() {
        XCTAssertFalse(MultiMetric.restingHr.higherIsBetter)
        XCTAssertFalse(MultiMetric.respiratory.higherIsBetter)
        XCTAssertTrue(MultiMetric.hrv.higherIsBetter)
        XCTAssertTrue(MultiMetric.charge.higherIsBetter)
    }

    // MARK: Resolution

    private func card(_ series: [MultiMetric: [String: Double]],
                      metrics: [MultiMetric],
                      windowDays: Int = 30) -> MultiMetricCard {
        MultiMetricCard(seriesByMetric: series, metrics: metrics,
                        style: .rows, windowDays: windowDays)
    }

    private func days(_ values: [Double], from: Int = 1) -> [String: Double] {
        var out: [String: Double] = [:]
        for (i, v) in values.enumerated() {
            out[String(format: "2026-09-%02d", from + i)] = v
        }
        return out
    }

    /// A metric with fewer than two points cannot show a trend and is dropped rather than drawn as
    /// a single dot on an empty axis.
    func testMetricsWithTooFewPointsAreDropped() {
        let r = card([.hrv: days([34]), .charge: days([60, 70, 80])],
                     metrics: [.hrv, .charge]).resolved
        XCTAssertEqual(r.map(\.metric), [.charge])
    }

    /// The window clips to the most RECENT days — reading "the last 7 days" must not show the
    /// oldest seven.
    func testWindowKeepsTheNewestDays() {
        let r = card([.charge: days(Array(stride(from: 1.0, through: 20.0, by: 1.0)))],
                     metrics: [.charge], windowDays: 5).resolved
        XCTAssertEqual(r.first?.points.count, 5)
        XCTAssertEqual(r.first?.points.last?.value, 20)
        XCTAssertEqual(r.first?.points.first?.value, 16)
    }

    /// Normalisation is per-metric, so two signals on wildly different scales are comparable in the
    /// overlay — the whole point of that style.
    func testNormalisationIsPerMetric() {
        let r = card([.steps: days([2000, 6000, 10000]),
                      .hrv: days([30, 40, 50])],
                     metrics: [.steps, .hrv]).resolved
        for m in r {
            XCTAssertEqual(m.normalized(m.min), 0, accuracy: 0.0001)
            XCTAssertEqual(m.normalized(m.max), 1, accuracy: 0.0001)
        }
    }

    /// A flat series has no range to normalise against. It must sit mid-axis rather than divide by
    /// zero or pin to an edge, which would read as an extreme.
    func testAFlatSeriesSitsMidAxis() {
        let r = card([.charge: days([70, 70, 70])], metrics: [.charge]).resolved
        XCTAssertEqual(r.first?.normalized(70), 0.5)
    }

    /// 260920 REGRESSION: the shared axis unioned each metric's OWN clipped points, so metrics
    /// recorded on different days produced MORE columns than the window — the maintainer selected
    /// a week and saw fifteen cells.
    func testTheSharedAxisNeverExceedsTheWindow() {
        // Two metrics on disjoint days: 10 days of steps, 10 different days of HRV.
        var steps: [String: Double] = [:], hrv: [String: Double] = [:]
        for i in 1...10 { steps[String(format: "2026-09-%02d", i)] = Double(i * 100) }
        for i in 11...20 { hrv[String(format: "2026-09-%02d", i)] = Double(30 + i) }
        let c = card([.steps: steps, .hrv: hrv], metrics: [.steps, .hrv], windowDays: 7)
        let axis = Set(c.resolved.flatMap { $0.points.map(\.day) }).sorted().suffix(7)
        XCTAssertEqual(axis.count, 7, "the axis must be the window, not the union of both metrics")
    }

    /// Points must arrive oldest-first whatever order the dictionary yields, or every line is drawn
    /// backwards.
    func testPointsAreChronological() {
        let r = card([.charge: days([10, 20, 30, 40])], metrics: [.charge]).resolved
        let ds = r.first?.points.map(\.day) ?? []
        XCTAssertEqual(ds, ds.sorted())
    }
}
