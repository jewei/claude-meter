import Foundation

/// Anthropic renamed Max 20x to Ultra and Max 5x to Max. A plan that the user picked in
/// Settings before the rename, and a reading from the archive, can still carry an old name.
enum ClaudePlanName {
    /// The current name of `plan`: `Max 20x` → `Ultra`, `Max 5x` → `Max`, in any letter case.
    /// Any other name is returned unchanged.
    static func current(_ plan: String) -> String {
        switch plan.trimmingCharacters(in: .whitespaces).lowercased() {
        case "max 20x": "Ultra"
        case "max 5x": "Max"
        default: plan
        }
    }
}
