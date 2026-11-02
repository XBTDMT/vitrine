import Foundation
import SQLite3
import UniformTypeIdentifiers

/// Everything the Diagnostics window shows, measured once (S-10, B-8, H-4).
struct DiagnosticsSnapshot: Sendable {
    let date: Date
    let claimed: [ClaimedType]
    let owners: [String: TypeOwner]
    let fileTypes: FileTypesSummary
    let extensions: ExtensionsSummary
    /// Every eligible Quick Look preview extension macOS would use, with its claims (for the Use Vitrine sheet).
    let installed: [InstalledExtension]
}

/// The live side of Diagnostics: runs the read-only listing tools, reads extension Info.plists, makes test files in a
/// private temporary folder and asks Quick Look about them. Never changes registration state; the repair actions
/// live in DiagnosticsRepair. Not used by the tests.
enum DiagnosticsProbe {
    static let pluginkitPath = "/usr/bin/pluginkit"
    static let qlmanagePath = "/usr/bin/qlmanage"

    // MARK: Running tools

    struct ToolResult: Sendable { let status: Int32; let output: String }

    /// Runs a tool with a deadline; stdout and stderr together.
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 30) -> ToolResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ToolResult(status: -1, output: "\(error.localizedDescription)") }
        let collected = OutputCollector()
        let reader = DispatchQueue(label: "diagnostics.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        p.waitUntilExit()
        return ToolResult(status: p.terminationStatus, output: String(decoding: collected.data, as: UTF8.self))
    }

    private final class OutputCollector: @unchecked Sendable { var data = Data() }

    // MARK: Listings

    static func pluginRecords(allCopies: Bool) -> [PluginRecord] {
        let args = ["-m"] + (allCopies ? ["-A", "-D"] : []) + ["-v", "-p", "com.apple.quicklook.preview"]
        return PluginKitParser.records(from: run(pluginkitPath, args).output)
    }

    /// macOS's own previewers (`qlmanage -m plugins`). The call takes ~15 s (measured 2026-10-30) and the list only
    /// changes with a system update, so it is kept for the session once it comes back non-empty.
    static func generators() -> [String: String] {
        if let cached = GeneratorCache.shared.value { return cached }
        var map: [String: String] = [:]
        for _ in 0..<2 where map.isEmpty {
            map = QuickLookParser.generators(from: run(qlmanagePath, ["-m", "plugins"], timeout: 45).output)
        }
        if !map.isEmpty { GeneratorCache.shared.value = map }
        return map
    }

    private final class GeneratorCache: @unchecked Sendable {
        static let shared = GeneratorCache()
        private let lock = NSLock()
        private var _value: [String: String]?
        var value: [String: String]? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    static func installed(_ records: [PluginRecord]) -> [InstalledExtension] {
        records.map { rec in
            var info: [String: Any] = [:], appName = "", appVersion = ""
            if let path = rec.path {
                info = NSDictionary(contentsOf: URL(fileURLWithPath: path).appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
                if let app = rec.parentAppPath,
                   let appInfo = NSDictionary(contentsOf: URL(fileURLWithPath: app).appending(path: "Contents/Info.plist")) as? [String: Any] {
                    appName = appInfo["CFBundleDisplayName"] as? String ?? appInfo["CFBundleName"] as? String
                        ?? ((app as NSString).lastPathComponent as NSString).deletingPathExtension
                    appVersion = appInfo["CFBundleShortVersionString"] as? String ?? ""
                }
            }
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? rec.identifier
            return InstalledExtension(record: rec, displayName: name, appName: appName.isEmpty ? name : appName,
                                      appVersion: appVersion, claims: InstalledExtension.claims(fromInfo: info))
        }
    }

    /// The types this build of Vitrine claims: its own PlugIns' QLSupportedContentTypes (generated from
    /// Config/uti-table.json by tools/gen_utis.py). Falls back to the copies pluginkit returns when the running app
    /// carries no extensions.
    static func claimedTypes(fallback: [InstalledExtension]) -> [ClaimedType] {
        var out: [ClaimedType] = []
        func add(id: String, claims: [String]) {
            let family = Diagnostics.identifiers.first { $0.0 == id }?.1 ?? id.components(separatedBy: ".").last?.capitalized ?? id
            for c in claims where !out.contains(where: { $0.uti == c }) { out.append(ClaimedType(uti: c, extensionID: id, family: family)) }
        }
        if let dir = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for appex in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where appex.pathExtension == "appex" {
                guard let info = NSDictionary(contentsOf: appex.appending(path: "Contents/Info.plist")) as? [String: Any],
                      let id = info["CFBundleIdentifier"] as? String,
                      ((info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String) == "com.apple.quicklook.preview"
                else { continue }
                add(id: id, claims: InstalledExtension.claims(fromInfo: info))
            }
        }
        if out.isEmpty {
            for e in fallback where e.maker == .vitrine && e.identifier.hasPrefix(InstalledExtension.vitrinePrefixes[0]) {
                add(id: e.identifier, claims: e.claims)
            }
        }
        // Keep the extension order of Diagnostics.identifiers.
        let order = Diagnostics.identifiers.map(\.0)
        return out.enumerated().sorted { a, b in
            let x = order.firstIndex(of: a.element.extensionID) ?? order.count, y = order.firstIndex(of: b.element.extensionID) ?? order.count
            return (x, a.offset) < (y, b.offset)
        }.map(\.element)
    }

    // MARK: The probe

    /// Asks Quick Look about one test file per claimed type: `qlmanage -p -o <dir> <files…>` computes previews into a
    /// folder without showing anything; a file macOS's own previewer draws is written out, and a file an extension
    /// answers for is reported as "did not produce any preview". The files are invented and deleted afterwards.
    static func probe(_ types: [String]) -> [String: TypeProbe] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "vitrine-diagnostics-\(UUID().uuidString)")
        let samples = root.appending(path: "samples"), out = root.appending(path: "out")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: samples, withIntermediateDirectories: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            let why = String(localized: "The test folder could not be made: \(error.localizedDescription)",
                             comment: "Diagnostics: why file types were not asked; the system's error message")
            return Dictionary(uniqueKeysWithValues: types.map { ($0, TypeProbe(uti: $0, sampleExtension: nil, resolvedType: nil, wellFormed: false, answer: nil, skippedBecause: why)) })
        }
        var made: [(uti: String, url: URL, ext: String?, wellFormed: Bool)] = []
        var results: [String: TypeProbe] = [:]
        for (i, uti) in types.enumerated() {
            switch SampleFile.make(uti: uti, index: i, in: samples) {
            case .made(let url, let ext, let wellFormed): made.append((uti, url, ext, wellFormed))
            case .skipped(let why):
                results[uti] = TypeProbe(uti: uti, sampleExtension: nil, resolvedType: nil, wellFormed: false, answer: nil, skippedBecause: why)
            }
        }
        guard !made.isEmpty else { return results }
        // qlmanage stops part-way through a list on some files (measured 2026-10-30: an uncaught "key cannot be nil"
        // exception, exit 6, on test .fs, .r and .provisionprofile files, losing every later answer), so files go in
        // small batches, several batches at once, and a batch that loses answers is settled again (see `settle`).
        let answers = ProbeAnswers()
        @Sendable func ask(_ urls: [URL], timeout: TimeInterval) {
            let result = run(qlmanagePath, ["-p", "-o", out.path] + urls.map(\.path), timeout: timeout)
            if ProcessInfo.processInfo.environment["VITRINE_DIAGNOSE_RAW"] != nil {
                FileHandle.standardError.write(Data("qlmanage exit \(result.status) for \(urls.map(\.lastPathComponent))\n\(result.output)\n".utf8))
            }
            answers.record(QuickLookParser.probeLines(from: result.output), status: result.status, for: urls.map(\.lastPathComponent))
        }
        // Ask a batch; ask again for what is left while that makes progress, and split a batch that makes none, so
        // a file that stops qlmanage ends up asked alone and costs only its own answer.
        @Sendable func settle(_ batch: [URL]) {
            ask(batch, timeout: 60)
            let missing = batch.filter { answers.line(for: $0.lastPathComponent) == nil }
            if missing.isEmpty || (missing.count == 1 && batch.count == 1) { return }
            if missing.count < batch.count { settle(missing); return }
            let half = missing.count / 2
            settle(Array(missing[..<half])); settle(Array(missing[half...]))
        }
        let urls = made.map(\.url)
        let batches = stride(from: 0, to: urls.count, by: 8).map { Array(urls[$0..<min($0 + 8, urls.count)]) }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 6
        for batch in batches { queue.addOperation { settle(batch) } }
        queue.waitUntilAllOperationsAreFinished()
        let lines = answers.lines, lastStatus = answers.statuses
        for m in made {
            let resolved = (try? m.url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            let answer = lines[m.url.lastPathComponent]
            let status = lastStatus[m.url.lastPathComponent] ?? 0
            results[m.uti] = TypeProbe(uti: m.uti, sampleExtension: m.ext, resolvedType: resolved, wellFormed: m.wellFormed,
                                       answer: answer,
                                       skippedBecause: answer == nil ? String(localized: "Quick Look stopped on the test file without an answer (qlmanage exit \(status)).",
                                                                              comment: "Diagnostics: why a file type was not asked; qlmanage is the tool, then its exit code") : nil)
        }
        return results
    }

    private final class GeneratorBox: @unchecked Sendable { var value: [String: String] = [:] }

    /// Answers gathered from batches that run at the same time.
    private final class ProbeAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String: QuickLookParser.ProbeLine] = [:], _statuses: [String: Int32] = [:]
        func record(_ new: [String: QuickLookParser.ProbeLine], status: Int32, for names: [String]) {
            lock.withLock {
                _lines.merge(new) { a, _ in a }
                for n in names { _statuses[n] = status }
            }
        }
        func line(for name: String) -> QuickLookParser.ProbeLine? { lock.withLock { _lines[name] } }
        var lines: [String: QuickLookParser.ProbeLine] { lock.withLock { _lines } }
        var statuses: [String: Int32] { lock.withLock { _statuses } }
    }

    // MARK: Everything

    static func snapshot(ownApp: String = Bundle.main.bundlePath) -> DiagnosticsSnapshot {
        let elected = pluginRecords(allCopies: false)
        let all = pluginRecords(allCopies: true)
        let installed = installed(elected)
        let claimed = claimedTypes(fallback: installed)
        // The generator list and the probe are independent; ask both at once.
        let gen = GeneratorBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) { gen.value = generators() }
        let probes = probe(claimed.map(\.uti))
        group.wait()
        let resolver = OwnerResolver(extensions: installed, generators: gen.value,
                                     conforms: { a, b in
                                         guard let x = UTType(a), let y = UTType(b) else { return false }
                                         return x.conforms(to: y)
                                     },
                                     describe: { UTType($0)?.localizedDescription },
                                     vitrineClaims: Set(claimed.map(\.uti)))
        var owners: [String: TypeOwner] = [:]
        for c in claimed { owners[c.uti] = resolver.owner(of: c, probe: probes[c.uti]) }
        let fileTypes = FileTypesSummary.make(claimed: claimed, owners: owners, extensionsOf: { extensions(of: $0) })
        let extensions = ExtensionsSummary.make(elected: elected, all: all, ownApp: ownApp, expected: Diagnostics.identifiers)
        return DiagnosticsSnapshot(date: Date(), claimed: claimed, owners: owners, fileTypes: fileTypes,
                                   extensions: extensions, installed: installed.filter { $0.record.isEligible })
    }

    static func extensions(of uti: String) -> [String] {
        UTType(uti)?.tags[.filenameExtension] ?? []
    }
}

