// Moves music files into <base>/<album artist>/<album>/ using their tags.
// Usage: organize <base folder> <file>...
// Exits 1 with a summary on stderr when some files were skipped, so Ommateum shows them.
import AVFoundation
import Foundation

let unknownArtist = "不明なアーティスト"
let unknownAlbum = "不明なアルバム"

struct Tags {
    var albumArtist: String?
    var artist: String?
    var album: String?
}

/// Album artist comes from a different field in each format: ID3 TPE2, iTunes aART, Vorbis ALBUMARTIST.
func readTags(_ url: URL) async throws -> Tags? {
    let asset = AVURLAsset(url: url)
    guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return nil }
    // Format-specific items (ID3, iTunes, Vorbis) plus the common ones AVFoundation derives from them.
    var items = try await asset.load(.commonMetadata)
    for format in try await asset.load(.availableMetadataFormats) {
        items += try await asset.loadMetadata(for: format)
    }
    var tags = Tags()
    for item in items {
        guard let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { continue }
        let key = (item.key as? String)?.uppercased().replacingOccurrences(of: " ", with: "")
        switch item.identifier {
        case .iTunesMetadataAlbumArtist, .id3MetadataBand:
            tags.albumArtist = tags.albumArtist ?? value
        case .commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer:
            tags.artist = tags.artist ?? value
        case .commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle:
            tags.album = tags.album ?? value
        default:
            // Vorbis comments (FLAC) have no identifiers of their own.
            switch key {
            case "ALBUMARTIST", "ALBUM_ARTIST": tags.albumArtist = tags.albumArtist ?? value
            case "ARTIST": tags.artist = tags.artist ?? value
            case "ALBUM": tags.album = tags.album ?? value
            default: break
            }
        }
    }
    return tags
}

/// A name that is safe as one path component: no "/" or ":" (the Finder shows ":" as "/"),
/// no leading dot (would hide the folder), at most 255 bytes.
func folderName(_ text: String) -> String {
    var name = text.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        .trimmingCharacters(in: .whitespaces)
    if name.hasPrefix(".") { name = "_" + name.dropFirst() }
    while name.utf8.count > 255 { name.removeLast() }
    return name.isEmpty ? "_" : name
}

/// "Song.mp3", then "Song 2.mp3", "Song 3.mp3"… like Ommateum's "Keep Both".
func freeDestination(for name: String, in folder: URL) -> URL {
    let fm = FileManager.default
    var candidate = folder.appendingPathComponent(name)
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 2
    while fm.fileExists(atPath: candidate.path) {
        let numbered = "\(base) \(number)"
        candidate = folder.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)")
        number += 1
    }
    return candidate
}

let arguments = CommandLine.arguments.dropFirst()
guard let basePath = arguments.first else {
    FileHandle.standardError.write(Data("使い方: organize <整理先のフォルダ> <ファイル>...\n".utf8))
    exit(2)
}
let base = URL(fileURLWithPath: basePath, isDirectory: true)
var moved = 0
var skipped: [String] = []

for path in arguments.dropFirst() {
    let file = URL(fileURLWithPath: path)
    let name = file.lastPathComponent
    do {
        guard let tags = try await readTags(file) else {
            skipped.append("\(name)（音声ファイルではありません）")
            continue
        }
        let artist = folderName(tags.albumArtist ?? tags.artist ?? unknownArtist)
        let album = folderName(tags.album ?? unknownAlbum)
        let folder = base.appendingPathComponent(artist, isDirectory: true).appendingPathComponent(album, isDirectory: true)
        if file.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path {
            continue // already in place
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: freeDestination(for: name, in: folder))
        moved += 1
    } catch let error as CocoaError {
        skipped.append("\(name)（\(error.localizedDescription)）") // file errors read well
    } catch {
        skipped.append("\(name)（読み込めません）") // AVFoundation's are vague ("Operation Stopped")
    }
}

if !skipped.isEmpty {
    var message = "\(moved) 件を整理し、\(skipped.count) 件をスキップしました。\n"
    message += skipped.prefix(20).map { "・\($0)" }.joined(separator: "\n")
    if skipped.count > 20 { message += "\n…ほか \(skipped.count - 20) 件" }
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
