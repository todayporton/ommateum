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
    /// `true` for cloud placeholders that are not downloaded locally (File Provider / iCloud Drive).
    let isCloudOnly: Bool

    /// Folders that the user navigates into (packages such as .app behave like files, as in Finder).
    var isNavigable: Bool { isDirectory && !isPackage }

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
        if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus {
            isCloudOnly = status == .notDownloaded
        } else {
            isCloudOnly = false
        }
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
