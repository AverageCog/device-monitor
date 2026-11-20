import Foundation

/// Incremental parser for the hub's event stream. Frames are `data: <json>\n\n`; the hub writes a
/// snapshot frame in many pieces and may deliver megabytes before the terminator arrives.
///
/// Works on bytes, so a chunk boundary inside a multi-byte UTF-8 character or between the two
/// newlines needs no special care. Mirrors `HubEvents.read()` in `public/session.js`, including
/// its 48 MiB bound on a frame that never ends.
public struct SSEParser: Sendable {
    public static let defaultLimit = 48 * 1024 * 1024

    private let limit: Int
    private var pending: [UInt8] = []
    /// Bytes at the front of `pending` already known not to start a frame terminator.
    private var scanned = 0

    public init(limit: Int = SSEParser.defaultLimit) {
        self.limit = limit
    }

    /// Bytes received so far that do not yet form a complete frame.
    public var pendingByteCount: Int { pending.count }

    /// Adds received bytes and returns the payload of every frame they complete, in order.
    /// Throws `HubError.responseTooLarge` once more than the limit is buffered.
    public mutating func feed(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        chunk.withUnsafeBytes { pending.append(contentsOf: $0) }
        guard pending.count <= limit else {
            pending = []
            scanned = 0
            throw HubError.responseTooLarge
        }
        var frames: [Data] = []
        var consumed = 0
        pending.withUnsafeBufferPointer { buffer in
            var search = scanned
            while let newline = Self.newline(in: buffer, from: search), newline + 1 < buffer.count {
                guard buffer[newline + 1] == 0x0A else {
                    search = newline + 1
                    continue
                }
                if let payload = Self.payload(UnsafeBufferPointer(rebasing: buffer[consumed..<newline])) { frames.append(payload) }
                consumed = newline + 2
                search = consumed
            }
        }
        if consumed == pending.count {
            // Do not keep a snapshot-sized allocation alive for the life of the stream.
            pending = []
        } else if consumed > 0 {
            pending.removeSubrange(0..<consumed)
        }
        // The final byte may be the first newline of a terminator that the next chunk completes.
        scanned = max(pending.count - 1, 0)
        return frames
    }

    private static func newline(in buffer: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start < buffer.count, let base = buffer.baseAddress,
              let hit = memchr(base + start, 0x0A, buffer.count - start) else { return nil }
        return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
    }

    /// The data of one frame: its `data:` lines joined by a newline, other lines ignored.
    private static func payload(_ frame: UnsafeBufferPointer<UInt8>) -> Data? {
        var lines: [UnsafeBufferPointer<UInt8>] = []
        var start = 0
        while start <= frame.count {
            let end = newline(in: frame, from: start) ?? frame.count
            let line = UnsafeBufferPointer(rebasing: frame[start..<end])
            // "data:" with one optional space before the value.
            if line.count >= 5, line[0] == 0x64, line[1] == 0x61, line[2] == 0x74, line[3] == 0x61, line[4] == 0x3A {
                let value = line.count > 5 && line[5] == 0x20 ? 6 : 5
                lines.append(UnsafeBufferPointer(rebasing: line[value...]))
            }
            start = end + 1
        }
        guard let first = lines.first else { return nil }
        var data = Data(buffer: first)
        for line in lines.dropFirst() {
            data.append(0x0A)
            data.append(line)
        }
        return data
    }
}
