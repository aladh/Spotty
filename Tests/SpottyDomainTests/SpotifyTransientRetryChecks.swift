import Testing
import SpottyDomain
import Foundation

@Suite("Spotify Transient Retry")
struct SpotifyTransientRetryTests {
    @Test
    func testSpotifyTransientRetry() {
        do {
            #expect((SpotifyTransientRetry.isRetryableStatus(429)) == true, "429 is retryable")
            #expect((SpotifyTransientRetry.isRetryableStatus(500)) == true, "500 is retryable")
            #expect((SpotifyTransientRetry.isRetryableStatus(502)) == true, "502 is retryable")
            #expect((SpotifyTransientRetry.isRetryableStatus(503)) == true, "503 is retryable")
            #expect((SpotifyTransientRetry.isRetryableStatus(504)) == true, "504 is retryable")
            #expect((!SpotifyTransientRetry.isRetryableStatus(501)) == true, "501 is not a transient 5xx")
            #expect((!SpotifyTransientRetry.isRetryableStatus(400)) == true, "400 is not retryable")
            #expect((!SpotifyTransientRetry.isRetryableStatus(401)) == true, "401 is not a transient HTTP retry")
            #expect((!SpotifyTransientRetry.isRetryableStatus(403)) == true, "403 is not retryable")

            #expect((SpotifyTransientRetry.isRetryableURLErrorCode(.timedOut)) == true, "timedOut is retryable")
            #expect(
                (SpotifyTransientRetry.isRetryableURLErrorCode(.networkConnectionLost)) == true,
                "networkConnectionLost is retryable")
            #expect(
                (SpotifyTransientRetry.isRetryableURLErrorCode(.cannotConnectToHost)) == true,
                "cannotConnectToHost is retryable")
            #expect((!SpotifyTransientRetry.isRetryableURLErrorCode(.cancelled)) == true, "cancelled is not retryable")
            #expect(
                (!SpotifyTransientRetry.isRetryableURLErrorCode(.secureConnectionFailed)) == true,
                "secureConnectionFailed is not retryable")
            #expect(
                (!SpotifyTransientRetry.isRetryableURLErrorCode(.notConnectedToInternet)) == true,
                "notConnectedToInternet is not an interruption retry")
            #expect(
                (!SpotifyTransientRetry.isRetryableURLErrorCode(.cannotFindHost)) == true,
                "cannotFindHost is not retryable"
            )
            #expect(
                (!SpotifyTransientRetry.isRetryableURLErrorCode(.userCancelledAuthentication)) == true,
                "userCancelledAuthentication is not retryable")

            #expect(
                (SpotifyTransientRetry.parseRetryAfter("7", now: Date(timeIntervalSince1970: 0))) == (7),
                "delta-seconds Retry-After is honored")
            #expect(
                (SpotifyTransientRetry.parseRetryAfter("  12\n", now: Date(timeIntervalSince1970: 0))) == (12),
                "delta-seconds trims surrounding whitespace")
            #expect(
                (SpotifyTransientRetry.parseRetryAfter("not-a-delay", now: Date(timeIntervalSince1970: 0))) == nil,
                "malformed Retry-After is ignored")
            #expect(
                (SpotifyTransientRetry.parseRetryAfter("  ", now: Date(timeIntervalSince1970: 0))) == nil,
                "empty Retry-After is ignored")
            #expect(
                (SpotifyTransientRetry.parseRetryAfter("+8", now: Date(timeIntervalSince1970: 0))) == nil,
                "signed delta-seconds are malformed")
            #expect(
                (SpotifyTransientRetry.parseRetryAfter("99999999999999999999", now: Date(timeIntervalSince1970: 0)))
                    == TimeInterval(Int.max),
                "overflowing delta-seconds retain a long throttle instead of falling back to an early retry")

            let now = Date(timeIntervalSince1970: 1_000_000)
            let httpDate = "Mon, 12 Jan 1970 13:46:40 GMT"
            #expect(
                (SpotifyTransientRetry.parseRetryAfter(httpDate, now: now)) == (0),
                "IMF-fixdate Retry-After is seconds until that instant")
            let later = "Mon, 12 Jan 1970 13:47:10 GMT"
            #expect(
                (SpotifyTransientRetry.parseRetryAfter(later, now: now)) == (30),
                "IMF-fixdate in the future is a positive delta")
            let past = "Mon, 12 Jan 1970 13:46:10 GMT"
            #expect(
                (SpotifyTransientRetry.parseRetryAfter(past, now: now)) == (-30),
                "IMF-fixdate in the past is a negative delta")

            #expect(
                (SpotifyTransientRetry.delay(
                    status: 429,
                    retryAfterHeader: "tomorrow",
                    completedAttempts: 1,
                    now: now,
                    unitJitter: 1
                )) == (0.5), "malformed 429 uses jittered backoff")
            #expect(
                (SpotifyTransientRetry.delay(
                    status: 429,
                    retryAfterHeader: "8",
                    completedAttempts: 1,
                    now: now,
                    unitJitter: 1
                )) == (8), "delta Retry-After replaces backoff")
            #expect(
                (SpotifyTransientRetry.delay(
                    status: 429,
                    retryAfterHeader: "3600",
                    completedAttempts: 1,
                    now: now,
                    unitJitter: 1
                )) == nil, "a long Retry-After stops retries instead of retrying early")
            #expect(
                (SpotifyTransientRetry.delay(
                    status: 503,
                    retryAfterHeader: "Mon, 12 Jan 1970 14:46:40 GMT",
                    completedAttempts: 1,
                    now: now,
                    unitJitter: 1
                )) == nil, "a long HTTP-date Retry-After also stops retries")
            #expect(
                (SpotifyTransientRetry.delay(
                    status: 429,
                    retryAfterHeader: past,
                    completedAttempts: 1,
                    now: now,
                    unitJitter: 1
                )) == (0), "past HTTP-date retries immediately")
            #expect(
                (SpotifyTransientRetry.delay(
                    status: 429,
                    retryAfterHeader: later,
                    completedAttempts: 1,
                    now: now,
                    unitJitter: 1
                )) == (30), "HTTP-date Retry-After is honored")
            #expect(
                (SpotifyTransientRetry.backoffDelay(completedAttempts: 2, unitJitter: 1)) == (1),
                "second backoff doubles")
            #expect(
                (SpotifyTransientRetry.delay(
                    status: 404,
                    retryAfterHeader: "5",
                    completedAttempts: 1,
                    now: now,
                    unitJitter: 1
                )) == nil, "non-retryable status has no delay")
        }
    }
}
