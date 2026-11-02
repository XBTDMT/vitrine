import Foundation

/// Reads Mach-O headers and load commands from a byte source. Every count and offset in the file is checked against
/// the slice it belongs to and capped by `BinaryLimits` before anything is allocated for it.
public enum MachOReader {
    static let magic32: UInt32 = 0xFEED_FACE
    static let magic64: UInt32 = 0xFEED_FACF
    static let cigam32: UInt32 = 0xCEFA_EDFE
    static let cigam64: UInt32 = 0xCFFA_EDFE
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF

    /// True when `prefix` (the first bytes of a file) starts like a thin or universal Mach-O. A universal header must
    /// also declare a plausible architecture count, which tells it apart from a Java class file.
    public static func looksLikeMachO(_ prefix: [UInt8], limits: BinaryLimits = .default) -> Bool {
        guard let be = prefix.be32(at: 0) else { return false }
        if [magic32, magic64, cigam32, cigam64].contains(be) { return true }
        if be == fatMagic || be == fatMagic64, let count = prefix.be32(at: 4) {
            return count > 0 && count <= UInt32(limits.maxFatSlices)
        }
        return false
    }

    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> MachOFile {
        try read(source: BinaryFileSource(url: url), limits: limits)
    }

    public static func read(source: any BinaryByteSource, limits: BinaryLimits = .default) throws -> MachOFile {
        let head = try source.read(at: 0, count: 8)
        guard let magic = head.be32(at: 0) else { throw BinaryError.notRecognized("a Mach-O binary (too short)") }
        if magic == fatMagic || magic == fatMagic64 {
            return try readUniversal(source: source, is64: magic == fatMagic64, limits: limits)
        }
        guard [magic32, magic64, cigam32, cigam64].contains(magic) else {
            throw BinaryError.notRecognized("a Mach-O binary")
        }
        let slice = try readSlice(source: source, fileOffset: 0, limits: limits)
        return MachOFile(isUniversal: false, usesFat64: false, slices: [slice], unreadableSlices: [], notes: [])
    }

    // MARK: - Universal

    static func readUniversal(source: any BinaryByteSource, is64: Bool, limits: BinaryLimits) throws -> MachOFile {
        let header = try source.exactly(8, at: 0, "the universal header")
        guard let declared = header.be32(at: 4) else { throw BinaryError.truncated("the universal header ends early") }
        guard declared > 0 else { throw BinaryError.malformed("the universal header lists no architectures") }
        guard declared <= UInt32(limits.maxFatSlices) else {
            throw BinaryError.notRecognized("a Mach-O binary (\(declared) architectures declared: a Java class file or damage)")
        }
        let entrySize = is64 ? 32 : 20
        let table = try source.exactly(Int(declared) * entrySize, at: 8, "the universal architecture table")
        var cursor = ByteCursor(table, bigEndian: true, what: "the universal architecture table")
        var slices: [MachOSlice] = []
        var unreadable: [MachOFile.UnreadableSlice] = []
        var notes: [String] = []
        var ranges: [(Int64, Int64)] = []
        let tableEnd = Int64(8 + table.count)
        for _ in 0..<declared {
            let cpu = CPUType(type: Int32(bitPattern: try cursor.u32()), subtype: Int32(bitPattern: try cursor.u32()))
            let offset: UInt64, size: UInt64
            if is64 {
                offset = try cursor.u64(); size = try cursor.u64()
                _ = try cursor.u32(); _ = try cursor.u32()        // align, reserved
            } else {
                offset = UInt64(try cursor.u32()); size = UInt64(try cursor.u32())
                _ = try cursor.u32()                              // align
            }
            guard offset <= UInt64(source.size), size <= UInt64(source.size) - offset else {
                unreadable.append(.init(cpu: cpu, offset: Int64(clamping: offset), size: Int64(clamping: size),
                                        reason: "the slice lies outside the file"))
                continue
            }
            let start = Int64(offset), length = Int64(size)
            guard start >= tableEnd else {
                unreadable.append(.init(cpu: cpu, offset: start, size: length,
                                        reason: "the slice overlaps the universal header"))
                continue
            }
            if ranges.contains(where: { start < $0.0 + $0.1 && $0.0 < start + length }) {
                notes.append("the \(cpu.name) slice overlaps another slice")
            }
            ranges.append((start, length))
            do {
                let sliceSource = BinarySliceSource(source, start: start, length: length)
                let slice = try readSlice(source: sliceSource, fileOffset: start, limits: limits)
                if slice.cpu != cpu {
                    notes.append("the universal header says \(cpu.name) but the slice says \(slice.cpu.name)")
                }
                slices.append(slice)
            } catch let error as BinaryError {
                unreadable.append(.init(cpu: cpu, offset: start, size: length, reason: error.reason))
            }
        }
        if slices.isEmpty, let first = unreadable.first {
            throw BinaryError.malformed("no architecture could be read (\(first.cpu.name): \(first.reason))")
        }
        return MachOFile(isUniversal: true, usesFat64: is64, slices: slices, unreadableSlices: unreadable, notes: notes)
    }

