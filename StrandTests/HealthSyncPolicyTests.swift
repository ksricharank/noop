import XCTest
@testable import Strand

/// Pins the pure Apple Health bridge decisions in `HealthSyncPolicy`. The bridge itself
/// (`HealthKitBridge`) is iOS-only and cannot be linked by this macOS-hosted suite, which is why the
/// decisions live in a shared sibling file — the same extraction pattern as #665.
final class HealthSyncPolicyTests: XCTestCase {

    /// A scratch UserDefaults suite so these tests never touch (or depend on) the app's real prefs.
    private var defaults: UserDefaults!
    private let suiteName = "HealthSyncPolicyTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - The "Write to Apple Health" switch

    /// Default ON: an install that has never touched the switch keeps writing back, byte-identical to
    /// the behaviour before the switch existed. This is the guard against `bool(forKey:)`'s
    /// unset-reads-false silently turning the export off for everyone.
    func testWriteBackDefaultsOn() {
        XCTAssertTrue(HealthSyncPolicy.writeBackEnabled(defaults))
    }

    /// The user's OFF sticks.
    func testWriteBackRespectsExplicitOff() {
        defaults.set(false, forKey: HealthSyncPolicy.writeBackEnabledKey)
        XCTAssertFalse(HealthSyncPolicy.writeBackEnabled(defaults))
    }

    /// An explicit ON (after an OFF) sticks too — the key round-trips, not just its absence.
    func testWriteBackRespectsExplicitOn() {
        defaults.set(false, forKey: HealthSyncPolicy.writeBackEnabledKey)
        defaults.set(true, forKey: HealthSyncPolicy.writeBackEnabledKey)
        XCTAssertTrue(HealthSyncPolicy.writeBackEnabled(defaults))
    }

    // MARK: - Resuming a prior grant

    /// The legacy path, unchanged: any authorized write type resumes.
    func testResumesOnWriteGrantAlone() {
        XCTAssertTrue(HealthSyncPolicy.shouldResumePriorGrant(
            anyWriteAuthorized: true, hasStoredReadSignature: false))
    }

    /// The fix: a read-only user (all writes off) whose earlier `requestAuthorization()` succeeded —
    /// proven by the stored read-type signature — resumes too. This was the configuration that
    /// silently disarmed background ingestion: write status was the only signal consulted, so
    /// `enableLiveDelivery()` never ran for exactly the battery-friendly all-reads-no-writes setup.
    func testResumesOnStoredReadSignatureAlone() {
        XCTAssertTrue(HealthSyncPolicy.shouldResumePriorGrant(
            anyWriteAuthorized: false, hasStoredReadSignature: true))
    }

    /// Both signals present resumes (the common upgrade case).
    func testResumesOnBothSignals() {
        XCTAssertTrue(HealthSyncPolicy.shouldResumePriorGrant(
            anyWriteAuthorized: true, hasStoredReadSignature: true))
    }

    /// Neither signal: a user who never completed the Health sheet must NOT be resumed — `auth` stays
    /// `.unknown` and the connect button remains the only entry, exactly as before.
    func testNeverResumesWithNeitherSignal() {
        XCTAssertFalse(HealthSyncPolicy.shouldResumePriorGrant(
            anyWriteAuthorized: false, hasStoredReadSignature: false))
    }
}
