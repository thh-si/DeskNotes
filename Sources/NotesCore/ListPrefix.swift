import Foundation

/// The prefix of a Markdown list item: `- `, `  * `, `3. `, `2) `, `- [ ] `, `- [x] `.
/// The calculator, the styler and the editor all read list items through this one definition.
public struct ListPrefix: Equatable {
    /// The whole prefix, up to where the item's text starts.
    public let range: NSRange
    public let indent: NSRange
    /// `-`, `*`, `+`, or a number with its delimiter: `12.`, `12)`.
    public let marker: NSRange
    /// The whitespace after the marker.
    public let spacing: NSRange
    /// `[ ]` or `[x]`, if the item is a task.
    public let box: NSRange?
    public let isChecked: Bool

    private static let regex = try! NSRegularExpression(pattern:
        #"^(?<indent>\s*)(?<marker>[-*+]|\d+[.)])(?<spacing>\s+)(?:(?<box>\[(?<mark>[ xX])\])(?:\s+|$))?"#)

    /// Ranges are relative to `line`, in UTF-16 units.
    public static func match(in line: String) -> ListPrefix? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let box = m.range(withName: "box")
        let mark = m.range(withName: "mark")
        return ListPrefix(range: m.range,
                          indent: m.range(withName: "indent"),
                          marker: m.range(withName: "marker"),
                          spacing: m.range(withName: "spacing"),
                          box: box.location == NSNotFound ? nil : box,
                          isChecked: mark.location != NSNotFound && ns.substring(with: mark).lowercased() == "x")
    }
}
