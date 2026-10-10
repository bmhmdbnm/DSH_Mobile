import Foundation

/// The pixel size of every picture the phone has ever decoded, kept on disk.
///
/// The wire protocol *usually* carries `width`/`height` on an image attachment,
/// and then the transcript can reserve the row's final height before a single
/// byte arrives (spec 009 「附件行高预留」). Older hosts and a few splice paths
/// omit it, though — for those the first render falls back to a 4:3 box, and
/// the moment the bytes are decoded the real size lands here, so the *next*
/// render of the same attachment (after a restart, or in another session) is
/// exact. This is the fallback table, not the primary source: the metadata on
/// the event always wins when it exists.
///
/// Storage is a single JSON file under `Caches`, deliberately *outside* the
/// attachment cache directory so `AttachmentDiskCache.prune()`/`clearAll()`
/// cannot drop the sizes along with the bytes they describe. It is a cache,
/// not truth: losing it costs one 4:3 placeholder per picture.
public final class AttachmentDimensions: @unchecked Sendable {

    /// The decoded pixel extent of one attachment.
    public struct Size: Sendable, Hashable, Codable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        /// Width over height, for reserving a row height from a column width.
        public var aspectRatio: Double? {
            guard width > 0, height > 0 else { return nil }
            return Double(width) / Double(height)
        }
    }

    private let file: URL
    private let lock = NSLock()
    private var sizes: [String: Size]
    private var loaded = false

    public init(file: URL? = nil, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.file = file ?? base.appendingPathComponent("attachment-dimensions.json")
        self.sizes = [:]
    }

    /// The remembered size, when this attachment was decoded before.
    public func size(scope: String, attachmentId: String) -> Size? {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return sizes[Self.key(scope: scope, attachmentId: attachmentId)]
    }

    /// Remembers a freshly decoded size. Writes through to disk immediately:
    /// the file is kilobytes, and a crash between decode and persist is exactly
    /// the cold-start case this exists for.
    public func record(scope: String, attachmentId: String, size: Size) {
        guard size.width > 0, size.height > 0, !attachmentId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        let key = Self.key(scope: scope, attachmentId: attachmentId)
        guard sizes[key] != size else { return }
        sizes[key] = size
        persistLocked()
    }

    /// Forgets everything, for 「清除本地缓存」.
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        sizes.removeAll()
        try? FileManager.default.removeItem(at: file)
    }

    private static func key(scope: String, attachmentId: String) -> String {
        "\(scope)|\(attachmentId)"
    }

    /// Reads the file once; a corrupt file is treated as empty, never fatal.
    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: Size].self, from: data)
        else { return }
        sizes = decoded
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(sizes) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
