import Foundation

extension Notification.Name {
    static let fontSizeChanged = Notification.Name("DeskNotesFontSizeChanged")
}

enum Settings {
    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "fontSize")
            return stored == 0 ? 14 : CGFloat(min(max(stored, 10), 32))
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 10), 32)), forKey: "fontSize")
            NotificationCenter.default.post(name: .fontSizeChanged, object: nil)
        }
    }
}
