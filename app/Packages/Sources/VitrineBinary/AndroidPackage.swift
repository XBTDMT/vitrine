import Foundation
import VitrineArchive

/// An Android package (`.apk`): a zip whose `AndroidManifest.xml` is Android's binary XML, decoded here by our own
/// reader (no Android tools). The manifest gives the package, versions, SDK levels and permissions; the signature
/// schemes come from the zip itself (v1: `META-INF/*.RSA|DSA|EC`; v2 and later: the APK Signing Block before the
/// central directory). Certificates are listed, never verified, and nothing is installed or run. The app's label is
/// shown only when the manifest holds it as text: a label that points into `resources.arsc` is not resolved.
/// roadmap: S-8
public struct AndroidPackage: Sendable, Equatable {
    public let packageName: String?
    public let versionName: String?
    public let versionCode: Int64?
    public let minSDK: Int?
    public let targetSDK: Int?
    public let compileSDK: Int?
    /// The `android:label` text, when it is text (see `labelIsResource`).
    public let label: String?
    /// The label is a resource reference (`@string/app_name`) that would need `resources.arsc`; not resolved.
    public let labelIsResource: Bool
    /// `uses-permission` names, in manifest order, without repeats.
    public let permissions: [String]
    public let debuggable: Bool
    public let usesCleartextTraffic: Bool?
    public let allowsBackup: Bool?
    public let activityCount: Int
    public let serviceCount: Int
    public let receiverCount: Int
    public let providerCount: Int
    /// "v1 (JAR signing)", "v2+ (APK Signing Block)".
    public let signatureSchemes: [String]
    /// Certificates from the v1 signature block, as stored, never verified (S-16 follow-up B, G-34). Android signing
    /// certificates are self-signed by design: even a verified APK signature proves only that the holder of that key
    /// signed it, so a certificate's name is always its own claim, never who made the app. Android knows a signer by
    /// its certificate's digest (`sha256Fingerprint`).
    public let certificates: [CertificateSummary]
    /// CPU ABIs with native code (`lib/<abi>/`).
    public let nativeABIs: [String]
    public let listing: ArchiveListing

    /// Permissions Android itself rates dangerous (runtime permissions) or special, by their `android.permission.`
    /// names.
    public var dangerousPermissions: [String] { permissions.filter { Self.dangerous.contains($0) } }

    static let dangerous: Set<String> = Set([
        "READ_CALENDAR", "WRITE_CALENDAR", "CAMERA", "READ_CONTACTS", "WRITE_CONTACTS", "GET_ACCOUNTS",
        "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION", "RECORD_AUDIO",
        "READ_PHONE_STATE", "READ_PHONE_NUMBERS", "CALL_PHONE", "ANSWER_PHONE_CALLS", "READ_CALL_LOG", "WRITE_CALL_LOG",
        "ADD_VOICEMAIL", "USE_SIP", "PROCESS_OUTGOING_CALLS", "BODY_SENSORS", "BODY_SENSORS_BACKGROUND", "SEND_SMS",
        "RECEIVE_SMS", "READ_SMS", "RECEIVE_WAP_PUSH", "RECEIVE_MMS", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE",
        "ACCESS_MEDIA_LOCATION", "ACTIVITY_RECOGNITION", "READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_MEDIA_AUDIO",
        "READ_MEDIA_VISUAL_USER_SELECTED", "POST_NOTIFICATIONS", "NEARBY_WIFI_DEVICES", "BLUETOOTH_SCAN",
        "BLUETOOTH_CONNECT", "BLUETOOTH_ADVERTISE", "UWB_RANGING",
        // Special access: granted in Settings, each a known abuse route.
        "SYSTEM_ALERT_WINDOW", "REQUEST_INSTALL_PACKAGES", "BIND_ACCESSIBILITY_SERVICE", "BIND_DEVICE_ADMIN",
        "MANAGE_EXTERNAL_STORAGE", "PACKAGE_USAGE_STATS", "QUERY_ALL_PACKAGES", "BIND_NOTIFICATION_LISTENER_SERVICE",
        "READ_PRIVILEGED_PHONE_STATE", "WRITE_SETTINGS",
    ].map { "android.permission.\($0)" })
}

/// Reads an `.apk` from a file or bytes. roadmap: S-8
public enum AndroidPackageReader {
    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> AndroidPackage {
        try read(source: try BinaryFileSource(url: url), fileName: url.lastPathComponent, limits: limits)
    }

