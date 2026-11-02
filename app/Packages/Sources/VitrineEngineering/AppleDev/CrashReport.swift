import Foundation

/// A crash report: the JSON `.ips` macOS 12 and later write (a header line, then a body), or a legacy text
/// `.crash` (best effort). The app and system it came from, the exception and why the process ended, the crashed
/// thread's top frames (image, symbol, offset) and how many binary images were loaded. roadmap: S-22
public struct CrashReportSummary: Sendable, Equatable {
    /// The most frames kept for the crashed thread and for the last exception's backtrace.
    public static let maxFrames = 30

    /// How the report is written. roadmap: S-22
    public enum Format: String, Sendable, Equatable {
        /// The `.ips` JSON header and body.
        case json
        /// The text layout of `.crash` files and of `.ips` files before macOS 12.
        case legacyText
    }

    /// One stack frame. roadmap: S-22
    public struct Frame: Sendable, Equatable {
        public var index: Int
        /// The binary the code is in ("Notes Lite", "libsystem_kernel.dylib"); nil when the report does not say.
        public var image: String?
        /// The function, when the report is symbolicated.
        public var symbol: String?
        /// Bytes into `symbol`.
        public var symbolOffset: Int?
        /// Bytes into the image, when no symbol is given (or as the report also states it).
        public var imageOffset: Int?
        /// The address as the legacy report writes it ("0x00000001000f1234").
        public var address: String?
        public var sourceFile: String?
        public var sourceLine: Int?
    }

    public var format: Format
    /// The `.ips` header's `bug_type` ("309" for a crash).
    public var bugType: String?
    /// "Crash", "Hang (stackshot)" …
    public var kind: String
    public var appName: String?
    public var bundleIdentifier: String?
    public var appVersion: String?
    public var buildVersion: String?
    public var osVersion: String?
    public var incidentIdentifier: String?
    /// The time as the report writes it.
    public var timestamp: String?
    public var processPath: String?
    public var processID: Int?
    public var parentProcess: String?
    public var cpuType: String?
    public var hardwareModel: String?
    /// "EXC_BAD_ACCESS", "EXC_CRASH" …
    public var exceptionType: String?
    /// "SIGSEGV", "SIGABRT" …
    public var signal: String?
    public var exceptionCodes: String?
    public var exceptionSubtype: String?
    /// What the exception usually means, in plain words.
    public var exceptionExplanation: String?
    /// "Namespace SIGNAL, Code 6, Abort trap: 6".
    public var terminationReason: String?
    /// Application Specific Information: messages the app or a library left just before the crash.
    public var applicationSpecificInformation: [String]
    /// The crashed (triggered) thread's number.
    public var crashedThread: Int?
    /// The crashed thread's name or dispatch queue.
    public var crashedThreadName: String?
    /// The crashed thread's top frames, at most `maxFrames`.
    public var frames: [Frame]
    /// The crashed thread had more frames than `frames` holds.
    public var framesTruncated: Bool
    /// The backtrace of the uncaught exception that ended the app, when the report carries one (top `maxFrames`).
    public var lastExceptionFrames: [Frame]
    public var threadCount: Int
    public var binaryImageCount: Int
    public var warnings: [AppleDevWarning]

