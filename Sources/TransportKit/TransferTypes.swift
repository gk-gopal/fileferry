import Foundation

public enum TransferMode: Sendable, Equatable {
    case copy
    /// Deletes the original — but only after the destination is verified.
    case move
}

/// What to do when the destination already has a file of that name.
///
/// The spec's "ask" is a UI concern: the app prompts, the user picks, and the
/// answer arrives here as one of these. The engine never blocks on a human.
public enum ConflictPolicy: Sendable, Equatable {
    case skip
    case overwrite
    /// Appends " 2", " 3", … before the extension, as Finder does.
    case rename
    case fail
}

public struct TransferJob: Sendable {
    public let sources: [String]
    public let destinationDirectory: String
    public let mode: TransferMode
    public let conflictPolicy: ConflictPolicy

    public init(
        sources: [String],
        destinationDirectory: String,
        mode: TransferMode = .copy,
        conflictPolicy: ConflictPolicy = .fail
    ) {
        self.sources = sources
        self.destinationDirectory = destinationDirectory
        self.mode = mode
        self.conflictPolicy = conflictPolicy
    }
}

/// One file's worth of work, after directories have been expanded.
public struct TransferItem: Sendable, Equatable, Hashable {
    public let source: String
    public let destination: String
    public let size: Int64

    public init(source: String, destination: String, size: Int64) {
        self.source = source
        self.destination = destination
        self.size = size
    }
}

public struct TransferProgress: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let completedFiles: Int
    public let totalFiles: Int
    public let currentFile: String?

    public var fraction: Double {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
    }
}

public struct TransferFailure: Sendable, Equatable {
    public let item: TransferItem
    public let reason: String
}

/// The outcome of a whole job. A per-item failure never aborts the batch, so
/// this reports everything that happened rather than just the first problem.
public struct TransferReport: Sendable, Equatable {
    public var transferred: [TransferItem] = []
    public var skipped: [TransferItem] = []
    public var failed: [TransferFailure] = []

    public var succeeded: Bool { failed.isEmpty }
    public var bytesTransferred: Int64 { transferred.reduce(0) { $0 + $1.size } }
}