    public static func read(source: any BinaryByteSource, fileName: String? = nil,
                            limits: BinaryLimits = .default) throws -> AndroidPackage {
        let listing: ArchiveListing
        do { listing = try VitrineArchive.list(source: source, fileName: fileName) } catch let error as ArchiveError {
            throw BinaryError.malformed("the package is not a readable zip: \(error.reason)")
        }
        guard listing.format == .zip else { throw BinaryError.notRecognized("an Android package (not a zip)") }
        guard let manifestIndex = listing.entries.lastIndex(where: { $0.path == "AndroidManifest.xml" }) else {
            throw BinaryError.notRecognized("an Android package (no AndroidManifest.xml)")
        }
        let data = try VitrineArchive.memberData(source: source, listing: listing, entryIndex: manifestIndex,
                                                 limit: limits.maxPackageXMLBytes)
        guard data.isComplete else { throw BinaryError.unsupported("the manifest is larger than \(limits.maxPackageXMLBytes) bytes") }
        let elements = try AndroidBinaryXML.parse(data.bytes)

        var manifest = AndroidBinaryXML.Element(name: "", depth: 0, attributes: [])
        var usesSDK: AndroidBinaryXML.Element?
        var application: AndroidBinaryXML.Element?
        var permissions: [String] = []
        var seenPermissions = Set<String>()        // a manifest may repeat one element 200,000 times: no linear search
        var counts: [String: Int] = [:]
        for e in elements {
            switch e.name {
            case "manifest" where e.depth == 0: manifest = e
            case "uses-sdk": usesSDK = e
            case "application": application = e
            case "uses-permission", "uses-permission-sdk-23", "uses-permission-sdk-m":
                if let name = e.value(named: "name", id: AndroidBinaryXML.Attr.name)?.text, seenPermissions.insert(name).inserted {
                    permissions.append(name)
                }
            case "activity", "activity-alias", "service", "receiver", "provider": counts[e.name, default: 0] += 1
            default: break
            }
        }
        let labelValue = application?.value(named: "label", id: AndroidBinaryXML.Attr.label)

        // Signature schemes: v1 signature blocks in META-INF, and the APK Signing Block magic right before the
        // central directory for v2, v3 and v4.
        var schemes: [String] = []
        let blocks = listing.entries.indices.filter { i in
            let p = listing.entries[i].path.uppercased()
            return p.hasPrefix("META-INF/") && (p.hasSuffix(".RSA") || p.hasSuffix(".DSA") || p.hasSuffix(".EC"))
        }
        // Listed as stored; nothing here checks the JAR or APK Signing Block signature, and a name is never a signer.
        var certificates: [CertificateSummary] = []
        if let first = blocks.first {
            schemes.append("v1 (JAR signing)")
            if let block = try? VitrineArchive.memberData(source: source, listing: listing, entryIndex: first, limit: 1 << 20),
               block.isComplete {
                certificates = CertificateSummary.fromCMS(block.bytes)
            }
        }
        if let directory = listing.zip?.centralDirectoryOffset, directory >= 24,
           let magic = try? source.read(at: directory - 16, count: 16), magic == Array("APK Sig Block 42".utf8) {
            schemes.append("v2+ (APK Signing Block)")
        }
        var abis: [String] = []
        var seenABIs = Set<String>()
        for entry in listing.entries {
            let parts = entry.path.split(separator: "/")
            if parts.count >= 3, parts[0] == "lib", seenABIs.insert(String(parts[1])).inserted { abis.append(String(parts[1])) }
        }

        return AndroidPackage(
            packageName: manifest.value(named: "package", id: nil)?.text,
            versionName: manifest.value(named: "versionName", id: AndroidBinaryXML.Attr.versionName)?.text,
            versionCode: manifest.value(named: "versionCode", id: AndroidBinaryXML.Attr.versionCode)?.integer,
            minSDK: usesSDK?.value(named: "minSdkVersion", id: AndroidBinaryXML.Attr.minSdkVersion)?.integer.map { Int($0) },
            targetSDK: usesSDK?.value(named: "targetSdkVersion", id: AndroidBinaryXML.Attr.targetSdkVersion)?.integer.map { Int($0) },
            compileSDK: manifest.value(named: "compileSdkVersion", id: AndroidBinaryXML.Attr.compileSdkVersion)?.integer.map { Int($0) },
            label: labelValue?.text, labelIsResource: labelValue?.isReference == true,
            permissions: permissions,
            debuggable: application?.value(named: "debuggable", id: AndroidBinaryXML.Attr.debuggable)?.bool ?? false,
            usesCleartextTraffic: application?.value(named: "usesCleartextTraffic", id: AndroidBinaryXML.Attr.usesCleartextTraffic)?.bool,
            allowsBackup: application?.value(named: "allowBackup", id: AndroidBinaryXML.Attr.allowBackup)?.bool,
            activityCount: (counts["activity"] ?? 0) + (counts["activity-alias"] ?? 0), serviceCount: counts["service"] ?? 0,
            receiverCount: counts["receiver"] ?? 0, providerCount: counts["provider"] ?? 0,
            signatureSchemes: schemes, certificates: certificates, nativeABIs: abis, listing: listing)
    }
}