    /// "EXC_BAD_ACCESS (SIGSEGV)": codes as the report writes them, never translated.
    var exceptionText: String { [exceptionType, signal.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ") }

    public var headline: String {
        let who = appName ?? bundleIdentifier
            ?? String(localized: "an app", bundle: .module, comment: "Crash report headline when the report names no app.")
        let kind = kind, what = exceptionText
        if what.isEmpty {
            return String(localized: "\(kind) — \(who)", bundle: .module, comment: "Headline of a crash report card: the kind of report and the app.")
        }
        return String(localized: "\(kind) — \(who): \(what)", bundle: .module,
                      comment: "Headline of a crash report card: the kind of report, the app, then the exception code such as EXC_BAD_ACCESS (SIGSEGV).")
    }

    public var facts: [AppleDevFact] {
        var out: [AppleDevFact] = []
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { out.append(.init(label, value)) } }
        add(String(localized: "App", bundle: .module, comment: "Fact label on a crash report card."), appName)
        add(String(localized: "Bundle ID", bundle: .module, comment: "Fact label on a crash report card."), bundleIdentifier)
        add(String(localized: "Version", bundle: .module, comment: "Fact label on a crash report card."),
            [appVersion, buildVersion.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
        add(String(localized: "OS", bundle: .module, comment: "Fact label on a crash report card: the operating system version."), osVersion)
        add(String(localized: "Hardware", bundle: .module, comment: "Fact label on a crash report card: the Mac or device model."), hardwareModel)
        add(String(localized: "CPU", bundle: .module, comment: "Fact label on a crash report card: the processor type."), cpuType)
        add(String(localized: "Date", bundle: .module, comment: "Fact label on a crash report card: when it happened."), timestamp)
        add(String(localized: "Incident", bundle: .module, comment: "Fact label on a crash report card: the report's identifier."), incidentIdentifier)
        add(String(localized: "Exception", bundle: .module, comment: "Fact label on a crash report card."), exceptionText)
        add(String(localized: "Codes", bundle: .module, comment: "Fact label on a crash report card: the exception codes."), exceptionCodes)
        add(String(localized: "Subtype", bundle: .module, comment: "Fact label on a crash report card: the exception subtype."), exceptionSubtype)
        add(String(localized: "Meaning", bundle: .module, comment: "Fact label on a crash report card: what the exception usually means."), exceptionExplanation)
        add(String(localized: "Termination", bundle: .module, comment: "Fact label on a crash report card: why the process ended."), terminationReason)
        add(String(localized: "Crashed thread", bundle: .module, comment: "Fact label on a crash report card."),
            crashedThread.map { n in "\(n)" + (crashedThreadName.map { "  \($0)" } ?? "") })
        add(String(localized: "Threads", bundle: .module, comment: "Fact label on a crash report card: how many threads the app had."),
            threadCount > 0 ? threadCount.formatted() : nil)
        add(String(localized: "Binary images", bundle: .module, comment: "Fact label on a crash report card: how many libraries and frameworks were loaded."),
            binaryImageCount > 0 ? binaryImageCount.formatted() : nil)
        add(String(localized: "Process", bundle: .module, comment: "Fact label on a crash report card: the program's path."), processPath)
        add(String(localized: "Parent process", bundle: .module, comment: "Fact label on a crash report card: the process that started the app."), parentProcess)
        return out
    }
}

enum CrashReportReader {
    static let maxThreads = 4_096
    static let maxImages = 100_000
    static let maxASI = 50

    static func read(_ data: Data) -> CrashReportSummary? {
        let bytes = [UInt8](data)
        guard !bytes.contains(0) else { return nil }
        // An .ips: the header is the first line, a JSON object; the body follows.
        let start = bytes.firstIndex { !AppleDevReader.isSpace($0) } ?? 0
        if start < bytes.count, bytes[start] == UInt8(ascii: "{") {
            let newline = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
            let headerData = Data(bytes[start..<newline])
            if let header = AppleDevJSON.object(headerData), isIPSHeader(header) {
                let body = Data(bytes[min(newline + 1, bytes.count)...])
                return fromIPS(header: header, body: body)
            }
            // A body without a separate header line (the whole file is one JSON object).
            if let whole = AppleDevJSON.object(Data(bytes)), whole["threads"] != nil || whole["exception"] != nil {
                return fromJSONBody(whole, header: [:], warnings: [])
            }
            return nil
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return fromText(text, header: [:])
    }

    /// The `.ips` header line names the report: its type, the app or the incident.
    static func isIPSHeader(_ header: [String: Any]) -> Bool {
        ["bug_type", "app_name", "incident_id", "os_version", "bundleID"].contains { header[$0] != nil }
    }

    static func looksLikeLegacyText(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        return head.hasPrefix("Process:") || head.hasPrefix("Incident Identifier:")
            || (head.contains("\nException Type:") && head.contains("\nProcess:"))
    }

    // MARK: JSON

    static func fromIPS(header: [String: Any], body: Data) -> CrashReportSummary? {
        let trimmed = body.drop { AppleDevReader.isSpace($0) }
        if trimmed.isEmpty {
            return fromJSONBody([:], header: header, warnings: [.init(.caution, String(
                localized: "The report holds only its header line, so the crash itself is not described.",
                bundle: .module, comment: "Warning on a crash report card."))])
        }
        if trimmed.first == UInt8(ascii: "{") {
            if let object = AppleDevJSON.object(Data(trimmed)) { return fromJSONBody(object, header: header, warnings: []) }
            return fromJSONBody([:], header: header, warnings: [.init(.caution, String(
                localized: "The report's body is damaged or cut short; only its header line could be read.",
                bundle: .module, comment: "Warning on a crash report card."))])
        }
        // Reports before macOS 12 (and iOS 14): a JSON header line, then the legacy text.
        return fromText(String(decoding: trimmed, as: UTF8.self), header: header)
    }

    static func fromJSONBody(_ b: [String: Any], header h: [String: Any], warnings start: [AppleDevWarning]) -> CrashReportSummary {
        var warnings = start
        let bundleInfo = b["bundleInfo"] as? [String: Any] ?? [:]
        let exception = b["exception"] as? [String: Any] ?? [:]
        let termination = b["termination"] as? [String: Any] ?? [:]
        let osVersion: String? = {
            if let os = b["osVersion"] as? [String: Any] {
                let train = AppleDevJSON.string(os["train"]), build = AppleDevJSON.string(os["build"])
                if let train { return build.map { "\(train) (\($0))" } ?? train }
            }
            return AppleDevJSON.string(h["os_version"])
        }()

        // Binary images: name or the path's last component.
        let imagesRaw = b["usedImages"] as? [Any] ?? []
        let images: [String?] = imagesRaw.prefix(maxImages).map { item in
            guard let d = item as? [String: Any] else { return nil }
            if let name = AppleDevJSON.string(d["name"]) { return name }
            return AppleDevJSON.string(d["path"]).map { ($0 as NSString).lastPathComponent }
        }

        let threads = (b["threads"] as? [Any] ?? []).prefix(maxThreads).compactMap { $0 as? [String: Any] }
        var crashed = AppleDevJSON.int(b["faultingThread"])
        if crashed == nil { crashed = threads.firstIndex { AppleDevJSON.bool($0["triggered"]) == true } }
        var frames: [CrashReportSummary.Frame] = [], framesTruncated = false, threadName: String?
        if let crashed, crashed >= 0, crashed < threads.count {
            let thread = threads[crashed]
            threadName = AppleDevJSON.string(thread["name"]) ?? AppleDevJSON.string(thread["queue"])
            let raw = thread["frames"] as? [Any] ?? []
            frames = jsonFrames(raw, images: images)
            framesTruncated = raw.count > CrashReportSummary.maxFrames
        }
        let lastException = jsonFrames(b["lastExceptionBacktrace"] as? [Any] ?? [], images: images)

        var asi: [String] = []
        if let d = b["asi"] as? [String: Any] {
            for (image, messages) in d.sorted(by: { $0.key < $1.key }) {
                for case let m as String in (messages as? [Any] ?? [messages]) where asi.count < maxASI {
                    asi.append("\(image): \(AppleDevText.clip(m, 500))")
                }
            }
        }

        let termText: String? = {
            guard !termination.isEmpty else { return nil }
            var parts: [String] = []
            if let ns = AppleDevJSON.string(termination["namespace"]) { parts.append("Namespace \(ns)") }
            if let code = AppleDevJSON.string(termination["code"]) { parts.append("Code \(code)") }
            if let indicator = AppleDevJSON.string(termination["indicator"]) { parts.append(indicator) }
            // "Namespace" and "Code" are the report's own words, kept as a legacy report prints them.
            if let by = AppleDevJSON.string(termination["byProc"]) {
                parts.append(String(localized: "by \(by)", bundle: .module, comment: "End of a crash report's termination reason: the process that ended the app."))
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }()
        let namespace = AppleDevJSON.string(termination["namespace"])
        let type = AppleDevJSON.string(exception["type"])
        let signal = AppleDevJSON.string(exception["signal"])
        let codes = AppleDevJSON.string(exception["codes"])
        let subtype = AppleDevJSON.string(exception["subtype"])

        let bugType = AppleDevJSON.string(h["bug_type"])
        let threadCount = threads.count
        if !b.isEmpty, threads.isEmpty || crashed == nil, isCrash(bugType) {
            warnings.append(.init(.caution, String(
                localized: "The report names no crashed thread, so it does not show where the app stopped.",
                bundle: .module, comment: "Warning on a crash report card.")))
        }
        warnings += commonWarnings(namespace: namespace, codes: codes, frames: frames, appName: AppleDevJSON.string(h["app_name"]) ?? AppleDevJSON.string(b["procName"]))
        if AppleDevJSON.int(h["roots_installed"]).map({ $0 != 0 }) == true {
            warnings.append(.init(.caution, String(
                localized: "The system had modified system files installed (roots) when this happened, so the crash may not come from the app.",
                bundle: .module, comment: "Warning on a crash report card. “Roots” are replacement system files installed for testing.")))
        }

        return CrashReportSummary(
            format: .json, bugType: bugType, kind: kindName(bugType),
            appName: AppleDevJSON.string(h["app_name"]) ?? AppleDevJSON.string(h["name"]) ?? AppleDevJSON.string(b["procName"]),
            bundleIdentifier: AppleDevJSON.string(h["bundleID"]) ?? AppleDevJSON.string(bundleInfo["CFBundleIdentifier"]),
            appVersion: AppleDevJSON.string(h["app_version"]) ?? AppleDevJSON.string(bundleInfo["CFBundleShortVersionString"]),
            buildVersion: AppleDevJSON.string(h["build_version"]) ?? AppleDevJSON.string(bundleInfo["CFBundleVersion"]),
            osVersion: osVersion,
            incidentIdentifier: AppleDevJSON.string(h["incident_id"]) ?? AppleDevJSON.string(b["incident"]),
            timestamp: AppleDevJSON.string(h["timestamp"]) ?? AppleDevJSON.string(b["captureTime"]),
            processPath: AppleDevJSON.string(b["procPath"]), processID: AppleDevJSON.int(b["pid"]),
            parentProcess: AppleDevJSON.string(b["parentProc"]), cpuType: AppleDevJSON.string(b["cpuType"]),
            hardwareModel: AppleDevJSON.string(b["modelCode"]),
            exceptionType: type, signal: signal, exceptionCodes: codes, exceptionSubtype: subtype,
            exceptionExplanation: explanation(type: type, signal: signal, codes: codes, subtype: subtype),
            terminationReason: termText, applicationSpecificInformation: asi,
            crashedThread: crashed, crashedThreadName: threadName, frames: frames, framesTruncated: framesTruncated,
            lastExceptionFrames: lastException, threadCount: threadCount, binaryImageCount: min(imagesRaw.count, maxImages),
            warnings: warnings.sorted { $0.level > $1.level })
    }

    static func jsonFrames(_ raw: [Any], images: [String?]) -> [CrashReportSummary.Frame] {
        raw.prefix(CrashReportSummary.maxFrames).enumerated().compactMap { index, item in
            guard let f = item as? [String: Any] else { return nil }
            let imageIndex = AppleDevJSON.int(f["imageIndex"])
            let image = imageIndex.flatMap { $0 >= 0 && $0 < images.count ? images[$0] : nil }
            return .init(index: index, image: image, symbol: AppleDevJSON.string(f["symbol"]).map { AppleDevText.clip($0, 500) },
                         symbolOffset: AppleDevJSON.int(f["symbolLocation"]), imageOffset: AppleDevJSON.int(f["imageOffset"]),
                         address: nil, sourceFile: AppleDevJSON.string(f["sourceFile"]), sourceLine: AppleDevJSON.int(f["sourceLine"]))
        }
    }

    // MARK: Legacy text

    static func fromText(_ text: String, header h: [String: Any]) -> CrashReportSummary? {
        var fields: [String: String] = [:]
        var frames: [CrashReportSummary.Frame] = [], framesTruncated = false
        var lastException: [CrashReportSummary.Frame] = []
        var crashedThread: Int?, threadName: String?
        var threadNumbers = Set<Int>(), imageCount = 0, asi: [String] = []
        enum Section { case header, crashedThread, otherThread, lastException, images, asi, other }
        var section = Section.header
        var lines = 0

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lines += 1
            if lines > 500_000 { break }
            let line = String(raw.prefix(4096))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if section != .header { section = .other }
                continue
            }
            if trimmed.hasPrefix("Thread "), let number = threadNumber(trimmed) {
                threadNumbers.insert(number)
                if trimmed.contains("Crashed") {
                    crashedThread = number
                    section = .crashedThread
                    if let r = trimmed.range(of: "Crashed::") {
                        let rest = trimmed[r.upperBound...].trimmingCharacters(in: .whitespaces)
                        if !rest.isEmpty { threadName = rest.replacingOccurrences(of: "Dispatch queue: ", with: "") }
                    }
                } else if trimmed.contains(" name:") {
                    if let r = trimmed.range(of: " name:") {
                        let name = trimmed[r.upperBound...].trimmingCharacters(in: .whitespaces)
                        if crashedThread == number || fields["Crashed Thread"].flatMap({ Int($0.prefix { $0.isNumber }) }) == number {
                            threadName = name.replacingOccurrences(of: "Dispatch queue: ", with: "")
                        }
                    }
                } else {
                    section = .otherThread
                }
                continue
            }
            if trimmed.hasPrefix("Last Exception Backtrace") { section = .lastException; continue }
            if trimmed.hasPrefix("Binary Images:") { section = .images; continue }
            if trimmed.hasPrefix("Application Specific Information:") { section = .asi; continue }
            switch section {
            case .crashedThread:
                if let frame = textFrame(trimmed) {
                    if frames.count < CrashReportSummary.maxFrames { frames.append(frame) } else { framesTruncated = true }
                }
            case .lastException:
                if lastException.count < CrashReportSummary.maxFrames, let frame = textFrame(trimmed) { lastException.append(frame) }
            case .images:
                if trimmed.hasPrefix("0x") { imageCount += 1 }
            case .asi:
                if asi.count < maxASI { asi.append(AppleDevText.clip(trimmed, 500)) }
            case .header, .other, .otherThread:
                if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if key.count <= 40, fields[key] == nil, fields.count < 200 { fields[key] = value }
                }
            }
        }

        let process = fields["Process"]
        guard process != nil || fields["Exception Type"] != nil || fields["Incident Identifier"] != nil || !h.isEmpty else {
            return nil
        }
        var processName: String?, pid: Int?
        if let process {
            if let open = process.lastIndex(of: "["), process.hasSuffix("]") {
                processName = process[..<open].trimmingCharacters(in: .whitespaces)
                pid = Int(process[process.index(after: open)..<process.index(before: process.endIndex)])
            } else {
                processName = process
            }
        }
        var version = fields["Version"], build: String?
        if let v = version, let open = v.lastIndex(of: "("), v.hasSuffix(")") {
            build = String(v[v.index(after: open)..<v.index(before: v.endIndex)])
            version = v[..<open].trimmingCharacters(in: .whitespaces)
        }
        // "EXC_BAD_ACCESS (SIGSEGV)"
        var type = fields["Exception Type"], signal: String?
        if let t = type, let open = t.firstIndex(of: "("), t.hasSuffix(")") {
            signal = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
            type = t[..<open].trimmingCharacters(in: .whitespaces)
        }
        if crashedThread == nil, let c = fields["Crashed Thread"] { crashedThread = Int(c.prefix { $0.isNumber }) }
        if threadName == nil, let c = fields["Crashed Thread"], let r = c.range(of: "Dispatch queue:") {
            threadName = c[r.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        let codes = fields["Exception Codes"], subtype = fields["Exception Subtype"]
        let termination = fields["Termination Reason"]
        let bugType = AppleDevJSON.string(h["bug_type"])
        let appName = AppleDevJSON.string(h["app_name"]) ?? processName

        var warnings: [AppleDevWarning] = []
        if crashedThread == nil || frames.isEmpty {
            warnings.append(.init(.caution, String(
                localized: "No crashed thread's frames were found, so the report does not show where the app stopped.",
                bundle: .module, comment: "Warning on a crash report card.")))
        }
        let namespace = termination.flatMap { t -> String? in
            guard let r = t.range(of: "Namespace ") else { return nil }
            return String(t[r.upperBound...].prefix { $0 != "," && $0 != " " })
        }
        warnings += commonWarnings(namespace: namespace, codes: codes, frames: frames, appName: appName)

        return CrashReportSummary(
            format: .legacyText, bugType: bugType, kind: kindName(bugType),
            appName: appName,
            bundleIdentifier: AppleDevJSON.string(h["bundleID"]) ?? fields["Identifier"],
            appVersion: AppleDevJSON.string(h["app_version"]) ?? version,
            buildVersion: AppleDevJSON.string(h["build_version"]) ?? build,
            osVersion: fields["OS Version"] ?? AppleDevJSON.string(h["os_version"]),
            incidentIdentifier: fields["Incident Identifier"] ?? AppleDevJSON.string(h["incident_id"]),
            timestamp: fields["Date/Time"] ?? AppleDevJSON.string(h["timestamp"]),
            processPath: fields["Path"], processID: pid, parentProcess: fields["Parent Process"],
            cpuType: fields["Code Type"], hardwareModel: fields["Hardware Model"] ?? fields["Model"],
            exceptionType: type, signal: signal, exceptionCodes: codes, exceptionSubtype: subtype,
            exceptionExplanation: explanation(type: type, signal: signal, codes: codes, subtype: subtype),
            terminationReason: termination, applicationSpecificInformation: asi,
            crashedThread: crashedThread, crashedThreadName: threadName, frames: frames, framesTruncated: framesTruncated,
            lastExceptionFrames: lastException, threadCount: threadNumbers.count, binaryImageCount: imageCount,
            warnings: warnings.sorted { $0.level > $1.level })
    }

    /// "Thread 3 Crashed:: …", "Thread 3 name: …", "Thread 3:" → 3.
    static func threadNumber(_ line: String) -> Int? {
        let digits = line.dropFirst("Thread ".count).prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 7 else { return nil }
        return Int(digits)
    }

    /// "1   Notes Lite   0x0000000100001234 main + 40 (main.swift:12)" or "… 0x1000f1234 0x100000000 + 4660".
    static func textFrame(_ line: String) -> CrashReportSummary.Frame? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 7, let index = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        // The address is the first "0x" after whitespace (image names may hold spaces; columns may be tabs).
        var addressStart: Substring.Index?
        var i = rest.startIndex
        while i < rest.endIndex {
            let next = rest.index(after: i)
            if rest[i].isWhitespace, rest[next...].hasPrefix("0x") { addressStart = next; break }
            i = next
        }
        guard let addressStart else { return nil }
        let image = rest[..<addressStart].trimmingCharacters(in: .whitespaces)
        let tail = rest[addressStart...]
        let address = String(tail.prefix { !$0.isWhitespace })
        var detail = tail.dropFirst(address.count).trimmingCharacters(in: .whitespaces)
        var sourceFile: String?, sourceLine: Int?
        if detail.hasSuffix(")"), let open = detail.lastIndex(of: "(") {
            let inside = detail[detail.index(after: open)..<detail.index(before: detail.endIndex)]
            if let colon = inside.lastIndex(of: ":"), let n = Int(inside[inside.index(after: colon)...]) {
                sourceFile = String(inside[..<colon])
                sourceLine = n
                detail = detail[..<open].trimmingCharacters(in: .whitespaces)
            }
        }
        var symbol: String?, symbolOffset: Int?, imageOffset: Int?
        if let plus = detail.range(of: " + ", options: .backwards) {
            let base = String(detail[..<plus.lowerBound]), offset = Int(detail[plus.upperBound...].trimmingCharacters(in: .whitespaces))
            if base.hasPrefix("0x") { imageOffset = offset } else { symbol = base; symbolOffset = offset }
        } else if !detail.isEmpty, !detail.hasPrefix("0x") {
            symbol = detail
        }
        return .init(index: index, image: image.isEmpty ? nil : image, symbol: symbol.map { AppleDevText.clip($0, 500) },
                     symbolOffset: symbolOffset, imageOffset: imageOffset, address: address,
                     sourceFile: sourceFile, sourceLine: sourceLine)
    }

    // MARK: Meaning

    static func isCrash(_ bugType: String?) -> Bool { bugType == nil || bugType == "309" || bugType == "109" }

    static func kindName(_ bugType: String?) -> String {
        switch bugType {
        case nil, "309", "109": String(localized: "Crash", bundle: .module, comment: "Kind of diagnostic report: an app crash.")
        case "210": String(localized: "Kernel panic", bundle: .module, comment: "Kind of diagnostic report: the whole system stopped.")
        case "288": String(localized: "Hang (stackshot)", bundle: .module, comment: "Kind of diagnostic report: an app stopped responding.")
        case "298": String(localized: "Memory pressure (Jetsam)", bundle: .module, comment: "Kind of diagnostic report: apps ended because memory ran low. Jetsam stays as is.")
        case let other?: String(localized: "Diagnostic report (type \(other))", bundle: .module, comment: "Kind of diagnostic report the preview does not name; the argument is its type number.")
        }
    }

    static func explanation(type: String?, signal: String?, codes: String?, subtype: String?) -> String? {
        let codeText = ((codes ?? "") + " " + (subtype ?? "")).lowercased()
        let memory = String(localized: "The app read or wrote memory it does not own.", bundle: .module, comment: "What a crash's exception usually means.")
        let abort = String(localized: "The app ended itself with abort(), most often after an uncaught exception or a failed assertion.", bundle: .module, comment: "What a crash's exception usually means. abort() stays as is.")
        let killed = String(localized: "The system killed the app.", bundle: .module, comment: "What a crash's exception usually means.")
        if codeText.contains("8badf00d") {
            return String(localized: "The system's watchdog ended the app because it stopped responding for too long (often at launch or resume).", bundle: .module, comment: "What a crash's exception usually means.")
        }
        switch type {
        case "EXC_BAD_ACCESS":
            if codeText.contains("at 0x0000000000000000") {
                return String(localized: "The app used memory at address zero: a pointer that was never set (a null pointer).", bundle: .module, comment: "What a crash's exception usually means.")
            }
            return String(localized: "The app read or wrote memory it does not own, for example through a freed or invalid pointer.", bundle: .module, comment: "What a crash's exception usually means.")
        case "EXC_BREAKPOINT":
            return String(localized: "The app stopped on a trap: in Swift usually a failed check such as unwrapping nil, an index out of range, an arithmetic overflow or a fatalError.", bundle: .module, comment: "What a crash's exception usually means. nil and fatalError stay as is.")
        case "EXC_BAD_INSTRUCTION":
            return String(localized: "The processor met an instruction it could not run; in Swift on Intel this is a failed runtime check.", bundle: .module, comment: "What a crash's exception usually means.")
        case "EXC_ARITHMETIC":
            return String(localized: "An arithmetic error, such as dividing an integer by zero.", bundle: .module, comment: "What a crash's exception usually means.")
        case "EXC_RESOURCE":
            return String(localized: "The app went over a resource limit (CPU, memory, wake-ups or disk writes).", bundle: .module, comment: "What a crash's exception usually means.")
        case "EXC_GUARD":
            return String(localized: "The app misused a protected resource, such as closing a file descriptor the system guards.", bundle: .module, comment: "What a crash's exception usually means.")
        case "EXC_CRASH":
            switch signal {
            case "SIGABRT": return abort
            case "SIGKILL": return killed
            default: return String(localized: "The process ended abnormally.", bundle: .module, comment: "What a crash's exception usually means.")
            }
        default:
            switch signal {
            case "SIGSEGV", "SIGBUS": return memory
            case "SIGABRT": return abort
            case "SIGILL", "SIGTRAP": return String(localized: "The app stopped on a trap or an instruction it could not run.", bundle: .module, comment: "What a crash's exception usually means.")
            case "SIGKILL": return killed
            default: return nil
            }
        }
    }

    static func commonWarnings(namespace: String?, codes: String?, frames: [CrashReportSummary.Frame], appName: String?) -> [AppleDevWarning] {
        var out: [AppleDevWarning] = []
        if namespace == "CODESIGNING" {
            out.append(.init(.danger, String(
                localized: "The system killed the app because its code signature was invalid: a file in the app was changed after signing, or the signature does not match.",
                bundle: .module, comment: "Warning on a crash report card.")))
        }
        if (codes ?? "").lowercased().contains("8badf00d") {
            out.append(.init(.caution, String(
                localized: "The watchdog ended the app for not responding (0x8badf00d): something blocks the main thread.",
                bundle: .module, comment: "Warning on a crash report card. 0x8badf00d is a code and stays as is.")))
        }
        if !frames.isEmpty {
            let appFrames = frames.filter { $0.image != nil && $0.image == appName }
            let checked = appFrames.isEmpty ? frames : appFrames
            if checked.allSatisfy({ $0.symbol == nil }) {
                out.append(.init(.caution, String(
                    localized: "The frames are not symbolicated (no function names). Open the report with the build's dSYM to see where in the code it stopped.",
                    bundle: .module, comment: "Warning on a crash report card. dSYM is the debug-symbols file Xcode makes with a build.")))
            }
        }
        return out
    }
}
