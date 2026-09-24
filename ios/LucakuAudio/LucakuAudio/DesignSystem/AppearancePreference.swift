import SwiftUI

/// Light/dark preference, stored per device rather than on the Profile.
///
/// This is deliberately local: it's a device concern, not an account one — the
/// same customer may want dark on a phone they read in bed and light on an
/// iPad in daylight. That matches how the Notifications & Settings PRD already
/// treats biometrics ("per-device Face ID state; a client/OS concern, not a
/// server-side preference"), so there's no backend field for it.
///
/// `.system` is the default, and it is the right default: forcing either scheme
/// globally overrides what the customer already told their phone. An earlier
/// build pinned the whole app to dark, which is what prompted adding this.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` hands control back to the OS — SwiftUI treats a nil
    /// `preferredColorScheme` as "follow the system", which is exactly what
    /// `.system` means here.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
