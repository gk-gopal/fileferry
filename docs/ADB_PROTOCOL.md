# The ADB wire protocol, as Conduit uses it

Conduit does not shell out to `adb`. It lets the `adb` binary run as the
*server* — which owns the USB connection, the part genuinely not worth
reimplementing — and then speaks the server's own protocol on
`127.0.0.1:5037`. This is what Android Studio does.

The protocol is not formally specified. The authority is AOSP's
[`SERVICES.TXT`](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/SERVICES.TXT)
and [`file_sync_service.h`](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/file_sync_service.h).
It stays stable in practice because Android Studio depends on it.

## Two framing layers, and they are different

This is the single most common source of bugs. Getting a length field wrong
desynchronises the stream, which presents as a **hang**, not a clean error.

| | Host protocol | Sync protocol |
|---|---|---|
| Request length | 4 ASCII hex digits, e.g. `000c` | binary `UInt32`, little-endian |
| Reply status | `OKAY` / `FAIL` | `OKAY` / `FAIL` / opcode |
| Used by | `host:*`, `shell,v2:` setup | everything after `sync:` |
| Implemented in | `HostProtocol.swift` | `SyncPacket.swift` |

A host request is the 4 hex digits followed by the ASCII service name:

```
000chost:version
0016host:transport:1A2B3C
```

## Services Conduit uses

| Service | Purpose |
|---|---|
| `host:version` | Health check — is a server actually listening on 5037? |
| `host:track-devices` | **Persistent** stream of device lists. A new hex-length-prefixed frame arrives on every connect or disconnect, so nothing polls |
| `host:transport:<serial>` | Switches this connection to talk to one device |
| `sync:` | Enters sync mode (send after a transport switch) |
| `shell,v2:<cmd>` | Runs a command with stdout and stderr separated and a real exit code |

## Sync opcodes

Always the **v2** opcodes. The v1 forms (`LIST`, `STAT`, `DENT`) encode file
size as a `UInt32` and silently misreport anything ≥ 4 GB — a 5 GB video shows
up as roughly 705 MB, since `5_000_000_000 mod 2^32 = 705_032_704`.

| Opcode | Meaning |
|---|---|
| `LIS2` | List a directory → a stream of `DNT2` frames, ending in `DONE` |
| `DNT2` | One directory entry |
| `STA2` | Stat one path → a single `STA2` reply |
| `RECV` | Pull → a stream of `DATA` frames, ending in `DONE` |
| `SEND` | Push → we write `DATA` frames, then `DONE`, then read a status |
| `QUIT` | End the session politely |

### `sync_dent_v2` / `sync_stat_v2` byte layout

After the 4-byte opcode, confirmed against `file_sync_service.h`:

```
offset  0   error   u32
        4   dev     u64
       12   ino     u64
       20   mode    u32     <- S_IFMT tells you directory vs file vs symlink
       24   nlink   u32
       28   uid     u32
       32   gid     u32
       36   size    u64     <- 64-bit; the entire reason for v2
       44   atime   i64
       52   mtime   i64
       60   ctime   i64
                    = 68 bytes
```

`DNT2` then carries a `u32` namelen and that many bytes of name. `STA2` stops
at 68.

### `DONE` is not always the same size

The trap that costs an afternoon. `DONE` is written as whichever struct the
current conversation uses, with its id swapped:

- **After a listing** — `sizeof(sync_dent_v2)` = 76 bytes, so 72 remain after
  the opcode.
- **After a `RECV`** — `sizeof(sync_data)` = 8 bytes, so 4 remain after the
  opcode.

Reading 4 where 72 was written leaves 68 bytes of garbage in the stream, and
the next request appears to hang.

### `SEND` puts the mode in the path

The `SEND` request path is not a path — it is `"<path>,<octal mode>"` as a
single string:

```
/sdcard/Download/photo.jpg,644
```

### Chunk size

`DATA` payloads are capped at **65536 bytes**. Larger is a protocol violation.
Conduit both enforces this when sending and rejects oversized frames when
receiving.

## `shell,v2:` framing

Different again: each frame is a **1-byte id**, a 4-byte little-endian length,
then the payload.

| id | Stream |
|---|---|
| 1 | stdout |
| 2 | stderr |
| 3 | exit code (a single byte of payload) |

## Measured performance

Directory listing time and transfer throughput against real hardware are
recorded here once Task 12 of the foundation plan runs. The numbers matter:
they are the evidence for choosing ADB over MTP, and belong in the README
rather than in an argument.

## Toolchain note

`swift test` fails with `no such module 'Testing'` when Command Line Tools is
the selected developer directory — that toolchain does not ship Swift Testing.

    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
