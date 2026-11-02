import Foundation

/// A reader for Apache Thrift's compact protocol (thrift/doc/specs/thrift-compact-protocol.md), which is how
/// Parquet writes its footer and page headers. Streaming and typed: the caller walks a struct field by field and
/// skips what it does not know, so nothing is built that Parquet does not use. Every read is bounds-checked; list
/// sizes are checked against the bytes left (an element is at least one byte), and nesting stops at `maxDepth`.
/// roadmap: S-21
struct ThriftReader {
    enum FieldType: UInt8 {
        case stop = 0, boolTrue = 1, boolFalse = 2, byte = 3, i16 = 4, i32 = 5, i64 = 6, double = 7, binary = 8
        case list = 9, set = 10, map = 11, structure = 12
    }

    let bytes: [UInt8]
    private(set) var position: Int
    let end: Int
    let maxDepth: Int
    private var depth = 0

    init(bytes: [UInt8], start: Int = 0, end: Int? = nil, maxDepth: Int = 48) {
        self.bytes = bytes
        self.position = start
        self.end = min(end ?? bytes.count, bytes.count)
        self.maxDepth = maxDepth
    }

    var remaining: Int { end - position }

    mutating func byte() throws -> UInt8 {
        guard position < end else { throw ColumnarError.truncated(String(localized: "a Thrift structure ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try byte()
            value |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
            guard shift < 64 else { throw ColumnarError.malformed(String(localized: "a Thrift varint is too long", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        }
    }

    mutating func zigzag() throws -> Int64 {
        let v = try varint()
        return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }

    mutating func i32() throws -> Int32 {
        let v = try zigzag()
        guard let n = Int32(exactly: v) else { throw ColumnarError.malformed(String(localized: "a Thrift i32 is out of range", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return n
    }

    mutating func i64() throws -> Int64 { try zigzag() }

    mutating func double() throws -> Double {
        guard remaining >= 8 else { throw ColumnarError.truncated(String(localized: "a Thrift double ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var bits: UInt64 = 0
        for k in 0..<8 { bits |= UInt64(bytes[position + k]) << (8 * UInt64(k)) }
        position += 8
        return Double(bitPattern: bits)
    }

    mutating func binary() throws -> ArraySlice<UInt8> {
        let n = try varint()
        guard n <= UInt64(remaining) else { throw ColumnarError.truncated(String(localized: "a Thrift string runs past its structure", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        defer { position += Int(n) }
        return bytes[position..<(position + Int(n))]
    }

    mutating func string() throws -> String { String(decoding: try binary(), as: UTF8.self) }

    /// A list or set header: element type and count, the count checked against the bytes left.
    mutating func listHeader() throws -> (type: FieldType, count: Int) {
        let header = try byte()
        var count = Int(header >> 4)
        if count == 15 {
            let n = try varint()
            guard n <= UInt64(Int32.max) else { throw ColumnarError.malformed(String(localized: "a Thrift list is too long", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            count = Int(n)
        }
        guard let type = FieldType(rawValue: header & 0x0F) else { throw ColumnarError.malformed(String(localized: "a Thrift list has an unknown element type", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        // Every element takes at least one byte (booleans in a list are one byte each).
        guard count <= remaining else { throw ColumnarError.malformed(String(localized: "a Thrift list claims more elements than bytes", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return (type, count)
    }

    /// Reads a list element's boolean (one byte, 1 for true).
    mutating func listBool() throws -> Bool { try byte() == 1 }

    /// Walks a struct: `field` is called with each field's id and type and must consume it (or call `skip`).
    mutating func readStruct(_ field: (inout ThriftReader, Int16, FieldType) throws -> Void) throws {
        depth += 1
        defer { depth -= 1 }
        guard depth <= maxDepth else { throw ColumnarError.malformed(String(localized: "Thrift structures are nested more than \(maxDepth) deep", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var last: Int16 = 0
        while true {
            let header = try byte()
            if header == 0 { return }
            guard let type = FieldType(rawValue: header & 0x0F) else { throw ColumnarError.malformed(String(localized: "a Thrift field has an unknown type", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let delta = Int16(header >> 4)
            let id: Int16
            if delta == 0 {
                let raw = try zigzag()
                guard let n = Int16(exactly: raw) else { throw ColumnarError.malformed(String(localized: "a Thrift field id is out of range", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                id = n
            } else {
                id = last &+ delta
            }
            last = id
            try field(&self, id, type)
        }
    }

    /// The value of a boolean field: its type carries it.
    static func bool(_ type: FieldType) -> Bool { type == .boolTrue }

    mutating func skip(_ type: FieldType) throws {
        switch type {
        case .stop: return
        case .boolTrue, .boolFalse: return
        case .byte: _ = try byte()
        case .i16, .i32, .i64: _ = try varint()
        case .double: _ = try double()
        case .binary: _ = try binary()
        case .list, .set:
            let (element, count) = try listHeader()
            depth += 1
            defer { depth -= 1 }
            guard depth <= maxDepth else { throw ColumnarError.malformed(String(localized: "Thrift lists are nested more than \(maxDepth) deep", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            for _ in 0..<count {
                if element == .boolTrue || element == .boolFalse { _ = try byte() } else { try skip(element) }
            }
        case .map:
            let n = try varint()
            guard n <= UInt64(remaining) else { throw ColumnarError.malformed(String(localized: "a Thrift map claims more entries than bytes", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            if n == 0 { return }
            let kinds = try byte()
            guard let key = FieldType(rawValue: kinds >> 4), let value = FieldType(rawValue: kinds & 0x0F) else {
                throw ColumnarError.malformed(String(localized: "a Thrift map has an unknown type", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
            depth += 1
            defer { depth -= 1 }
            guard depth <= maxDepth else { throw ColumnarError.malformed(String(localized: "Thrift maps are nested more than \(maxDepth) deep", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            for _ in 0..<n {
                if key == .boolTrue || key == .boolFalse { _ = try byte() } else { try skip(key) }
                if value == .boolTrue || value == .boolFalse { _ = try byte() } else { try skip(value) }
            }
        case .structure:
            try readStruct { r, _, t in try r.skip(t) }
        }
    }

    /// Skips one list element (a boolean element is a byte, unlike a boolean field).
    mutating func skipElement(_ type: FieldType) throws {
        if type == .boolTrue || type == .boolFalse { _ = try byte() } else { try skip(type) }
    }

    /// A list of structs, each read by `element`.
    mutating func readList<T>(_ element: (inout ThriftReader) throws -> T) throws -> [T] {
        let (type, count) = try listHeader()
        var out: [T] = []
        out.reserveCapacity(min(count, 4_096))
        for _ in 0..<count {
            if type == .structure { out.append(try element(&self)) } else { try skipElement(type) }
        }
        return out
    }

    /// A list of i32 values (enums).
    mutating func readI32List() throws -> [Int32] {
        let (type, count) = try listHeader()
        var out: [Int32] = []
        for _ in 0..<count {
            if type == .i32 || type == .i16 || type == .i64 { out.append(Int32(truncatingIfNeeded: try zigzag())) } else { try skipElement(type) }
        }
        return out
    }

    mutating func readStringList() throws -> [String] {
        let (type, count) = try listHeader()
        var out: [String] = []
        for _ in 0..<count {
            if type == .binary { out.append(try string()) } else { try skipElement(type) }
        }
        return out
    }
}
