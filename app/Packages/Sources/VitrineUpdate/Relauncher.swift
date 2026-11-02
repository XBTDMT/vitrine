// After an install, a small detached shell (no network, fixed arguments, no interpolation into the script text) waits
// for this process to quit, opens the new app, and if macOS refuses to open it, puts the previous app back and opens
// that instead (G-21: the rollback copy is kept until the new app launches).
public import Foundation

public enum Relauncher {
    /// $1 pid to wait for · $2 the installed app · $3 the rollback copy · $4 the open tool (/usr/bin/open in the app).
    /// The wait is bounded (60 s): if this process is still alive by then the new app stays installed and is used at the
    /// next launch.
    static let script = """
    pid="$1"; app="$2"; rollback="$3"; opener="$4"
    n=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
      n=$((n+1)); [ "$n" -gt 300 ] && exit 0
      /bin/sleep 0.2
    done
    "$opener" "$app" && exit 0
    [ -d "$rollback" ] || exit 1
    /bin/mv "$app" "$rollback.failed" && /bin/mv "$rollback" "$app" && /bin/rm -rf "$rollback.failed"
    "$opener" "$app"
    """

    /// Starts the helper; the caller then quits the app. False when it could not be started (the new app is installed
    /// either way and runs at the next launch).
    @discardableResult
    public static func start(_ prepared: PreparedRelaunch, waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                             opener: URL = URL(filePath: "/usr/bin/open")) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "vitrine-update-relaunch", String(pid), prepared.app.path, prepared.rollback.path, opener.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); return true } catch { return false }
    }
}
