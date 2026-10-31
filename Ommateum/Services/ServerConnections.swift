import AppKit
import NetFS

/// A server (and optionally one share on it) as typed by the user or reported by a mounted volume.
struct ServerAddress: Equatable {
    private static let schemes = ["smb", "afp", "nfs", "http", "https"]

    /// Short name shown in the sidebar and used to recognise the same server across URL spellings.
    let name: String
    /// The server without a path. Passwords are dropped: NetAuth keeps them in the Keychain.
    let baseURL: URL
    let share: String?

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "smb://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let name = Self.serverName(of: url) else { return nil }
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else { return nil }
        self.name = name
        self.baseURL = baseURL
        share = url.pathComponents.first { $0 != "/" }
    }

    /// "smb://user@MyNAS._smb._tcp.local/music" → "MyNAS", "smb://nas.local/x" → "nas". IP addresses and other hosts stay whole.
    private static func serverName(of url: URL) -> String? {
        guard var host = url.host?.removingPercentEncoding, !host.isEmpty else { return nil }
        if let service = host.range(of: "._") { host = String(host[..<service.lowerBound]) }
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        return host
    }
}

/// A server remembered in the sidebar, whether connected or not.
struct RegisteredServer: Codable, Equatable {
    var name: String
    var url: String
    var shares: [String]

    func mountURL(share: String?) -> URL? {
        guard let base = URL(string: url) else { return nil }
        return share.map { base.appendingPathComponent($0) } ?? base
    }
}

/// Mounts network volumes through the public NetFS API. The system shows its own sign-in
/// (and share selection when no share is given) and stores the password in the Keychain.
enum ServerConnector {
    static func mount(_ url: URL, window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        let openOptions = NSMutableDictionary(dictionary: ["UIOption": "AllowUI"]) // kNAUIOptionKey / kNAUIOptionAllowUI
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions as CFMutableDictionary, nil, &requestID, .main) { status, _, mountpoints in
            MainActor.assumeIsolated {
                finish(status: status, mountpoints: mountpoints, url: url, window: window, completion: completion)
            }
        }
        if status != 0 { finish(status: status, mountpoints: nil, url: url, window: window, completion: completion) }
    }

    private static func finish(status: Int32, mountpoints: CFArray?, url: URL, window: NSWindow?, completion: ([URL]) -> Void) {
        let userCanceled: Int32 = -128
        switch status {
        case 0:
            completion(((mountpoints as? [String]) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) })
        case EEXIST:
            completion([]) // already mounted
        case userCanceled, ECANCELED:
            break
        default:
            let reason = String(cString: strerror(status))
            FileOperations.shared.showError(message: "「\(url.absoluteString)」に接続できませんでした（\(status): \(reason)）。", window: window)
        }
    }
}
