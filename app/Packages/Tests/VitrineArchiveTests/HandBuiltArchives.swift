import Foundation
@testable import VitrineArchive

/// Archives no tool on this Mac writes, built byte by byte from the public format descriptions with invented names
/// and contents: RAR 4 and RAR 5 (stored members only; RAR's compressor is not public and is never needed to test a
/// listing), Microsoft Cabinet (uncompressed folder), LHA (`-lh0-`, stored) and RPM (lead, empty headers, a cpio
/// payload made by /usr/bin/tar). Each builder writes only what the format requires. roadmap: S-8
enum HandBuilt {
    struct Member {
        var name: String
        var data: [UInt8]
        var isDirectory = false
        init(_ name: String, _ text: String) { self.name = name; self.data = Array(text.utf8) }
        init(directory name: String) { self.name = name; self.data = []; isDirectory = true }
    }

    // MARK: RAR 4 (RAR 2.9 archive format: marker, main header, file headers, end of archive)

    /// `solid` sets MHD_SOLID; `encryptedHeaders` sets MHD_PASSWORD (the names would be encrypted); `encryptFiles`
    /// sets each file's FHD_PASSWORD flag (its data would be encrypted; here it is stored as is).
    static func rar4(_ members: [Member], solid: Bool = false, encryptedHeaders: Bool = false,
                     encryptFiles: Bool = false) -> [UInt8] {
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        var mainFlags: UInt16 = 0
        if solid { mainFlags |= 0x0008 }
        if encryptedHeaders { mainFlags |= 0x0080 }
        var main: [UInt8] = [0x73]
        main.le16(mainFlags); main.le16(13); main.le16(0); main.le32(0)
        out += rar4Header(main)
        for m in members {
            let name = Array(m.name.utf8)
            var flags: UInt16 = 0x8000                                  // LONG_BLOCK: data follows
            if m.isDirectory { flags |= 0x00E0 }
            if encryptFiles && !m.isDirectory { flags |= 0x0004 }
            var h: [UInt8] = [0x74]
            h.le16(flags); h.le16(UInt16(32 + name.count))
            h.le32(UInt32(m.data.count)); h.le32(UInt32(m.data.count))
            h.append(3)                                                 // host OS: Unix
            h.le32(CRC32.checksum(m.data))
            h.le32(dosTime)
            h.append(20)                                                // needs version 2.0
            h.append(0x30)                                              // method: store
            h.le16(UInt16(name.count))
            h.le32(m.isDirectory ? 0o040755 : 0o100644)
            h += name
            out += rar4Header(h) + m.data
        }
        var end: [UInt8] = [0x7B]
        end.le16(0x4000); end.le16(7)
        out += rar4Header(end)
        return out
    }

    /// Prefixes the low 16 bits of the CRC32 of everything from HEAD_TYPE on.
    private static func rar4Header(_ body: [UInt8]) -> [UInt8] {
        var h: [UInt8] = []
        h.le16(UInt16(truncatingIfNeeded: CRC32.checksum(body)))
        return h + body
    }

    // MARK: RAR 5

    static func rar5(_ members: [Member], solid: Bool = false) -> [UInt8] {
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        out += rar5Header(vint(1) + vint(0) + vint(solid ? 0x0004 : 0))                 // main archive header
        for m in members {
            let name = Array(m.name.utf8)
            var fields: [UInt8] = []
            fields += vint(2)                                               // file header
            fields += vint(0x0002)                                          // header flags: data area present
            fields += vint(UInt64(m.data.count))                            // data size
            fields += vint(m.isDirectory ? 0x0001 : 0x0004)                 // file flags: directory / CRC32 present
            fields += vint(UInt64(m.data.count))                            // unpacked size
            fields += vint(m.isDirectory ? 0o040755 : 0o100644)             // attributes (Unix mode)
            if !m.isDirectory { fields.le32(CRC32.checksum(m.data)) }
            fields += vint(0)                                               // compression: version 0, store
            fields += vint(1)                                               // host OS: Unix
            fields += vint(UInt64(name.count))
            fields += name
            out += rar5Header(fields) + m.data
        }
        out += rar5Header(vint(5) + vint(0) + vint(0))                       // end of archive
        return out
    }

