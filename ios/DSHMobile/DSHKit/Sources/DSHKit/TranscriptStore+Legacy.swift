import Foundation

/// One-time import of the whole-file JSON snapshots this store replaces.
///
/// Without it an upgrade looks like "all my history disappeared": the JSON files
/// are gone (or ignored) and the new database starts empty. The import runs on
/// the first open of a scope, moves every record in, and deletes the file it read
/// — so a session's older pages are still there on a cold start (spec FR-033).
///
/// Two honest limitations:
///   * the filename is the *slugged* session id (that is what the old cache
///     wrote), so an id containing characters outside `[A-Za-z0-9-_]` cannot be
///     recovered verbatim — it is imported under its slug instead of dropped;
///   * there is no record of when the reader last opened a session, so the
///     snapshot's own `savedAt` becomes the archive clock. A file that is already
///     six days old therefore has one day left, not seven.
extension TranscriptStore {

    func importLegacyFiles(in directory: URL, scope: String, handle: SQLiteHandle) throws {
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let legacy = entries.filter { $0.pathExtension == "json" }
        guard !legacy.isEmpty else { return }
        for url in legacy {
            defer { try? fileManager.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                if url.lastPathComponent.hasSuffix(".older.json") {
                    try importOlder(data, url: url, scope: scope)
                } else {
                    try importTail(data, url: url, scope: scope)
                }
            } catch {
                // Unreadable or stale: the file goes, the session simply starts
                // cold next time (the same rule the JSON cache used).
                continue
            }
        }
    }

    private func importTail(_ data: Data, url: URL, scope: String) throws {
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(SessionTranscriptSnapshot.self, from: data)
        guard snapshot.schema == SessionTranscriptSnapshot.schemaVersion else { return }
        let sessionId = url.deletingPathExtension().lastPathComponent
        try append(scope: scope, sessionId: sessionId, records: snapshot.records,
                   hasMore: snapshot.hasOlder, openedAt: snapshot.savedAt)
    }

    private func importOlder(_ data: Data, url: URL, scope: String) throws {
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(SessionOlderSnapshot.self, from: data)
        guard snapshot.schema == SessionOlderSnapshot.schemaVersion else { return }
        let sessionId = url.lastPathComponent
            .replacingOccurrences(of: ".older.json", with: "")
        try append(scope: scope, sessionId: sessionId, records: snapshot.records,
                   hasMore: snapshot.hasOlder, openedAt: snapshot.savedAt)
    }
}
