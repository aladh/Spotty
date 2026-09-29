import Foundation

/// Bounded transient waits for Spotify HTTP requests. Request owners choose whether replay is
/// safe and interpret credential refusals; this owner handles the shared budget and delay policy.
nonisolated enum SpotifyTransientRetry {
    /// Total HTTP attempts for one replayable request, including any 401 credential retry.
    static let maximumAttempts = 3
    /// Per-delay cap; this does not bound cumulative transport time or the whole operation.
    private static let maximumDelaySeconds: TimeInterval = 30
    private static let baseDelaySeconds: TimeInterval = 0.5

    /// Whether losing the HTTP response would make a replay unsafe.
    enum Replay: Sendable, Equatable {
        /// Idempotent reads. Transient 429/5xx and interrupt-class network errors may replay.
        case safe
        /// Mutations and other writes. One transport attempt, plus at most one 401 retry.
        case unsafe
    }

    /// Clock, sleeper, and jitter injected so checks never wait on the wall clock.
    struct Timing: Sendable {
        let now: @Sendable () -> Date
        let sleep: @Sendable (TimeInterval) async throws -> Void
        let unitJitter: @Sendable () -> Double

        static let production = Self(
            now: { Date() },
            sleep: { seconds in
                guard seconds > 0 else { return }
                try await Task.sleep(for: .seconds(seconds))
            },
            unitJitter: { Double.random(in: 0...1) }
        )

        init(
            now: @escaping @Sendable () -> Date,
            sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
            unitJitter: @escaping @Sendable () -> Double
        ) {
            self.now = now
            self.sleep = sleep
            self.unitJitter = unitJitter
        }
    }

    /// Completes the bounded wait when another transient attempt is permitted. The request
    /// owner still checks cancellation and admission immediately before its next wire attempt.
    static func wait(after error: URLError, completedAttempts: Int, timing: Timing) async throws -> Bool {
        guard completedAttempts < maximumAttempts, isRetryableURLError(error) else { return false }
        try await timing.sleep(backoffDelay(completedAttempts: completedAttempts, unitJitter: timing.unitJitter()))
        return true
    }

    static func wait(
        afterStatus status: Int, retryAfterHeader: String?, completedAttempts: Int, timing: Timing
    ) async throws -> Bool {
        guard completedAttempts < maximumAttempts,
            let seconds = delay(
                status: status, retryAfterHeader: retryAfterHeader,
                completedAttempts: completedAttempts, now: timing.now(), unitJitter: timing.unitJitter())
        else { return false }
        try await timing.sleep(seconds)
        return true
    }

    private static func isRetryableStatus(_ status: Int) -> Bool {
        switch status {
        case 429, 500, 502, 503, 504:
            true
        default:
            false
        }
    }

    private static func isRetryableURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost:
            true
        default:
            false
        }
    }

    /// Delay before the next attempt after `completedAttempts` finished tries.
    ///
    /// A parseable `Retry-After` replaces jittered backoff. If it exceeds the per-delay cap,
    /// return nil so the caller surfaces the response without replaying early. Malformed
    /// values fall through to backoff so a 429 still retries.
    private static func delay(
        status: Int,
        retryAfterHeader: String?,
        completedAttempts: Int,
        now: Date,
        unitJitter: Double
    ) -> TimeInterval? {
        guard isRetryableStatus(status) else { return nil }
        if let retryAfterHeader, let parsed = parseRetryAfter(retryAfterHeader, now: now) {
            guard parsed <= maximumDelaySeconds else { return nil }
            return max(0, parsed)
        }
        return backoffDelay(completedAttempts: completedAttempts, unitJitter: unitJitter)
    }

    private static func backoffDelay(completedAttempts: Int, unitJitter: Double) -> TimeInterval {
        let attemptIndex = max(0, completedAttempts - 1)
        let clamped = min(1, max(0, unitJitter))
        let raw = baseDelaySeconds * pow(2, Double(attemptIndex)) * (0.5 + 0.5 * clamped)
        return min(maximumDelaySeconds, raw)
    }

    /// Seconds to wait from a `Retry-After` value, or `nil` when the field is unusable.
    private static func parseRetryAfter(_ header: String, now: Date) -> TimeInterval? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = parseDeltaSeconds(trimmed) {
            return TimeInterval(seconds)
        }
        if let date = parseHTTPDate(trimmed) {
            return date.timeIntervalSince(now)
        }
        return nil
    }

    private static func parseDeltaSeconds(_ value: String) -> Int? {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return nil
        }
        // A syntactically valid delay beyond Int's range is still a long throttle.
        return Int(value) ?? Int.max
    }

    /// IMF-fixdate first (`EEE, dd MMM yyyy HH:mm:ss GMT`). RFC 850 and asctime only when
    /// Foundation's POSIX formatter accepts them.
    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "EEEE, dd-MMM-yy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: value)
    }
}