    // MARK: - One slice

    /// Load command numbers this reader understands (`LC_*`).
    enum Command {
        static let segment: UInt32 = 0x1
        static let loadDylib: UInt32 = 0xC
        static let idDylib: UInt32 = 0xD
        static let segment64: UInt32 = 0x19
        static let uuid: UInt32 = 0x1B
        static let codeSignature: UInt32 = 0x1D
        static let lazyLoadDylib: UInt32 = 0x20
        static let encryptionInfo: UInt32 = 0x21
        static let versionMinMacOS: UInt32 = 0x24
        static let versionMinIPhoneOS: UInt32 = 0x25
        static let sourceVersion: UInt32 = 0x2A
        static let encryptionInfo64: UInt32 = 0x2C
        static let versionMinTVOS: UInt32 = 0x2F
        static let versionMinWatchOS: UInt32 = 0x30
        static let buildVersion: UInt32 = 0x32
        static let loadWeakDylib: UInt32 = 0x8000_0018
        static let rpath: UInt32 = 0x8000_001C
        static let reexportDylib: UInt32 = 0x8000_001F
        static let loadUpwardDylib: UInt32 = 0x8000_0023
        static let main: UInt32 = 0x8000_0028
    }

    /// Accumulates one slice's facts while its load commands are walked.
    private struct SliceBuilder {
        var platforms: [BuildVersion] = []
        var uuid: UUID?
        var installName: LinkedDylib?
        var dylibs: [LinkedDylib] = []
        var rpaths: [String] = []
        var encryption: EncryptionInfo?
        var signatureRange: FileRange?
        var segments: [Segment] = []
        var entryOffset: UInt64?
        var sourceVersion: String?
        var notes: [String] = []
    }

