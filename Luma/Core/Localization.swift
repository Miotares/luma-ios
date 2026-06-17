import Foundation

/// Localized, pluralized count labels. The actual plural rules live in the String
/// Catalog (keys "%lld Songs", "%lld Alben", "%lld Wiedergaben") with variations for
/// both German and English — so "1 Song" / "5 Songs" agree grammatically per language.
enum CountText {
    static func songs(_ n: Int) -> String { String(localized: "\(n) Songs") }
    static func albums(_ n: Int) -> String { String(localized: "\(n) Alben") }
    static func plays(_ n: Int) -> String { String(localized: "\(n) Wiedergaben") }
}

/// Locale-aware duration formatting (hours + minutes), e.g. "2 Std. 12 Min." (de) /
/// "2 hr 12 min" (en). Avoids hard-coded unit words so it localizes automatically.
enum DurationText {
    static func hoursMinutes(_ t: TimeInterval) -> String {
        Duration.seconds(max(0, t)).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated)
        )
    }
}
