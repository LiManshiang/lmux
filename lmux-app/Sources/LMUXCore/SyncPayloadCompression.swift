import Foundation

/// Compression for the conversation payload carried inside a `.lmuxsession`
/// bundle.
///
/// A `.lmuxsession` file holds the whole conversation JSONL as one JSON string,
/// and on a long agent session that string reaches 100 MB. Most of it is
/// redundant: measured over a real 104 MB conversation, `providerData` alone is
/// 54% of the bytes and it restates the record's own fields
/// (`providerData.toolResult` repeats `output`, `providerData.reasoning`
/// repeats `rawContent`, `providerData.arguments` repeats `arguments`), which is
/// the kind of thing a general-purpose compressor eats. On that same file:
///
///     lzfse   108.5 MB -> 18.2 MB   6.0x   2.5s
///     zlib    108.5 MB -> 21.8 MB   5.0x   0.8s
///     lzma    108.5 MB -> 14.1 MB   7.7x   9.1s
///
/// LZFSE is the pick: built into Foundation (no dependency), and its extra
/// ratio over zlib costs a couple of seconds on a sync that is already moving
/// hundreds of megabytes. LZMA's further 1.7x is not worth nine seconds.
///
/// The encoding is *recorded* in the bundle rather than assumed, so a bundle
/// written before compression existed (no tag at all) still reads as plain
/// text, and a tag this build does not recognise is refused rather than handed
/// on as if it were a conversation.
public enum SyncPayloadCompression {
    /// Tag written into the bundle for a compressed payload.
    public static let lzfseBase64 = "lzfse-base64"

    /// Payloads smaller than this stay uncompressed.
    ///
    /// Two reasons, both real. Base64 costs 33% of the compressed size back, so
    /// a payload that compresses poorly can come out *larger* than the plain
    /// text. And staying under this line keeps a bundle readable by a build
    /// from before compression existed, which would otherwise decode the base64
    /// as if it were the conversation — there is no in-band way to protect it,
    /// because such a build reads neither `content_encoding` nor `version`.
    /// Above the line that compatibility is deliberately given up: the machines
    /// sharing a sync directory have to be on the same side of this change. The
    /// size that motivated it — 100 MB conversations — sits two orders of
    /// magnitude above the line, so the line is not doing the work; it only
    /// keeps the small, common case universally readable.
    public static let minimumBytes = 1 << 20

    /// The payload as it should be stored: what to put in `content`, and the
    /// tag to record alongside it (nil when stored plain).
    public struct Encoded {
        /// The text to store in the bundle's `content` field: either the
        /// payload itself, or its base64 (see `encoding`).
        public let content: String
        /// The tag to write to `content_encoding`, or nil for plain text.
        public let encoding: String?

        public init(content: String, encoding: String?) {
            self.content = content
            self.encoding = encoding
        }
    }

    /// Compress a payload for storage, or return it unchanged when compressing
    /// would not pay off.
    public static func encode(_ text: String) -> Encoded {
        let raw = Data(text.utf8)
        guard raw.count >= minimumBytes,
              let packed = try? (raw as NSData).compressed(using: .lzfse)
        else {
            return Encoded(content: text, encoding: nil)
        }
        let base64 = (packed as Data).base64EncodedString()
        // `content` is a JSON string in both forms, so the escaping overhead is
        // the same on either side of this comparison and cancels out.
        guard base64.utf8.count < raw.count else {
            return Encoded(content: text, encoding: nil)
        }
        return Encoded(content: base64, encoding: lzfseBase64)
    }

    /// The plain text behind a stored payload, or nil when the tag is unknown,
    /// the base64 is damaged, or the bytes are not UTF-8.
    ///
    /// Callers must treat nil as "cannot read this bundle" rather than falling
    /// back to the stored string: importing a misread payload writes garbage
    /// into a conversation, which is far worse than skipping the file.
    public static func decode(content: String, encoding: String?) -> String? {
        guard let encoding, !encoding.isEmpty else { return content }
        // Refuse an unknown tag before touching the payload: it is the
        // difference between "this file came from a newer build" and "this file
        // is corrupt", and neither may be read as text.
        guard encoding == lzfseBase64 else { return nil }
        guard let packed = Data(base64Encoded: content),
              let raw = try? (packed as NSData).decompressed(using: .lzfse)
        else { return nil }
        return String(data: raw as Data, encoding: .utf8)
    }
}
