import AlarmKit
import SwiftUI

/// What a cook-mode alarm carries to its Live Activity (Lock Screen / Dynamic Island).
/// Shared with the MiseWidgets extension, which renders `AlarmAttributes<CookTimerMetadata>`.
struct CookTimerMetadata: AlarmMetadata {
    /// "Chicken chow mein".
    var recipeTitle: String
    /// 1-based step number.
    var step: Int
    /// "Simmer the sauce".
    var timerTitle: String

    var subtitle: String { "Step \(step) · \(recipeTitle)" }
}

/// Fixed warm-kitchen colours for system surfaces that can't read the asset catalog
/// (AlarmKit encodes the tint into the alarm). Values from DESIGN.md.
enum CookTimerColors {
    /// `accent`, light (#C2410C).
    static let accent = Color(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255)
}
