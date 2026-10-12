import Foundation
import SwiftUI

/// Sleep stage durations in the sleep card headline's own form: under an hour stays `17m`; an hour
/// or more is `1h 29m`, and an exact hour is `2h 0m` (the headline prints `8h 0m`, not `8h`).
enum StageDuration {
    static func label(minutes: Int) -> String {
        let m = max(minutes, 0)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// What VoiceOver speaks for the same value.
    static func spoken(minutes: Int) -> String {
        let m = max(minutes, 0)
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        guard m >= 60 else { return unit(m, "minute") }
        return m % 60 == 0 ? unit(m / 60, "hour") : "\(unit(m / 60, "hour")) \(unit(m % 60, "minute"))"
    }
}

/// The stage legend's layout: one row when it fits, else two columns, so h/m labels never wrap
/// mid-item on the narrowest phone.
struct StageLegendFlow: View {
    let items: [AnyView]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(items.indices, id: \.self) { items[$0].fixedSize(horizontal: true, vertical: false) }
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { items[$0] }
            }
        }
    }
}
