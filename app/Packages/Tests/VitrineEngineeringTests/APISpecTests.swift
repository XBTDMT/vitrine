import Foundation
import Testing
@testable import VitrineEngineering

/// API and schema files (E-3). Every fixture is invented here (Acme and Harbor names); no real spec is copied.
/// roadmap: S-22
@Suite struct APISpecTests {
    func read(_ text: String, _ name: String) -> APISpec? {
        APISpecReader.read(data: Data(text.utf8), fileName: name)
    }

    func hasWarning(_ warnings: [APISpecWarning], _ level: APISpecWarning.Level, _ fragment: String) -> Bool {
        warnings.contains { $0.level == level && $0.reason.contains(fragment) }
    }

    // MARK: OpenAPI

    static let harborYAML = """
    openapi: 3.1.0
    info:
      title: Acme Harbor API
      version: 1.4.0
      description: |
        Book berths and track ships in the Acme harbor.
        Invented for Vitrine's tests.
    servers:
      - url: https://api.harbor.example/v1
        description: Production
      - url: http://staging.harbor.example/v1
      - url: http://localhost:8080
    security:
      - bearerAuth: []
    tags:
      - name: ships
        description: Ships in port
      - name: berths
    paths:
      /ships:
        get:
          operationId: listShips
          summary: List ships
          tags: [ships]
        post:
          operationId: createShip
          summary: Register a ship
          tags: [ships]
      /ships/{id}:
        get:
          operationId: getShip
          tags: [ships]
        delete:
          operationId: removeShip
          deprecated: true
          tags: [ships, berths]
      /health:
        get:
          operationId: health
          security: []
      /berths:
        get:
          operationId: listBerths
          tags: [berths]
          security:
            - {}
            - apiKey: []
    components:
      schemas:
        Ship: { type: object }
        Berth: { type: object }
      parameters:
        ShipId: { name: id, in: path }
      securitySchemes:
        bearerAuth:
          type: http
          scheme: bearer
          bearerFormat: JWT
        apiKey:
          type: apiKey
          in: header
          name: X-Harbor-Key
    """

    @Test func openAPI31YAMLReadsOperationsTagsSecurityAndServers() throws {
        let spec = try #require(read(Self.harborYAML, "openapi.yaml"))
        guard case .openAPI(let s) = spec else { Issue.record("not OpenAPI"); return }
        #expect(s.dialect == .openAPI31)
        #expect(s.specVersion == "3.1.0")
        #expect(s.title == "Acme Harbor API")
        #expect(s.apiVersion == "1.4.0")
        #expect(s.description?.hasPrefix("Book berths") == true)
        #expect(s.servers.map(\.url) == ["https://api.harbor.example/v1", "http://staging.harbor.example/v1", "http://localhost:8080"])
        #expect(s.servers.map(\.isPlainHTTP) == [false, true, false])
        #expect(s.operationCount == 6)
        #expect(s.pathCount == 4)
        #expect(s.operations.map { "\($0.method) \($0.path)" }.first == "GET /ships")
        let health = try #require(s.operations.first { $0.operationId == "health" })
        #expect(health.isUnsecured && health.declaresSecurity)
        let ship = try #require(s.operations.first { $0.operationId == "getShip" })
        #expect(ship.security == ["bearerAuth"] && !ship.declaresSecurity)
        let berths = try #require(s.operations.first { $0.operationId == "listBerths" })
        #expect(berths.allowsAnonymous && berths.security == ["apiKey"])
        #expect(s.deprecatedCount == 1)
        #expect(s.tagGroups.map(\.name) == ["ships", "berths", nil])
        #expect(s.tagGroups[0].description == "Ships in port")
        #expect(s.tagGroups[0].operationIndices.count == 4)
        #expect(s.tagGroups[1].operationIndices.count == 2)        // removeShip is in both groups
        #expect(s.schemaCount == 2)
        #expect(s.componentCounts.contains { $0.kind == "parameters" && $0.count == 1 })
        #expect(s.securitySchemes.map(\.name) == ["bearerAuth", "apiKey"])
        #expect(s.securitySchemes[0].detail == "bearer (JWT)")
        #expect(s.securitySchemes[1].detail == "header X-Harbor-Key")
        #expect(s.globalSecurity == ["bearerAuth"])
        #expect(!s.truncated)

        #expect(hasWarning(s.warnings, .caution, "GET /health"))
        #expect(hasWarning(s.warnings, .danger, "http://staging.harbor.example/v1"))
        #expect(!s.warnings.contains { $0.reason.contains("localhost") })

        let p = spec.presentation
        #expect(p.headline == "Acme Harbor API 1.4.0")
        #expect(p.facts.contains(APISpecFact("Operations", "6")))
        #expect(p.facts.contains(APISpecFact("Format", "OpenAPI 3.1.0")))
        #expect(p.outline.first == APISpecOutlineItem(depth: 0, title: "ships", detail: "4 operations"))
        #expect(p.outline.contains { $0.title == "DELETE /ships/{id}" && $0.deprecated })
        #expect(p.warnings.first?.level == .danger)                 // most serious first
    }

