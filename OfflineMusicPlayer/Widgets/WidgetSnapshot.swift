import Foundation
import WidgetKit
import CryptoKit
import UIKit
import ImageIO

struct WidgetSnapshot: Codable, Equatable {
    var title: String
    var artist: String
    var artworkName: String?
    static let empty = WidgetSnapshot(title: "", artist: "", artworkName: nil)
    var hasTrack: Bool { !title.isEmpty }
}

enum CassetteWidgetConfiguration {
    static let kind = "CassetteLastPlayed"
    static let appGroup = "group.com.local.offlinemusicplayer"
    static let snapshotDefaultsKey = "cassette.widget.snapshot"
    static let artworkDefaultsKey = "cassette.widget.artwork"
    static let artworkNameDefaultsKey = "cassette.widget.artworkName"
    static let playerURL = URL(string: "cassette://player")!
    static let libraryURL = URL(string: "cassette://library")!
    static func opensPlayer(_ url: URL) -> Bool {
        validRoute(url, host: "player")
    }
    static func opensLibrary(_ url: URL) -> Bool { validRoute(url, host: "library") }
    private static func validRoute(_ url: URL, host: String) -> Bool {
        url.scheme?.lowercased() == "cassette" && url.host == host && url.path.isEmpty && url.query == nil && url.fragment == nil && url.user == nil && url.password == nil && url.port == nil
    }
    /// Extracts `com.apple.security.application-groups` from a provisioning profile or `.xcent` plist data.
    static func extractAppGroups(from data: Data) -> [String] {
        guard !data.isEmpty, data.count <= 512_000 else { return [] }
        let xmlSlice: Data
        if let start = data.range(of: Data("<?xml".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) {
            xmlSlice = data.subdata(in: start.lowerBound..<end.upperBound)
        } else {
            xmlSlice = data
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: xmlSlice, options: [], format: nil) as? [String: Any] else {
            return []
        }
        if let entitlements = plist["Entitlements"] as? [String: Any],
           let groups = entitlements["com.apple.security.application-groups"] as? [String] {
            return groups.filter { !$0.isEmpty }
        }
        if let groups = plist["com.apple.security.application-groups"] as? [String] {
            return groups.filter { !$0.isEmpty }
        }
        return []
    }
    /// Resolves candidate App Group identifiers across standard Xcode signing and re-signed/sideloaded bundles
    /// (such as Sideloadly/AltStore/SideStore where bundle and group IDs gain a team/account suffix).
    static func candidateAppGroups(bundle: Bundle = .main) -> [String] {
        var candidates: [String] = []
        func appendUnique(_ group: String) {
            let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }
        let bundleURL = bundle.bundleURL
        var searchBundles = [bundleURL]
        if bundleURL.pathExtension == "appex" {
            let parentApp = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if parentApp.pathExtension == "app" {
                searchBundles.append(parentApp)
            }
        }
        for url in searchBundles {
            for file in ["embedded.mobileprovision", "archived-expanded-entitlements.xcent"] {
                if let data = try? Data(contentsOf: url.appendingPathComponent(file)) {
                    extractAppGroups(from: data).forEach(appendUnique)
                }
            }
        }
        if let id = bundle.bundleIdentifier, !id.isEmpty {
            let baseID = id.hasSuffix(".widget") ? String(id.dropLast(".widget".count)) : id
            appendUnique("group." + baseID)
            appendUnique("group." + id)
        }
        if bundleURL.pathExtension == "appex" {
            let parentApp = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let parentInfo = NSDictionary(contentsOf: parentApp.appendingPathComponent("Info.plist")) as? [String: Any],
               let parentID = parentInfo["CFBundleIdentifier"] as? String, !parentID.isEmpty {
                appendUnique("group." + parentID)
            }
        }
        appendUnique(appGroup)
        return candidates
    }
    static var resolvedAppGroup: String? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        for group in candidateAppGroups() {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
                return group
            }
        }
        return nil
        #endif
    }
    static var sharedDefaults: UserDefaults? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        guard let group = resolvedAppGroup ?? candidateAppGroups().first else { return nil }
        return UserDefaults(suiteName: group)
        #endif
    }
    static var directory: URL? {
        #if targetEnvironment(macCatalyst)
        return nil // Desktop previews/tests inject a private directory; no group entitlement is needed.
        #else
        for group in candidateAppGroups() {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return container.appendingPathComponent("Widget", isDirectory: true)
            }
        }
        return nil
        #endif
    }
    static func read(from directory: URL?, defaults: UserDefaults? = nil) -> WidgetSnapshot {
        readValidSnapshot(from: directory, defaults: defaults) ?? .empty
    }
    static func readValidSnapshot(from directory: URL?, defaults: UserDefaults? = nil) -> WidgetSnapshot? {
        if let directory = directory {
            let file = directory.appendingPathComponent("snapshot.json")
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
               size.isSymbolicLink != true, (size.fileSize ?? 64_001) <= 64_000,
               let data = try? Data(contentsOf: file),
               let snapshot = decodeSnapshot(from: data) {
                return snapshot
            }
        }
        if let data = defaults?.data(forKey: snapshotDefaultsKey),
           let snapshot = decodeSnapshot(from: data) {
            return snapshot
        }
        return nil
    }
    private static func decodeSnapshot(from data: Data) -> WidgetSnapshot? {
        guard data.count <= 64_000,
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.title.count <= 1000, snapshot.artist.count <= 1000,
              snapshot.artworkName.map(validArtworkName) ?? true else { return nil }
        return snapshot
    }
    private static func validArtworkName(_ name: String) -> Bool {
        name.hasPrefix("cover-") && name.hasSuffix(".jpg") && !name.contains("/") && !name.contains("..")
    }
    /// The extension must never decode an arbitrary full-resolution image or follow a symlink.
    static func artwork(for snapshot: WidgetSnapshot, in directory: URL?, defaults: UserDefaults? = nil) -> UIImage? {
        guard let name = snapshot.artworkName, validArtworkName(name) else { return nil }
        if let directory = directory {
            let file = directory.appendingPathComponent(name)
            if let attributes = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey]),
               attributes.isSymbolicLink != true, attributes.isRegularFile == true,
               let size = attributes.fileSize, size > 0, size <= 2_000_000,
               let data = try? Data(contentsOf: file),
               let image = decodeThumbnail(from: data) {
                return image
            }
        }
        if let defaults = defaults,
           defaults.string(forKey: artworkNameDefaultsKey) == name,
           let data = defaults.data(forKey: artworkDefaultsKey),
           let image = decodeThumbnail(from: data) {
            return image
        }
        return nil
    }
    static func decodeThumbnail(from data: Data, maxPixelSize: Int = 320) -> UIImage? {
        guard !data.isEmpty, data.count <= 2_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    static func retryDate(after date: Date) -> Date { date.addingTimeInterval(30 * 60) }
}

