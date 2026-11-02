import Foundation
import VitrineArchive
import VitrineSupport

/// One name a pickle imports when it is loaded (`module.name`), how, how often, and what that means. roadmap: S-21
public struct PickleImport: Sendable, Equatable {
    /// What importing the name means for this Mac. roadmap: S-21
    public enum Verdict: String, Sendable, Equatable {
        /// Can run commands, read or write files, reach the network, or evaluate code.
        case dangerous
        /// A rebuild function or container class PyTorch, NumPy and the standard library use for plain data.
        case knownSafe
        /// Neither: third-party or custom code that runs when the file loads.
        case unknown
    }

    /// `module.name`, e.g. `os.system` or `torch._utils._rebuild_tensor_v2`.
    public var name: String
    /// GLOBAL, STACK_GLOBAL or INST.
    public var opcode: String
    public var count: Int
    public var verdict: Verdict
    /// Why a dangerous import is dangerous, in plain English.
    public var reason: String?
    /// The pickle calls it (REDUCE, INST, OBJ, NEWOBJ), not only names it.
    public var isCalled: Bool
    /// The first string argument seen in a call, clipped (the command `os.system` would run).
    public var firstArgument: String?
    /// The archive member it was found in (`archive/data.pkl`), nil for a plain pickle.
    public var member: String?
}

/// How the pickle stream was found. roadmap: S-21
public enum PickleContainer: Sendable, Equatable {
    /// The file is one or more pickle streams.
    case raw
    /// A PyTorch zip (torch.save since 1.6): the pickle is the `data.pkl` member.
    case pytorchZip(member: String)
    /// A NumPy `.npy` array of Python objects: the pickle follows the array header.
    case numpyObjectArray(descr: String, shape: String)
    /// A compressed joblib file, decompressed in memory first.
    case compressed(String)
}

/// A static scan of a pickle (T-7): the protocol, every import a load would perform, and which of them can harm the
/// Mac. Nothing is unpickled or run; the opcodes are only read. roadmap: S-21
public struct PickleSummary: Sendable, Equatable {
    public var container: PickleContainer
    /// Protocols the streams declare (0–5); 0 or 1 when a stream has no PROTO opcode.
    public var protocols: [Int]
    public var streamCount: Int
    public var opcodeCount: Int
    public var imports: [PickleImport]
    public var importsTruncated: Bool
    /// Calls the pickle makes of imported names.
    public var callCount: Int
    /// The scan stopped before the end of the stream, and why.
    public var stoppedEarly: String?
    public var scannedBytes: Int
    /// PyTorch zips: the number of tensor storage members, and whether TorchScript code is inside.
    public var storageCount: Int?
    public var hasTorchScriptCode: Bool
    public var headline: String
    public var facts: [AIFact]
    public var warnings: [AIWarning]

    public var dangerousImports: [PickleImport] { imports.filter { $0.verdict == .dangerous } }
}