    @Test func swagger2JSONReadsHostAndWarnsOnWeakSchemes() throws {
        let json = """
        {
          "swagger": "2.0",
          "info": { "title": "Harbor Legacy", "version": "0.9" },
          "host": "legacy.harbor.example",
          "basePath": "/v2",
          "schemes": ["http", "https"],
          "securityDefinitions": {
            "basic": { "type": "basic" },
            "key": { "type": "apiKey", "in": "query", "name": "key" },
            "oauth": { "type": "oauth2", "flow": "implicit", "authorizationUrl": "https://auth.harbor.example" }
          },
          "security": [ { "basic": [] } ],
          "paths": {
            "/docks": { "get": { "operationId": "docks", "tags": ["docks"] } },
            "/docks/{id}": { "get": { "operationId": "docks" }, "parameters": [] }
          },
          "definitions": { "Dock": { "type": "object" } }
        }
        """
        let spec = try #require(read(json, "swagger.json"))
        guard case .openAPI(let s) = spec else { Issue.record("not OpenAPI"); return }
        #expect(s.dialect == .swagger2)
        #expect(s.servers.map(\.url) == ["http://legacy.harbor.example/v2", "https://legacy.harbor.example/v2"])
        #expect(s.operationCount == 2)
        #expect(s.schemaCount == 1)
        #expect(s.securitySchemes.map(\.type) == ["basic", "apiKey", "oauth2"])
        #expect(hasWarning(s.warnings, .caution, "HTTP Basic"))
        #expect(hasWarning(s.warnings, .caution, "URL query"))
        #expect(hasWarning(s.warnings, .caution, "implicit flow"))
        #expect(hasWarning(s.warnings, .caution, "Operation IDs used more than once: docks"))
        #expect(hasWarning(s.warnings, .danger, "http://legacy.harbor.example/v2"))
        #expect(spec.presentation.facts.contains(APISpecFact("Format", "Swagger 2.0")))
    }

    @Test func openAPIIsRecognisedByContentNotByName() {
        #expect(read(Self.harborYAML, "harbor-api") != nil)                 // no extension: sniffed by its key
        #expect(read(Self.harborYAML, "acme.openapi.yml") != nil)
        #expect(read(#"{ "name": "acme-harbor", "version": "1.0.0" }"#, "package.json") == nil)
        #expect(read(#"{ "$schema": "https://json.schemastore.org/tsconfig", "compilerOptions": { "strict": true } }"#, "tsconfig.json") == nil)
        #expect(read("name: harbor\nreplicas: 2\n", "values.yaml") == nil)
        #expect(read("just some notes about swagger\n", "notes.txt") == nil)
    }

    @Test func openAPIMalformedGivesPartialOrNil() {
        let broken = #"{ "openapi": "3.0.3", "info": { "title": "Acme Broken" }, "paths": { "/a": { "get": { "operationId": "a" } }, "/b": { "get": "#
        if let spec = read(broken, "openapi.json") {
            guard case .openAPI(let s) = spec else { Issue.record("not OpenAPI"); return }
            #expect(s.truncated)
            #expect(s.title == "Acme Broken")
            #expect(s.warnings.contains { $0.reason.contains("syntax error") })
        }
        // Broken YAML: whatever comes back, reading it and drawing it must not crash.
        _ = read("openapi: [3.0\n  : : :\n\t- {", "openapi.yaml")?.presentation
    }

    @Test func openAPIOperationListIsCappedAndCounted() throws {
        var yaml = "openapi: 3.0.0\ninfo: { title: Acme Many, version: '1' }\npaths:\n"
        for i in 0..<2_100 { yaml += "  /ships/\(i):\n    get: { operationId: op\(i) }\n" }
        let spec = try #require(read(yaml, "openapi.yaml"))
        guard case .openAPI(let s) = spec else { Issue.record("not OpenAPI"); return }
        #expect(s.operations.count == APISpecReader.maxListItems)
        #expect(s.operationCount == 2_100)
        #expect(s.truncated)
        #expect(spec.presentation.outline.count == APISpecReader.maxListItems)
        #expect(spec.presentation.outlineTruncated)
    }

    // MARK: GraphQL

    static let harborSDL = #"""
    """
    The Acme harbor schema.
    """
    schema { query: Query mutation: Mutation subscription: Subscription }

    directive @auth(role: String = "crew") repeatable on FIELD_DEFINITION | OBJECT

    scalar DateTime

    interface Node { id: ID! }

