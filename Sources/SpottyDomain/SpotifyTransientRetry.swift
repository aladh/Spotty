import Foundation

/// Bounded retry decisions for credentialed Spotify HTTP reads.
///
/// The policy is classification and delay math only: a 429 honors `Retry-After` when it is a
/// delta-seconds value or an IMF-fixdate HTTP date Foundation can parse; other 5xx listed below
/// and interrupt-class `URLError`s use jittered exponential backoff, all capped. Writes never
/// consult this type for replay — `SpotifyCredentials` still allows one named 401 retry.
public enum SpotifyTransientRetry {
    /// Total HTTP attempts for one replayable request, including any 401 credential retry.
    public static let maximumAttempts = 3
    /// Hard cap so a long or huge `Retry-After` cannot park a task indefinitely.
    public static let maximumDelaySeconds: TimeInterval = 30
    public static let baseDelaySeconds: TimeInterval = 0.5

    /// Whether losing the HTTP response would make a replay unsafe.
    public enum Replay: Sendable, Equatable {
        /// Idempotent reads. Transient 429/5xx and interrupt-class network errors may replay.
        case safe
        /// Mutations and other writes. One transport attempt, plus at most one 401 retry.
        case unsafe
    }

    /// Clock, sleeper, and jitter injected so checks never wait on the wall clock.
    public struct Timing: Sendable {
        public let now: @Sendable () -> Date
        public let sleep: @Sendable (TimeInterval) async throws -> Void
        public let unitJitter: @Sendable () -> Double

        public init(
            now: @escaping @Sendable () -> Date,
            sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
            unitJitter: @escaping @Sendable () -> Double
        ) {
            self.now = now
            self.sleep = sleep
            self.unitJitter = unitJitter
        }

        public static let production = Timing(
            now: { Date() },
            sleep: { seconds in
                guard seconds > 0 else { return }
                try await Task.sleep(for: .seconds(seconds))
            },
            unitJitter: { Double.random(in: 0...1) }
        )

    }

    public static func isRetryableStatus(_ status: Int) -> Bool {
        switch status {
        case 429, 500, 502, 503, 504:
            true
        default:
            false
        }
    }

    public static func isRetryableURLError(_ error: URLError) -> Bool {
        isRetryableURLErrorCode(error.code)
    }

    public static func isRetryableURLErrorCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost:
            true
        default:
            false
        }
    }

    /// Delay before the next attempt after `completedAttempts` finished tries.
    ///
    /// A parseable `Retry-After` replaces jittered backoff and is then capped. Malformed
    /// values fall through to backoff so a 429 still retries.
    public static func delay(
        status: Int,
        retryAfterHeader: String?,
        completedAttempts: Int,
        now: Date,
        unitJitter: Double
    ) -> TimeInterval? {
        guard isRetryableStatus(status) else { return nil }
        if let retryAfterHeader, let parsed = parseRetryAfter(retryAfterHeader, now: now) {
            return min(maximumDelaySeconds, max(0, parsed))
        }
        return backoffDelay(completedAttempts: completedAttempts, unitJitter: unitJitter)
    }

    public static func backoffDelay(completedAttempts: Int, unitJitter: Double) -> TimeInterval {
        let attemptIndex = max(0, completedAttempts - 1)
        let clamped = min(1, max(0, unitJitter))
        let raw = baseDelaySeconds * pow(2, Double(attemptIndex)) * (0.5 + 0.5 * clamped)
        return min(maximumDelaySeconds, raw)
    }

    /// Seconds to wait from a `Retry-After` value, or `nil` when the field is unusable.
    public static func parseRetryAfter(_ header: String, now: Date) -> TimeInterval? {
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

    static func parseDeltaSeconds(_ value: String) -> Int? {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return nil
        }
        return Int(value)
    }

    /// IMF-fixdate first (`EEE, dd MMM yyyy HH:mm:ss GMT`). RFC 850 and asctime only when
    /// Foundation's POSIX formatter accepts them.
    static func parseHTTPDate(_ value: String) -> Date? {
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
