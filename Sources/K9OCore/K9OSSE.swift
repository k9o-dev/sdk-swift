import Foundation

/// One Server-Sent Events frame with its control fields.
struct K9OSSEFrame: Equatable {
    var id: String?
    var event: String?
    /// The assembled `data:` text, or nil for a frame that carries none (a comment, a `retry:` hint).
    var data: String?
    /// The `retry:` hint in milliseconds.
    var retry: Int?
}

/// Incremental SSE parser: feed it chunks of bytes in any split, read whole frames out.
struct K9OSSEParser {
    private var buffer = [UInt8]()

    mutating func feed(_ chunk: Data) -> [K9OSSEFrame] {
        buffer.append(contentsOf: chunk)
        var frames: [K9OSSEFrame] = []
        while let (end, sepLen) = boundary() {
            let raw = Array(buffer[0..<end])
            buffer.removeFirst(end + sepLen)
            while let f = buffer.first, f == 0x0A || f == 0x0D { buffer.removeFirst() }
            if let frame = Self.frame(String(decoding: raw, as: UTF8.self)) { frames.append(frame) }
        }
        return frames
    }

    /// A trailing frame without its blank line is still returned.
    mutating func finish() -> [K9OSSEFrame] {
        let text = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = []
        if text.isEmpty { return [] }
        return Self.frame(text).map { [$0] } ?? []
    }

    private func boundary() -> (Int, Int)? {
        var i = 0
        while i < buffer.count {
            if buffer[i] == 0x0A, i + 1 < buffer.count, buffer[i + 1] == 0x0A { return (i, 2) }
            if buffer[i] == 0x0D, i + 3 < buffer.count, buffer[i + 1] == 0x0A, buffer[i + 2] == 0x0D, buffer[i + 3] == 0x0A {
                return (i, 4)
            }
            i += 1
        }
        return nil
    }

    private static func frame(_ raw: String) -> K9OSSEFrame? {
        var f = K9OSSEFrame()
        var data: [String] = []
        var seen = false
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            if line.isEmpty || line.hasPrefix(":") { continue }
            let field: Substring
            var val: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[line.startIndex..<colon]
                val = line[line.index(after: colon)...]
                if val.hasPrefix(" ") { val = val.dropFirst() }
            } else {
                field = line
                val = ""
            }
            switch field {
            case "data": data.append(String(val))
            case "id": f.id = String(val)
            case "event": f.event = String(val)
            case "retry":
                guard !val.isEmpty, val.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(val) else { continue }
                f.retry = n
            default: continue
            }
            seen = true
        }
        if !seen { return nil }
        if !data.isEmpty { f.data = data.joined(separator: "\n") }
        return f
    }
}
