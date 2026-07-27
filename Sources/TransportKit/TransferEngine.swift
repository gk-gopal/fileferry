import Foundation

/// Orchestrates one job: expand, preflight, transfer, verify, delete.
///
/// Independent of any particular transport, so it is fully testable against
/// in-memory fakes with no phone and no adb.
public actor TransferEngine {
    public static let defaultConcurrency = 2

    private let concurrency: Int

    public init(concurrency: Int = TransferEngine.defaultConcurrency) {
        self.concurrency = max(1, concurrency)
    }

    public func run(
        _ job: TransferJob,
        from source: any DeviceTransport,
        to destination: any DeviceTransport,
        onProgress: @Sendable @escaping (TransferProgress) -> Void = { _ in }
    ) async throws -> TransferReport {
        let items = try await expand(job, source: source)
        let totalBytes = items.reduce(0) { $0 + $1.size }

        try await preflight(bytes: totalBytes, into: job.destinationDirectory, on: destination)

        let resolved = try await resolveConflicts(items, policy: job.conflictPolicy, on: destination)
        try await createDirectories(for: resolved.items, on: destination)

        var report = TransferReport()
        report.skipped = resolved.skipped

        let tracker = ProgressTracker(
            totalBytes: totalBytes,
            totalFiles: resolved.items.count,
            report: onProgress
        )

        // A bounded pool, not a task per file: USB is the bottleneck, and more
        // streams than this costs throughput while muddling progress.
        let outcomes = await withTaskGroup(
            of: (TransferItem, Result<Void, Error>).self,
            returning: [(TransferItem, Result<Void, Error>)].self
        ) { group in
            var iterator = resolved.items.makeIterator()
            var running = 0
            var collected: [(TransferItem, Result<Void, Error>)] = []

            func submit(_ item: TransferItem) {
                group.addTask {
                    do {
                        try await self.transferOne(
                            item, mode: job.mode,
                            from: source, to: destination, tracker: tracker
                        )
                        return (item, .success(()))
                    } catch {
                        return (item, .failure(error))
                    }
                }
            }

            while running < self.concurrency, let next = iterator.next() {
                submit(next)
                running += 1
            }
            while let finished = await group.next() {
                collected.append(finished)
                if let next = iterator.next() { submit(next) }
            }
            return collected
        }

        // Restore the caller's order — task groups complete out of order.
        let order = Dictionary(uniqueKeysWithValues: resolved.items.enumerated().map { ($1, $0) })
        for (item, result) in outcomes.sorted(by: { (order[$0.0] ?? 0) < (order[$1.0] ?? 0) }) {
            switch result {
            case .success:
                report.transferred.append(item)
            case .failure(let error):
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                report.failed.append(TransferFailure(item: item, reason: reason))
            }
        }
        return report
    }

    // MARK: - Stages

    /// Walks directories depth-first into concrete files.
    func expand(_ job: TransferJob, source: any DeviceTransport) async throws -> [TransferItem] {
        var items: [TransferItem] = []
        for path in job.sources {
            let entry = try await source.stat(path)
            let target = join(job.destinationDirectory, entry.name)
            if entry.isDirectory {
                try await walk(entry.path, to: target, source: source, into: &items)
            } else {
                items.append(TransferItem(source: entry.path, destination: target, size: entry.size))
            }
        }
        return items
    }

    private func walk(
        _ directory: String,
        to destination: String,
        source: any DeviceTransport,
        into items: inout [TransferItem]
    ) async throws {
        for entry in try await source.list(directory) {
            let target = join(destination, entry.name)
            if entry.isDirectory {
                try await walk(entry.path, to: target, source: source, into: &items)
            } else {
                items.append(TransferItem(source: entry.path, destination: target, size: entry.size))
            }
        }
    }

    /// Fails before moving a byte rather than 900 MB in.
    func preflight(bytes: Int64, into directory: String, on destination: any DeviceTransport) async throws {
        guard bytes > 0 else { return }
        let available = try await destination.freeSpace(at: directory)
        guard available >= bytes else {
            throw TransportError.insufficientSpace(needed: bytes, available: available)
        }
    }

    func resolveConflicts(
        _ items: [TransferItem],
        policy: ConflictPolicy,
        on destination: any DeviceTransport
    ) async throws -> (items: [TransferItem], skipped: [TransferItem]) {
        var keep: [TransferItem] = []
        var skipped: [TransferItem] = []
        for item in items {
            guard await destination.exists(item.destination) else {
                keep.append(item)
                continue
            }
            switch policy {
            case .skip:
                skipped.append(item)
            case .overwrite:
                keep.append(item)
            case .fail:
                throw TransportError.io("\(item.destination) already exists.")
            case .rename:
                var candidate = item.destination
                var suffix = 2
                while await destination.exists(candidate) {
                    candidate = disambiguate(item.destination, suffix)
                    suffix += 1
                }
                keep.append(TransferItem(source: item.source, destination: candidate, size: item.size))
            }
        }
        return (keep, skipped)
    }

    private func createDirectories(for items: [TransferItem], on destination: any DeviceTransport) async throws {
        var made = Set<String>()
        for item in items {
            let parent = (item.destination as NSString).deletingLastPathComponent
            guard !parent.isEmpty, made.insert(parent).inserted else { continue }
            try await destination.mkdir(parent)
        }
    }

    private func transferOne(
        _ item: TransferItem,
        mode: TransferMode,
        from source: any DeviceTransport,
        to destination: any DeviceTransport,
        tracker: ProgressTracker
    ) async throws {
        try Task.checkCancellation()
        await tracker.begin(item.source)

        let counted = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for try await chunk in source.read(item.source) {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                        await tracker.advance(by: Int64(chunk.count))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        try await destination.write(item.destination, from: counted)

        if mode == .move {
            // Verify before deleting. A move that deletes on faith turns a
            // truncated write into permanent data loss.
            let landed = try await destination.stat(item.destination)
            guard landed.size == item.size else {
                throw TransportError.verificationFailed(
                    path: item.destination, expected: item.size, found: landed.size)
            }
            try await source.delete(item.source)
        }
        await tracker.finish()
    }

    // MARK: - Paths

    func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// "photo.jpg" → "photo 2.jpg", matching Finder.
    func disambiguate(_ path: String, _ suffix: Int) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
    }
}

/// Coalesces byte counts to ~10 Hz. Publishing every 64 KB chunk would pin the
/// main thread during a fast transfer.
actor ProgressTracker {
    private let totalBytes: Int64
    private let totalFiles: Int
    private let report: @Sendable (TransferProgress) -> Void

    private var completedBytes: Int64 = 0
    private var completedFiles = 0
    private var current: String?
    private var lastEmit = Date.distantPast

    init(totalBytes: Int64, totalFiles: Int, report: @escaping @Sendable (TransferProgress) -> Void) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.report = report
    }

    func begin(_ path: String) {
        current = path
        emit(force: true)
    }

    func advance(by bytes: Int64) {
        completedBytes += bytes
        emit(force: false)
    }

    func finish() {
        completedFiles += 1
        emit(force: true)
    }

    private func emit(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return }
        lastEmit = now
        report(TransferProgress(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            currentFile: current
        ))
    }
}
