import Foundation

/// `ommateum://` URLs that open something in a new window, so launchers, Shortcuts and links can reach Ommateum.
///
/// - `ommateum://open?path=/Users/me/Documents` opens the folder in a new window. A file opens its folder with
///   the file selected. `~` is expanded.
/// - `ommateum://workspace?name=作業` shows the window that has the workspace open, or opens it in a new window.
enum AppURL: Equatable {
    case open(path: String)
    case workspace(name: String)

    static let scheme = "ommateum"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch components.host?.lowercased() {
        case "open":
            guard let path = value("path") else { return nil }
            self = .open(path: (path as NSString).expandingTildeInPath)
        case "workspace":
            guard let name = value("name") else { return nil }
            self = .workspace(name: name)
        default:
            return nil
        }
    }

    var url: URL {
        let (host, key, value) = switch self {
        case .open(let path): ("open", "path", path)
        case .workspace(let name): ("workspace", "name", name)
        }
        // Encoded by hand: URLComponents leaves "&", "+" and "=" as they are inside a query value,
        // and other tools read them as separators or a space.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return URL(string: "\(Self.scheme)://\(host)?\(key)=\(encoded)")!
    }
}