/// Android's binary XML (the AAPT `ResXMLTree` format): a string pool, an optional resource-id map, then start and
/// end element chunks whose attributes carry typed values. Only what the manifest needs is decoded; every offset and
/// count is checked against the chunk it lives in. roadmap: S-8
enum AndroidBinaryXML {
    /// Framework attribute resource ids (android.R.attr), used when a manifest's attribute names are stripped.
    enum Attr {
        static let label: UInt32 = 0x0101_0001
        static let name: UInt32 = 0x0101_0003
        static let debuggable: UInt32 = 0x0101_000F
        static let minSdkVersion: UInt32 = 0x0101_020C
        static let versionCode: UInt32 = 0x0101_021B
        static let versionName: UInt32 = 0x0101_021C
        static let targetSdkVersion: UInt32 = 0x0101_0270
        static let allowBackup: UInt32 = 0x0101_0280
        static let usesCleartextTraffic: UInt32 = 0x0101_04EC
        static let compileSdkVersion: UInt32 = 0x0101_0572
    }

    enum Value: Equatable {
        case string(String)
        case integer(Int64)
        case boolean(Bool)
        case reference(UInt32)
        case other(type: UInt8, data: UInt32)

        var text: String? {
            switch self {
            case .string(let s): s
            case .integer(let i): String(i)
            default: nil
            }
        }
        var integer: Int64? {
            switch self {
            case .integer(let i): i
            case .string(let s): Int64(s)
            default: nil
            }
        }
        var bool: Bool? { if case .boolean(let b) = self { b } else { nil } }
        var isReference: Bool { if case .reference = self { true } else { false } }
    }

    struct Attribute: Equatable {
        let name: String
        let resourceID: UInt32?
        let value: Value
    }

    struct Element: Equatable {
        let name: String
        let depth: Int
        let attributes: [Attribute]

        /// The attribute by its name or, when names were stripped, by its framework resource id.
        func value(named name: String, id: UInt32?) -> Value? {
            if let a = attributes.first(where: { $0.name == name }) { return a.value }
            if let id, let a = attributes.first(where: { $0.resourceID == id }) { return a.value }
            return nil
        }
    }

    static let maxElements = 200_000
    static let maxStrings = 500_000

    static func parse(_ bytes: [UInt8]) throws -> [Element] {
        var c = ByteCursor(bytes, what: "the manifest")
        guard try c.u16() == 0x0003 else { throw BinaryError.notRecognized("binary XML (the manifest is plain text or damaged)") }
        let headerSize = Int(try c.u16())
        let total = min(Int(try c.u32()), bytes.count)
        var offset = max(8, headerSize)
        var strings: [String] = []
        var resourceIDs: [UInt32] = []
        var elements: [Element] = []
        var depth = 0
        while offset + 8 <= total {
            var h = ByteCursor(bytes, at: offset, what: "a manifest chunk")
            let type = try h.u16()
            let chunkHeader = Int(try h.u16())
            let size = Int(try h.u32())
            guard size >= 8, offset + size <= total else { throw BinaryError.malformed("a manifest chunk runs past the end") }
            let chunk = Array(bytes[offset..<(offset + size)])
            switch type {
            case 0x0001: strings = try stringPool(chunk)
            case 0x0180:
                var r = ByteCursor(chunk, at: chunkHeader, what: "the resource map")
                while r.remaining >= 4, resourceIDs.count < maxStrings { resourceIDs.append(try r.u32()) }
            case 0x0102:
                guard elements.count < maxElements else { throw BinaryError.unsupported("the manifest has too many elements") }
                elements.append(try element(chunk, header: chunkHeader, depth: depth, strings: strings, ids: resourceIDs))
                depth += 1
            case 0x0103:
                depth = max(0, depth - 1)
            default:
                break
            }
            offset += size
        }
        return elements
    }

