import Foundation

/// Strings that reach the UI as runtime values (operation log reasons, helper refusals, battery condition).
/// Listing them here lets the compiler extract them into the string catalog so they can be translated.
enum DynamicStrings {
    static let all: [LocalizedStringResource] = [
        // SafetyKit.RefusalReason.englishDescription
        "Not an absolute path", "Protected location", "A system folder that holds other items", "Belongs to another user",
        "Whitelisted", "Contains a whitelisted item", "Outside the folders KeelMac may change", "Needs the KeelMac helper",
        "No longer exists", "Changed since the preview",
        // HelperShared.HelperRejection.englishDescription
        "The request could not be read", "The app and the helper are different versions", "Not a valid launchd label",
        "macOS's own launch items are never changed", "The plist is not in /Library/LaunchAgents or /Library/LaunchDaemons",
        "The plist does not belong to that label", "Not a clean absolute path", "No items to remove", "Too many items in one request",
        "Not a valid amount of space",
        // App-side reasons
        "The helper didn’t respond", "Took too long and was stopped", "Not available on this version of macOS",
        "Permission denied", "Operation not permitted",
        // Battery condition from IOKit / System Information
        "Normal", "Service Recommended",
    ]
}
