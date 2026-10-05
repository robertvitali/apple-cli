import Darwin
import Foundation

/// Watches, from a thread of its own, for the runner withholding this test process. A wall-clock
/// bound charges the code under test with every moment the host did not run the process, and a
/// starved or swapping host can withhold more than any headroom a bound keeps above the product's
/// own waits. The probe sleeps in fixed ticks and records each wake-up later than its tolerance as
/// a lapse, from when the tick should have ended to when it did. It never observes the launcher: a
/// launcher that waits too long on its own thread leaves the probe on time, so the probe can only
/// make an attempt re-run, never make one pass.
///
/// What it records is a lower bound on the time withheld, not a measurement of it. Lateness under
/// the tolerance is not counted, tick by tick, and the probe sees only its own thread: a runner
/// that slows every thread without blocking any for a whole tolerance, or that starves the
/// launcher's thread while this one runs, can make a correct launcher cross a bound with less than
/// the headroom recorded. Such an attempt still fails. The probe narrows what a wall-clock bound
/// charges to the launcher; it does not remove it.
///
/// Its thread runs at the user-interactive quality of service, above the test thread, so that CPU
/// contention delays it no more than the code it watches. A lapse it records while the launcher's
/// thread ran is an overcount; it can only re-run an attempt, and the last attempt sets nothing
/// aside.
///
/// It has internal access so tests in any file can use it. It reads `CLOCK_UPTIME_RAW` through
/// `clock_gettime_nsec_np`, because `ReadyGatedChildren.uptimeNanoseconds()` is private to
/// ScriptLauncherTests.swift; it is the same clock that decorator stamps on, that the `now()`
/// helpers in `OwnedProcessCleanupTests` and `ProcessResourceTests` and the former's
/// `Fixture.uptimeNanoseconds()` read, and that every Python stamp compared across processes reads
/// as `time.CLOCK_UPTIME_RAW` (the `root-observed-exited` stamp moved too, for consistency,
/// although no check reads its content), so a caller hands `lapsed(from:to:)` its own stamps. It is
/// also the clock the launcher's deadlines read: `CLOCK_UPTIME_RAW` and
/// `DispatchTime.uptimeNanoseconds` are both `mach_absolute_time` converted to nanoseconds, so a
/// `DispatchTime` value's `uptimeNanoseconds` is a stamp on this clock too. Per XNU's published
/// source, the kernel's `alarm()` timer, which the Python fixtures arm, runs on the same uptime
/// base.
///
/// A system sleep pauses this clock, together with the launcher's `DispatchTime` deadlines and the
/// fixtures' alarms, so the probe does not record a sleep as a lapse, which is correct: a sleep
/// moves none of them apart. Stopping the process (SIGSTOP) does not pause it, so a stall injected
/// that way is still recorded.
final class DeschedulingProbe: @unchecked Sendable {
    /// The 1 ms a check keeps in hand where it holds a stamp on this clock to an event another
    /// reader of the same clock timed: a launcher deadline set with `DispatchTime`, or a fixture's
    /// kernel alarm. All of them read `mach_absolute_time`, so no frequency slew separates them;
    /// what remains is truncation. `DispatchTime` arithmetic and `uptimeNanoseconds` convert
    /// between nanoseconds and the clock's ticks (about 42 ns each on the Apple silicon measured)
    /// and round by at most a tick. Per XNU's published source the kernel arms an alarm from the
    /// uptime truncated to whole microseconds and converts the expiry to ticks with truncation, so
    /// an alarm can fire up to about a microsecond before a nanosecond stamp read just before it
    /// was armed, plus its seconds. A millisecond covers both many times over, while an event
    /// stamped more than a millisecond before its due time still fails the check.
    static let clockRoundingNanoseconds: UInt64 = 1_000_000
    private static let tickMicroseconds: useconds_t = 50_000
    /// Lateness below this is scheduling jitter rather than the process being withheld.
    private static let toleranceNanoseconds: UInt64 = 100_000_000
    /// Bounds `stop()`: the thread finishes within a tick of being asked, unless the runner is
    /// itself withholding it, and a probe must never become the hang.
    private static let stopWaitSeconds: Double = 30
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var stopping = false
    private var lapses: [(from: UInt64, to: UInt64)] = []

    /// `CLOCK_UPTIME_RAW` in nanoseconds, or `nil` if the clock could not be read, which
    /// `clock_gettime_nsec_np` reports as zero. A failed read records no lapse.
    private static func uptimeNanoseconds() -> UInt64? {
        let value = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return value == 0 ? nil : value
    }

    init() {
        let thread = Thread { [self] in
            let tick = UInt64(Self.tickMicroseconds) * 1_000
            var last = Self.uptimeNanoseconds()
            while !lock.withLock({ stopping }) {
                usleep(Self.tickMicroseconds)
                let now = Self.uptimeNanoseconds()
                if let previous = last, let now,
                   now > previous + tick + Self.toleranceNanoseconds {
                    lock.withLock { lapses.append((from: previous + tick, to: now)) }
                }
                last = now
            }
            finished.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the probe and waits, bounded, for its thread. Safe to call more than once.
    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopping = true }
            return !stopping
        }
        if first { _ = finished.wait(timeout: .now() + Self.stopWaitSeconds) }
    }

    /// Stops the probe, then returns how much of `start...end` (`CLOCK_UPTIME_RAW` nanoseconds)
    /// fell inside recorded lapses.
    func lapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        stop()
        return lock.withLock {
            lapses.reduce(UInt64(0)) { total, lapse in
                let low = max(lapse.from, start)
                let high = min(lapse.to, end)
                return high > low ? total + (high - low) : total
            }
        }
    }

    /// Nanoseconds as seconds with one decimal, for diagnostics.
    static func seconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.1f", Double(nanoseconds) / 1_000_000_000)
    }
}
