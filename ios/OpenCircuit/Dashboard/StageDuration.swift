import Foundation

/// Sleep stage durations: under an hour stays `17m`, an hour or more reads `1h 29m`, and an exact
/// hour `2h`, matching the sleep card headline.
enum StageDuration {
    static func label(minutes: Int) -> String {
        let m = max(minutes, 0)
        guard m >= 60 else { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// What VoiceOver speaks for the same value.
    static func spoken(minutes: Int) -> String {
        let m = max(minutes, 0)
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        guard m >= 60 else { return unit(m, "minute") }
        return m % 60 == 0 ? unit(m / 60, "hour") : "\(unit(m / 60, "hour")) \(unit(m % 60, "minute"))"
    }
}
