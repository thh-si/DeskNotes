import Foundation

/// Decides what a ⌘-clicked `[label](target)` may open. Notes often hold pasted text, and the label
/// hides the target, so only web and mail links are opened: `file://`, custom app schemes and the
/// like could launch apps, mount shares or trigger other apps' URL handlers.
public enum LinkPolicy {
    public static let webSchemes: Set<String> = ["http", "https"]

    /// The URL to open, or nil if the link must not be opened. `example.com` becomes `https://example.com`.
    public static func url(for target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("mailto:") {
            return URL(string: trimmed)
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
