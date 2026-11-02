import Foundation

/// VitrineBinary: facts about executables, bundles, signatures, profiles, installers and disk images
/// (ARCHITECTURE §3). Read-only: nothing is ever executed, mounted or installed, and the Security framework is only
/// asked offline questions (`kSecCSNoNetworkAccess`). roadmap: S-8, S-22
public enum VitrineBinary {
    /// What `inspect` found.
    public enum Inspection: Sendable, Equatable {
        case machO(MachOFile)
        case bundle(BundleFacts)
        case installerPackage(InstallerPackage)
        case diskImage(DiskImage)
        case provisioningProfile(ProvisioningProfile)
    }

    /// Reads whichever of this module's formats `url` holds: a bundle folder, a Mach-O file, a flat package, a disk
    /// image or a provisioning profile, chosen by content (and the extension where content cannot decide). The
    /// Security framework's signature assessment is separate (`SignatureVerifier.assess`), because a full check of a
    /// large app takes longer than a first paint.
    public static func inspect(_ url: URL, limits: BinaryLimits = .default) throws -> Inspection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BinaryError.unreadable("the file does not exist")
        }
        if isDirectory.boolValue { return .bundle(try BundleReader.read(contentsOf: url, limits: limits)) }

        let source = try BinaryFileSource(url: url)
        let head = try source.read(at: 0, count: 16)
        if MachOReader.looksLikeMachO(head, limits: limits) {
            return .machO(try MachOReader.read(source: source, limits: limits))
        }
        if head.be32(at: 0) == InstallerPackageReader.magic {
            return .installerPackage(try InstallerPackageReader.read(source: source, limits: limits))
        }
        let ext = url.pathExtension.lowercased()
        if ext == "mobileprovision" || ext == "provisionprofile" {
            return .provisioningProfile(try ProvisioningProfileReader.read(contentsOf: url, limits: limits))
        }
        let tail = source.size >= 512 ? try source.read(at: source.size - 512, count: 4) : []
        let hasTrailer = tail.be32(at: 0) == DiskImageReader.kolyMagic
        if head.prefix(8).elementsEqual("encrcdsa".utf8) || head.prefix(4).elementsEqual("AEA1".utf8) || ext == "dmg"
            || hasTrailer {
            return .diskImage(try DiskImageReader.read(source: source, limits: limits))
        }
        throw BinaryError.notRecognized("an app, binary, package, disk image or provisioning profile")
    }
}
