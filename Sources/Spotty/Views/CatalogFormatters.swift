import Foundation

func formatDuration(_ interval: TimeInterval) -> String {
    formatMinutesSeconds(boundedDurationSeconds(interval, rounding: .down))
}

func roundedCatalogDurationSeconds(_ interval: TimeInterval) -> Int {
    boundedDurationSeconds(interval, rounding: .toNearestOrAwayFromZero)
}

func formatCatalogDuration(_ interval: TimeInterval) -> String {
    formatMinutesSeconds(roundedCatalogDurationSeconds(interval))
}

private func formatMinutesSeconds(_ total: Int) -> String {
    String(format: "%d:%02d", total / 60, total % 60)
}

private func boundedDurationSeconds(
    _ interval: TimeInterval,
    rounding rule: FloatingPointRoundingRule
) -> Int {
    guard interval.isFinite, interval > 0 else { return 0 }
    let rounded = interval.rounded(rule)
    // `Double(Int.max)` rounds to the first unrepresentable positive Int value.
    guard rounded < TimeInterval(Int.max) else { return 0 }
    return Int(rounded)
}

func formatDateAdded(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .omitted) ?? "—"
}

func formatPlaylistDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = roundedCatalogDurationSeconds(interval)
    let hours = totalSeconds / 3_600
    if hours > 0 {
        let minutes = (totalSeconds % 3_600) / 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if minutes == 0 {
        return "\(seconds) sec"
    }
    if seconds == 0 {
        return "\(minutes) min"
    }
    return "\(minutes) min \(seconds) sec"
}

func formatPlaylistDateAdded(_ date: Date?, now: Date = .now) -> String {
    guard let date else { return "—" }
    let age = now.timeIntervalSince(date)
    guard age >= 0, age < 7 * 24 * 60 * 60 else { return formatDateAdded(date) }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
}
