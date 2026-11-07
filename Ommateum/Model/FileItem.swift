import Foundation
import UniformTypeIdentifiers

/// Metadata of one file system entry as shown in a browser. Created off the main thread by `DirectoryLoader`.
struct FileItem: Hashable, Sendable {
    nonisolated static let resourceKeys: [URLResourceKey] = [
        .localizedNameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isAliasFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey,
        .localizedTypeDescriptionKey, .contentTypeKey, .tagNamesKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isAlias: Bool
    let size: Int64?
    let dateModified: Date?
    let dateCreated: Date?
    let kind: String
    let tags: [String]
    let contentType: UTType?
    /// `true` for cloud placeholders that are not downloaded locally (File Provider / iCloud Drive).
    let isCloudOnly: Bool

    /// Folders that the user navigates into (packages such as .app behave like files, as in Finder).
    var isNavigable: Bool { isDirectory && !isPackage }

    /// Whether the list view shows a thumbnail instead of the icon. Like Finder, only for pictures and movies:
    /// at 16 points a document's thumbnail is a blank page.
    var showsListThumbnail: Bool {
        guard let contentType, !isDirectory else { return false }
        return contentType.conforms(to: .image) || contentType.conforms(to: .movie)
    }

    /// - Parameter directory: The folder that was listed. The item's URL is rebuilt from it so that every URL in a
    ///   listing uses the same spelling as the folder URL (the system may return `/private/tmp/…` for `/tmp/…`).
    nonisolated init(url: URL, in directory: URL? = nil) {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.url = directory.map { $0.appendingPathComponent(url.lastPathComponent, isDirectory: values?.isDirectory ?? false) } ?? url
        name = values?.localizedName ?? url.lastPathComponent
        isDirectory = values?.isDirectory ?? false
        isPackage = values?.isPackage ?? false
        isHidden = values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
        isAlias = (values?.isAliasFile ?? false) && !(values?.isSymbolicLink ?? false)
        size = (isDirectory && !isPackage) ? nil : (values?.fileSize).map(Int64.init)
        dateModified = values?.contentModificationDate
        dateCreated = values?.creationDate
        kind = values?.localizedTypeDescription ?? ""
        tags = values?.tagNames ?? []
        contentType = values?.contentType
        if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus {
            isCloudOnly = status == .notDownloaded
        } else {
            isCloudOnly = false
        }
    }

    /// Case-, width- and diacritic-insensitive name match used by the search bar.
    nonisolated func matches(query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || name.localizedStandardContains(text)
    }

    nonisolated static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.url == rhs.url }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

extension Array where Element == FileItem {
    /// Sorts like Finder: localized "natural" name comparison; ties are broken by name.
    nonisolated func sorted(by spec: SortSpec) -> [FileItem] {
        sorted { lhs, rhs in
            let order: ComparisonResult
            switch spec.key {
            case .name:
                order = lhs.name.localizedStandardCompare(rhs.name)
            case .dateModified:
                order = Self.compare(lhs.dateModified, rhs.dateModified)
            case .dateCreated:
                order = Self.compare(lhs.dateCreated, rhs.dateCreated)
            case .size:
                order = Self.compare(lhs.size ?? -1, rhs.size ?? -1)
            case .kind:
                order = lhs.kind.localizedStandardCompare(rhs.kind)
            }
            if order == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return spec.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private nonisolated static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (l?, r?): l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
        case (nil, _?): .orderedAscending
        case (_?, nil): .orderedDescending
        case (nil, nil): .orderedSame
        }
    }
}

struct FileItemGroup: Equatable, Sendable {
    let title: String
    let items: [FileItem]
}

extension Array where Element == FileItem {
    /// Groups already-sorted items, keeping their order inside each group, like Finder's "グループ分け".
    nonisolated func grouped(by key: GroupKey, now: Date = Date(), calendar: Calendar = .current) -> [FileItemGroup] {
        switch key {
        case .kind:
            return Dictionary(grouping: self, by: \.kind)
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { FileItemGroup(title: $0.key.isEmpty ? "その他" : $0.key, items: $0.value) }
        case .dateModified:
            return buckets(["今日", "昨日", "過去7日間", "過去30日間", "それ以前"]) { item in
                guard let date = item.dateModified else { return 4 }
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
                switch days {
                case ...0: return 0
                case 1: return 1
                case 2...7: return 2
                case 8...30: return 3
                default: return 4
                }
            }
        case .size:
            return buckets(["1 GB 以上", "100 MB〜1 GB", "1 MB〜100 MB", "1 MB 未満", "フォルダ"]) { item in
                guard let size = item.size else { return 4 }
                switch size {
                case 1_000_000_000...: return 0
                case 100_000_000...: return 1
                case 1_000_000...: return 2
                default: return 3
                }
            }
        }
    }

    private nonisolated func buckets(_ titles: [String], index: (FileItem) -> Int) -> [FileItemGroup] {
        let grouped = Dictionary(grouping: self, by: index)
        return titles.indices.compactMap { position in
            grouped[position].map { FileItemGroup(title: titles[position], items: $0) }
        }
    }
}
