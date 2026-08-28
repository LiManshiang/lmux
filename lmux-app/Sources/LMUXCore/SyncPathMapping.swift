import Foundation

/// A path mapping entry: rewrite `from` to `to` on import.
/// Cross-device sync uses these to translate paths between machines that
/// mount the same project at different locations (e.g. `/Users/limanshiang`
/// vs `/Users/manshiangli`).
public struct PathMapping: Equatable, Identifiable {
    public var from: String
    public var to: String
    public var id: String { "\(from)→\(to)" }

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public enum SyncPathMapping {
    /// Apply a list of path mappings (longest `from` prefix first) to a path
    /// or text blob containing absolute paths (e.g. project_dir, JSONL cwd).
    public static func apply(_ text: String, mappings: [PathMapping]) -> String {
        var result = text
        let sorted = mappings.sorted { $0.from.count > $1.from.count }
        for mapping in sorted where !mapping.from.isEmpty {
            result = result.replacingOccurrences(of: mapping.from, with: mapping.to)
        }
        return result
    }

    /// Strip characters that are invalid in file names or make it unsafe.
    public static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return name
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
