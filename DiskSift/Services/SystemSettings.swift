import AppKit

@MainActor
enum SystemSettings {
    // Apple Developer Forums: https://developer.apple.com/forums/thread/791996
    static func openFullDiskAccess() {
        for address in [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