enum PickleReader {
    static func read(source: any ByteSource, fileName: String) -> PickleSummary? {
        let limit = Int(AIFormatsLimits.maxOtherBytes)
        guard let head = try? source.read(at: 0, count: 16), !head.isEmpty else { return nil }
        let ext = (fileName.lowercased() as NSString).pathExtension

        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return torchZip(source: source, fileName: fileName)
        }
        if head.starts(with: [0x93] + Array("NUMPY".utf8)) {
            return numpy(source: source)
        }
        guard ext != "npy" else { return nil }
        let picklish = ext == "joblib" || ext == "pkl" || ext == "pickle"
        if picklish, PickleDecompression.supported(head) != nil {
            guard let input = try? source.read(at: 0, count: limit),
                  let unpacked = PickleDecompression.decompress(input, fileSize: source.size, limit: limit) else { return nil }
            return compressed(unpacked)
        }
        if let name = compressionName(head) {
            guard picklish else { return nil }
            return PickleScan.unscanned(.compressed(name), reason: String(localized: "It is compressed with \(name), which this reader cannot open, so its imports were not checked.", bundle: .module, comment: "Warning on a pickle card. The argument is a compression name such as bzip2."))
        }
        // A `.bin` or `.ckpt` is only taken for a pickle when it starts like one (protocol 2–5).
        let looksLikePickle = head.count >= 2 && head[0] == 0x80 && (2...5).contains(head[1])
        if ["bin", "ckpt"].contains(ext), !looksLikePickle { return nil }
        guard let bytes = try? source.read(at: 0, count: limit) else { return nil }
        var scan = PickleScan(bytes: bytes, member: nil)
        scan.run(multipleStreams: true)
        // A `.pt` or `.pth` that neither starts nor scans like a pickle is someone else's format.
        if !looksLikePickle, ["pt", "pth"].contains(ext),
           scan.opcodeCount < 2 || (scan.stoppedEarly != nil && scan.imports.isEmpty && scan.opcodeCount < 8) {
            return nil
        }
        var facts: [AIFact] = []
        if scan.streamCount > 1, ["pt", "pth", "bin", "ckpt"].contains(ext) {
            facts.append(AIFact(AIFormat.formatLabel, String(localized: "Legacy PyTorch file (several pickles, before torch 1.6)", bundle: .module, comment: "The format of a pickle file. PyTorch and torch are product names.")))
        }
        if Int64(bytes.count) < source.size {
            let read = AIFormat.bytes(Int64(bytes.count)), total = AIFormat.bytes(source.size)
            facts.append(AIFact(String(localized: "Scanned", bundle: .module, comment: "Fact label on a pickle card: how much of the file was checked."),
                                String(localized: "the first \(read) of \(total)", bundle: .module, comment: "How much of a large file was read. Two sizes such as 8 MB and 12 MB.")))
        }
        return scan.summary(container: .raw, extraFacts: facts, extraWarnings: [])
    }

    // MARK: Containers

    /// A decompressed pickle's card. When the compressed data could not be followed to its end exactly as Python
    /// reads it, the card says so as a danger and never reports a clean scan: what was not followed may hold anything.
    static func compressed(_ unpacked: PickleDecompression) -> PickleSummary {
        let container = PickleContainer.compressed(unpacked.name)
        let notFollowed = unpacked.problem.map { why in
            AIWarning(.danger, String(localized: "The compressed data could not be followed to its end (\(why)), so this file may hold imports the scan did not see. Treat it as unsafe.", bundle: .module, comment: "Danger on a pickle card whose compressed data could not be read completely. The argument is a technical reason in English."))
        }
        guard !unpacked.bytes.isEmpty else {
            return PickleScan.unscanned(container, warning: notFollowed ?? AIWarning(.danger, String(localized: "The compressed data holds nothing to scan, so its imports were not checked. Treat it as unsafe.", bundle: .module, comment: "Danger on a pickle card whose compressed data decompresses to nothing.")))
        }
        var scan = PickleScan(bytes: unpacked.bytes, member: nil)
        scan.run(multipleStreams: true)
        var summary = scan.summary(container: container, extraFacts: [], extraWarnings: notFollowed.map { [$0] } ?? [])
        if notFollowed != nil, summary.dangerousImports.isEmpty {
            summary.headline = String(localized: "Compressed pickle (only partly scanned)", bundle: .module, comment: "Headline of a pickle card whose compressed data could not be read completely.")
        }
        return summary
    }

    static func torchZip(source: any ByteSource, fileName: String) -> PickleSummary? {
        guard let listing = try? VitrineArchive.list(source: source, fileName: fileName) else { return nil }
        let files = listing.entries.enumerated().filter { $0.element.type == .file }
        func depth(_ p: String) -> Int { p.split(separator: "/").count }
        let dataPickles = files.filter { $0.element.path == "data.pkl" || ($0.element.path.hasSuffix("/data.pkl") && depth($0.element.path) == 2) }
        guard let data = dataPickles.min(by: { $0.element.path.count < $1.element.path.count }) else { return nil }
        let prefix = String(data.element.path.dropLast("data.pkl".count))
        var pickles = [data]
        if let constants = files.first(where: { $0.element.path == prefix + "constants.pkl" }) { pickles.append(constants) }

        var combined = PickleScan(bytes: [], member: nil)
        var warnings: [AIWarning] = []
        for (index, entry) in pickles {
            do {
                let member = try VitrineArchive.memberData(source: source, fileName: fileName, listing: listing, entryIndex: index,
                                                           limit: Int(AIFormatsLimits.maxOtherBytes))
                var scan = PickleScan(bytes: member.bytes, member: entry.path)
                scan.run(multipleStreams: false)
                combined.absorb(scan)
                if !member.isComplete {
                    let size = AIFormat.bytes(Int64(member.bytes.count)), path = entry.path
                    warnings.append(AIWarning(.caution, String(localized: "Only the first \(size) of \(path) was scanned.", bundle: .module, comment: "Warning on a PyTorch file card. A size, then a member path inside the file.")))
                }
            } catch {
                let path = entry.path, detail = "\(error)"
                warnings.append(AIWarning(.caution, String(localized: "\(path) could not be read (\(detail)), so its imports were not checked.", bundle: .module, comment: "Warning on a PyTorch file card. A member path, then a technical reason in English."), subject: entry.path))
            }
        }
        let storages = files.filter { $0.element.path.hasPrefix(prefix + "data/") }.count
        let code = files.contains { $0.element.path.hasPrefix(prefix + "code/") }
        combined.storageCount = storages
        combined.hasTorchScriptCode = code
        let format = code
            ? String(localized: "TorchScript archive (torch.jit.save)", bundle: .module, comment: "The format of a PyTorch file. TorchScript and torch.jit.save are names.")
            : String(localized: "PyTorch zip (torch.save)", bundle: .module, comment: "The format of a PyTorch file. PyTorch and torch.save are names.")
        var facts = [AIFact(AIFormat.formatLabel, format),
                     AIFact(String(localized: "Tensor storages", bundle: .module, comment: "Fact label on a PyTorch file card: the number of tensor data blocks."), AIFormat.count(storages))]
        if let version = files.first(where: { $0.element.path == prefix + "version" || $0.element.path == prefix + ".data/version" }),
           let bytes = try? VitrineArchive.memberData(source: source, fileName: fileName, listing: listing, entryIndex: version.offset, limit: 32).bytes {
            facts.append(AIFact(String(localized: "Archive version", bundle: .module, comment: "Fact label on a PyTorch file card."),
                                AIFormat.text(bytes).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if code {
            let folder = prefix + "code/"
            warnings.append(AIWarning(.caution, String(localized: "It holds TorchScript code (\(folder)), a program torch.jit.load compiles and runs.", bundle: .module, comment: "Warning on a PyTorch file card. The argument is a folder inside the file.")))
        }
        return combined.summary(container: .pytorchZip(member: data.element.path), extraFacts: facts, extraWarnings: warnings)
    }

    static func numpy(source: any ByteSource) -> PickleSummary? {
        guard let head = try? source.read(at: 0, count: 12), head.count >= 10 else { return nil }
        let major = head[6]
        let headerLength: Int, start: Int
        if major == 1 { headerLength = Int(head[8]) | Int(head[9]) << 8; start = 10 }
        else {
            guard head.count >= 12 else { return nil }
            headerLength = Int(head[8]) | Int(head[9]) << 8 | Int(head[10]) << 16 | Int(head[11]) << 24; start = 12
        }
        guard headerLength < 1_000_000, let headerBytes = try? source.read(at: Int64(start), count: headerLength) else { return nil }
        let header = AIFormat.text(headerBytes)
        func field(_ key: String) -> String? {
            guard let r = header.range(of: "'\(key)':") else { return nil }
            var rest = header[r.upperBound...].drop(while: { $0 == " " })
            if rest.first == "'" { rest = rest.dropFirst(); return String(rest.prefix(while: { $0 != "'" })) }
            if rest.first == "(" { return "(" + rest.dropFirst().prefix(while: { $0 != ")" }) + ")" }
            if rest.first == "[" { return "[" + rest.dropFirst().prefix(while: { $0 != "]" }) + "]" }
            return String(rest.prefix(while: { $0 != "," && $0 != "}" }))
        }
        let descr = field("descr") ?? "?"
        guard header.range(of: #"'[|<>=]?O\d*'"#, options: .regularExpression) != nil else { return nil }
        let shape = field("shape") ?? "?"
        let offset = Int64(start + headerLength)
        guard let bytes = try? source.read(at: offset, count: Int(AIFormatsLimits.maxOtherBytes)) else { return nil }
        var scan = PickleScan(bytes: bytes, member: nil)
        scan.run(multipleStreams: false)
        let facts = [AIFact(AIFormat.formatLabel, String(localized: "NumPy array of Python objects (.npy, dtype \(descr))", bundle: .module, comment: "The format of a NumPy file. The argument is a NumPy dtype code such as |O.")),
                     AIFact(String(localized: "Shape", bundle: .module, comment: "Fact label on a NumPy file card: the array's dimensions."), shape)]
        let warnings = [AIWarning(.caution, String(localized: "Object arrays are stored as a pickle; numpy.load refuses them unless allow_pickle=True, which runs the imports below.", bundle: .module, comment: "Warning on a NumPy file card. numpy.load and allow_pickle=True are code and stay as written."))]
        return scan.summary(container: .numpyObjectArray(descr: descr, shape: shape), extraFacts: facts, extraWarnings: warnings)
    }

    /// The compression a file starts with: the ones PickleDecompression opens, then the ones it names but cannot open.
    static func compressionName(_ head: [UInt8]) -> String? {
        if let name = PickleDecompression.supported(head) { return name }
        if head.starts(with: Array("BZh".utf8)) { return "bzip2" }
        if head.starts(with: [0x5D, 0x00, 0x00]) { return "lzma" }
        if head.starts(with: [0x04, 0x22, 0x4D, 0x18]) { return "lz4" }
        return nil
    }
}

/// The opcode walk. A small symbolic stack and memo follow strings far enough to name STACK_GLOBAL imports and the
/// first string argument of a call; every other value is opaque. Bounded by the input (8 MB) and fixed caps.
struct PickleScan {
    enum Value: Equatable {
        case mark
        case string(String)
        case global(String)
        case tuple([Value])
        case other
    }

    let bytes: [UInt8]
    let member: String?
    var position = 0
    var stack: [Value] = []
    var memo: [Int: Value] = [:]
    var protocols: [Int] = []
    var streamCount = 0
    var opcodeCount = 0
    var callCount = 0
    var imports: [PickleImport] = []
    var importIndex: [String: Int] = [:]
    var importsTruncated = false
    var stoppedEarly: String?
    var unresolvedStackGlobals = 0
    var extensionCodes = 0
    var persistentIDs = 0
    var storageCount: Int?
    var hasTorchScriptCode = false
    var scannedBytes = 0

    static let maxStack = 100_000
    static let maxMemo = 200_000
    static let maxStreams = 16

    init(bytes: [UInt8], member: String?) { self.bytes = bytes; self.member = member }

    mutating func absorb(_ other: PickleScan) {
        for item in other.imports { record(item.name, opcode: item.opcode, member: item.member, count: item.count, called: item.isCalled, argument: item.firstArgument) }
        protocols += other.protocols.filter { !protocols.contains($0) }
        streamCount += other.streamCount
        opcodeCount += other.opcodeCount
        callCount += other.callCount
        scannedBytes += other.scannedBytes
        unresolvedStackGlobals += other.unresolvedStackGlobals
        extensionCodes += other.extensionCodes
        importsTruncated = importsTruncated || other.importsTruncated
        if stoppedEarly == nil, let why = other.stoppedEarly { stoppedEarly = (other.member.map { "\($0): " } ?? "") + why }
    }

    mutating func run(multipleStreams: Bool) {
        while position < bytes.count, streamCount < Self.maxStreams {
            let start = position
            let finished = runStream()
            if finished { streamCount += 1 }
            scannedBytes = position
            guard finished, multipleStreams, stoppedEarly == nil else { break }
            // A following stream must start like one (legacy torch files are several pickles back to back).
            guard position + 1 < bytes.count, bytes[position] == 0x80, (2...5).contains(bytes[position + 1]) else { break }
            stack.removeAll(); memo.removeAll()
            if position == start { break }
        }
        scannedBytes = position
    }

    // MARK: Reading primitives

    private mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard n >= 0, n <= bytes.count - position else { return nil }
        defer { position += n }
        return bytes[position..<(position + n)]
    }

    private mutating func uint(_ width: Int) -> Int? {
        guard let b = take(width) else { return nil }
        var v: UInt64 = 0
        for (i, byte) in b.enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
        return v > UInt64(Int.max) ? nil : Int(v)
    }

    private mutating func line() -> String? {
        guard let nl = bytes[position...].firstIndex(of: 0x0A) else { return nil }
        let s = AIFormat.text(bytes[position..<nl])
        position = nl + 1
        return s.hasSuffix("\r") ? String(s.dropLast()) : s
    }

    private mutating func push(_ v: Value) -> Bool {
        guard stack.count < Self.maxStack else { stoppedEarly = "the stack grew past \(Self.maxStack) items"; return false }
        stack.append(v); return true
    }

    private mutating func pop() -> Value { stack.popLast() ?? .other }

    private mutating func popToMark() -> [Value] {
        guard let m = stack.lastIndex(of: .mark) else { let all = stack; stack.removeAll(); return all }
        let items = Array(stack[(m + 1)...])
        stack.removeSubrange(m...)
        return items
    }

    private static func clipped(_ s: String) -> String { s.count > 4096 ? String(s.prefix(4096)) : s }

    // MARK: The walk

    /// One pickle up to STOP. True when STOP was reached.
    private mutating func runStream() -> Bool {
        stack.removeAll(keepingCapacity: true)
        var sawProto = false
        while position < bytes.count {
            let at = position
            let op = bytes[position]
            position += 1
            opcodeCount += 1
            func fail(_ why: String) -> Bool { stoppedEarly = "\(why) at byte \(at)"; return false }
            func pushString(_ s: String?) -> Bool { guard let s else { return fail("a string runs past the end") }; return push(.string(Self.clipped(s))) }
            func pushOther() -> Bool { push(.other) }

            switch op {
            case 0x80:   // PROTO
                guard let v = take(1)?.first else { return fail("PROTO has no version") }
                guard v <= 5 else { return fail("unknown protocol \(v)") }
                if !protocols.contains(Int(v)) { protocols.append(Int(v)) }
                sawProto = true
            case 0x2E:   // STOP
                if !sawProto, !protocols.contains(0) { protocols.append(0) }
                return true
            case 0x95:   // FRAME
                guard take(8) != nil else { return fail("FRAME runs past the end") }
            case 0x28: guard push(.mark) else { return false }                      // MARK
            case 0x30: _ = pop()                                                    // POP
            case 0x31: _ = popToMark()                                              // POP_MARK
            case 0x32: guard push(stack.last ?? .other) else { return false }       // DUP
            // Numbers and constants.
            case 0x46, 0x49, 0x4C:                                                  // FLOAT, INT, LONG
                guard line() != nil else { return fail("a number runs past the end") }
                guard pushOther() else { return false }
            case 0x4A: guard take(4) != nil, pushOther() else { return fail("BININT runs past the end") }
            case 0x4B: guard take(1) != nil, pushOther() else { return fail("BININT1 runs past the end") }
            case 0x4D: guard take(2) != nil, pushOther() else { return fail("BININT2 runs past the end") }
            case 0x47: guard take(8) != nil, pushOther() else { return fail("BINFLOAT runs past the end") }
            case 0x8A: guard let n = uint(1), take(n) != nil, pushOther() else { return fail("LONG1 runs past the end") }
            case 0x8B: guard let n = uint(4), take(n) != nil, pushOther() else { return fail("LONG4 runs past the end") }
            case 0x4E, 0x88, 0x89, 0x29, 0x5D, 0x7D, 0x8F, 0x97:                    // NONE, TRUE, FALSE, (), [], {}, set(), NEXT_BUFFER
                guard pushOther() else { return false }
            case 0x98: break                                                        // READONLY_BUFFER
            // Strings and bytes.
            case 0x53:                                                              // STRING 'text'
                guard var s = line() else { return fail("STRING runs past the end") }
                if s.count >= 2, let f = s.first, f == "'" || f == "\"" { s = String(s.dropFirst().dropLast()) }
                guard pushString(s) else { return false }
            case 0x56: guard pushString(line()) else { return false }               // UNICODE (raw-unicode-escape)
            case 0x54, 0x58:                                                        // BINSTRING, BINUNICODE
                guard let n = uint(4), let b = take(n) else { return fail("a string runs past the end") }
                guard pushString(AIFormat.text(b)) else { return false }
            case 0x55, 0x8C:                                                        // SHORT_BINSTRING, SHORT_BINUNICODE
                guard let n = uint(1), let b = take(n) else { return fail("a string runs past the end") }
                guard pushString(AIFormat.text(b)) else { return false }
            case 0x8D:                                                              // BINUNICODE8
                guard let n = uint(8), let b = take(n) else { return fail("a string runs past the end") }
                guard pushString(AIFormat.text(b)) else { return false }
            case 0x42: guard let n = uint(4), take(n) != nil, pushOther() else { return fail("BINBYTES runs past the end") }
            case 0x43: guard let n = uint(1), take(n) != nil, pushOther() else { return fail("SHORT_BINBYTES runs past the end") }
            case 0x8E, 0x96: guard let n = uint(8), take(n) != nil, pushOther() else { return fail("BINBYTES8 runs past the end") }
            // Containers.
            case 0x61: _ = pop()                                                    // APPEND
            case 0x65, 0x75, 0x90: _ = popToMark()                                  // APPENDS, SETITEMS, ADDITEMS
            case 0x73: _ = pop(); _ = pop()                                         // SETITEM
            case 0x64, 0x6C, 0x91: _ = popToMark(); guard pushOther() else { return false }   // DICT, LIST, FROZENSET
            case 0x74: guard push(.tuple(Array(popToMark().prefix(8)))) else { return false }  // TUPLE
            case 0x85: let a = pop(); guard push(.tuple([a])) else { return false }            // TUPLE1
            case 0x86: let b = pop(), a = pop(); guard push(.tuple([a, b])) else { return false }
            case 0x87: let c = pop(), b = pop(), a = pop(); guard push(.tuple([a, b, c])) else { return false }
            case 0x62: _ = pop()                                                    // BUILD
            // Memo.
            case 0x70:                                                              // PUT n
                guard let s = line(), let n = Int(s.trimmingCharacters(in: .whitespaces)) else { return fail("PUT has no index") }
                remember(n)
            case 0x71: guard let n = uint(1) else { return fail("BINPUT runs past the end") }; remember(n)
            case 0x72: guard let n = uint(4) else { return fail("LONG_BINPUT runs past the end") }; remember(n)
            case 0x94: remember(memo.count)                                         // MEMOIZE
            case 0x67:                                                              // GET n
                guard let s = line(), let n = Int(s.trimmingCharacters(in: .whitespaces)) else { return fail("GET has no index") }
                guard push(memo[n] ?? .other) else { return false }
            case 0x68: guard let n = uint(1) else { return fail("BINGET runs past the end") }; guard push(memo[n] ?? .other) else { return false }
            case 0x6A: guard let n = uint(4) else { return fail("LONG_BINGET runs past the end") }; guard push(memo[n] ?? .other) else { return false }
            // Persistent ids (PyTorch's storages).
            case 0x50: guard line() != nil else { return fail("PERSID runs past the end") }; persistentIDs += 1; guard pushOther() else { return false }
            case 0x51: _ = pop(); persistentIDs += 1; guard pushOther() else { return false }
            // Imports and calls.
            case 0x63:                                                              // GLOBAL module\nname\n
                guard let module = line(), let name = line() else { return fail("GLOBAL runs past the end") }
                let full = "\(module).\(name)"
                record(full, opcode: "GLOBAL", member: member)
                guard push(.global(full)) else { return false }
            case 0x93:                                                              // STACK_GLOBAL
                let name = pop(), module = pop()
                if case .string(let m) = module, case .string(let n) = name {
                    let full = "\(m).\(n)"
                    record(full, opcode: "STACK_GLOBAL", member: member)
                    guard push(.global(full)) else { return false }
                } else {
                    unresolvedStackGlobals += 1
                    guard pushOther() else { return false }
                }
            case 0x69:                                                              // INST module\nname\n (calls it)
                guard let module = line(), let name = line() else { return fail("INST runs past the end") }
                let args = popToMark()
                let full = "\(module).\(name)"
                record(full, opcode: "INST", member: member, called: true, argument: firstString(args))
                callCount += 1
                guard pushOther() else { return false }
            case 0x6F:                                                              // OBJ: MARK callable args… OBJ
                let items = popToMark()
                if case .global(let name)? = items.first {
                    record(name, opcode: nil, member: member, called: true, argument: firstString(Array(items.dropFirst())))
                }
                callCount += 1
                guard pushOther() else { return false }
            case 0x52:                                                              // REDUCE callable args
                let args = pop(), callable = pop()
                call(callable, args: args)
                guard pushOther() else { return false }
            case 0x81:                                                              // NEWOBJ cls args
                let args = pop(), cls = pop()
                call(cls, args: args)
                guard pushOther() else { return false }
            case 0x92:                                                              // NEWOBJ_EX cls args kwargs
                _ = pop(); let args = pop(), cls = pop()
                call(cls, args: args)
                guard pushOther() else { return false }
            case 0x82: guard take(1) != nil else { return fail("EXT1 runs past the end") }; extensionCodes += 1; guard pushOther() else { return false }
            case 0x83: guard take(2) != nil else { return fail("EXT2 runs past the end") }; extensionCodes += 1; guard pushOther() else { return false }
            case 0x84: guard take(4) != nil else { return fail("EXT4 runs past the end") }; extensionCodes += 1; guard pushOther() else { return false }
            default:
                return fail(String(format: "unknown opcode 0x%02X", op))
            }
            if stoppedEarly != nil { return false }
        }
        stoppedEarly = "the stream ends before its STOP opcode"
        return false
    }

    private mutating func remember(_ n: Int) {
        guard memo.count < Self.maxMemo || memo[n] != nil else { return }
        memo[n] = stack.last ?? .other
    }

    private func firstString(_ values: [Value]) -> String? {
        for v in values {
            switch v {
            case .string(let s): return AIFormat.clip(s, 200)
            case .tuple(let inner): if let s = firstString(inner) { return s }
            default: continue
            }
        }
        return nil
    }

    private mutating func call(_ callable: Value, args: Value) {
        callCount += 1
        guard case .global(let name) = callable else { return }
        record(name, opcode: nil, member: member, called: true, argument: firstString([args]))
    }

    /// Adds or updates an import. `opcode` nil marks a call of an already recorded name.
    mutating func record(_ name: String, opcode: String?, member: String?, count: Int = 1, called: Bool = false, argument: String? = nil) {
        if let i = importIndex[name] {
            if opcode != nil { imports[i].count += count }
            if called { imports[i].isCalled = true }
            if imports[i].firstArgument == nil { imports[i].firstArgument = argument }
            return
        }
        guard imports.count < AIFormatsLimits.maxListItems else { importsTruncated = true; return }
        let (verdict, reason) = PickleClassifier.classify(name)
        importIndex[name] = imports.count
        imports.append(PickleImport(name: name, opcode: opcode ?? "GLOBAL", count: opcode == nil ? 0 : count, verdict: verdict,
                                    reason: reason, isCalled: called, firstArgument: argument, member: member))
    }

    // MARK: Summary

    func summary(container: PickleContainer, extraFacts: [AIFact], extraWarnings: [AIWarning]) -> PickleSummary {
        var warnings: [AIWarning] = []
        let dangerous = imports.filter { $0.verdict == .dangerous }
        for item in dangerous {
            let name = item.name
            let why = item.reason ?? String(localized: "It can harm this Mac.", bundle: .module, comment: "Why a name a pickle imports is dangerous, when no specific reason is known.")
            let reason: String
            if let arg = item.firstArgument {
                reason = String(localized: "Loading this file imports \(name) and calls it with “\(arg)”. \(why)", bundle: .module, comment: "Danger on a pickle card. A Python name such as os.system, the text it is called with, then why that is dangerous.")
            } else if item.isCalled {
                reason = String(localized: "Loading this file imports \(name) and calls it. \(why)", bundle: .module, comment: "Danger on a pickle card. A Python name such as os.system, then why that is dangerous.")
            } else {
                reason = String(localized: "Loading this file imports \(name). \(why)", bundle: .module, comment: "Danger on a pickle card. A Python name such as os.system, then why that is dangerous.")
            }
            warnings.append(AIWarning(.danger, reason, subject: item.name))
        }
        let unknown = imports.filter { $0.verdict == .unknown }
        if !unknown.isEmpty {
            let names = unknown.prefix(5).map(\.name).joined(separator: ", ") + (unknown.count > 5 ? " …" : "")
            let count = unknown.count
            warnings.append(AIWarning(.caution, String(localized: "Loading it runs code from \(count) names outside the known-safe list (\(names)); that code must be installed and trusted.", bundle: .module, comment: "Warning on a pickle card. A number of Python names (plural forms), then some of them.")))
        }
        if unresolvedStackGlobals > 0 {
            let count = unresolvedStackGlobals
            warnings.append(AIWarning(.caution, String(localized: "\(count) imports are built in a way this scan cannot follow, so they may hide anything.", bundle: .module, comment: "Warning on a pickle card. The argument is a number of imports (plural forms).")))
        }
        if extensionCodes > 0 {
            warnings.append(AIWarning(.caution, String(localized: "It imports names through the copyreg extension registry, which hides what is imported.", bundle: .module, comment: "Warning on a pickle card. copyreg is a Python module name.")))
        }
        if let why = stoppedEarly {
            warnings.append(AIWarning(.caution, String(localized: "The scan stopped early (\(why)); imports after that point were not checked.", bundle: .module, comment: "Warning on a pickle card. The argument is a technical reason in English.")))
        }
        if dangerous.isEmpty { warnings.insert(AIWarning(.caution, Self.loadOnlyIfTrusted), at: 0) }
        warnings = extraWarnings + warnings

        var facts = extraFacts
        let protos = protocols.sorted().map(String.init).joined(separator: ", ")
        if !protos.isEmpty { facts.append(AIFact(String(localized: "Protocol", bundle: .module, comment: "Fact label on a pickle card: the pickle protocol version."), protos)) }
        if streamCount > 1 {
            facts.append(AIFact(String(localized: "Pickle streams", bundle: .module, comment: "Fact label on a pickle card: how many pickles the file holds."), AIFormat.count(streamCount)))
        }
        facts.append(AIFact(String(localized: "Imports", bundle: .module, comment: "Fact label on a pickle card: Python names the file imports when loaded."),
                            AIFormat.count(imports.count) + (importsTruncated ? "+" : "")))
        if !dangerous.isEmpty {
            facts.append(AIFact(String(localized: "Dangerous", bundle: .module, comment: "Fact label on a pickle card: the dangerous Python names it imports."), dangerous.map(\.name).joined(separator: ", ")))
        }
        let safe = imports.filter { $0.verdict == .knownSafe }
        if !safe.isEmpty {
            facts.append(AIFact(String(localized: "Known safe", bundle: .module, comment: "Fact label on a pickle card: the known-safe Python names it imports."), AIFormat.clip(safe.map(\.name).joined(separator: ", "), 400)))
        }
        facts.append(AIFact(String(localized: "Opcodes", bundle: .module, comment: "Fact label on a pickle card: the number of pickle instructions read."), AIFormat.count(opcodeCount)))
        if persistentIDs > 0 {
            facts.append(AIFact(String(localized: "Persistent ids", bundle: .module, comment: "Fact label on a pickle card: references to data stored outside the pickle."), AIFormat.count(persistentIDs)))
        }

        let headline: String
        if !dangerous.isEmpty {
            let names = dangerous.prefix(3).map(\.name).joined(separator: ", ")
            headline = String(localized: "Pickle that can run commands: \(names)", bundle: .module, comment: "Headline of a pickle card. The argument is a list of Python names such as os.system.")
        } else if !unknown.isEmpty {
            let count = unknown.count
            headline = String(localized: "Pickle importing \(count) unfamiliar names", bundle: .module, comment: "Headline of a pickle card. The argument is a number of Python names (plural forms).")
        } else if imports.isEmpty {
            headline = String(localized: "Pickle with no imports", bundle: .module, comment: "Headline of a pickle card.")
        } else {
            headline = String(localized: "Pickle using only known-safe imports", bundle: .module, comment: "Headline of a pickle card.")
        }

        return PickleSummary(container: container, protocols: protocols.sorted(), streamCount: streamCount,
                             opcodeCount: opcodeCount, imports: imports, importsTruncated: importsTruncated,
                             callCount: callCount, stoppedEarly: stoppedEarly, scannedBytes: scannedBytes,
                             storageCount: storageCount, hasTorchScriptCode: hasTorchScriptCode, headline: headline,
                             facts: facts, warnings: warnings)
    }

    static func unscanned(_ container: PickleContainer, reason: String) -> PickleSummary {
        unscanned(container, warning: AIWarning(.caution, reason))
    }

    static func unscanned(_ container: PickleContainer, warning: AIWarning) -> PickleSummary {
        PickleSummary(container: container, protocols: [], streamCount: 0, opcodeCount: 0, imports: [], importsTruncated: false,
                      callCount: 0, stoppedEarly: warning.reason, scannedBytes: 0, storageCount: nil, hasTorchScriptCode: false,
                      headline: String(localized: "Compressed pickle (not scanned)", bundle: .module, comment: "Headline of a pickle card whose compression could not be opened."),
                      facts: [], warnings: [warning, AIWarning(.caution, loadOnlyIfTrusted)])
    }

    static var loadOnlyIfTrusted: String {
        String(localized: "Pickle files can run code when loaded; load this one only if you trust where it came from.", bundle: .module, comment: "The standing caution on every pickle card.")
    }
}

/// Which imported names are dangerous, which are the known-safe rebuild functions, and which are neither.
enum PickleClassifier {
    /// What a dangerous name can do, each with one plain-English sentence.
    enum Harm {
        case system, programs, runsCode, files, network, email, browser, nativeCode, imports, processes, internals
        case nestedPickle, installs, attributes, internetCode

        var reason: String {
            switch self {
            case .system: String(localized: "It can run commands, delete files and change the system.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (os, posix).")
            case .programs: String(localized: "It starts other programs or runs shell commands.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (subprocess, pty, platform.popen).")
            case .runsCode: String(localized: "It runs Python code.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (runpy, eval, exec, the debugger).")
            case .files: String(localized: "It reads, writes or deletes files.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (shutil, open, tempfile).")
            case .network: String(localized: "It opens network connections.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (socket, urllib, requests).")
            case .email: String(localized: "It sends email.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (smtplib).")
            case .browser: String(localized: "It opens web pages.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (webbrowser).")
            case .nativeCode: String(localized: "It calls native code directly.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (ctypes).")
            case .imports: String(localized: "It imports any module by name.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (importlib, __import__).")
            case .processes: String(localized: "It starts other processes or threads.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (multiprocessing).")
            case .internals: String(localized: "It reaches the interpreter's internals.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (sys, gc, inspect, types).")
            case .nestedPickle: String(localized: "It loads more serialized code, which can hide anything.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (pickle.loads, marshal, dill).")
            case .installs: String(localized: "It installs packages or builds code.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (pip, setuptools).")
            case .attributes: String(localized: "It reaches attributes and methods by name, a way to call anything.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (getattr, operator.methodcaller).")
            case .internetCode: String(localized: "It downloads and runs code from the internet.", bundle: .module, comment: "Why a Python name a pickle imports is dangerous (torch.hub).")
            }
        }
    }

    /// Modules where every name is dangerous.
    static let dangerousModules: [String: Harm] = [
        "os": .system, "posix": .system, "nt": .system,
        "subprocess": .programs, "commands": .programs, "pty": .programs, "platform": .programs, "pydoc": .programs,
        "distutils": .programs, "venv": .programs,
        "runpy": .runsCode, "code": .runsCode, "codeop": .runsCode, "pdb": .runsCode, "bdb": .runsCode, "timeit": .runsCode,
        "numpy.testing": .runsCode, "torch.jit": .runsCode, "keras.src.saving": .runsCode,
        "shutil": .files, "tempfile": .files, "glob": .files, "io": .files, "_io": .files, "fileinput": .files,
        "socket": .network, "ssl": .network, "http": .network, "urllib": .network, "urllib2": .network, "requests": .network,
        "httpx": .network, "ftplib": .network, "telnetlib": .network, "asyncio": .network,
        "smtplib": .email, "webbrowser": .browser, "ctypes": .nativeCode, "cffi": .nativeCode,
        "importlib": .imports, "imp": .imports, "pkgutil": .imports, "zipimport": .imports,
        "multiprocessing": .processes, "concurrent": .processes, "signal": .processes,
        "sys": .internals, "types": .internals, "inspect": .internals, "gc": .internals,
        "marshal": .nestedPickle, "pickle": .nestedPickle, "_pickle": .nestedPickle, "cPickle": .nestedPickle,
        "dill": .nestedPickle, "cloudpickle": .nestedPickle, "shelve": .nestedPickle,
        "setuptools": .installs, "pip": .installs, "operator": .attributes, "torch.hub": .internetCode,
    ]

    static let dangerousBuiltins: Set<String> = [
        "eval", "exec", "execfile", "compile", "__import__", "getattr", "setattr", "delattr", "open", "file", "input",
        "raw_input", "globals", "locals", "vars", "breakpoint", "apply", "memoryview", "help", "exit", "quit", "reload",
    ]

    static let safePrefixes: [String] = [
        "torch._utils._rebuild_", "torch._tensor._rebuild_", "torch.nn.modules.", "torch.nn.parameter.", "torch.storage._load_from_bytes",
        "torch.ao.quantization.", "torch.nn.utils.parametrize.", "numpy.core.multiarray._reconstruct", "numpy._core.multiarray._reconstruct",
        "numpy.core.multiarray.scalar", "numpy._core.multiarray.scalar", "numpy.random._pickle.", "numpy.dtypes.",
        "collections.OrderedDict", "collections.Counter", "collections.deque", "collections.defaultdict", "collections.namedtuple",
        "datetime.", "decimal.Decimal", "fractions.Fraction", "uuid.UUID", "copyreg._reconstructor", "copy_reg._reconstructor",
        "_codecs.encode", "re._compile", "enum.", "builtins.object", "pathlib.PosixPath", "pathlib.PurePosixPath",
        "pathlib.WindowsPath", "pathlib.PureWindowsPath", "pathlib.Path", "io.BytesIO", "_io.BytesIO", "types.SimpleNamespace",
        "operator.itemgetter",
    ]

    static let safeNames: Set<String> = [
        "torch.Size", "torch.device", "torch.dtype", "torch.layout", "torch.memory_format", "torch.Tensor", "torch.serialization._get_layout",
        "torch.float32", "torch.float16", "torch.bfloat16", "torch.float64", "torch.int64", "torch.int32", "torch.int16", "torch.int8",
        "torch.uint8", "torch.bool", "torch.complex64", "torch.complex128", "torch.float8_e4m3fn", "torch.float8_e5m2",
        "torch.strided", "torch.sparse_coo", "torch.contiguous_format", "torch.channels_last", "torch.preserve_format",
        "numpy.ndarray", "numpy.dtype", "numpy.core.multiarray._reconstruct", "numpy.core.numeric._frombuffer",
        "numpy._core.numeric._frombuffer", "builtins.set", "builtins.frozenset", "builtins.slice", "builtins.complex",
        "builtins.bytearray", "builtins.range", "builtins.list", "builtins.dict", "builtins.tuple", "builtins.int",
        "builtins.float", "builtins.str", "builtins.bytes", "builtins.bool", "__builtin__.set", "__builtin__.frozenset",
        "__builtin__.slice", "__builtin__.complex", "__builtin__.bytearray", "__builtin__.object", "builtins.print",
    ]

    static let torchStorageSuffix = "Storage"

    static func classify(_ name: String) -> (PickleImport.Verdict, String?) {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let last = parts.last ?? name
        if parts.first == "builtins" || parts.first == "__builtin__" {
            if dangerousBuiltins.contains(last) {
                let harm: Harm
                switch last {
                case "eval", "exec", "execfile", "compile", "breakpoint", "input", "raw_input", "help": harm = .runsCode
                case "__import__", "reload": harm = .imports
                case "open", "file": harm = .files
                case "exit", "quit": harm = .system
                default: harm = .attributes
                }
                return (.dangerous, harm.reason)
            }
        }
        if safeNames.contains(name) || safePrefixes.contains(where: { name.hasPrefix($0) }) { return (.knownSafe, nil) }
        if parts.count == 2, parts[0] == "torch", last.hasSuffix(torchStorageSuffix) { return (.knownSafe, nil) }
        // The longest dangerous module prefix wins (torch.hub before torch).
        for k in stride(from: parts.count - 1, through: 1, by: -1) {
            let module = parts[0..<k].joined(separator: ".")
            if let harm = dangerousModules[module] { return (.dangerous, harm.reason) }
        }
        if parts.first == "__main__" { return (.unknown, nil) }
        if parts.first == "builtins" || parts.first == "__builtin__" { return (.knownSafe, nil) }
        return (.unknown, nil)
    }
}
