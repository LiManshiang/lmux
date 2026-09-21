import Foundation

/// Which side of a conversation is ahead, for the import half of sync.
///
/// A cloud file's modification date says when it was written, not what it
/// holds. An export made by a machine whose own copy of the conversation is
/// behind rewrites the cloud file with *less* history than the other machine
/// has — two machines whose copies had drifted apart did exactly that, and the
/// file arrived looking brand new. Deciding from the file date alone would
/// overwrite the newer local conversation and delete everything in between, so
/// the decision is taken from the conversation itself: the timestamp of its
/// last record.
///
/// Pure, so the rule can be tested without a sync folder or a filesystem.
public enum SyncImport {
    /// The timestamp of the last record that carries one, or nil when the text
    /// holds no timestamped record at all.
    ///
    /// Scans backwards from the end because records are appended: the newest
    /// one is last. A record without a timestamp (some bookkeeping records have
    /// none) is skipped rather than ending the search.
    public static func lastRecordTimestamp(in text: String) -> Int64? {
        var end = text.endIndex
        while let found = text.range(of: "\"timestamp\":", options: .backwards,
                                     range: text.startIndex..<end) {
            let digits = text[found.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty, let value = Int64(digits) {
                return value
            }
            end = found.lowerBound
        }
        return nil
    }

    /// True when the cloud copy's records stop before the local copy's — an
    /// older copy of the same conversation, which must not replace the local
    /// one.
    ///
    /// Without a timestamp on either side there is no evidence, and the answer
    /// is false: the caller then keeps whatever behaviour it had rather than
    /// inventing an order.
    public static func cloudIsBehindLocal(localLast: Int64?, cloudLast: Int64?) -> Bool {
        guard let localLast, let cloudLast else { return false }
        return cloudLast < localLast
    }

    /// True when the cloud copy's records run past the local copy's — history
    /// the other machine has and this one does not, which must not be published
    /// over (that is how the two machines took turns shrinking the file).
    public static func cloudIsAheadOfLocal(localLast: Int64?, cloudLast: Int64?) -> Bool {
        guard let localLast, let cloudLast else { return false }
        return cloudLast > localLast
    }
}
