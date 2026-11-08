import Foundation

/// Text shown to the user, looked up in Localizable.xcstrings. The key is the English text, which is also what
/// appears when no translation exists. Arguments fill `%@` / `%ld` as in `String(format:)`; a translation may
/// reorder them with `%1$@`.
nonisolated func loc(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
}

/// The language chosen in 設定 ▸ 一般. Stored as this app's own `AppleLanguages`, which macOS reads at launch,
/// so a change takes effect after relaunching.
enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case japanese = "ja"

    /// Each language is named in itself, as in the system's language lists.
    var title: String {
        switch self {
        case .system: loc("System")
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    /// What the running app was launched with; set before anything can change it.
    static let atLaunch = AppLanguage.current

    static var current: AppLanguage {
        // Only this app's domain: `UserDefaults.standard` would also return the system-wide list.
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}
