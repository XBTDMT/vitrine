import Foundation

/// A Mach-O file: one architecture (thin) or several behind a fat header (universal). Read from the headers and load
/// commands only (`<mach-o/loader.h>`, `<mach-o/fat.h>`), never mapped, linked or run.
public struct MachOFile: Sendable, Equatable {
    /// True when the file starts with a fat header, even one holding a single architecture.
    public let isUniversal: Bool
    /// The fat header used 64-bit offsets (`FAT_MAGIC_64`).
    public let usesFat64: Bool
    /// One per architecture, in header order. A universal slice that could not be read is absent from here and
    /// named in `unreadableSlices`.
    public let slices: [MachOSlice]
    /// Architectures the fat header lists but whose slice could not be read, with the reason.
    public let unreadableSlices: [UnreadableSlice]
    /// File-level oddities that did not stop the read (overlapping slices, an unknown fat alignment).
    public let notes: [String]

    public struct UnreadableSlice: Sendable, Equatable {
        public let cpu: CPUType
        public let offset: Int64
        public let size: Int64
        public let reason: String
    }

    /// Architecture names in slice order (`arm64`, `x86_64`, …).
    public var architectures: [String] { slices.map(\.cpu.name) }
}

/// One architecture's facts.
public struct MachOSlice: Sendable, Equatable {
    /// Where this slice starts in the file and how long it is (the whole file for a thin binary).
    public let fileOffset: Int64
    public let fileSize: Int64
    public let cpu: CPUType
    public let is64Bit: Bool
    /// The slice is big-endian (PowerPC); everything Apple ships today is little-endian.
    public let isBigEndian: Bool
    public let fileType: MachOFileType
    public let flags: MachOHeaderFlags
    /// `LC_BUILD_VERSION` (one per platform; zippered Catalyst binaries carry two) or the older version-min
    /// commands, which name one platform.
    public let platforms: [BuildVersion]
    public let uuid: UUID?
    /// `LC_ID_DYLIB`: the install name of a dylib or framework, with its versions.
    public let installName: LinkedDylib?
    public let linkedDylibs: [LinkedDylib]
    public let rpaths: [String]
    public let encryption: EncryptionInfo?
    /// Where `LC_CODE_SIGNATURE` says the embedded signature lies (slice-relative), if it has one.
    public let codeSignatureRange: FileRange?
    /// The embedded signature parsed statically, when present and readable.
    public let codeSignature: EmbeddedSignature?
    /// Why the signature could not be parsed, when `codeSignatureRange` is set but `codeSignature` is nil.
    public let codeSignatureProblem: String?
    public let segments: [Segment]
    /// `LC_MAIN`'s entry point offset (executables only).
    public let entryOffset: UInt64?
    /// `LC_SOURCE_VERSION`, as `a.b.c.d.e`.
    public let sourceVersion: String?
    /// Load commands the header declares, and how many were read.
    public let declaredLoadCommands: Int
    public let readLoadCommands: Int
    /// Problems met while reading that did not stop it (a short command, a cap reached). Empty for a clean slice.
    public let notes: [String]

    public var hasCodeSignature: Bool { codeSignatureRange != nil }
    public var isPIE: Bool { flags.contains(.pie) }
    /// Every load command was read and nothing was odd.
    public var isComplete: Bool { notes.isEmpty && readLoadCommands == declaredLoadCommands }
}

public struct FileRange: Sendable, Equatable {
    public let offset: Int64
    public let length: Int64
}

/// A CPU type and subtype with their names.
public struct CPUType: Sendable, Equatable, CustomStringConvertible {
    public let type: Int32
    public let subtype: Int32

    public init(type: Int32, subtype: Int32) { self.type = type; self.subtype = subtype }

    static let abi64: Int32 = 0x0100_0000
    static let abi64_32: Int32 = 0x0200_0000
    static let x86: Int32 = 7
    static let arm: Int32 = 12
    static let powerPC: Int32 = 18

    /// The subtype without its capability bits (the high byte: pointer-authentication ABI on arm64e, LIB64 on x86).
    public var baseSubtype: Int32 { subtype & 0x00FF_FFFF }

