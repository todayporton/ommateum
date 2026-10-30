import AppKit

/// Share extensions installed on the system (AirDrop, Dropbox Transfer, …), used through the public NSSharingService API.
enum SharingServices {
    /// The installed share service whose title matches, if it accepts these items.
    static func service(titled title: String, for urls: [URL]) -> NSSharingService? {
        guard !urls.isEmpty else { return nil }
        return lookup.services(for: urls).first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
    }

    /// The standard "共有" submenu (macOS 13+).
    static func shareMenuItem(for urls: [URL]) -> NSMenuItem {
        let item = NSSharingServicePicker(items: urls).standardShareMenuItem
        item.title = "共有"
        return item
    }

    // `sharingServices(forItems:)` is deprecated in favour of the picker, but it is still the only public way
    // to invoke one specific service directly. Calling it through a protocol keeps the deprecation local.
    private protocol Lookup { func services(for items: [Any]) -> [NSSharingService] }
    private struct LegacyLookup: Lookup {
        @available(macOS, deprecated: 13.0)
        func services(for items: [Any]) -> [NSSharingService] { NSSharingService.sharingServices(forItems: items) }
    }
    private static let lookup: any Lookup = LegacyLookup()
}