    static func readSlice(source: any BinaryByteSource, fileOffset: Int64, limits: BinaryLimits) throws -> MachOSlice {
        let probe = try source.exactly(4, at: 0, "the Mach-O header")
        guard let magic = probe.be32(at: 0) else { throw BinaryError.truncated("the Mach-O header ends early") }
        let is64: Bool, bigEndian: Bool
        switch magic {
        case magic64: is64 = true; bigEndian = true
        case magic32: is64 = false; bigEndian = true
        case cigam64: is64 = true; bigEndian = false
        case cigam32: is64 = false; bigEndian = false
        default: throw BinaryError.notRecognized("a Mach-O slice (bad magic)")
        }
        let headerSize = is64 ? 32 : 28
        var header = ByteCursor(try source.exactly(headerSize, at: 0, "the Mach-O header"), at: 4,
                                bigEndian: bigEndian, what: "the Mach-O header")
        let cpu = CPUType(type: Int32(bitPattern: try header.u32()), subtype: Int32(bitPattern: try header.u32()))
        let fileType = MachOFileType(rawValue: try header.u32())
        let declared = Int(try header.u32())
        let sizeOfCommands = Int(try header.u32())
        let flags = MachOHeaderFlags(rawValue: try header.u32())

        var b = SliceBuilder()
        let available = Int(min(Int64(Int.max), max(0, source.size - Int64(headerSize))))
        var commandBytes = sizeOfCommands
        if commandBytes > available {
            b.notes.append("the load commands claim \(sizeOfCommands) bytes but only \(available) follow the header")
            commandBytes = available
        }
        if commandBytes > limits.maxLoadCommandBytes {
            b.notes.append("load commands are read up to \(limits.maxLoadCommandBytes) of \(sizeOfCommands) bytes")
            commandBytes = limits.maxLoadCommandBytes
        }
        let area = try source.exactly(commandBytes, at: Int64(headerSize), "the load commands")

        var position = 0
        var read = 0
        let wanted = min(declared, limits.maxLoadCommands)
        if declared > limits.maxLoadCommands {
            b.notes.append("\(declared) load commands declared; the first \(limits.maxLoadCommands) are read")
        }
        while read < wanted {
            guard position + 8 <= area.count,
                  let cmd = bigEndian ? area.be32(at: position) : area.le32(at: position),
                  let size32 = bigEndian ? area.be32(at: position + 4) : area.le32(at: position + 4) else {
                b.notes.append("load command \(read + 1) of \(declared) lies past the load command area")
                break
            }
            let size = Int(size32)
            guard size >= 8, size <= area.count - position else {
                b.notes.append("load command \(read + 1) has an impossible size (\(size) bytes)")
                break
            }
            let command = Array(area[position..<(position + size)])
            do {
                try parseCommand(cmd, command, bigEndian: bigEndian, sliceSize: source.size, into: &b)
            } catch let error as BinaryError {
                b.notes.append("load command \(read + 1) (0x\(String(cmd, radix: 16))) is damaged: \(error.reason)")
            }
            position += size
            read += 1
        }

        var signature: EmbeddedSignature?
        var signatureProblem: String?
        if let range = b.signatureRange {
            if range.offset + range.length > source.size {
                signatureProblem = "the code signature lies outside the file"
            } else if range.length > Int64(limits.maxSignatureBytes) {
                signatureProblem = "the code signature (\(range.length) bytes) is larger than the \(limits.maxSignatureBytes)-byte cap"
            } else {
                do {
                    let bytes = try source.exactly(Int(range.length), at: range.offset, "the code signature")
                    signature = try EmbeddedSignature.parse(bytes, limits: limits)
                } catch let error as BinaryError {
                    signatureProblem = error.reason
                }
            }
        }

        return MachOSlice(fileOffset: fileOffset, fileSize: source.size, cpu: cpu, is64Bit: is64,
                          isBigEndian: bigEndian, fileType: fileType, flags: flags, platforms: b.platforms,
                          uuid: b.uuid, installName: b.installName, linkedDylibs: b.dylibs, rpaths: b.rpaths,
                          encryption: b.encryption, codeSignatureRange: b.signatureRange, codeSignature: signature,
                          codeSignatureProblem: signatureProblem, segments: b.segments, entryOffset: b.entryOffset,
                          sourceVersion: b.sourceVersion, declaredLoadCommands: declared, readLoadCommands: read,
                          notes: b.notes)
    }

    /// A load command string (`union lc_str`): an offset from the command's start, past its fixed part.
    private static func commandString(_ command: [UInt8], offset: UInt32, fixedSize: Int) throws -> String {
        let at = Int(offset)
        guard at >= fixedSize, at < command.count else {
            throw BinaryError.malformed("a name points outside its load command")
        }
        return command.cString(at: at) ?? ""
    }