    /// The name `lipo` and `arch` use: `arm64`, `arm64e`, `x86_64`, `x86_64h`, `i386`, `armv7k`, `arm64_32`, `ppc`…
    public var name: String {
        switch type {
        case Self.x86 | Self.abi64:
            return baseSubtype == 8 ? "x86_64h" : "x86_64"
        case Self.x86:
            return "i386"
        case Self.arm | Self.abi64:
            switch baseSubtype {
            case 1: return "arm64v8"
            case 2: return "arm64e"
            default: return "arm64"
            }
        case Self.arm | Self.abi64_32:
            return "arm64_32"
        case Self.arm:
            switch baseSubtype {
            case 5: return "armv4t"
            case 6: return "armv6"
            case 7: return "armv5"
            case 8: return "xscale"
            case 9: return "armv7"
            case 10: return "armv7f"
            case 11: return "armv7s"
            case 12: return "armv7k"
            case 13: return "armv8"
            case 14: return "armv6m"
            case 15: return "armv7m"
            case 16: return "armv7em"
            default: return "arm"
            }
        case Self.powerPC: return "ppc"
        case Self.powerPC | Self.abi64: return "ppc64"
        default:
            return "cpu \(type) subtype \(baseSubtype)"
        }
    }

    /// arm64e's pointer-authentication ABI version, when the subtype carries one (`CPU_SUBTYPE_PTRAUTH_ABI`).
    public var pointerAuthenticationABIVersion: Int? {
        guard type == Self.arm | Self.abi64, baseSubtype == 2, UInt32(bitPattern: subtype) & 0x8000_0000 != 0
        else { return nil }
        return Int((UInt32(bitPattern: subtype) >> 24) & 0x0F)
    }

    public var description: String { name }
}

/// `MH_EXECUTE`, `MH_DYLIB`, `MH_BUNDLE`…
public struct MachOFileType: Sendable, Equatable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let object = MachOFileType(rawValue: 1)
    public static let executable = MachOFileType(rawValue: 2)
    public static let dylib = MachOFileType(rawValue: 6)
    public static let bundle = MachOFileType(rawValue: 8)
    public static let kextBundle = MachOFileType(rawValue: 11)

    public var name: String {
        switch rawValue {
        case 1: "object"
        case 2: "executable"
        case 3: "fixed VM shared library"
        case 4: "core dump"
        case 5: "preloaded executable"
        case 6: "dynamic library"
        case 7: "dynamic linker"
        case 8: "bundle"
        case 9: "dynamic library stub"
        case 10: "debug symbols (dSYM)"
        case 11: "kernel extension"
        case 12: "file set"
        case 13: "GPU program"
        case 14: "GPU support library"
        default: "file type \(rawValue)"
        }
    }

    public var description: String { name }
}

/// The header's `flags` word (`MH_PIE`, `MH_TWOLEVEL`, …).
public struct MachOHeaderFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let noUndefinedSymbols = MachOHeaderFlags(rawValue: 0x1)
    public static let dyldLink = MachOHeaderFlags(rawValue: 0x4)
    public static let twoLevelNamespace = MachOHeaderFlags(rawValue: 0x80)
    public static let weakDefines = MachOHeaderFlags(rawValue: 0x8000)
    public static let bindsToWeak = MachOHeaderFlags(rawValue: 0x1_0000)
    public static let allowStackExecution = MachOHeaderFlags(rawValue: 0x2_0000)
    public static let pie = MachOHeaderFlags(rawValue: 0x20_0000)
    public static let noHeapExecution = MachOHeaderFlags(rawValue: 0x100_0000)
    public static let appExtensionSafe = MachOHeaderFlags(rawValue: 0x200_0000)

    static let names: [(UInt32, String)] = [
        (0x1, "NOUNDEFS"), (0x2, "INCRLINK"), (0x4, "DYLDLINK"), (0x8, "BINDATLOAD"), (0x10, "PREBOUND"),
        (0x20, "SPLIT_SEGS"), (0x40, "LAZY_INIT"), (0x80, "TWOLEVEL"), (0x100, "FORCE_FLAT"),
        (0x200, "NOMULTIDEFS"), (0x400, "NOFIXPREBINDING"), (0x800, "PREBINDABLE"), (0x1000, "ALLMODSBOUND"),
        (0x2000, "SUBSECTIONS_VIA_SYMBOLS"), (0x4000, "CANONICAL"), (0x8000, "WEAK_DEFINES"),
        (0x1_0000, "BINDS_TO_WEAK"), (0x2_0000, "ALLOW_STACK_EXECUTION"), (0x4_0000, "ROOT_SAFE"),
        (0x8_0000, "SETUID_SAFE"), (0x10_0000, "NO_REEXPORTED_DYLIBS"), (0x20_0000, "PIE"),
        (0x40_0000, "DEAD_STRIPPABLE_DYLIB"), (0x80_0000, "HAS_TLV_DESCRIPTORS"), (0x100_0000, "NO_HEAP_EXECUTION"),
        (0x200_0000, "APP_EXTENSION_SAFE"), (0x400_0000, "NLIST_OUTOFSYNC_WITH_DYLDINFO"),
        (0x800_0000, "SIM_SUPPORT"), (0x8000_0000, "DYLIB_IN_CACHE"),
    ]

    /// The `MH_` names of the set bits, unknown bits as hex.
    public var names: [String] {
        var out: [String] = []
        var rest = rawValue
        for (bit, name) in Self.names where rawValue & bit != 0 {
            out.append(name)
            rest &= ~bit
        }
        if rest != 0 { out.append(String(format: "0x%x", rest)) }
        return out
    }
}

