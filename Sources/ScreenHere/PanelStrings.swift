import Foundation

/// The panel's wording, kept out of the SwiftUI body so it stays testable.
enum PanelStrings {
    /// Longest display name rendered before truncating, so the panel stays narrow.
    static let maxNameLength = 26

    /// What ⇧⌘3 does right now, as the sentence following the shortcut chip.
    static func headline(isOn: Bool) -> String {
        isOn ? "captures the screen under your pointer" : "is handled by macOS"
    }

    /// The warning line, or nil when there is nothing wrong to report.
    /// A missing permission outranks the takeover state: without it every
    /// capture silently produces nothing.
    static func problem(status: TakeoverController.Status,
                        permissionGranted: Bool) -> String? {
        if !permissionGranted, status != .off {
            return "Screen Recording permission needed"
        }
        switch status {
        case .onPendingLogout: return "Log out to finish taking over ⇧⌘3"
        case .failed(let reason): return reason
        case .on, .off: return nil
        }
    }

    /// Truncates long display names with an ellipsis so the panel stays narrow.
    static func shortName(_ name: String, max: Int = maxNameLength) -> String {
        guard name.count > max else { return name }
        return name.prefix(max - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
