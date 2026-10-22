import Foundation

struct MusicSource: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var bookmark: Data?
    var isOwned: Bool
    var needsReconnect = false
    var enabled = true
    var excludedPaths: [String] = []
    enum CodingKeys: String, CodingKey { case id, name, bookmark, isOwned, needsReconnect, enabled, excludedPaths }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark); isOwned = try c.decode(Bool.self, forKey: .isOwned)
        needsReconnect = try c.decodeIfPresent(Bool.self, forKey: .needsReconnect) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        excludedPaths = try c.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
    }
    init(id: UUID, name: String, bookmark: Data? = nil, isOwned: Bool) {
        self.id = id; self.name = name; self.bookmark = bookmark; self.isOwned = isOwned
    }
    func permits(_ path: String) -> Bool { enabled && !excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") } }
}

struct TrackLocation: Codable, Equatable {
    var sourceID: UUID
    var relativePath: String
    var available: Bool
}

struct Track: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String
    var duration: Double
    var trackNumber: Int
    var discNumber: Int
    var fingerprint: String
    var artwork: String?
    var lyrics: String?
    var locations: [TrackLocation]
    var added: Date
    var favorite = false
    // Optional fields keep older persisted JSON records readable without a schema migration.
    var audioFormat: String? = nil
    var bitrate: Int? = nil
    var audioQualityLabel: String {
        let format = audioFormat ?? locations.first.map { URL(fileURLWithPath: $0.relativePath).pathExtension.uppercased() }.flatMap { $0.isEmpty ? nil : $0 } ?? "Audio"
        if let bitrate = bitrate, bitrate > 0 { return "\(format) · \(Int((Double(bitrate) / 1000).rounded())) kbps" }
        return "\(format) · Bitrate unavailable"
    }
    var available: Bool { locations.contains { $0.available } }
    var albumKey: String { albumArtist + "\u{1f}" + album }

    /// Splits semicolon- or null-separated artist tags (e.g. "Artist A; Artist B" or ID3v2.4 multi-value strings)
    /// into distinct trimmed artist names while preserving their original order.
    static func parseArtists(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["Unknown Artist"] }
        let parts = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ";\u{0000}"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [trimmed] }
        var seen = Set<String>()
        var unique: [String] = []
        for part in parts {
            let key = part.lowercased()
            if seen.insert(key).inserted {
                unique.append(part)
            }
        }
        return unique
    }

    var artistList: [String] { Self.parseArtists(artist) }
    var displayArtist: String { artistList.joined(separator: ", ") }
}

struct MusicPlaylist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var trackIDs: [String] = []
    var importedSourceID: UUID? = nil
    var importedPath: String? = nil
    var unresolvedPaths: [String]? = nil
}

struct PlaybackHistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var trackID: String
    var playedAt = Date()
}

struct PlayedSong: Identifiable {
    let entry: PlaybackHistoryEntry
    let track: Track
    var id: UUID { entry.id }
}

enum RepeatMode: String, Codable, CaseIterable { case off, all, one }
struct PlaybackSnapshot: Codable {
    var queue: [String]
    var index: Int
    var position: Double
    var repeatMode: RepeatMode
    var shuffle: Bool
}

struct LyricLine: Identifiable, Equatable {
    var id: Int
    var time: Double
    var text: String
}

enum LRCParser {
    static func activeLine(in lines: [LyricLine], at position: Double) -> Int? {
        guard position.isFinite else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= position { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? lines[low - 1].id : nil
    }

    static func parse(_ text: String) -> [LyricLine] {
        let pattern = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d{1,2}(?:\\.\\d+)?)\\]")
        let offsetPattern = try! NSRegularExpression(pattern: "\\[offset:([+-]?\\d+)\\]", options: .caseInsensitive)
        let ns = text as NSString
        let offset = offsetPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            .flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var result: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw as NSString
            let matches = pattern.matches(in: raw, range: NSRange(location: 0, length: line.length))
            guard let last = matches.last else { continue }
            let body = line.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Double(line.substring(with: match.range(at: 1))),
                      let seconds = Double(line.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                result.append((max(0, minutes * 60 + seconds + offset), body))
            }
        }
        return result.enumerated().sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
            .enumerated().map { LyricLine(id: $0.offset, time: $0.element.element.0, text: $0.element.element.1) }
    }
}