    static func element(_ chunk: [UInt8], header: Int, depth: Int, strings: [String], ids: [UInt32]) throws -> Element {
        func string(_ index: UInt32) -> String { index == 0xFFFF_FFFF || Int(index) >= strings.count ? "" : strings[Int(index)] }
        var c = ByteCursor(chunk, at: header, what: "a manifest element")
        _ = try c.u32()                                                    // namespace
        let name = string(try c.u32())
        let attributeStart = Int(try c.u16())
        let attributeSize = Int(try c.u16())
        let count = Int(try c.u16())
        guard attributeSize >= 20 else { throw BinaryError.malformed("a manifest attribute is too small") }
        var attributes: [Attribute] = []
        for i in 0..<min(count, 4096) {
            var a = ByteCursor(chunk, at: header + attributeStart + i * attributeSize, what: "a manifest attribute")
            _ = try a.u32()                                                // namespace
            let nameIndex = try a.u32()
            let raw = try a.u32()
            _ = try a.u16(); _ = try a.u8()                                // value size, reserved
            let dataType = try a.u8()
            let data = try a.u32()
            let value: Value
            switch dataType {
            case 0x03: value = .string(raw != 0xFFFF_FFFF ? string(raw) : string(data))
            case 0x10: value = .integer(Int64(Int32(bitPattern: data)))
            case 0x11: value = .integer(Int64(data))
            case 0x12: value = .boolean(data != 0)
            case 0x01: value = .reference(data)
            default: value = raw != 0xFFFF_FFFF ? .string(string(raw)) : .other(type: dataType, data: data)
            }
            let id = Int(nameIndex) < ids.count ? ids[Int(nameIndex)] : nil
            attributes.append(Attribute(name: string(nameIndex), resourceID: id, value: value))
        }
        return Element(name: name, depth: depth, attributes: attributes)
    }

    /// The string pool: UTF-16 (default) or UTF-8 (flag 0x100) strings, each with its own length prefix.
    static func stringPool(_ chunk: [UInt8]) throws -> [String] {
        var c = ByteCursor(chunk, at: 8, what: "the string pool")
        let count = Int(try c.u32())
        _ = try c.u32()                                                    // style count
        let flags = try c.u32()
        let stringsStart = Int(try c.u32())
        _ = try c.u32()                                                    // styles start
        guard count <= maxStrings else { throw BinaryError.unsupported("the manifest has too many strings") }
        let utf8 = flags & 0x100 != 0
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        let headerSize = Int(UInt16(chunk[2]) | UInt16(chunk[3]) << 8)
        var o = ByteCursor(chunk, at: headerSize, what: "the string offsets")
        for _ in 0..<count { offsets.append(Int(try o.u32())) }
        // Offsets come from the file and may alias one string or overlap: each distinct offset is decoded once and
        // shared, and the string data decoded from distinct offsets may not pass the pool's own size (strings that
        // overlap to say more than the chunk holds are the binary-XML form of entity expansion).
        var decoded: [Int: String] = [:]
        var budget = chunk.count
        var strings: [String] = []
        strings.reserveCapacity(count)
        for start in offsets {
            if let shared = decoded[start] { strings.append(shared); continue }
            let (string, spanned) = poolString(chunk, at: stringsStart + start, utf8: utf8)
            budget -= spanned
            guard budget >= 0 else {
                throw BinaryError.unsupported("the manifest's strings overlap to more text than its string pool holds")
            }
            decoded[start] = string
            strings.append(string)
        }
        return strings
    }

    /// The string at `at` and the bytes of string data it spans; ("", 0) when it does not fit in the chunk.
    private static func poolString(_ chunk: [UInt8], at: Int, utf8: Bool) -> (String, Int) {
        guard at >= 0, at < chunk.count else { return ("", 0) }
        if utf8 {
            var i = at
            func length() -> Int? {
                guard i < chunk.count else { return nil }
                var n = Int(chunk[i]); i += 1
                if n & 0x80 != 0 { guard i < chunk.count else { return nil }; n = (n & 0x7F) << 8 | Int(chunk[i]); i += 1 }
                return n
            }
            guard length() != nil, let bytes = length(), bytes <= chunk.count - i else { return ("", 0) }
            return (String(decoding: chunk[i..<(i + bytes)], as: UTF8.self), bytes)
        }
        guard at + 2 <= chunk.count else { return ("", 0) }
        var i = at
        var n = Int(UInt16(chunk[i]) | UInt16(chunk[i + 1]) << 8); i += 2
        if n & 0x8000 != 0 {
            guard i + 2 <= chunk.count else { return ("", 0) }
            n = (n & 0x7FFF) << 16 | Int(UInt16(chunk[i]) | UInt16(chunk[i + 1]) << 8); i += 2
        }
        guard n <= (chunk.count - i) / 2 else { return ("", 0) }
        let units = stride(from: i, to: i + n * 2, by: 2).map { UInt16(chunk[$0]) | UInt16(chunk[$0 + 1]) << 8 }
        return (String(decoding: units, as: UTF16.self), n * 2)
    }
}