/// Invented test files, one per type. A file is well-formed when macOS's own previewer would accept it: any text for
/// a text type, an empty but valid ZIP, tar, gzip, bzip2 or SQLite file, a folder, a TextBundle. Other binary types
/// get a placeholder, which the resolver trusts only where macOS has no previewer of its own.
enum SampleFile {
    enum Outcome { case made(URL, ext: String?, wellFormed: Bool), skipped(String) }

    static func make(uti: String, index: Int, in dir: URL) -> Outcome {
        let fm = FileManager.default
        if uti == UTType.folder.identifier {
            let url = dir.appending(path: "t\(index)")
            return (try? fm.createDirectory(at: url, withIntermediateDirectories: false)) != nil ? .made(url, ext: nil, wellFormed: true)
                : .skipped(String(localized: "The test folder could not be made.", comment: "Diagnostics: why folders were not asked"))
        }
        guard let type = UTType(uti) else {
            return .skipped(String(localized: "macOS does not know this type on this Mac, so no file can have it.", comment: "Diagnostics: why a file type was not asked"))
        }
        guard let ext = type.preferredFilenameExtension else {
            return .skipped(String(localized: "No filename extension gives a file this type, so macOS cannot be asked with a test file.",
                                   comment: "Diagnostics: why a file type was not asked"))
        }
        let url = dir.appending(path: "t\(index).\(ext)")
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) {
            // A fake app could be registered with Launch Services by being looked at; never make one.
            return .skipped(String(localized: "A test app is never made, so that nothing new is registered with macOS.", comment: "Diagnostics: why apps were not asked"))
        }
        do {
            // The type macOS gives a file with this extension decides the content (public.markdown's .md is
            // net.daringfireball.markdown on disk); an XML property list is a valid file for every plist type.
            let onDisk = UTType(filenameExtension: ext) ?? type
            if [type, onDisk].contains(where: { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) || $0.conforms(to: .propertyList) }) {
                try textSample(for: onDisk.conforms(to: .propertyList) ? .propertyList : onDisk).write(to: url, atomically: true, encoding: .utf8)
                return .made(url, ext: ext, wellFormed: true)
            }
            if uti == "org.textbundle.package" {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                try "# Sample\n".write(to: url.appending(path: "text.md"), atomically: true, encoding: .utf8)
                try #"{"version":2}"#.write(to: url.appending(path: "info.json"), atomically: true, encoding: .utf8)
                return .made(url, ext: ext, wellFormed: true)
            }
            if let bytes = binarySample(for: type) {
                try Data(bytes).write(to: url)
                return .made(url, ext: ext, wellFormed: true)
            }
            if type.conforms(to: UTType("public.database") ?? .data), uti.contains("sqlite"), makeSQLite(at: url) {
                return .made(url, ext: ext, wellFormed: true)
            }
            if type.conforms(to: .directory) || type.conforms(to: .package) {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return .made(url, ext: ext, wellFormed: false)
            }
            try Data("vitrine diagnostics test file\n".utf8).write(to: url)
            return .made(url, ext: ext, wellFormed: false)
        } catch {
            return .skipped(String(localized: "The test file could not be written: \(error.localizedDescription)",
                                   comment: "Diagnostics: why a file type was not asked; the system's error message"))
        }
    }

    static func textSample(for type: UTType) -> String {
        if type.conforms(to: .svg) { return #"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>"# + "\n" }
        if type.conforms(to: .json) { return "{\"sample\": 1}\n" }
        if type.conforms(to: .propertyList) || type.conforms(to: .xml) {
            return #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>sample</key><integer>1</integer></dict></plist>"# + "\n"
        }
        if type.conforms(to: .commaSeparatedText) { return "name,count\nalpha,1\n" }
        if type.conforms(to: .tabSeparatedText) { return "name\tcount\nalpha\t1\n" }
        return "sample\n"
    }

    /// Empty but valid archives: ZIP end-of-central-directory record, a tar end marker, gzip and bzip2 of nothing.
    static func binarySample(for type: UTType) -> [UInt8]? {
        let zip = UTType("public.zip-archive"), tar = UTType("public.tar-archive")
        let gzip = UTType("org.gnu.gnu-zip-archive"), bzip2 = UTType("public.bzip2-archive")
        let tarGz = UTType("org.gnu.gnu-zip-tar-archive"), tarBz = UTType("public.tar-bzip2-archive")
        if let tarGz, type.conforms(to: tarGz) { return nil }
        if let tarBz, type.conforms(to: tarBz) { return nil }
        if let zip, type.conforms(to: zip) { return [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18) }
        if let tar, type.conforms(to: tar) { return [UInt8](repeating: 0, count: 1024) }
        if let gzip, type == gzip { return [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03, 0x03, 0x00, 0, 0, 0, 0, 0, 0, 0, 0] }
        if let bzip2, type == bzip2 { return [0x42, 0x5A, 0x68, 0x39, 0x17, 0x72, 0x45, 0x38, 0x50, 0x90, 0, 0, 0, 0] }
        return nil
    }

    static func makeSQLite(at url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, "CREATE TABLE sample (name TEXT, count INTEGER); INSERT INTO sample VALUES ('alpha', 1);", nil, nil, nil) == SQLITE_OK
    }
}
