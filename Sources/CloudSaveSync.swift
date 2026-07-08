import Foundation

/// Mirrors per-game save deltas (`changes.jsdos`) between the local library and an
/// iCloud ubiquity container, keyed by a game's stable **content hash** (so a save
/// follows the same game across devices / reinstalls — see `Game.contentHash`).
///
/// The rest of the app keeps reading/writing local files; this layer just keeps the
/// local `changes.jsdos` current. It **no-ops entirely** when iCloud is unavailable
/// (container unprovisioned / user signed out), so the app is never broken by it.
///
/// Main-thread only (NSMetadataQuery posts on the run loop it's started on); file
/// copies are dispatched to a background queue.
@MainActor
final class CloudSaveSync {
    // Must EXACTLY match the iCloud container provisioned on the App ID in the
    // Developer portal (case-sensitive). The account's existing container is mixed-case.
    nonisolated static let containerID = "iCloud.com.mantene.PocketDOS"
    /// Saves larger than this stay local (SPEC H46: large disk images don't sync).
    nonisolated static let sizeCapBytes = 20 * 1_048_576

    /// Pure size-cap gate — extracted so it's unit-testable without iCloud.
    nonisolated static func withinSizeCap(_ bytes: Int) -> Bool { bytes <= sizeCapBytes }

    private var containerURL: URL?
    private var query: NSMetadataQuery?
    private var resolveFolder: ((String) -> URL?)?

    var isAvailable: Bool { containerURL != nil }

    init() {
        // url(forUbiquityContainerIdentifier:) blocks (network/daemon) on first call —
        // resolve it off the main thread, then publish back on main.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let url = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID)
            DispatchQueue.main.async {
                guard let self else { return }
                self.containerURL = url
                NSLog(url == nil ? "[pdos-cloud] iCloud unavailable — local-only"
                                 : "[pdos-cloud] iCloud available")
                if url != nil, self.resolveFolder != nil { self.beginQuery() }
            }
        }
    }

    private var savesRoot: URL? {
        containerURL?.appendingPathComponent("Documents/Saves", isDirectory: true)
    }

    private func remoteURL(forContentHash hash: String) -> URL? {
        guard !hash.isEmpty, let root = savesRoot else { return nil }
        return root.appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent(Game.saveFileName)
    }

    // MARK: - Push (local → cloud)

    /// Upload a local save for `contentHash`, if within the size cap. Coordinated write.
    func pushSave(localURL: URL, contentHash: String) {
        guard let remote = remoteURL(forContentHash: contentHash) else { return }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let size = (try? fm.attributesOfItem(atPath: localURL.path)[.size]) as? Int else { return }
            guard CloudSaveSync.withinSizeCap(size) else {
                NSLog("[pdos-cloud] save \(size) bytes exceeds cap — staying local")
                return
            }
            let coordinator = NSFileCoordinator()
            var err: NSError?
            coordinator.coordinate(writingItemAt: remote, options: .forReplacing, error: &err) { dst in
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: localURL, to: dst)
            }
            if let err { NSLog("[pdos-cloud] push failed: \(err.localizedDescription)") }
            else { NSLog("[pdos-cloud] pushed save for \(contentHash.prefix(8))…") }
        }
    }

    // MARK: - Pull (cloud → local)

    /// Begin observing the container; `resolveFolder` maps a content hash to the local
    /// game folder (nil when that game isn't imported here — the save stays remote).
    func start(resolveFolder: @escaping (String) -> URL?) {
        self.resolveFolder = resolveFolder
        if containerURL != nil { beginQuery() }   // else: started once the container resolves
    }

    /// Begin the ubiquitous-documents query. No-op unless iCloud is available, so a
    /// device/user without iCloud never spins one up.
    private func beginQuery() {
        guard query == nil, containerURL != nil else { return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, Game.saveFileName)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(queryUpdated),
                           name: .NSMetadataQueryDidFinishGathering, object: q)
        center.addObserver(self, selector: #selector(queryUpdated),
                           name: .NSMetadataQueryDidUpdate, object: q)
        query = q
        q.start()
    }

    /// Re-evaluate current results — e.g. right after importing a game whose hash now
    /// resolves locally, to pull a save the container already holds.
    func checkForSave(contentHash: String) {
        guard query != nil else { return }
        queryUpdated()
    }

    @objc private func queryUpdated() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        for i in 0 ..< q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let remoteURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            // .../Documents/Saves/<hash>/changes.jsdos
            let hash = remoteURL.deletingLastPathComponent().lastPathComponent
            guard let folder = resolveFolder?(hash) else { continue }   // game not present here
            pullIfNewer(remoteURL: remoteURL, item: item,
                        to: folder.appendingPathComponent(Game.saveFileName))
        }
    }

    private func pullIfNewer(remoteURL: URL, item: NSMetadataItem, to localURL: URL) {
        // Materialize the remote file first if it isn't downloaded yet; it'll reappear
        // in a later query update once present.
        let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
            try? FileManager.default.startDownloadingUbiquitousItem(at: remoteURL)
            return
        }
        let remoteDate = (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date) ?? .distantPast
        let localDate = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        guard remoteDate > localDate else { return }   // last-writer-wins by mtime
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let coordinator = NSFileCoordinator()
            var err: NSError?
            coordinator.coordinate(readingItemAt: remoteURL, options: [], error: &err) { src in
                try? fm.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: localURL)
                try? fm.copyItem(at: src, to: localURL)
                NSLog("[pdos-cloud] pulled newer save into \(localURL.deletingLastPathComponent().lastPathComponent)")
            }
            if let err { NSLog("[pdos-cloud] pull failed: \(err.localizedDescription)") }
        }
    }
}