/// Publishes only when visible metadata/artwork changes, never on progress ticks or Play/Pause.
actor WidgetSnapshotStore {
    static let shared = WidgetSnapshotStore(directory: CassetteWidgetConfiguration.directory, defaults: CassetteWidgetConfiguration.sharedDefaults, usesDynamicContainer: true)
    private let directory: URL?
    private let defaults: UserDefaults?
    private let usesDynamicContainer: Bool
    init(directory: URL?, defaults: UserDefaults? = nil, usesDynamicContainer: Bool = false) {
        self.directory = directory
        self.defaults = defaults
        self.usesDynamicContainer = usesDynamicContainer
    }
    @discardableResult
    func publish(title: String, artist: String, artwork: URL?, force: Bool = false) throws -> Bool {
        try Task.checkCancellation()
        let activeDirectory = usesDynamicContainer ? (directory ?? CassetteWidgetConfiguration.directory) : directory
        let activeDefaults = usesDynamicContainer ? (defaults ?? CassetteWidgetConfiguration.sharedDefaults) : defaults
        guard activeDirectory != nil || activeDefaults != nil else { return false }
        let fm = FileManager.default
        if let activeDirectory = activeDirectory {
            try fm.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
            #if !targetEnvironment(macCatalyst)
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: activeDirectory.path)
            #endif
        }
        var snapshot = WidgetSnapshot(title: String(title.prefix(1000)), artist: String(artist.prefix(1000)), artworkName: nil)
        var sharedCoverBytes: Data?
        if let artwork = artwork, let attributes = try? artwork.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), attributes.isSymbolicLink != true,
           let size = attributes.fileSize, size > 0, size <= 2_000_000,
           let bytes = try? Data(contentsOf: artwork), bytes.count <= 2_000_000 {
            // Only the already-downsampled cover is shared, never audio, bookmarks or the library database.
            let name = "cover-" + SHA256.hash(data: bytes).prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
            if let activeDirectory = activeDirectory {
                let destination = activeDirectory.appendingPathComponent(name)
                // A cover failure must not prevent the title/fallback from reaching the widget.
                do {
                    if force || !fm.fileExists(atPath: destination.path) { try write(bytes, to: destination) }
                    snapshot.artworkName = name
                    sharedCoverBytes = bytes
                } catch { snapshot.artworkName = nil }
            } else {
                snapshot.artworkName = name
                sharedCoverBytes = bytes
            }
        }
        guard force || CassetteWidgetConfiguration.readValidSnapshot(from: activeDirectory, defaults: activeDefaults) != snapshot else { return false }
        try Task.checkCancellation()
        let encoded = try JSONEncoder().encode(snapshot)
        if let activeDirectory = activeDirectory {
            try write(encoded, to: activeDirectory.appendingPathComponent("snapshot.json"))
            // Bound storage. Keep one prior cover so a currently rendered old entry can still load it.
            let covers = (try? fm.contentsOfDirectory(at: activeDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let obsolete = covers.filter { $0.lastPathComponent.hasPrefix("cover-") && $0.lastPathComponent != snapshot.artworkName }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in obsolete.dropFirst() { try? fm.removeItem(at: old) }
        }
        if let activeDefaults = activeDefaults {
            activeDefaults.set(encoded, forKey: CassetteWidgetConfiguration.snapshotDefaultsKey)
            if let name = snapshot.artworkName, let bytes = sharedCoverBytes {
                let compact = bytes.count <= 256_000 ? bytes : CassetteWidgetConfiguration.decodeThumbnail(from: bytes)?.jpegData(compressionQuality: 0.75)
                if let compact = compact, compact.count <= 256_000 {
                    activeDefaults.set(name, forKey: CassetteWidgetConfiguration.artworkNameDefaultsKey)
                    activeDefaults.set(compact, forKey: CassetteWidgetConfiguration.artworkDefaultsKey)
                }
            } else {
                activeDefaults.removeObject(forKey: CassetteWidgetConfiguration.artworkNameDefaultsKey)
                activeDefaults.removeObject(forKey: CassetteWidgetConfiguration.artworkDefaultsKey)
            }
            activeDefaults.synchronize()
        }
        return true
    }
    private func write(_ data: Data, to url: URL) throws {
        #if targetEnvironment(macCatalyst)
        try data.write(to: url, options: .atomic)
        #else
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

}
