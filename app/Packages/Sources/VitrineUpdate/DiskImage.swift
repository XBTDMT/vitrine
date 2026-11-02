// Opens the downloaded disk image read-only, without Finder or auto-open, at a mount point inside Vitrine's private
// mount folder (G-21). The image's own checksums are verified by hdiutil on attach.
public import Foundation

public protocol DiskImageMounting: Sendable {
    /// Attaches `image` read-only under `mountRoot` and returns the mount point.
    func attach(_ image: URL, under mountRoot: URL) async throws(UpdateError) -> URL
    /// Detaches what `attach` returned. Never throws: a failure is logged and the system cleans up at logout.
    func detach(_ mountPoint: URL) async
}

public struct HdiutilMounter: DiskImageMounting {
    public static let hdiutil = URL(filePath: "/usr/bin/hdiutil")
    public var timeout: Duration

    public init(timeout: Duration = .seconds(120)) { self.timeout = timeout }

    public func attach(_ image: URL, under mountRoot: URL) async throws(UpdateError) -> URL {
        let run = await ProcessRunner.run(Self.hdiutil, ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist",
                                                         "-mountrandom", mountRoot.path, image.path], timeout: timeout)
        guard run.status == 0 else { throw .diskImage("hdiutil attach exit \(run.status)") }
        guard let point = Self.mountPoint(fromPlist: run.output) else { throw .diskImage("no mount point") }
        // The mount point must be where we asked, not anywhere hdiutil (or a planted plist) chose.
        let root = mountRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = point.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root + "/") else {
            await detach(point)
            throw .diskImage("mount point outside the update folder")
        }
        return point
    }

    public func detach(_ mountPoint: URL) async {
        let first = await ProcessRunner.run(Self.hdiutil, ["detach", mountPoint.path, "-quiet"], timeout: timeout)
        if first.status != 0 {
            let forced = await ProcessRunner.run(Self.hdiutil, ["detach", mountPoint.path, "-force", "-quiet"], timeout: timeout)
            if forced.status != 0 { UpdateLog.logger.error("update: disk image detach failed, exit \(forced.status)") }
        }
    }

    /// The first `mount-point` in `hdiutil attach -plist` output.
    static func mountPoint(fromPlist data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let path = entity["mount-point"] as? String, !path.isEmpty { return URL(filePath: path, directoryHint: .isDirectory) }
        }
        return nil
    }
}

/// Runs a tool with no shell, no stdin, and a deadline; returns its exit status and standard output.
/// Output goes to a private temporary file, not a pipe: hdiutil leaves a helper holding inherited descriptors after it
/// exits, so reading a pipe to its end would wait for that helper, not for hdiutil.
enum ProcessRunner {
    struct Run: Sendable {
        var status: Int32
        var output: Data
    }

    /// Past the deadline the tool is asked to stop (SIGTERM), then made to (SIGKILL) after `grace`; if it still has not
    /// exited after a second `grace` — a tool blocked inside the kernel, as hdiutil is while the disk-image service is busy
    /// with a network Time Machine image — the run is reported failed and never waited on, so an update can never hang
    /// Vitrine (2026-10-28: an attach waited on diskimagesiod for 28 minutes).
    static func run(_ executable: URL, _ arguments: [String], timeout: Duration, grace: Duration = .seconds(5)) async -> Run {
        await Task.detached(priority: .utility) {
            let outFile = FileManager.default.temporaryDirectory.appending(path: "vitrine-update-\(UUID().uuidString).out")
            guard FileManager.default.createFile(atPath: outFile.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let out = try? FileHandle(forWritingTo: outFile) else { return Run(status: -1, output: Data()) }
            defer {
                try? out.close()
                try? FileManager.default.removeItem(at: outFile)
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardOutput = out
            do { try process.run() } catch { return Run(status: -1, output: Data()) }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                process.terminate()
                if !(await exits(process, within: grace)) {
                    kill(process.processIdentifier, SIGKILL)
                    if !(await exits(process, within: grace)) { return Run(status: -1, output: Data()) }
                }
                return Run(status: -1, output: Data())
            }
            let output = (try? Data(contentsOf: outFile)) ?? Data()
            return Run(status: process.terminationStatus, output: output)
        }.value
    }

    private static func exits(_ process: Process, within limit: Duration) async -> Bool {
        let end = ContinuousClock.now.advanced(by: limit)
        while process.isRunning, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(50)) }
        return !process.isRunning
    }
}