    private static func rar5Header(_ fields: [UInt8]) -> [UInt8] {
        let sized = vint(UInt64(fields.count)) + fields
        var h: [UInt8] = []
        h.le32(CRC32.checksum(sized))
        return h + sized
    }

    static func vint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    // MARK: Microsoft Cabinet, one uncompressed folder

    static func cab(_ members: [Member]) -> [UInt8] {
        let files = members.filter { !$0.isDirectory }
        let payload = files.flatMap(\.data)
        let headerSize = 36, folderSize = 8
        let fileRecords = files.map { 16 + $0.name.utf8.count + 1 }.reduce(0, +)
        let dataStart = headerSize + folderSize + fileRecords
        let total = dataStart + 8 + payload.count
        var out: [UInt8] = Array("MSCF".utf8)
        out.le32(0); out.le32(UInt32(total)); out.le32(0)
        out.le32(UInt32(headerSize + folderSize))                            // first CFFILE
        out.le32(0)
        out.append(3); out.append(1)                                         // version 1.3
        out.le16(1); out.le16(UInt16(files.count)); out.le16(0); out.le16(0x1234); out.le16(0)
        out.le32(UInt32(dataStart)); out.le16(1); out.le16(0)                // CFFOLDER: one block, no compression
        var offset: UInt32 = 0
        for f in files {
            out.le32(UInt32(f.data.count)); out.le32(offset); out.le16(0)
            out.le16(dosDate); out.le16(dosTimeOfDay); out.le16(0x20)
            out += Array(f.name.utf8) + [0]
            offset += UInt32(f.data.count)
        }
        out.le32(0)                                                          // no checksum
        out.le16(UInt16(payload.count)); out.le16(UInt16(payload.count))
        return out + payload
    }

    // MARK: LHA level 0, stored

    static func lha(_ members: [Member]) -> [UInt8] {
        var out: [UInt8] = []
        for m in members where !m.isDirectory {
            let name = Array(m.name.utf8)
            var body: [UInt8] = Array("-lh0-".utf8)
            body.le32(UInt32(m.data.count)); body.le32(UInt32(m.data.count))
            body.le32(dosTime)
            body.append(0x20); body.append(0)                               // attribute, header level 0
            body.append(UInt8(name.count)); body += name
            body.le16(crc16(m.data))
            let sum = body.reduce(UInt8(0)) { $0 &+ $1 }
            out += [UInt8(body.count), sum] + body + m.data
        }
        return out + [0]
    }

    /// CRC-16/ARC (reflected 0x8005), what LHA stores for each member.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    // MARK: RPM

    /// The 96-byte lead, an empty signature header, an empty main header, then `payload` (a compressed cpio).
    static func rpm(payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0xED, 0xAB, 0xEE, 0xDB, 3, 0]
        out += [0, 0, 0, 1]                                                  // binary package, arch 1
        out += Array("invented-package-1.0".utf8) + [UInt8](repeating: 0, count: 66 - 20)
        out += [0, 1, 0, 5] + [UInt8](repeating: 0, count: 16)              // os 1, signature type 5
        let emptyHeader: [UInt8] = [0x8E, 0xAD, 0xE8, 0x01, 0, 0, 0, 0] + [0, 0, 0, 0] + [0, 0, 0, 0]
        out += emptyHeader                                                   // 16 bytes: already 8-aligned
        out += emptyHeader
        return out + payload
    }

    // 2026-10-05 12:34:56 in MS-DOS form.
    static let dosDate: UInt16 = UInt16((2026 - 1980) << 9 | 10 << 5 | 5)
    static let dosTimeOfDay: UInt16 = UInt16(12 << 11 | 34 << 5 | 28)
    static var dosTime: UInt32 { UInt32(dosDate) << 16 | UInt32(dosTimeOfDay) }
}
