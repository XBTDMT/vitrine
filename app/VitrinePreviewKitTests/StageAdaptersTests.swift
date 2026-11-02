import XCTest
@testable import VitrinePreviewKit
import VitrineEngineering

/// The readers' summaries mapped onto the picked stage views (F8, F9): Compose services left of what they depend on,
/// Actions jobs right of what they need, warnings on their nodes, undefined dependencies drawn and marked, HAR
/// requests as waterfall rows with failures marked. Invented files only. roadmap: S-22
final class StageAdaptersTests: XCTestCase {
    private func infra(_ text: String, _ name: String, path: String? = nil) throws -> InfraDocument {
        try XCTUnwrap(InfraReader.read(data: Data(text.utf8), fileName: name, path: path ?? name))
    }

    func testComposeServicesPointAtWhatTheyDependOn() throws {
        guard case .compose(let s) = try infra("""
        services:
          web:
            image: nginx:1.27
            depends_on: [api]
          api:
            build: ./api
            depends_on:
              db: {condition: service_healthy}
              queue: {condition: service_started}
          db:
            image: postgres:16.4
          agent:
            image: example/monitor:1.0
            privileged: true
        """, "compose.yaml") else { return XCTFail("compose") }
        let g = StageAdapters.graph(s)
        XCTAssertEqual(Set(g.nodes.map(\.id)), ["web", "api", "db", "agent", "queue"])
        XCTAssertTrue(g.edges.contains(StageGraph.Edge(from: "web", to: "api", label: nil)))
        XCTAssertTrue(g.edges.contains(StageGraph.Edge(from: "api", to: "db", label: "healthy")), "Compose's condition in a word")
        XCTAssertEqual(g.nodes.first { $0.id == "api" }?.subtitle, "build ./api")
        XCTAssertEqual(g.nodes.first { $0.id == "web" }?.subtitle, "nginx:1.27")
        XCTAssertEqual(g.nodes.first { $0.id == "agent" }?.warning, .danger, "a privileged service is marked on its node")
        let queue = try XCTUnwrap(g.nodes.first { $0.id == "queue" })
        XCTAssertEqual(queue.warning, .caution, "an undefined dependency is drawn and marked")
        XCTAssertNil(g.nodes.first { $0.id == "db" }?.warning)
    }

    func testWorkflowJobsRunLeftToRight() throws {
        guard case .githubWorkflow(let s) = try infra("""
        on: push
        jobs:
          build:
            runs-on: ubuntu-latest
            steps: [{run: make}]
          test:
            needs: build
            runs-on: macos-15
            steps: [{run: make test}]
          deploy:
            needs: [test]
            runs-on: ubuntu-latest
            steps: [{run: make deploy}]
        """, "ci.yml", path: "/repo/.github/workflows/ci.yml") else { return XCTFail("workflow") }
        let g = StageAdapters.graph(s)
        XCTAssertTrue(g.edges.contains { $0.from == "build" && $0.to == "test" }, "a job sits right of the job it needs")
        XCTAssertTrue(g.edges.contains { $0.from == "test" && $0.to == "deploy" })
        XCTAssertEqual(g.nodes.first { $0.id == "test" }?.subtitle, "macos-15")
    }

    func testHARRequestsBecomeRowsWithFailuresMarked() throws {
        guard case .har(let s) = try infra("""
        {"log": {"version": "1.2", "creator": {"name": "Example", "version": "1"}, "entries": [
          {"startedDateTime": "2026-11-01T10:00:00.000Z", "time": 120,
           "request": {"method": "GET", "url": "https://shop.example/", "headers": []},
           "response": {"status": 200, "headers": [], "content": {"size": 2048, "mimeType": "text/html"}}, "timings": {}},
          {"startedDateTime": "2026-11-01T10:00:00.300Z", "time": 80,
           "request": {"method": "POST", "url": "https://shop.example/api/cart", "headers": []},
           "response": {"status": 500, "headers": [], "content": {"size": 12, "mimeType": "application/json"}}, "timings": {}}
        ]}}
        """, "session.har") else { return XCTFail("har") }
        let rows = StageAdapters.waterfall(s)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "GET shop.example/")
        XCTAssertFalse(rows[0].isError)
        XCTAssertEqual(rows[1].startMs, 300, accuracy: 0.5)
        XCTAssertEqual(rows[1].durationMs, 80, accuracy: 0.5)
        XCTAssertTrue(rows[1].isError)
        XCTAssertTrue(rows[1].detail?.hasPrefix("500") == true)
    }
}