    "A ship in port"
    type Ship implements Node & Named @auth(role: "harbormaster") {
      id: ID!
      name: String
      oldName: String @deprecated(reason: "Use name")
      berth(at: DateTime): Berth
    }

    interface Named { name: String }

    type Berth implements Node { id: ID!, number: Int! }

    union Vessel = | Ship | Berth

    enum Status {
      DOCKED
      AT_SEA
      RETIRED @deprecated
    }

    input ShipInput {
      name: String!
      status: Status = DOCKED
      tags: [String!] = ["cargo", "fast"]
    }

    type Query {
      ship(id: ID!): Ship
      ships(first: Int = 10, after: String): [Ship!]!
    }

    extend type Query {
      vessels(status: Status): [Vessel]
    }

    type Mutation { registerShip(input: ShipInput!): Ship }
    type Subscription { arrivals: Ship! }
    """#

    @Test func graphQLSchemaReadsTypesRootsDirectivesAndDeprecations() throws {
        let spec = try #require(read(Self.harborSDL, "harbor.graphqls"))
        guard case .graphQL(let s) = spec else { Issue.record("not GraphQL"); return }
        #expect(s.documentKind == .schema)
        #expect(s.typeCounts[.object] == 5)
        #expect(s.typeCounts[.interface] == 2)
        #expect(s.typeCounts[.union] == 1)
        #expect(s.typeCounts[.enumeration] == 1)
        #expect(s.typeCounts[.input] == 1)
        #expect(s.typeCounts[.scalar] == 1)
        #expect(s.queryType == "Query" && s.mutationType == "Mutation" && s.subscriptionType == "Subscription")
        #expect(s.queryFields.map(\.signature) == ["ship(id: ID!): Ship", "ships(first: Int = 10, after: String): [Ship!]!",
                                                    "vessels(status: Status): [Vessel]"])
        #expect(s.mutationFields.map(\.signature) == ["registerShip(input: ShipInput!): Ship"])
        #expect(s.subscriptionFields.first?.type == "Ship!")
        let ship = try #require(s.types.first { $0.name == "Ship" })
        #expect(ship.implements == ["Node", "Named"])
        #expect(ship.description == "A ship in port")
        #expect(ship.directives == ["auth"])
        let old = try #require(ship.fields.first { $0.name == "oldName" })
        #expect(old.deprecated && old.deprecationReason == "Use name")
        #expect(s.types.first { $0.name == "Vessel" }?.unionMembers == ["Ship", "Berth"])
        let input = try #require(s.types.first { $0.name == "ShipInput" })
        #expect(input.fields.map(\.signature) == ["name: String!", "status: Status = DOCKED", "tags: [String!] = [\"cargo\" \"fast\"]"])
        #expect(s.types.contains { $0.name == "Query" && $0.isExtension })
        #expect(s.directives.first?.name == "auth")
        #expect(s.directives.first?.repeatable == true)
        #expect(s.directives.first?.locations == ["FIELD_DEFINITION", "OBJECT"])
        #expect(s.deprecated == ["Ship.oldName", "Status.RETIRED"])
        #expect(hasWarning(s.warnings, .caution, "@deprecated"))
        #expect(!s.truncated)

        let p = spec.presentation
        #expect(p.headline == "GraphQL schema · 11 types")
        #expect(p.outline.first == APISpecOutlineItem(depth: 0, title: "Query", detail: "3 fields"))
        #expect(p.outline.contains { $0.title == "oldName: String" && $0.deprecated })
    }

    @Test func graphQLOperationsDocumentListsOperationsAndFragments() throws {
        let doc = """
        query ShipById($id: ID!, $withBerth: Boolean = false) {
          ship(id: $id) { ...ShipParts berth @include(if: $withBerth) { number } }
        }
        mutation Register { registerShip(input: { name: "Harbor Queen", tags: ["a"] }) { id } }
        fragment ShipParts on Ship { id name }
        { ships { id } }
        """
        let spec = try #require(read(doc, "queries.graphql"))
        guard case .graphQL(let s) = spec else { Issue.record("not GraphQL"); return }
        #expect(s.documentKind == .operations)
        #expect(s.operations.map(\.name) == ["ShipById", "Register", nil])
        #expect(s.operations.map(\.kind) == [.query, .mutation, .query])
        #expect(s.operations[0].variables.map(\.signature) == ["$id: ID!", "$withBerth: Boolean = false"])
        #expect(s.fragments == [GraphQLSummary.Fragment(name: "ShipParts", typeCondition: "Ship")])
        #expect(hasWarning(s.warnings, .caution, "anonymous operation"))
        #expect(spec.presentation.headline == "GraphQL operations · 3 operations")
    }

    @Test func graphQLDuplicateTypeIsDangerAndBrokenDefinitionsAreSkipped() throws {
        let doc = """
        type Ship { id: ID! }
        type Ship { name: String }
        type Berth { number: Int!
        type Dock { id: ID! }
        enum Tide { HIGH LOW }
        """
        let spec = try #require(read(doc, "broken.gql"))
        guard case .graphQL(let s) = spec else { Issue.record("not GraphQL"); return }
        #expect(hasWarning(s.warnings, .danger, "Defined more than once: Ship"))
        #expect(s.warnings.contains { $0.level == .caution && $0.reason.hasPrefix("Line 4") })
        #expect(s.types.map(\.name).contains("Tide"))
        #expect(read("This is not GraphQL at all, just prose; with % signs.", "notes.graphql") == nil)
        #expect(read("type Ship { name: String", "cut.graphql") == nil)
        if let empty = read("# only a comment\n", "empty.graphql"), case .graphQL(let e) = empty {
            #expect(e.documentKind == .empty)
        } else {
            Issue.record("an empty GraphQL file is an empty document")
        }
    }

    @Test func graphQLTypeListIsCappedAndCounted() throws {
        let doc = (0..<2_100).map { "scalar Harbor\($0)" }.joined(separator: "\n")
        let spec = try #require(read(doc, "many.graphql"))
        guard case .graphQL(let s) = spec else { Issue.record("not GraphQL"); return }
        #expect(s.types.count == APISpecReader.maxListItems)
        #expect(s.typeCounts[.scalar] == 2_100)
        #expect(s.truncated)
    }

    // MARK: Protocol Buffers

    static let harborProto = """
    // Invented for Vitrine's tests.
    syntax = "proto3";
    package acme.harbor.v1;

    import "google/protobuf/timestamp.proto";
    import public "acme/common.proto";

    option java_package = "com.acme.harbor";
    option go_package = "example.com/acme/harbor;harbor";
    option (acme.rules).strict = { level: 2 };

    /* Ships in port. */
    message Ship {
      string id = 1;
      string name = 2 [deprecated = true];
      repeated string tags = 3;
      map<string, Berth> berths = 4;
      oneof owner {
        string company = 5;
        Person person = 6;
      }
      .google.protobuf.Timestamp arrived = 7;
      optional int32 crew = 8 [(acme.rules).min = { value: 1 }];
      reserved 20, 30 to 39;
      reserved "legacy";

      message Person { string name = 1; }
      enum Kind { KIND_UNSPECIFIED = 0; CARGO = 1; TANKER = 2; }
    }

    message Berth { int32 number = 1; }

    enum Status {
      STATUS_UNSPECIFIED = 0;
      DOCKED = 1;
      AT_SEA = 2 [deprecated = true];
    }

    service HarborService {
      rpc GetShip (GetShipRequest) returns (Ship);
      rpc WatchArrivals (WatchRequest) returns (stream Ship);
      rpc UploadManifest (stream ManifestChunk) returns (UploadReply) {
        option deprecated = true;
      }
      rpc Chat (stream Message) returns (stream Message) {}
    }
    """

    @Test func protobufReadsMessagesEnumsServicesAndOptions() throws {
        let spec = try #require(read(Self.harborProto, "harbor.proto"))
        guard case .protobuf(let s) = spec else { Issue.record("not protobuf"); return }
        #expect(s.syntax == "proto3")
        #expect(s.package == "acme.harbor.v1")
        #expect(s.imports == [.init(path: "google/protobuf/timestamp.proto", modifier: nil), .init(path: "acme/common.proto", modifier: "public")])
        #expect(s.options.first == .init(name: "java_package", value: "\"com.acme.harbor\""))
        #expect(s.options.contains { $0.name == "(acme.rules).strict" && $0.value == "{…}" })
        #expect(s.messageCount == 3)
        #expect(s.enumCount == 2)
        #expect(s.fieldCount == 10)
        #expect(s.rpcCount == 4)
        let ship = try #require(s.messages.first)
        #expect(ship.fullName == "acme.harbor.v1.Ship")
        #expect(ship.fields.map(\.name) == ["id", "name", "tags", "berths", "company", "person", "arrived", "crew"])
        #expect(ship.fields[1].deprecated)
        #expect(ship.fields[2].label == .repeated)
        #expect(ship.fields[3].isMap && ship.fields[3].mapKey == "string" && ship.fields[3].mapValue == "Berth")
        #expect(ship.fields[3].type == "map<string, Berth>")
        #expect(ship.fields[4].oneof == "owner")
        #expect(ship.fields[6].type == ".google.protobuf.Timestamp")
        #expect(ship.fields[7].label == .optional && ship.fields[7].number == 8)
        #expect(ship.oneofs == [.init(name: "owner", fieldNames: ["company", "person"])])
        #expect(ship.reservedNumbers == ["20", "30 to 39"])
        #expect(ship.reservedNames == ["legacy"])
        #expect(ship.messages.map(\.fullName) == ["acme.harbor.v1.Ship.Person"])
        #expect(ship.enums.first?.values.map(\.name) == ["KIND_UNSPECIFIED", "CARGO", "TANKER"])
        #expect(s.enums.first?.values.last?.deprecated == true)
        let rpcs = try #require(s.services.first?.rpcs)
        #expect(rpcs.map(\.signature) == ["GetShip(GetShipRequest) returns (Ship)", "WatchArrivals(WatchRequest) returns (stream Ship)",
                                          "UploadManifest(stream ManifestChunk) returns (UploadReply)", "Chat(stream Message) returns (stream Message)"])
        #expect(rpcs[2].deprecated)
        #expect(!s.warnings.contains { $0.level == .danger })
        #expect(hasWarning(s.warnings, .caution, "UploadManifest"))
        #expect(!s.truncated)

        let p = spec.presentation
        #expect(p.headline == "acme.harbor.v1 (proto3)")
        #expect(p.outline.first == APISpecOutlineItem(depth: 0, title: "service HarborService", detail: "4 RPCs"))
        #expect(p.outline.contains { $0.depth == 1 && $0.title == "repeated string tags = 3" })
    }

    @Test func protobufWarnsOnNumberingFaults() throws {
        let proto = """
        package acme.dock;
        message Dock {
          required string id = 1;
          optional string name = 1;
          optional int32 slot = 19500;
          optional int32 old = 5;
          reserved 5;
        }
        enum Tide { HIGH = 1; LOW = 1; }
        """
        let spec = try #require(read(proto, "dock.proto"))
        guard case .protobuf(let s) = spec else { Issue.record("not protobuf"); return }
        #expect(s.syntax == nil)
        #expect(hasWarning(s.warnings, .caution, "no syntax line"))
        #expect(hasWarning(s.warnings, .danger, "Message Dock uses field number 1 more than once (id, name)"))
        #expect(hasWarning(s.warnings, .danger, "19500"))
        #expect(hasWarning(s.warnings, .danger, "Dock.old uses number 5, which its message marks reserved"))
        #expect(hasWarning(s.warnings, .danger, "HIGH and LOW the same number 1"))
        #expect(hasWarning(s.warnings, .caution, "Required field (1 in all): Dock.id"))

        let three = "syntax = \"proto3\";\nenum Flag { ON = 1; OFF = 2; }\n"
        guard case .protobuf(let t)? = read(three, "flag.proto") else { Issue.record("not protobuf"); return }
        #expect(hasWarning(t.warnings, .danger, "proto3 needs the first value to be 0"))
    }

    @Test func protobufMalformedSkipsAndGarbageIsNil() throws {
        let proto = """
        syntax = "proto3";
        message Ship {
          string id = 1;
          %%% nonsense here;
          string name = 2;
        }
        message Berth { int32 number = 1; }
        """
        let spec = try #require(read(proto, "ship.proto"))
        guard case .protobuf(let s) = spec else { Issue.record("not protobuf"); return }
        #expect(s.messages.map(\.name) == ["Ship", "Berth"])
        #expect(s.messages[0].fields.map(\.name) == ["id", "name"])
        #expect(s.warnings.contains { $0.level == .caution && $0.reason.hasPrefix("Line 4") })
        #expect(read("%%% this is not a proto file ###", "x.proto") == nil)
        #expect(read("syntax = \"proto3\";\nmessage Open { string a = 1;", "open.proto") != nil)
    }

    @Test func protobufFieldsAreCappedAndNestingIsBounded() throws {
        var proto = "syntax = \"proto3\";\nmessage Wide {\n"
        for i in 1...2_100 { proto += "  string f\(i) = \(i);\n" }
        proto += "}\n"
        guard case .protobuf(let s)? = read(proto, "wide.proto") else { Issue.record("not protobuf"); return }
        #expect(s.messages.first?.fields.count == APISpecReader.maxListItems)
        #expect(s.fieldCount == 2_100)
        #expect(s.truncated)

        let deep = "syntax = \"proto3\";\n" + String(repeating: "message M { ", count: 60) + String(repeating: "} ", count: 60)
        guard case .protobuf(let d)? = read(deep, "deep.proto") else { Issue.record("not protobuf"); return }
        #expect(d.truncated)
        #expect(d.messages.count == 1)
    }

    // MARK: JSON Schema

    static let harborSchema = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://schemas.harbor.example/ship.json",
      "title": "Acme Ship",
      "description": "A ship registered with the Acme harbor.",
      "type": "object",
      "required": ["id", "name", "captain"],
      "properties": {
        "id": { "type": "string", "format": "uuid", "description": "Registry id" },
        "name": { "type": "string" },
        "status": { "enum": ["docked", "at-sea", "retired"] },
        "tags": { "type": "array", "items": { "type": "string" } },
        "owner": {
          "type": "object",
          "properties": {
            "company": { "type": "string" },
            "address": {
              "type": "object",
              "required": ["city"],
              "properties": { "city": { "type": "string" }, "zip": { "type": ["string", "null"] } }
            }
          }
        },
        "berth": { "$ref": "#/$defs/Berth" },
        "crew": { "type": "array", "items": { "$ref": "#/$defs/Sailor" } },
        "cargo": { "oneOf": [ { "type": "string" }, { "type": "integer" } ], "deprecated": true },
        "dock": { "$ref": "#/$defs/Dock" }
      },
      "$defs": {
        "Berth": { "type": "object", "properties": { "number": { "type": "integer" } } },
        "Sailor": { "type": "object" }
      }
    }
    """

    @Test func jsonSchemaReadsPropertiesTreeDefinitionsAndRefs() throws {
        let spec = try #require(read(Self.harborSchema, "ship.json"))
        guard case .jsonSchema(let s) = spec else { Issue.record("not JSON Schema"); return }
        #expect(s.title == "Acme Ship")
        #expect(s.draft == "2020-12")
        #expect(s.id == "https://schemas.harbor.example/ship.json")
        #expect(s.rootTypes == ["object"])
        #expect(s.properties.map(\.name) == ["id", "name", "status", "tags", "owner", "berth", "crew", "cargo", "dock"])
        let id = s.properties[0]
        #expect(id.required && id.format == "uuid" && id.description == "Registry id" && id.types == ["string"])
        #expect(s.properties[2].types == ["enum"] && s.properties[2].enumValues == ["docked", "at-sea", "retired"])
        #expect(s.properties[3].types == ["array<string>"])
        let address = try #require(s.properties[4].children.first { $0.name == "address" })
        #expect(address.children.map(\.name) == ["city", "zip"])
        #expect(address.children[0].required)
        #expect(address.children[1].types == ["string", "null"])
        #expect(s.properties[5].ref == "#/$defs/Berth")
        #expect(s.properties[6].types == ["array<Sailor>"])
        #expect(s.properties[7].combinators == ["oneOf (2)"] && s.properties[7].deprecated)
        #expect(s.definitionCount == 2 && s.definitionNames == ["Berth", "Sailor"])
        #expect(s.refs == ["#/$defs/Berth", "#/$defs/Sailor", "#/$defs/Dock"])
        #expect(hasWarning(s.warnings, .caution, "#/$defs/Dock"))
        #expect(hasWarning(s.warnings, .caution, "captain"))
        #expect(!s.truncated)

        let p = spec.presentation
        #expect(p.headline == "Acme Ship")
        #expect(p.facts.contains(APISpecFact("Draft", "2020-12")))
        #expect(p.outline.first == APISpecOutlineItem(depth: 0, title: "id", detail: "string · required · uuid"))
        #expect(p.outline.contains { $0.depth == 2 && $0.title == "city" })
    }

    @Test func jsonSchemaTreeStopsAtDepthSix() throws {
        var inner = #"{ "type": "string" }"#
        for level in (1...8).reversed() { inner = #"{ "type": "object", "properties": { "l\#(level)": \#(inner) } }"# }
        let doc = #"{ "$schema": "http://json-schema.org/draft-07/schema#", "type": "object", "properties": { "root": \#(inner) } }"#
        guard case .jsonSchema(let s)? = read(doc, "deep.json") else { Issue.record("not JSON Schema"); return }
        #expect(s.draft == "draft-07")
        var node = try #require(s.properties.first)
        var depth = 1
        while let next = node.children.first { node = next; depth += 1 }
        #expect(depth == APISpecReader.maxPropertyDepth)
        #expect(node.childrenCut)
    }

    @Test func jsonSchemaIsRecognisedByMetaSchemaOrName() {
        #expect(read(#"{ "type": "object", "properties": { "a": { "type": "string" } } }"#, "harbor.schema.json") != nil)
        #expect(read(#"{ "$schema": "https://json.schemastore.org/foo", "berths": 4 }"#, "harbor.json") == nil)
        #expect(read("$schema: http://json-schema.org/draft-07/schema#\ntype: object\nproperties:\n  a: { type: string }\n", "dock.yaml") != nil)
        if let spec = read(#"{ "$schema": "https://json-schema.org/draft/2020-12/schema", "title": "Cut", "properties": { "a": "#, "cut.json"),
           case .jsonSchema(let s) = spec {
            #expect(s.truncated)
        }
    }

    // MARK: Avro

    static let harborAvsc = """
    {
      "type": "record",
      "name": "Ship",
      "namespace": "acme.harbor",
      "doc": "A ship in port.",
      "fields": [
        { "name": "id", "type": "string" },
        { "name": "nickname", "type": ["null", "string"], "default": null, "doc": "Optional" },
        { "name": "flag", "type": ["string", "null"], "default": null },
        { "name": "arrived", "type": { "type": "long", "logicalType": "timestamp-millis" } },
        { "name": "fee", "type": { "type": "bytes", "logicalType": "decimal", "precision": 9, "scale": 2 } },
        { "name": "kind", "type": { "type": "enum", "name": "Kind", "symbols": ["CARGO", "TANKER"], "default": "FERRY" } },
        { "name": "crew", "type": { "type": "array", "items": { "type": "record", "name": "Sailor", "fields": [ { "name": "name", "type": "string" } ] } } },
        { "name": "cargo", "type": { "type": "map", "values": "long" } },
        { "name": "hash", "type": { "type": "fixed", "name": "Hash", "size": 16 } },
        { "name": "dock", "type": "acme.harbor.Dock" },
        { "name": "id", "type": "int" }
      ]
    }
    """

    @Test func avroSchemaReadsRecordsTypesDefaultsAndWarnings() throws {
        let spec = try #require(read(Self.harborAvsc, "ship.avsc"))
        guard case .avro(let s) = spec else { Issue.record("not Avro"); return }
        #expect(s.source == .schema)
        #expect(s.rootType == "record acme.harbor.Ship")
        #expect(s.namespace == "acme.harbor" && s.doc == "A ship in port.")
        #expect(s.namedTypes.map(\.fullName) == ["acme.harbor.Ship", "acme.harbor.Kind", "acme.harbor.Sailor", "acme.harbor.Hash"])
        #expect(s.namedTypes[2].definedIn == "acme.harbor.Ship")
        #expect(s.namedTypes[3].size == 16)
        let ship = s.namedTypes[0]
        #expect(ship.fields.map(\.type) == ["string", "null | string", "string | null", "timestamp-millis (long)", "decimal(9,2) (bytes)",
                                            "acme.harbor.Kind", "array<acme.harbor.Sailor>", "map<long>", "acme.harbor.Hash",
                                            "acme.harbor.Dock", "int"])
        #expect(ship.fields[1].optional && ship.fields[1].defaultValue == "null" && ship.fields[1].doc == "Optional")
        #expect(ship.fields[3].logicalType == "timestamp-millis")
        #expect(hasWarning(s.warnings, .caution, "Ship.flag defaults to null"))
        #expect(!s.warnings.contains { $0.reason.contains("Ship.nickname") })
        #expect(hasWarning(s.warnings, .danger, "Kind defaults to FERRY"))
        #expect(hasWarning(s.warnings, .danger, "Record Ship has field names used more than once (id)"))
        #expect(hasWarning(s.warnings, .caution, "acme.harbor.Dock"))
        #expect(spec.presentation.headline == "record acme.harbor.Ship")
        #expect(spec.presentation.facts.contains(APISpecFact("Records", "2")))
    }

    @Test func avroProtocolAndAvroInPlainJSON() throws {
        let avpr = """
        { "protocol": "HarborService", "namespace": "acme.harbor",
          "types": [ { "type": "record", "name": "Berth", "fields": [ { "name": "number", "type": "int" } ] },
                     { "type": "error", "name": "Full", "fields": [] } ],
          "messages": { "reserve": { "request": [ { "name": "berth", "type": "Berth" } ], "response": "boolean", "errors": ["Full"] },
                        "ping": { "request": [], "response": "null", "one-way": true } } }
        """
        guard case .avro(let p)? = read(avpr, "harbor.avpr") else { Issue.record("not Avro"); return }
        #expect(p.source == .protocolJSON && p.protocolName == "HarborService")
        #expect(p.messages.map(\.name) == ["reserve", "ping"])
        #expect(p.messages[0].parameters.first?.type == "Berth" && p.messages[0].errors == ["Full"])
        #expect(p.messages[1].oneWay)
        #expect(p.warnings.isEmpty)
        #expect(read(#"{ "type": "record", "name": "Dock", "fields": [ { "name": "id", "type": "long" } ] }"#, "dock.json") != nil)
    }

    @Test func avroIDLReadsProtocolRecordsAndMessages() throws {
        let idl = """
        /** The Acme harbor protocol. */
        @namespace("acme.harbor")
        protocol HarborService {
          import idl "common.avdl";

          enum Kind { CARGO, TANKER } = CARGO;
          fixed Hash(16);

          /** A ship in port. */
          record Ship {
            string id;
            string? nickname = null;
            union { null, int } crew = null;
            union { string, null } flag = null;
            array<string> tags = [];
            map<long> cargo;
            decimal(9, 2) fee;
            date built;
            timestamp_ms arrived;
            @logicalType("uuid") string registry;
            Kind kind = "CARGO";
            int x, y;
          }

          error Full { string reason; }

          boolean reserve(Ship ship, int berth) throws Full;
          void ping() oneway;
        }
        """
        let spec = try #require(read(idl, "harbor.avdl"))
        guard case .avro(let s) = spec else { Issue.record("not Avro"); return }
        #expect(s.source == .idl)
        #expect(s.protocolName == "HarborService" && s.namespace == "acme.harbor")
        #expect(s.doc == "The Acme harbor protocol.")
        #expect(s.imports == ["common.avdl"])
        #expect(s.namedTypes.map(\.name) == ["Kind", "Hash", "Ship", "Full"])
        #expect(s.namedTypes[0].symbols == ["CARGO", "TANKER"])
        #expect(s.namedTypes[1].size == 16)
        let ship = s.namedTypes[2]
        #expect(ship.doc == "A ship in port.")
        #expect(ship.fields.map(\.name) == ["id", "nickname", "crew", "flag", "tags", "cargo", "fee", "built", "arrived", "registry", "kind", "x", "y"])
        #expect(ship.fields[1].type == "null | string" && ship.fields[1].optional)
        #expect(ship.fields[2].type == "null | int")
        #expect(ship.fields[4].type == "array<string>" && ship.fields[4].defaultValue == "[]")
        #expect(ship.fields[6].type == "decimal(9,2) (bytes)")
        #expect(ship.fields[7].type == "date (int)")
        #expect(ship.fields[9].type == "uuid (string)")
        #expect(hasWarning(s.warnings, .caution, "Ship.flag defaults to null"))
        #expect(s.messages.map(\.name) == ["reserve", "ping"])
        #expect(s.messages[0].parameters.map(\.type) == ["Ship", "int"] && s.messages[0].errors == ["Full"] && s.messages[0].response == "boolean")
        #expect(s.messages[1].oneWay)
        #expect(spec.presentation.headline == "protocol HarborService")
    }

    @Test func avroMalformedInput() {
        if case .avro(let s)? = read(#"{ "type": "record", "name": "Cut", "fields": [ { "name": "a", "type": "#, "cut.avsc") {
            #expect(s.truncated)
        }
        #expect(read("this is { not avro ] at all", "bad.avsc") == nil)
        #expect(read("%%% nothing here", "bad.avdl") == nil)
        guard case .avro(let s)? = read("protocol P { record R { string a; %%% junk; int b; } }", "junk.avdl") else {
            Issue.record("a partly readable IDL file still reads"); return
        }
        #expect(s.warnings.contains { $0.reason.contains("best effort") })
    }

    // MARK: Limits and robustness

    @Test func knownExtensionsAndBinaryInput() {
        #expect(APISpecReader.knownExtensions.isSuperset(of: ["graphql", "gql", "graphqls", "proto", "avsc", "avdl"]))
        #expect(!APISpecReader.knownExtensions.contains("json"))
        var binary = Data("syntax = \"proto3\";".utf8)
        binary.append(contentsOf: [0, 1, 2, 0])
        #expect(APISpecReader.read(data: binary, fileName: "x.proto") == nil)
    }

    @Test func inputPastEightMegabytesIsMarkedTruncated() throws {
        var text = "type Ship { id: ID! }\n"
        let pad = String(repeating: "# harbor padding line\n", count: 1_000)
        while text.utf8.count <= APISpecReader.maxBytes { text += pad }
        text += "type Late { id: ID! }\n"
        guard case .graphQL(let s)? = read(text, "big.graphql") else { Issue.record("not GraphQL"); return }
        #expect(s.truncated)
        #expect(s.types.map(\.name) == ["Ship"])
    }

    @Test func randomAndCutInputNeverCrashes() {
        var seed: UInt64 = 0x5EED_ACE
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let alphabet = Array("{}[]()<>:;,=@\"'`#/*!|&.$-_ \n\tabcxyzQ019 messagetypeenumrecordschemaopenapi".utf8)
        let names = ["a.graphql", "a.proto", "a.avsc", "a.avdl", "a.json", "a.yaml", "openapi"]
        for name in names {
            for _ in 0..<150 {
                let length = Int(next() % 400)
                let bytes = (0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] }
                let spec = APISpecReader.read(data: Data(bytes), fileName: name)
                _ = spec?.presentation
            }
        }
        let fixtures: [(String, String)] = [(Self.harborYAML, "openapi.yaml"), (Self.harborSDL, "s.graphql"), (Self.harborProto, "h.proto"),
                                            (Self.harborSchema, "s.json"), (Self.harborAvsc, "s.avsc")]
        for (text, name) in fixtures {
            let bytes = Array(text.utf8)
            for cut in stride(from: 0, to: bytes.count, by: 7) {
                _ = APISpecReader.read(data: Data(bytes[0..<cut]), fileName: name)?.presentation
            }
        }
    }
}
