import XCTest
@testable import VitrinePreviewKit

@MainActor
final class FileMonitorTests: XCTestCase {
    func testDetectsInPlaceWrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sbm-\(UUID().uuidString).md")
        try Data("one".utf8).write(to: url)
        let fired = expectation(description: "reload")
        let monitor = FileMonitor(url: url, debounce: 0.05) { fired.fulfill() }
        try await Task.sleep(for: .milliseconds(1100)) // modification dates have 1 s granularity on some volumes
        try Data("two".utf8).write(to: url)
        await fulfillment(of: [fired], timeout: 3)
        monitor.stop()
    }

    func testDetectsTempAndRenameSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("doc.md")
        try Data("one".utf8).write(to: url)
        let fired = expectation(description: "reload after rename")
        let monitor = FileMonitor(url: url, debounce: 0.05) { fired.fulfill() }
        try await Task.sleep(for: .milliseconds(1100))
        let tmp = dir.appendingPathComponent("doc.md.tmp")
        try Data("two".utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        await fulfillment(of: [fired], timeout: 3)
        monitor.stop()
    }
}
