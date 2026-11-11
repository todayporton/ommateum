import Foundation

/// The moments that play a sound, each set in 設定 ▸ サウンド.
enum SoundEvent: String, CaseIterable {
    /// Moving to the Trash, and deleting without it.
    case trash
    /// Copy, move and duplicate, when every item made it.
    case transferDone

    var title: String {
        switch self {
        case .trash: loc("Move to Trash and Delete")
        case .transferDone: loc("Copy and Move Finished")
        }
    }

    var preferenceKey: String { "sound." + rawValue }

    /// The Finder's own sounds for the same moments.
    var defaultSound: URL {
        switch self {
        case .trash: SoundLibrary.systemSounds.appendingPathComponent("finder/move to trash.aif")
        // The Finder plays this file when a move finishes (found in the system sound server's log; the name is misleading).
        case .transferDone: SoundLibrary.systemSounds.appendingPathComponent("system/Volume Mount.aif")
        }
    }
}

/// Sound files offered in the settings, grouped by where they live.
enum SoundLibrary {
    static let systemSounds = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds")

    struct Group: Identifiable {
        let title: String
        let sounds: [URL]
        var id: String { title }
    }

    static let fileExtensions: Set<String> = ["aif", "aiff", "caf", "wav", "mp3", "m4a"]

    /// Alert sounds, including the user's own in ~/Library/Sounds, then the system's effect sounds.
    static func groups() -> [Group] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sources: [(String, URL)] = [
            (loc("Alert Sounds"), URL(fileURLWithPath: "/System/Library/Sounds")),
            (loc("Your Sounds"), home.appendingPathComponent("Library/Sounds")),
            (loc("Your Sounds"), URL(fileURLWithPath: "/Library/Sounds")),
            ("Finder", systemSounds.appendingPathComponent("finder")),
            ("Dock", systemSounds.appendingPathComponent("dock")),
            (loc("System"), systemSounds.appendingPathComponent("system")),
        ]
        var groups: [Group] = []
        for (title, directory) in sources {
            let sounds = soundFiles(in: directory)
            guard !sounds.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index] = Group(title: title, sounds: (groups[index].sounds + sounds).sorted(by: isOrderedBefore))
            } else {
                groups.append(Group(title: title, sounds: sounds))
            }
        }
        return groups
    }

    static func soundFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { fileExtensions.contains($0.pathExtension.lowercased()) }.sorted(by: isOrderedBefore)
    }

    static func name(of sound: URL) -> String { sound.deletingPathExtension().lastPathComponent }

    private static func isOrderedBefore(_ a: URL, _ b: URL) -> Bool {
        name(of: a).localizedStandardCompare(name(of: b)) == .orderedAscending
    }
}
