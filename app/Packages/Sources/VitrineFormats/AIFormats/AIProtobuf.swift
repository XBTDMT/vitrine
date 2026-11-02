import Foundation

/// One protobuf field: its number and wire type, the value for varints and fixed widths, and for length-delimited
/// fields where the payload lies (read only when asked).
struct AIProtoField {
    let number: Int
    let wireType: Int
    /// Varint, fixed32 or fixed64 value.
    let value: UInt64
    /// Length-delimited payload.
    let payload: Range<Int64>

    var int64: Int64 { Int64(bitPattern: value) }
}

/// A protobuf wire-format reader over an `AIByteReader`. Payloads are skipped by offset, so a model's weights cost
/// nothing; strings and sub-messages are read only when the caller asks. Groups (wire types 3 and 4) are refused.
struct AIProtobuf {
    let reader: AIByteReader
    static let maxFieldsPerMessage = 5_000_000

    /// Calls `body` with each field of the message in `range`, in order; `body` returns false to stop.
    func fields(in range: Range<Int64>, _ body: (AIProtoField) throws -> Bool) throws {
        var cursor = AICursor(reader, at: range.lowerBound)
        var seen = 0
        while cursor.offset < range.upperBound {
            seen += 1
            guard seen <= Self.maxFieldsPerMessage else { throw AIReadError.malformed("a message has too many fields") }
            let key = try varint(&cursor, end: range.upperBound)
            let wire = Int(key & 7)
            let number = Int(key >> 3)
            guard number > 0 else { throw AIReadError.malformed("field number 0 at byte \(cursor.offset)") }
            let field: AIProtoField
            switch wire {
            case 0:
                field = AIProtoField(number: number, wireType: 0, value: try varint(&cursor, end: range.upperBound), payload: 0..<0)
            case 1:
                guard range.upperBound - cursor.offset >= 8 else { throw AIReadError.truncated("inside a fixed64 field") }
                field = AIProtoField(number: number, wireType: 1, value: try cursor.u64("a fixed64 field"), payload: 0..<0)
            case 5:
                guard range.upperBound - cursor.offset >= 4 else { throw AIReadError.truncated("inside a fixed32 field") }
                field = AIProtoField(number: number, wireType: 5, value: UInt64(try cursor.u32("a fixed32 field")), payload: 0..<0)
            case 2:
                let length = try varint(&cursor, end: range.upperBound)
                guard length <= UInt64(range.upperBound - cursor.offset) else {
                    throw AIReadError.truncated("field \(number) declares \(length) bytes past the end of its message")
                }
                let start = cursor.offset
                cursor.offset += Int64(length)
                field = AIProtoField(number: number, wireType: 2, value: length, payload: start..<cursor.offset)
            default:
                throw AIReadError.malformed("wire type \(wire) at byte \(cursor.offset)")
            }
            if try !body(field) { return }
        }
    }

    func varint(_ cursor: inout AICursor, end: Int64) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard cursor.offset < end else { throw AIReadError.truncated("inside a varint") }
            let byte = try cursor.u8("a varint")
            if shift < 64 { value |= UInt64(byte & 0x7F) << shift }
            if byte & 0x80 == 0 { return value }
            shift += 7
            guard shift < 70 else { throw AIReadError.malformed("a varint longer than 10 bytes") }
        }
    }

    /// A length-delimited field's payload as UTF-8, clipped to `limit` bytes.
    func string(_ field: AIProtoField, limit: Int = 4096) throws -> String {
        let count = Int(min(Int64(limit), field.payload.count > 0 ? Int64(field.payload.count) : 0))
        let bytes = try reader.bytes(at: field.payload.lowerBound, count: count, "a string field")
        return AIFormat.text(bytes) + (field.payload.count > limit ? "…" : "")
    }

    /// Packed (or single) varints of a repeated numeric field.
    func varints(_ field: AIProtoField) throws -> [UInt64] {
        if field.wireType == 0 { return [field.value] }
        guard field.wireType == 2 else { return [] }
        var out: [UInt64] = []
        var cursor = AICursor(reader, at: field.payload.lowerBound)
        while cursor.offset < field.payload.upperBound, out.count < 64 {
            out.append(try varint(&cursor, end: field.payload.upperBound))
        }
        return out
    }
}
