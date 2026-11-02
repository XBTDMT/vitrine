import Foundation
import Testing
@testable import VitrineEngineering

/// Infrastructure files (E-4) for the infra lens (T-8). Every fixture is invented here (acme-notes, harbor-api); the
/// secret-looking values are made-up canaries, and each test that has them checks they never reach the summary.
/// roadmap: S-22
@Suite struct InfraTests {
    func read(_ text: String, _ name: String, path: String? = nil) -> InfraDocument? {
        InfraReader.read(data: Data(text.utf8), fileName: name, path: path)
    }

    /// The canary must not appear anywhere in the summary, facts, warnings or lists.
    func expectAbsent(_ doc: InfraDocument?, _ canaries: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let dump = String(reflecting: doc as Any)
        for canary in canaries { #expect(!dump.contains(canary), "value leaked: \(canary)", sourceLocation: sourceLocation) }
    }

    // MARK: Routing

    @Test func routesByNameAndPath() {
        #expect(InfraReader.kind(fileName: "terraform.tfstate", path: nil) == .terraformState)
        #expect(InfraReader.kind(fileName: "terraform.tfstate.backup", path: nil) == .terraformState)
        #expect(InfraReader.kind(fileName: "compose.yaml", path: nil) == .compose)
        #expect(InfraReader.kind(fileName: "docker-compose.yml", path: nil) == .compose)
        #expect(InfraReader.kind(fileName: "docker-compose.prod.yml", path: nil) == .compose)
        #expect(InfraReader.kind(fileName: "ci.yml", path: "/w/acme-notes/.github/workflows/ci.yml") == .githubWorkflow)
        #expect(InfraReader.kind(fileName: "ci.yml", path: "/w/acme-notes/config/ci.yml") == nil)
        #expect(InfraReader.kind(fileName: "Dockerfile", path: nil) == .dockerfile)
        #expect(InfraReader.kind(fileName: "api.Dockerfile", path: nil) == .dockerfile)
        #expect(InfraReader.kind(fileName: "Containerfile", path: nil) == .dockerfile)
        #expect(InfraReader.kind(fileName: "Dockerfile.dev", path: nil) == .dockerfile)
        #expect(InfraReader.kind(fileName: "Dockerfile.md", path: nil) == nil)
        #expect(InfraReader.kind(fileName: "session.har", path: nil) == .har)
        #expect(InfraReader.kind(fileName: "deploy.yaml", path: nil) == nil)
        #expect(InfraReader.kind(fileName: "notes.txt", path: nil) == nil)
    }

    @Test func sniffsContentWhenTheNameDoesNotDecide() {
        #expect(read(Self.kubernetes, "deploy.yaml")?.kind == .kubernetes)
        #expect(read(Self.compose, "stack.yml")?.kind == .compose)
        #expect(read(Self.workflow, "ci.yml")?.kind == .githubWorkflow)
        #expect(read(Self.tfstate, "state.json")?.kind == .terraformState)
        #expect(read(Self.har, "capture.json")?.kind == .har)
        #expect(read(Self.dockerfile, "build")?.kind == .dockerfile)
        // Ordinary files are not mistaken for infrastructure.
        #expect(read("{\"name\": \"acme-notes\", \"version\": \"1.0.0\"}", "package.json") == nil)
        #expect(read("title: Acme notes\nitems:\n  - one\n", "notes.yaml") == nil)
        #expect(read("From: someone at acme\nSubject: notes\n", "letter") == nil)
    }

    // MARK: Terraform state

    static let tfstate = """
    {
      "version": 4,
      "terraform_version": "1.9.5",
      "serial": 12,
      "lineage": "00000000-1111-2222-3333-444444444444",
      "outputs": {
        "endpoint": {"value": "notes.acme.example", "type": "string"},
        "db_password": {"value": "CANARY-OUTPUT-hunter2", "type": "string", "sensitive": true}
      },
      "resources": [
        {"mode": "managed", "type": "aws_db_instance", "name": "notes",
         "provider": "provider[\\"registry.terraform.io/hashicorp/aws\\"]",
         "instances": [{"schema_version": 1,
           "attributes": {"identifier": "acme-notes", "password": "CANARY-DB-pass", "password_length": 24,
                          "nested": {"client_secret": "CANARY-NESTED", "secret_arn": "arn:aws:acme"}},
           "sensitive_attributes": [[{"type": "get_attr", "value": "password"}]]}]},
        {"mode": "data", "type": "aws_ami", "name": "base", "module": "module.network",
         "provider": "provider[\\"registry.terraform.io/hashicorp/aws\\"].west",
         "instances": [{"attributes": {"id": "ami-123"}}, {"attributes": {"id": "ami-456"}}]}
      ]
    }
    """

    @Test func terraformStateCountsSecretsByNameNeverValue() throws {
        let doc = read(Self.tfstate, "terraform.tfstate")
        guard case .terraformState(let s) = try #require(doc) else { Issue.record("wrong kind"); return }
        #expect(s.formatVersion == 4)
        #expect(s.terraformVersion == "1.9.5")
        #expect(s.serial == 12)
        #expect(s.totalResources == 2)
        #expect(s.totalInstances == 3)
        #expect(s.resources[0].address == "aws_db_instance.notes")
        #expect(s.resources[0].provider == "hashicorp/aws")
        #expect(s.resources[1].address == "module.network.data.aws_ami.base")
        #expect(s.resources[1].provider == "hashicorp/aws.west")
        #expect(s.resources[1].instanceCount == 2)
        #expect(s.outputs == [.init(name: "endpoint", sensitive: false), .init(name: "db_password", sensitive: true)])
        #expect(s.secrets.sensitiveAttributes == 1)
        #expect(s.secrets.secretNamedAttributes == 2)       // password, client_secret; not password_length or secret_arn
        #expect(s.secrets.sensitiveOutputs == 1)
        #expect(s.secrets.names.first == InfraNameCount(name: "password", count: 2))
        #expect(s.secrets.names.contains { $0.name == "client_secret" })
        #expect(s.warnings.first?.code == .secretsInState)
        #expect(s.warnings.first?.level == .danger)
        #expect(s.headline.contains("2 resources"))
        #expect(!s.truncated)
        expectAbsent(doc, ["CANARY-OUTPUT-hunter2", "CANARY-DB-pass", "CANARY-NESTED"])
    }

    @Test func terraformStateMalformed() {
        #expect(read("{\"version\": 4, \"terraform_version\": \"1.9.5\", \"resources\": [ {\"type\": ", "x.tfstate").map(\.truncated) == true)
        #expect(read("not json at all", "x.tfstate") == nil)
        #expect(read("[1, 2, 3]", "x.tfstate") == nil)
        #expect(read("", "x.tfstate") == nil)
        let old = read("{\"version\": 3, \"terraform_version\": \"0.11.14\", \"lineage\": \"x\", \"modules\": []}", "x.tfstate")
        #expect(old?.warnings.contains { $0.code == .unknownStateVersion } == true)
    }

    // MARK: Compose

    static let compose = """
    name: acme-notes
    x-common: &common
      restart: unless-stopped
      networks: [backend]
    services:
      harbor-api:
        <<: *common
        build:
          context: ./api
        ports:
          - "8080:80"
          - target: 443
            published: 8443
            protocol: tcp
        environment:
          LOG_LEVEL: info
          API_TOKEN: CANARY-COMPOSE-TOKEN
          DB_PASSWORD: ${DB_PASSWORD}
        depends_on:
          db:
            condition: service_healthy
        secrets: [db_password]
      db:
        image: postgres
        volumes:
          - db-data:/var/lib/postgresql/data
        environment:
          - POSTGRES_PASSWORD=CANARY-COMPOSE-PG
          - POSTGRES_DB=notes
      agent:
        image: acme/agent:1.2@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        privileged: true
        network_mode: host
        cap_add: [SYS_ADMIN]
        volumes:
          - /var/run/docker.sock:/var/run/docker.sock:ro
        depends_on: [harbor-api, cache]
    networks:
      backend: {}
    volumes:
      db-data:
    secrets:
      db_password:
        file: ./db_password.txt
    """

    @Test func composeServicesGraphAndWarnings() throws {
        let doc = read(Self.compose, "compose.yaml")
        guard case .compose(let s) = try #require(doc) else { Issue.record("wrong kind"); return }
        #expect(s.projectName == "acme-notes")
        #expect(s.services.map(\.name) == ["harbor-api", "db", "agent"])
        let api = s.services[0]
        #expect(api.build == "./api")
        #expect(api.restart == "unless-stopped")            // from the << merge key
        #expect(api.networks == ["backend"])
        #expect(api.ports == ["8080:80", "8443:443/tcp"])
        #expect(api.environmentKeys == ["LOG_LEVEL", "API_TOKEN", "DB_PASSWORD"])
        #expect(api.secrets == ["db_password"])
        #expect(s.services[1].environmentKeys == ["POSTGRES_PASSWORD", "POSTGRES_DB"])
        #expect(s.services[1].image?.floats == true)
        #expect(s.services[2].image?.pinnedByDigest == true)
        #expect(s.graph.edges.contains(.init(from: "harbor-api", to: "db", label: "service_healthy")))
        #expect(s.graph.edges.contains(.init(from: "agent", to: "harbor-api")))
        #expect(s.graph.missing == ["cache"])
        #expect(!s.graph.hasCycle)
        #expect(s.networks == ["backend"])
        #expect(s.volumes == ["db-data"])
        #expect(s.secrets == ["db_password"])

        let codes = s.warnings.map(\.code)
        #expect(codes.contains(.privileged))
        #expect(codes.contains(.hostNetwork))
        #expect(codes.contains(.dockerSocket))
        #expect(codes.contains(.dangerousCapability))
        #expect(codes.contains(.unpinnedImage))
        #expect(codes.contains(.missingDependency))
        #expect(s.warnings.filter { $0.code == .inlineSecretEnvironment }.map(\.subject) == ["harbor-api", "db"])
        #expect(s.warnings.first?.level == .danger)
        #expect(s.headline == "Compose · 3 services")
        expectAbsent(doc, ["CANARY-COMPOSE-TOKEN", "CANARY-COMPOSE-PG"])
    }

    @Test func composeCycleAndMalformed() {
        let loop = "services:\n  a:\n    image: x:1\n    depends_on: [b]\n  b:\n    image: y:1\n    depends_on: [a]\n"
        if case .compose(let s) = read(loop, "compose.yml") { #expect(s.graph.hasCycle) } else { Issue.record("not read") }
        #expect(read("services: [unclosed\n  - {", "compose.yaml") == nil || read("services: [unclosed\n  - {", "compose.yaml")?.truncated == true)
        #expect(read("\u{0}\u{1}\u{2}binary", "compose.yaml") == nil)
        #expect(read("just a string", "docker-compose.yml") == nil)
    }

    // MARK: GitHub Actions

    static let workflow = """
    name: Harbor CI
    on:
      pull_request_target:
        branches: [main]
      workflow_dispatch:
    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
            with:
              ref: ${{ github.event.pull_request.head.sha }}
          - uses: actions/setup-node@1d0ff469b7ec7b3cb9d8673fde0c81c44821de2a
          - run: npm ci
          - uses: ./.github/actions/acme-local
          - uses: docker://alpine:3.20
      test:
        needs: build
        runs-on: [self-hosted, linux]
        permissions: write-all
        strategy:
          matrix:
            node: [20, 22]
        steps:
          - run: npm test
      release:
        needs: [build, test, publish]
        uses: acme/workflows/.github/workflows/release.yml@main
        permissions:
          contents: write
          id-token: write
    """

    @Test func workflowJobsUsesPermissionsAndDanger() throws {
        let doc = read(Self.workflow, "ci.yml", path: "/w/acme-notes/.github/workflows/ci.yml")
        guard case .githubWorkflow(let s) = try #require(doc) else { Issue.record("wrong kind"); return }
        #expect(s.name == "Harbor CI")
        #expect(s.triggers == ["pull_request_target", "workflow_dispatch"])
        #expect(s.jobs.map(\.id) == ["build", "test", "release"])
        #expect(s.jobs[0].steps == 5)
        #expect(s.jobs[0].runsOn == "ubuntu-latest")
        #expect(s.jobs[1].runsOn == "self-hosted, linux")
        #expect(s.jobs[1].matrix)
        #expect(s.jobs[1].permissions == .writeAll)
        #expect(s.jobs[2].permissions == .scoped([.init(name: "contents", access: "write"), .init(name: "id-token", access: "write")]))
        #expect(s.jobs[2].uses == "acme/workflows/.github/workflows/release.yml@main")
        #expect(s.permissions == .notSet)
        let pins = Dictionary(s.uses.map { ($0.reference, $0.pinning) }, uniquingKeysWith: { a, _ in a })
        #expect(pins["actions/checkout@v4"] == .unpinned)
        #expect(pins["actions/setup-node@1d0ff469b7ec7b3cb9d8673fde0c81c44821de2a"] == .pinned)
        #expect(pins["./.github/actions/acme-local"] == .local)
        #expect(pins["docker://alpine:3.20"] == .docker)
        #expect(pins["acme/workflows/.github/workflows/release.yml@main"] == .unpinned)
        #expect(s.graph.edges.contains(.init(from: "test", to: "build")))
        #expect(s.graph.missing == ["publish"])

        let danger = s.warnings.first
        #expect(danger?.code == .pullRequestTargetCheckout)
        #expect(danger?.level == .danger)
        #expect(danger?.subject == "build")
        let codes = s.warnings.map(\.code)
        #expect(codes.contains(.permissionsWriteAll))
        #expect(codes.contains(.permissionsNotSet))       // build sets none and the top level sets none
        #expect(codes.contains(.unpinnedAction))
        #expect(codes.contains(.missingDependency))
    }

    @Test func workflowSafeShapeHasNoDanger() throws {
        let safe = """
        on: [push, pull_request]
        permissions:
          contents: read
        jobs:
          lint:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567
        """
        guard case .githubWorkflow(let s) = try #require(read(safe, "lint.yaml", path: ".github/workflows/lint.yaml")) else { Issue.record("wrong kind"); return }
        #expect(s.triggers == ["push", "pull_request"])
        #expect(s.permissions == .scoped([.init(name: "contents", access: "read")]))
        #expect(s.warnings.isEmpty)
        // A plain pull_request with a head checkout is not the pull_request_target danger.
        let plain = "on: pull_request\njobs:\n  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n    steps:\n      - uses: actions/checkout@v4\n        with:\n          ref: ${{ github.head_ref }}\n"
        #expect(read(plain, "a.yml", path: ".github/workflows/a.yml")?.warnings.contains { $0.level == .danger } == false)
    }

    @Test func workflowMalformed() {
        let path = ".github/workflows/x.yml"
        #expect(read("jobs: : : [", "x.yml", path: path) == nil)
        #expect(read("name: no jobs here\n", "x.yml", path: path) == nil)
        #expect(read("jobs: 3\non: push\n", "x.yml", path: path) == nil)
        let cut = read("on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: [unclosed", "x.yml", path: path)
        #expect(cut == nil || cut?.truncated == true)
    }

    // MARK: Kubernetes

    static let kubernetes = """
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: harbor-api
      namespace: acme
    spec:
      template:
        spec:
          hostNetwork: true
          securityContext:
            runAsUser: 0
          initContainers:
            - name: migrate
              image: harbor/migrate:2.1
          containers:
            - name: api
              image: harbor/api
              securityContext:
                privileged: true
            - name: sidecar
              image: harbor/sidecar:latest
              securityContext:
                runAsUser: 1000
          volumes:
            - name: logs
              hostPath:
                path: /var/log
            - name: sock
              hostPath:
                path: /var/run/docker.sock
    ---
    apiVersion: v1
    kind: Secret
    metadata:
      name: harbor-creds
      namespace: acme
    type: Opaque
    data:
      username: Q0FOQVJZLUs4Uy1VU0VS
      password: Q0FOQVJZLUs4Uy1QQVNT
    stringData:
      token: CANARY-K8S-TOKEN
    ---
    apiVersion: v1
    kind: List
    items:
      - apiVersion: v1
        kind: Service
        metadata: {name: harbor-api, namespace: acme}
      - apiVersion: batch/v1
        kind: CronJob
        metadata: {name: nightly}
        spec:
          jobTemplate:
            spec:
              template:
                spec:
                  containers:
                    - name: job
                      image: harbor/job@sha256:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd
    ---
    just: a config, not an object
    """

    @Test func kubernetesObjectsImagesSecretsWarnings() throws {
        let doc = read(Self.kubernetes, "harbor.yaml")
        guard case .kubernetes(let s) = try #require(doc) else { Issue.record("wrong kind"); return }
        #expect(s.objects.map(\.kind) == ["Deployment", "Secret", "Service", "CronJob"])
        #expect(s.totalObjects == 4)
        #expect(s.objects[0].namespace == "acme")
        #expect(s.objects[2].document == 3)
        #expect(s.namespaces == ["acme"])
        #expect(s.otherDocuments == 1)
        #expect(s.containers.map(\.name) == ["api", "sidecar", "migrate", "job"])
        #expect(s.containers.first { $0.name == "api" }?.runAsUser == 0)
        #expect(s.containers.first { $0.name == "sidecar" }?.runAsUser == 1000)
        #expect(s.containers.first { $0.name == "migrate" }?.role == "init")
        #expect(s.containers.first { $0.name == "job" }?.image?.pinnedByDigest == true)
        #expect(s.secrets == [.init(name: "harbor-creds", namespace: "acme", type: "Opaque", keys: ["username", "password", "token"])])

        let byCode = Dictionary(grouping: s.warnings, by: \.code)
        #expect(byCode[.privileged]?.first?.subject == "Deployment/harbor-api api")
        #expect(byCode[.unpinnedImage]?.compactMap(\.subject).sorted() == ["Deployment/harbor-api api", "Deployment/harbor-api sidecar"])
        #expect(byCode[.hostNetwork] != nil)
        #expect(byCode[.hostPath]?.count == 1)
        #expect(byCode[.dockerSocket]?.first?.level == .danger)
        #expect(byCode[.runsAsRoot]?.compactMap(\.subject).sorted() == ["Deployment/harbor-api api", "Deployment/harbor-api migrate"])
        #expect(s.warnings.first?.level == .danger)
        expectAbsent(doc, ["Q0FOQVJZLUs4Uy1VU0VS", "Q0FOQVJZLUs4Uy1QQVNT", "CANARY-K8S-TOKEN"])
    }

    @Test func kubernetesMalformed() {
        #expect(read("apiVersion: v1\nkind: Pod\nmetadata: {name: [", "pod.yaml") == nil || read("apiVersion: v1\nkind: Pod\nmetadata: {name: [", "pod.yaml")?.truncated == true)
        #expect(read("apiVersion: v1\n", "x.yaml") == nil)
        // Helm templates are not YAML; they never crash and give at most a partial summary.
        let helm = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {{ .Values.name }}\n  {{- include \"labels\" . | nindent 4 }}\n"
        _ = read(helm, "configmap.yaml")
        // Deep nesting stays within the depth bound.
        let deep = "apiVersion: v1\nkind: ConfigMap\ndata:\n" + String(repeating: "[", count: 5_000)
        _ = read(deep, "deep.yaml")
    }

    // MARK: Dockerfile

    static let dockerfile = """
    # syntax=docker/dockerfile:1
    ARG NODE=22
    FROM --platform=linux/amd64 node:${NODE}-alpine AS build
    WORKDIR /src
    COPY package.json \\
         package-lock.json ./
    RUN npm ci && \\
        curl -fsSL https://get.acme.example/install.sh | sh
    RUN <<EOF
    echo FROM inside a heredoc is not an instruction
    wget -qO- https://acme.example/x | bash
    EOF
    ADD https://acme.example/notes.tar.gz /opt/
    ADD --checksum=sha256:abc https://acme.example/ok.tar.gz /opt/
    FROM nginx AS runtime
    COPY --from=build /src/dist /usr/share/nginx/html
    EXPOSE 80 443
    USER root
    HEALTHCHECK CMD curl -f http://localhost/ || exit 1
    CMD ["nginx", "-g", "daemon off;"]
    """

    @Test func dockerfileStagesInstructionsAndWarnings() throws {
        guard case .dockerfile(let s) = try #require(read(Self.dockerfile, "Dockerfile")) else { Issue.record("wrong kind"); return }
        #expect(s.stages.map(\.name) == ["build", "runtime"])
        #expect(s.stages[0].base == "node:${NODE}-alpine")
        #expect(s.stages[0].platform == "linux/amd64")
        #expect(s.stages[0].image?.usesVariable == true)
        #expect(s.stages[1].image?.floats == true)
        #expect(s.stages[1].line == 15)
        let counts = Dictionary(uniqueKeysWithValues: s.instructions.map { ($0.name, $0.count) })
        #expect(counts["FROM"] == 2)
        #expect(counts["RUN"] == 2)
        #expect(counts["COPY"] == 2)
        #expect(counts["ADD"] == 2)
        #expect(counts["ARG"] == 1)
        #expect(s.finalUser == "root")
        #expect(s.exposedPorts == ["80", "443"])
        #expect(s.hasEntrypoint)
        #expect(s.hasHealthcheck)
        let codes = s.warnings.map(\.code)
        #expect(codes.filter { $0 == .pipeToShell }.count == 2)    // the continued RUN and the heredoc
        #expect(codes.filter { $0 == .remoteAdd }.count == 1)      // the --checksum one is fine
        #expect(codes.contains(.rootUser))
        #expect(codes.contains(.unpinnedImage))
        #expect(!codes.contains(.privileged))
    }

    @Test func dockerfileWithoutUserAndPinnedBase() throws {
        let text = "FROM harbor.example:5000/acme/base@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nRUN echo hi\n"
        guard case .dockerfile(let s) = try #require(read(text, "api.Dockerfile")) else { Issue.record("wrong kind"); return }
        #expect(s.stages[0].image?.pinnedByDigest == true)
        #expect(s.finalUser == nil)
        #expect(s.warnings.map(\.code) == [.rootUser])
        let user = "FROM acme/base:1.0\nUSER 10001:10001\n"
        #expect(read(user, "Containerfile")?.warnings.isEmpty == true)
    }

    @Test func dockerfileMalformed() {
        #expect(read("", "Dockerfile") == nil)
        #expect(read("hello there\nthis is prose\n", "Dockerfile") == nil)
        _ = read("FROM \\\n\\\n\\\n", "Dockerfile")
        _ = read("RUN <<EOF\nnever closed\n", "Dockerfile")
        _ = read(String(repeating: "FROM a\n", count: 3), "Dockerfile")
        #expect(read("FROM\n", "Dockerfile")?.kind == .dockerfile)
    }

    // MARK: HAR

    static let har = """
    {"log": {
      "version": "1.2",
      "creator": {"name": "AcmeCapture", "version": "3.1"},
      "pages": [{"id": "page_1"}],
      "entries": [
        {"startedDateTime": "2026-03-01T10:00:00.000Z", "time": 120.5,
         "request": {"method": "GET", "url": "https://user:CANARY-URL-PASS@notes.acme.example/api/notes?token=CANARY-QUERY&page=2#frag",
                     "headers": [{"name": "Authorization", "value": "Bearer CANARY-BEARER"},
                                 {"name": "Cookie", "value": "sid=CANARY-SID; theme=dark"}],
                     "cookies": []},
         "response": {"status": 200, "headers": [{"name": "Set-Cookie", "value": "session=CANARY-SET; Path=/; HttpOnly"}],
                      "cookies": [], "content": {"size": 2048, "mimeType": "application/json"}, "bodySize": 900}},
        {"startedDateTime": "2026-03-01T10:00:00.250Z", "time": 50,
         "request": {"method": "POST", "url": "https://cdn.harbor.example/upload", "postData": {"text": "CANARY-BODY"},
                     "headers": [], "cookies": [{"name": "csrf", "value": "CANARY-CSRF"}]},
         "response": {"status": 201, "headers": [], "cookies": [{"name": "uploaded", "value": "CANARY-UP"}],
                      "content": {"size": -1}, "bodySize": 12}},
        {"startedDateTime": "2026-03-01T11:00:01+01:00", "time": 10,
         "request": {"method": "GET", "url": "https://notes.acme.example/", "headers": []},
         "response": {"status": 0, "content": {}}}
      ]}}
    """

    @Test func harWaterfallHostsAndCredentialNamesOnly() throws {
        let doc = read(Self.har, "session.har")
        guard case .har(let s) = try #require(doc) else { Issue.record("wrong kind"); return }
        #expect(s.version == "1.2")
        #expect(s.creator == "AcmeCapture 3.1")
        #expect(s.pages == 1)
        #expect(s.totalEntries == 3)
        #expect(s.hosts == [.init(name: "notes.acme.example", count: 2), .init(name: "cdn.harbor.example", count: 1)])
        let first = s.entries[0]
        #expect(first.startOffsetMs == 0)
        #expect(first.durationMs == 120.5)
        #expect(first.method == "GET")
        #expect(first.status == 200)
        #expect(first.host == "notes.acme.example")
        #expect(first.path == "/api/notes?token&page")
        #expect(first.responseSize == 2048)
        #expect(s.entries[1].startOffsetMs == 250)
        #expect(s.entries[1].responseSize == 12)
        #expect(s.entries[2].startOffsetMs == 1000)       // 11:00:01+01:00 is 10:00:01Z
        #expect(s.entries[2].status == 0)
        #expect(s.totalTimeMs == 1010)
        #expect(s.requestsWithBody == 1)
        #expect(s.credentials.authorizationCount == 1)
        #expect(s.credentials.cookieNames.map(\.name) == ["sid", "theme", "csrf"])
        #expect(s.credentials.setCookieNames.map(\.name) == ["session", "uploaded"])
        #expect(s.warnings.map(\.code) == [.authorizationHeaders, .cookies])
        #expect(s.warnings[0].level == .danger)
        expectAbsent(doc, ["CANARY-URL-PASS", "CANARY-QUERY", "CANARY-BEARER", "CANARY-SID", "CANARY-SET", "CANARY-BODY",
                           "CANARY-CSRF", "CANARY-UP", "Bearer", "frag"])
    }

    @Test func harPathIsCutTo120() throws {
        let long = "/" + String(repeating: "a", count: 300)
        let text = "{\"log\": {\"creator\": {\"name\": \"x\"}, \"entries\": [{\"request\": {\"method\": \"GET\", \"url\": \"https://acme.example\(long)\"}, \"response\": {\"status\": 200}}]}}"
        guard case .har(let s) = try #require(read(text, "x.har")) else { Issue.record("wrong kind"); return }
        #expect(s.entries[0].path.count == 120)
        #expect(s.entries[0].startOffsetMs == nil)
    }

    @Test func harMalformed() {
        #expect(read("{\"log\": 7}", "x.har") == nil)
        #expect(read("{{{{", "x.har") == nil)
        let cut = read("{\"log\": {\"creator\": {\"name\": \"x\"}, \"entries\": [{\"request\": {\"method\": \"GET\", \"url\": \"https://a.example/\"}}, {\"req", "x.har")
        #expect(cut?.truncated == true)
        #expect(cut.flatMap { if case .har(let s) = $0 { s.totalEntries } else { nil } } ?? 0 >= 1)
        _ = read("{\"log\": {\"entries\": [{\"startedDateTime\": \"yesterday\", \"time\": -5, \"request\": {\"url\": 3}}]}}", "x.har")
    }

    // MARK: Limits

    @Test func listsAreCappedAndFlaggedTruncated() throws {
        var services = "services:\n"
        for k in 0..<2_500 { services += "  svc-\(k):\n    image: acme/notes:\(k)\n" }
        guard case .compose(let c) = try #require(read(services, "compose.yaml")) else { Issue.record("wrong kind"); return }
        #expect(c.totalServices == 2_500)
        #expect(c.services.count == InfraReader.maxItems)
        #expect(c.truncated)

        var entries: [String] = []
        for k in 0..<2_100 {
            entries.append("{\"startedDateTime\": \"2026-03-01T10:00:00Z\", \"time\": \(k), \"request\": {\"method\": \"GET\", \"url\": \"https://h\(k % 3).acme.example/\(k)\"}, \"response\": {\"status\": 200}}")
        }
        let har = "{\"log\": {\"creator\": {\"name\": \"x\"}, \"entries\": [\(entries.joined(separator: ","))]}}"
        guard case .har(let h) = try #require(read(har, "big.har")) else { Issue.record("wrong kind"); return }
        #expect(h.totalEntries == 2_100)
        #expect(h.entries.count == InfraReader.maxItems)
        #expect(h.truncated)
        #expect(h.totalTimeMs == 2_099)

        var docs: [String] = []
        for k in 0..<2_050 { docs.append("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cm-\(k)\n") }
        guard case .kubernetes(let k) = try #require(read(docs.joined(separator: "---\n"), "many.yaml")) else { Issue.record("wrong kind"); return }
        #expect(k.totalObjects == 2_050)
        #expect(k.objects.count == InfraReader.maxItems)
        #expect(k.truncated)
    }

    @Test func inputPastEightMegabytesIsCut() throws {
        var text = "FROM acme/base:1.0\n"
        let line = "RUN echo " + String(repeating: "x", count: 1_000) + "\n"
        while text.utf8.count <= InfraReader.maxBytes { text += line }
        guard case .dockerfile(let s) = try #require(read(text, "Dockerfile")) else { Issue.record("wrong kind"); return }
        #expect(s.truncated)
    }

    @Test func secretNameHeuristic() {
        for name in ["password", "DB_PASSWORD", "client_secret", "ClientSecret", "api-key", "private_key", "access_key",
                     "github_token", "connection_string", "secret"] {
            #expect(InfraText.looksSecret(name), "\(name)")
        }
        for name in ["secret_arn", "token_type", "password_length", "username", "identifier", "tokenizer_id", "region"] {
            #expect(!InfraText.looksSecret(name), "\(name)")
        }
    }

    @Test func imageReferences() {
        #expect(InfraImage("nginx").floats)
        #expect(InfraImage("nginx:latest").floats)
        #expect(!InfraImage("nginx:1.27").floats)
        #expect(InfraImage("harbor.example:5000/acme/notes").tag == nil)
        #expect(InfraImage("harbor.example:5000/acme/notes:2").tag == "2")
        #expect(!InfraImage("acme/notes@sha256:00").floats)
        #expect(!InfraImage("acme/notes:${TAG}").floats)
    }
}
