import Foundation

/// A 50 ms CPU probe that measures how starved background execution is RIGHT NOW (260929).
///
/// WHY THIS EXISTS — read before deleting, especially during an upstream uplift:
/// iOS 27 polices sustained background CPU adaptively. The 260929-0711 log caught the signature
/// directly: a one-night pass whose foreground twin takes ~5 s spent `read=4187ms compute=585833ms`
/// — 585 SECONDS of wall for seconds of work, because background-priority threads were scheduled at
/// ~1% duty. The controlled comparison across the log archive (260914/19 vs 260920+) shows the
/// pathology began exactly when upstream v11.8.0 replaced "defer heavy passes out of the
/// background" with "pace them through it" (#2296): the same light pass that ran 8-30 s for three
/// weeks — including on iOS 27 with the pre-uplift app — became 2272 s and then 8360 s, worsening
/// daily as the OS clamped the process harder. Foreground stayed at 30 ms/statement throughout,
/// and HealthKit calls in the same process starved identically, which no app-level cause can fake.
///
/// The probe: burn ~50 ms of THREAD CPU at `.utility` (the class the passes run at) and report the
/// wall it took. factor ≈ 1 means background execution is healthy; the policy's threshold decides
/// when a pass must instead wait for a granted task window or foreground, where iOS provides real
/// CPU. Bounded: a fully-starved probe gives up after 5 s of wall and reports the (huge) factor.
enum BackgroundCPUCanary {

    static let targetCPUMillis = 50.0

    struct Reading {
        let cpuMs: Double
        let wallMs: Double
        /// Wall per unit of CPU. 1.0 = scheduled immediately; 10 = the thread got a tenth of a core.
        var factor: Double { cpuMs > 0 ? wallMs / cpuMs : .infinity }
    }

    /// Measure on a `.utility` detached task — the QoS the scoring passes actually run at, so the
    /// probe suffers exactly the starvation the pass would.
    static func measure() async -> Reading {
        await Task.detached(priority: .utility) { measureSync() }.value
    }

    /// The synchronous probe body. Runs on the calling thread; only the CPU clock of THIS thread is
    /// read, so concurrent work elsewhere cannot skew it.
    nonisolated static func measureSync() -> Reading {
        let wall0 = DispatchTime.now().uptimeNanoseconds
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var sink: UInt64 = 0x9E37_79B9_7F4A_7C15
        while true {
            for _ in 0..<4096 {
                sink = sink &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            }
            if Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0)
                >= targetCPUMillis * 1_000_000 { break }
            // A fully-starved thread must not spin forever: 5 s of wall is already a ×100+ verdict.
            if DispatchTime.now().uptimeNanoseconds &- wall0 > 5_000_000_000 { break }
        }
        withExtendedLifetime(sink) {}
        let wallMs = Double(DispatchTime.now().uptimeNanoseconds &- wall0) / 1_000_000
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1_000_000
        return Reading(cpuMs: cpuMs, wallMs: wallMs)
    }
}
