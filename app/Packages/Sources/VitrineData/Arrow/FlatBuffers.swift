import Foundation

/// A minimal reader for the FlatBuffers binary format (google/flatbuffers docs, "FlatBuffers internals"), enough
/// for Arrow's metadata: tables found through a signed offset to their vtable, fields by vtable slot, unsigned
/// offsets to sub-tables, vectors and strings, inline structs, and unions as a type byte beside a table offset. Every
/// position is checked against the buffer before it is read, so a hostile offset gives an error, never a read
/// outside the bytes. Recursion depth is the caller's to bound. roadmap: S-21
struct FlatTable {
    let bytes: [UInt8]
    let position: Int
    private let vtable: Int
    private let vtableSize: Int

    /// The root table: the first four bytes are its offset.
    static func root(_ bytes: [UInt8]) throws -> FlatTable {
        let offset = try FlatTable.u32(bytes, 0)
        return try FlatTable(bytes: bytes, position: Int(offset))
    }

    init(bytes: [UInt8], position: Int) throws {
        guard position >= 0, position + 4 <= bytes.count else { throw ColumnarError.malformed(String(localized: "a FlatBuffers table lies outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        self.bytes = bytes
        self.position = position
        let soffset = Int(Int32(bitPattern: try FlatTable.u32(bytes, position)))
        let vt = position - soffset
        guard vt >= 0, vt + 4 <= bytes.count else { throw ColumnarError.malformed(String(localized: "a FlatBuffers vtable lies outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let size = Int(try FlatTable.u16(bytes, vt))
        guard size >= 4, size % 2 == 0, vt + size <= bytes.count else { throw ColumnarError.malformed(String(localized: "a FlatBuffers vtable has a bad size", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        vtable = vt
        vtableSize = size
    }

    static func u16(_ b: [UInt8], _ at: Int) throws -> UInt16 {
        guard at >= 0, at + 2 <= b.count else { throw ColumnarError.malformed(String(localized: "a FlatBuffers value lies outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return UInt16(b[at]) | UInt16(b[at + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= b.count else { throw ColumnarError.malformed(String(localized: "a FlatBuffers value lies outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    static func u64(_ b: [UInt8], _ at: Int) throws -> UInt64 {
        guard at >= 0, at + 8 <= b.count else { throw ColumnarError.malformed(String(localized: "a FlatBuffers value lies outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[at + k]) << (8 * UInt64(k)) }
        return v
    }

    /// Where field `slot` is stored, or nil when it is absent (it then has its default).
    func fieldPosition(_ slot: Int) throws -> Int? {
        let entry = 4 + 2 * slot
        guard entry + 2 <= vtableSize else { return nil }
        let offset = Int(try FlatTable.u16(bytes, vtable + entry))
        return offset == 0 ? nil : position + offset
    }

    func int8(_ slot: Int, default d: Int8 = 0) throws -> Int8 {
        guard let p = try fieldPosition(slot) else { return d }
        guard p < bytes.count else { throw ColumnarError.malformed(String(localized: "a FlatBuffers value lies outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return Int8(bitPattern: bytes[p])
    }

    func uint8(_ slot: Int, default d: UInt8 = 0) throws -> UInt8 { UInt8(bitPattern: try int8(slot, default: Int8(bitPattern: d))) }

    func bool(_ slot: Int, default d: Bool = false) throws -> Bool { try int8(slot, default: d ? 1 : 0) != 0 }

    func int16(_ slot: Int, default d: Int16 = 0) throws -> Int16 {
        guard let p = try fieldPosition(slot) else { return d }
        return Int16(bitPattern: try FlatTable.u16(bytes, p))
    }

    func int32(_ slot: Int, default d: Int32 = 0) throws -> Int32 {
        guard let p = try fieldPosition(slot) else { return d }
        return Int32(bitPattern: try FlatTable.u32(bytes, p))
    }

    func int64(_ slot: Int, default d: Int64 = 0) throws -> Int64 {
        guard let p = try fieldPosition(slot) else { return d }
        return Int64(bitPattern: try FlatTable.u64(bytes, p))
    }

    /// The position an offset field points to.
    private func target(_ slot: Int) throws -> Int? {
        guard let p = try fieldPosition(slot) else { return nil }
        let t = p + Int(try FlatTable.u32(bytes, p))
        guard t < bytes.count else { throw ColumnarError.malformed(String(localized: "a FlatBuffers offset points outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return t
    }

    func table(_ slot: Int) throws -> FlatTable? {
        guard let t = try target(slot) else { return nil }
        return try FlatTable(bytes: bytes, position: t)
    }

    func string(_ slot: Int) throws -> String? {
        guard let t = try target(slot) else { return nil }
        let n = Int(try FlatTable.u32(bytes, t))
        guard n <= bytes.count - t - 4 else { throw ColumnarError.malformed(String(localized: "a FlatBuffers string runs past its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return String(decoding: bytes[(t + 4)..<(t + 4 + n)], as: UTF8.self)
    }

    /// A vector's element count and the position of its first element, checked to fit `elementSize` bytes each.
    func vector(_ slot: Int, elementSize: Int) throws -> (count: Int, start: Int)? {
        guard let t = try target(slot) else { return nil }
        let n = Int(try FlatTable.u32(bytes, t))
        guard n <= (bytes.count - t - 4) / max(elementSize, 1) else { throw ColumnarError.malformed(String(localized: "a FlatBuffers vector runs past its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return (n, t + 4)
    }

    /// A vector of tables.
    func tables(_ slot: Int) throws -> [FlatTable] {
        guard let (n, start) = try vector(slot, elementSize: 4) else { return [] }
        return try (0..<n).map { k in
            let at = start + 4 * k
            return try FlatTable(bytes: bytes, position: at + Int(try FlatTable.u32(bytes, at)))
        }
    }
}
