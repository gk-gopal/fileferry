import Foundation

public struct SyncEntry: Sendable, Equatable {
    public let name: String
    public let size: Int64
    public let mode: UInt32
    public let mtime: Date

    public init(name: String, size: Int64, mode: UInt32, mtime: Date) {
        self.name = name
        self.size = size
        self.mode = mode
        self.mtime = mtime
    }

    /// S_IFMT / S_IFDIR from stat(2).
    public var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
    public var isSymlink: Bool { (mode & 0o170000) == 0o120000 }

    /// Byte layout of `sync_dent_v2` / `sync_stat_v2` after the 4-byte opcode,
    /// per AOSP `file_sync_service.h`:
    ///
    ///     offset  0  error  u32
    ///             4  dev    u64
    ///            12  ino    u64
    ///            20  mode   u32
    ///            24  nlink  u32
    ///            28  uid    u32
    ///            32  gid    u32
    ///            36  size   u64   <- 64-bit, which is the whole point of v2
    ///            44  atime  i64
    ///            52  mtime  i64
    ///            60  ctime  i64
    ///                             = 68 bytes
    ///
    /// For DNT2 a u32 namelen follows, which the caller consumes before
    /// reading the name.
    public static func parseDNT2(header: Data, name: String) -> SyncEntry {
        let bytes = [UInt8](header)
        func u32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            }
        }
        func i64(_ offset: Int) -> Int64 {
            bytes[offset..<offset + 8].withUnsafeBytes {
                Int64(littleEndian: $0.loadUnaligned(as: Int64.self))
            }
        }
        return SyncEntry(
            name: name,
            size: i64(36),
            mode: u32(20),
            mtime: Date(timeIntervalSince1970: TimeInterval(i64(52)))
        )
    }
}