/// A packed `xxxx.yy.zz` version (load commands) — `nibble` packing as `<mach-o/loader.h>` defines it.
public struct MachOVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init(packed: UInt32) {
        major = Int(packed >> 16); minor = Int((packed >> 8) & 0xFF); patch = Int(packed & 0xFF)
    }

    public init(major: Int, minor: Int, patch: Int = 0) { self.major = major; self.minor = minor; self.patch = patch }

    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }

    public static func < (a: MachOVersion, b: MachOVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// The platform a slice was built for (`PLATFORM_*` in `<mach-o/loader.h>`).
public struct MachOPlatform: Sendable, Equatable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let macOS = MachOPlatform(rawValue: 1)
    public static let iOS = MachOPlatform(rawValue: 2)
    public static let macCatalyst = MachOPlatform(rawValue: 6)

    public var name: String {
        switch rawValue {
        case 1: "macOS"
        case 2: "iOS"
        case 3: "tvOS"
        case 4: "watchOS"
        case 5: "bridgeOS"
        case 6: "Mac Catalyst"
        case 7: "iOS Simulator"
        case 8: "tvOS Simulator"
        case 9: "watchOS Simulator"
        case 10: "DriverKit"
        case 11: "visionOS"
        case 12: "visionOS Simulator"
        case 13: "firmware"
        case 14: "sepOS"
        default: "platform \(rawValue)"
        }
    }

    public var description: String { name }
}

/// Minimum OS and SDK for one platform.
public struct BuildVersion: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case buildVersion, versionMin }

    public let platform: MachOPlatform
    public let minimumOS: MachOVersion
    public let sdk: MachOVersion
    /// The tools that built it (`LC_BUILD_VERSION` only): name and version.
    public let tools: [Tool]
    public let source: Source

    public struct Tool: Sendable, Equatable {
        public let name: String
        public let version: MachOVersion
    }

    static func toolName(_ raw: UInt32) -> String {
        switch raw {
        case 1: "clang"
        case 2: "swift"
        case 3: "ld"
        case 4: "lld"
        case 1024: "Metal"
        case 1025: "AIR linker"
        case 1026: "AIR native"
        case 1027: "AIR native plug-in"
        case 1028: "AIR packer"
        case 1031: "GPU archiver"
        case 1032: "Metal framework"
        default: "tool \(raw)"
        }
    }
}

/// A dylib this slice links (or is).
public struct LinkedDylib: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case load = "load", weak = "weak", reexport = "re-export", lazy = "lazy", upward = "upward", id = "id"
    }

    public let path: String
    public let kind: Kind
    public let currentVersion: MachOVersion
    public let compatibilityVersion: MachOVersion
}

/// `LC_ENCRYPTION_INFO(_64)`: FairPlay-encrypted range. `cryptID` 0 means the range is described but not encrypted.
public struct EncryptionInfo: Sendable, Equatable {
    public let offset: UInt32
    public let size: UInt32
    public let cryptID: UInt32
    public var isEncrypted: Bool { cryptID != 0 }
}

/// A segment's name and sizes (`LC_SEGMENT(_64)`).
public struct Segment: Sendable, Equatable {
    public let name: String
    public let vmAddress: UInt64
    public let vmSize: UInt64
    public let fileOffset: UInt64
    public let fileSize: UInt64
    public let sectionCount: Int
    /// `VM_PROT_*` bits as `rwx` text, initial and maximum.
    public let initialProtection: String
    public let maximumProtection: String

    static func protection(_ raw: UInt32) -> String {
        (raw & 1 != 0 ? "r" : "-") + (raw & 2 != 0 ? "w" : "-") + (raw & 4 != 0 ? "x" : "-")
    }
}