    private static func parseCommand(_ cmd: UInt32, _ command: [UInt8], bigEndian: Bool, sliceSize: Int64,
                                     into b: inout SliceBuilder) throws {
        var c = ByteCursor(command, at: 8, bigEndian: bigEndian, what: "the load command")
        switch cmd {
        case Command.segment, Command.segment64:
            let wide = cmd == Command.segment64
            let name = try c.take(16).cString(at: 0) ?? ""
            let vmAddress = wide ? try c.u64() : UInt64(try c.u32())
            let vmSize = wide ? try c.u64() : UInt64(try c.u32())
            let fileOffset = wide ? try c.u64() : UInt64(try c.u32())
            let fileSize = wide ? try c.u64() : UInt64(try c.u32())
            let maxProt = try c.u32(), initProt = try c.u32()
            let sections = try c.u32()
            let sectionSize = wide ? 80 : 68
            if UInt64(sections) * UInt64(sectionSize) > UInt64(max(0, c.remaining - 4)) {
                b.notes.append("segment \(name) declares \(sections) sections that do not fit its command")
            }
            if fileSize > 0, fileOffset > UInt64(sliceSize) || fileSize > UInt64(sliceSize) - fileOffset {
                b.notes.append("segment \(name) maps bytes past the end of the file")
            }
            b.segments.append(Segment(name: name, vmAddress: vmAddress, vmSize: vmSize, fileOffset: fileOffset,
                                      fileSize: fileSize, sectionCount: Int(sections),
                                      initialProtection: Segment.protection(initProt),
                                      maximumProtection: Segment.protection(maxProt)))
        case Command.loadDylib, Command.loadWeakDylib, Command.reexportDylib, Command.lazyLoadDylib,
             Command.loadUpwardDylib, Command.idDylib:
            let nameOffset = try c.u32()
            _ = try c.u32()                                       // timestamp
            let current = MachOVersion(packed: try c.u32())
            let compatibility = MachOVersion(packed: try c.u32())
            let path = try commandString(command, offset: nameOffset, fixedSize: 24)
            let kind: LinkedDylib.Kind = switch cmd {
            case Command.loadWeakDylib: .weak
            case Command.reexportDylib: .reexport
            case Command.lazyLoadDylib: .lazy
            case Command.loadUpwardDylib: .upward
            case Command.idDylib: .id
            default: .load
            }
            let dylib = LinkedDylib(path: path, kind: kind, currentVersion: current, compatibilityVersion: compatibility)
            if kind == .id { b.installName = dylib } else { b.dylibs.append(dylib) }
        case Command.rpath:
            b.rpaths.append(try commandString(command, offset: try c.u32(), fixedSize: 12))
        case Command.uuid:
            let raw = try c.take(16)
            b.uuid = UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9],
                                 raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
        case Command.codeSignature:
            let offset = try c.u32(), size = try c.u32()
            b.signatureRange = FileRange(offset: Int64(offset), length: Int64(size))
        case Command.encryptionInfo, Command.encryptionInfo64:
            b.encryption = EncryptionInfo(offset: try c.u32(), size: try c.u32(), cryptID: try c.u32())
        case Command.versionMinMacOS, Command.versionMinIPhoneOS, Command.versionMinTVOS, Command.versionMinWatchOS:
            let platform: MachOPlatform = switch cmd {
            case Command.versionMinMacOS: .macOS
            case Command.versionMinIPhoneOS: .iOS
            case Command.versionMinTVOS: MachOPlatform(rawValue: 3)
            default: MachOPlatform(rawValue: 4)
            }
            let minimum = MachOVersion(packed: try c.u32())
            let sdk = MachOVersion(packed: try c.u32())
            b.platforms.append(BuildVersion(platform: platform, minimumOS: minimum, sdk: sdk, tools: [], source: .versionMin))
        case Command.buildVersion:
            let platform = MachOPlatform(rawValue: try c.u32())
            let minimum = MachOVersion(packed: try c.u32())
            let sdk = MachOVersion(packed: try c.u32())
            let declaredTools = Int(try c.u32())
            var tools: [BuildVersion.Tool] = []
            // Each tool is 8 bytes; the count is believed only as far as the command holds them.
            for _ in 0..<min(declaredTools, c.remaining / 8) {
                let tool = try c.u32()
                tools.append(.init(name: BuildVersion.toolName(tool), version: MachOVersion(packed: try c.u32())))
            }
            if declaredTools > tools.count { b.notes.append("LC_BUILD_VERSION declares more tools than it holds") }
            b.platforms.append(BuildVersion(platform: platform, minimumOS: minimum, sdk: sdk, tools: tools,
                                            source: .buildVersion))
        case Command.main:
            b.entryOffset = try c.u64()
        case Command.sourceVersion:
            let v = try c.u64()
            let parts = [v >> 40, (v >> 30) & 0x3FF, (v >> 20) & 0x3FF, (v >> 10) & 0x3FF, v & 0x3FF]
            var shown = parts
            while shown.count > 2, shown.last == 0 { shown.removeLast() }
            b.sourceVersion = shown.map(String.init).joined(separator: ".")
        default:
            break
        }
    }
}
