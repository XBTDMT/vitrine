import Foundation

/// One API or schema file read for the docs-style card (E-3): an OpenAPI or Swagger description, a GraphQL schema or
/// operations document, a Protocol Buffers file, a JSON Schema or an Avro schema. Each case carries the summary its
/// reader made; `presentation` turns any of them into the headline, facts, outline and warnings a card draws.
/// roadmap: S-22
public enum APISpec: Sendable, Equatable {
    case openAPI(OpenAPISummary)
    case graphQL(GraphQLSummary)
    case protobuf(ProtobufSummary)
    case jsonSchema(JSONSchemaSummary)
    case avro(AvroSummary)

    /// Which of the five formats this is, for routing and icons. roadmap: S-22
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case openAPI, graphQL, protobuf, jsonSchema, avro
    }

    public var kind: Kind {
        switch self {
        case .openAPI: .openAPI
        case .graphQL: .graphQL
        case .protobuf: .protobuf
        case .jsonSchema: .jsonSchema
        case .avro: .avro
        }
    }

    /// The warnings the reader raised, most serious first.
    public var warnings: [APISpecWarning] {
        let list: [APISpecWarning]
        switch self {
        case .openAPI(let s): list = s.warnings
        case .graphQL(let s): list = s.warnings
        case .protobuf(let s): list = s.warnings
        case .jsonSchema(let s): list = s.warnings
        case .avro(let s): list = s.warnings
        }
        return list.filter { $0.level == .danger } + list.filter { $0.level == .caution }
    }

    /// The input passed a limit (more than 8 MB, more than 2,000 items in a list, nesting too deep) or ended in the
    /// middle of a structure, so the summary was read from part of it.
    public var truncated: Bool {
        switch self {
        case .openAPI(let s): s.truncated
        case .graphQL(let s): s.truncated
        case .protobuf(let s): s.truncated
        case .jsonSchema(let s): s.truncated
        case .avro(let s): s.truncated
        }
    }
}

/// Something a reader of the spec should know before trusting or using it, with a plain-English reason.
/// `caution` is worth a look (an unauthenticated operation among authenticated ones, a deprecated item, a syntax
/// error the reader skipped past); `danger` is a real fault or exposure (credentials over plain HTTP, a field
/// number used twice, a type defined twice). roadmap: S-22
public struct APISpecWarning: Sendable, Equatable {
    /// How serious a warning is. roadmap: S-22
    public enum Level: String, Sendable, Equatable { case caution, danger }

    public var level: Level
    public var reason: String

    public init(_ level: Level, _ reason: String) {
        self.level = level
        self.reason = reason
    }
}

/// One labelled fact on a card ("Operations" → "14"). roadmap: S-22
public struct APISpecFact: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// One row of a card's outline, stored flat in reading order: `depth` 0 is a group (a tag, a service, a type), 1 its
/// members, and so on, so a list view can indent rows without walking a tree. roadmap: S-22
public struct APISpecOutlineItem: Sendable, Equatable {
    public var depth: Int
    public var title: String
    /// A short second column: an operation's summary, a field's type, a group's member count.
    public var detail: String?
    /// The item is marked deprecated in the file.
    public var deprecated: Bool

    public init(depth: Int, title: String, detail: String? = nil, deprecated: Bool = false) {
        self.depth = depth
        self.title = title
        self.detail = detail
        self.deprecated = deprecated
    }
}

/// What a docs-style card shows for any spec: a headline, labelled facts, a flat outline (at most
/// `APISpecReader.maxListItems` rows, `outlineTruncated` when more were cut) and the warnings. Labels and
/// sentences are translated through VitrineEngineering's String Catalog; names from the file stay as written.
/// roadmap: S-22
public struct APISpecPresentation: Sendable, Equatable {
    public var headline: String
    public var facts: [APISpecFact]
    public var outline: [APISpecOutlineItem]
    public var outlineTruncated: Bool
    public var warnings: [APISpecWarning]
    public var truncated: Bool
}

// MARK: - OpenAPI and Swagger

/// An OpenAPI 3.x or Swagger 2.0 description: its title and version, servers, every operation with its tags and
/// security, grouped by tag, the components it declares and its security schemes. roadmap: S-22
public struct OpenAPISummary: Sendable, Equatable {
    /// Which specification the file follows, from its `openapi` or `swagger` key. roadmap: S-22
    public enum Dialect: String, Sendable, Equatable { case swagger2, openAPI30, openAPI31, openAPI32, otherOpenAPI }

    public var dialect: Dialect
    /// The `openapi` / `swagger` value as written ("3.1.0", "2.0").
    public var specVersion: String
    public var title: String?
    /// `info.version`: the API's own version.
    public var apiVersion: String?
    /// `info.description`, cut to `APISpecReader.maxDescriptionLength` characters.
    public var description: String?
    /// OpenAPI 3 `servers`, or Swagger 2's `schemes` × `host` + `basePath`.
    public var servers: [Server]
    /// The operations in file order, at most `APISpecReader.maxListItems`.
    public var operations: [Operation]
    /// Every operation counted, even past the cap.
    public var operationCount: Int
    public var pathCount: Int
    /// The operations grouped by tag: declared tags first in their declared order, then tags only operations use,
    /// then the untagged group (name nil). An operation with two tags is in both groups.
    public var tagGroups: [TagGroup]
    /// `components` (3.x) or `definitions` / `parameters` / `responses` / `securityDefinitions` (2.0), kind → count.
    public var componentCounts: [ComponentCount]
    /// `components.schemas` (3.x) or `definitions` (2.0).
    public var schemaCount: Int
    public var securitySchemes: [SecurityScheme]
    /// The names in the top-level `security` requirement, which operations without their own inherit.
    public var globalSecurity: [String]
    /// OpenAPI 3.1 `webhooks`.
    public var webhookCount: Int
    public var warnings: [APISpecWarning]
    public var truncated: Bool

    public var deprecatedCount: Int { operations.filter(\.deprecated).count }

    /// One server the API is served from. roadmap: S-22
    public struct Server: Sendable, Equatable {
        public var url: String
        public var description: String?
        /// The URL starts with `http://` (not https) and does not point at this machine.
        public var isPlainHTTP: Bool
    }

    /// One operation: a method on a path. roadmap: S-22
    public struct Operation: Sendable, Equatable {
        /// "GET", "POST", … upper-cased.
        public var method: String
        public var path: String
        public var operationId: String?
        public var summary: String?
        public var tags: [String]
        public var deprecated: Bool
        /// The security scheme names that apply: the operation's own `security`, or the global one when it has none.
        public var security: [String]
        /// The operation states its own `security` instead of inheriting the global one.
        public var declaresSecurity: Bool
        /// One of the alternatives is the empty requirement `{}`, so a caller may also come without credentials.
        public var allowsAnonymous: Bool
        /// No security requirement applies at all.
        public var isUnsecured: Bool { security.isEmpty }
    }

    /// The operations under one tag. roadmap: S-22
    public struct TagGroup: Sendable, Equatable {
        /// nil for the untagged operations.
        public var name: String?
        public var description: String?
        /// Indices into `operations`.
        public var operationIndices: [Int]
    }

    /// How many of one kind of component the file declares. roadmap: S-22
    public struct ComponentCount: Sendable, Equatable {
        public var kind: String
        public var count: Int
    }

    /// One declared security scheme. roadmap: S-22
    public struct SecurityScheme: Sendable, Equatable {
        public var name: String
        /// `apiKey`, `http`, `oauth2`, `openIdConnect`, `mutualTLS`, or 2.0's `basic`.
        public var type: String
        /// "bearer (JWT)", "header X-Api-Key", "flows: authorizationCode, clientCredentials", …
        public var detail: String?
    }
}

// MARK: - GraphQL

/// A GraphQL SDL schema and/or an executable document: types by kind, the root operation fields with argument
/// signatures, directive definitions, deprecations, and the named operations and fragments of a query file.
/// roadmap: S-22
public struct GraphQLSummary: Sendable, Equatable {
    /// What the document holds. roadmap: S-22
    public enum DocumentKind: String, Sendable, Equatable { case schema, operations, mixed, empty }
    /// The kind of a type definition. roadmap: S-22
    public enum TypeKind: String, Sendable, Equatable, CaseIterable { case object = "type", input, enumeration = "enum", interface, union, scalar }
    /// The kind of an operation. roadmap: S-22
    public enum OperationKind: String, Sendable, Equatable { case query, mutation, subscription }

    public var documentKind: DocumentKind
    /// Type definitions and extensions in file order, at most `APISpecReader.maxListItems`.
    public var types: [TypeDefinition]
    /// Definitions per kind (extensions not counted), even past the cap.
    public var typeCounts: [TypeKind: Int]
    /// The root type names: from a `schema { … }` block, else `Query` / `Mutation` / `Subscription` when defined.
    public var queryType: String?
    public var mutationType: String?
    public var subscriptionType: String?
    /// The root types' fields, extensions included.
    public var queryFields: [Field]
    public var mutationFields: [Field]
    public var subscriptionFields: [Field]
    public var directives: [DirectiveDefinition]
    /// Every `@deprecated` item as "Type.field", "Type.field(arg)" or "Enum.VALUE".
    public var deprecated: [String]
    public var operations: [Operation]
    public var fragments: [Fragment]
    public var warnings: [APISpecWarning]
    public var truncated: Bool

    /// One type definition or extension. roadmap: S-22
    public struct TypeDefinition: Sendable, Equatable {
        public var name: String
        public var kind: TypeKind
        public var description: String?
        /// Written as `extend type …`.
        public var isExtension: Bool
        public var implements: [String]
        /// Fields of an object, interface or input type.
        public var fields: [Field]
        public var enumValues: [EnumValue]
        public var unionMembers: [String]
        /// Directive names applied to the type itself, without `@`.
        public var directives: [String]
    }

    /// One field or input field. roadmap: S-22
    public struct Field: Sendable, Equatable {
        public var name: String
        public var arguments: [Argument]
        /// The type as written: `String`, `[Harbor!]!`.
        public var type: String
        /// An input field's default value, as written.
        public var defaultValue: String?
        public var description: String?
        public var deprecated: Bool
        public var deprecationReason: String?
        public var directives: [String]

        /// `name(arg: Type = default, …): Type`.
        public var signature: String {
            let args = arguments.isEmpty ? "" : "(" + arguments.map(\.signature).joined(separator: ", ") + ")"
            return "\(name)\(args): \(type)" + (defaultValue.map { " = \($0)" } ?? "")
        }
    }

    /// One argument, input value or operation variable (variables keep their `$`). roadmap: S-22
    public struct Argument: Sendable, Equatable {
        public var name: String
        public var type: String
        public var defaultValue: String?
        public var deprecated: Bool

        public var signature: String { "\(name): \(type)" + (defaultValue.map { " = \($0)" } ?? "") }
    }

    /// One enum value. roadmap: S-22
    public struct EnumValue: Sendable, Equatable {
        public var name: String
        public var description: String?
        public var deprecated: Bool
        public var deprecationReason: String?
    }

    /// One `directive @name(…) on …` definition. roadmap: S-22
    public struct DirectiveDefinition: Sendable, Equatable {
        public var name: String
        public var arguments: [Argument]
        public var locations: [String]
        public var repeatable: Bool
    }

    /// One operation of an executable document. roadmap: S-22
    public struct Operation: Sendable, Equatable {
        public var kind: OperationKind
        /// nil for an anonymous operation (including the `{ … }` shorthand).
        public var name: String?
        public var variables: [Argument]
    }

    /// One fragment definition. roadmap: S-22
    public struct Fragment: Sendable, Equatable {
        public var name: String
        public var typeCondition: String
    }
}

// MARK: - Protocol Buffers

/// A `.proto` file: its syntax or edition, package, imports and options, messages (with fields, nested messages and
/// enums, oneofs and maps), enums and services with their RPCs. roadmap: S-22
public struct ProtobufSummary: Sendable, Equatable {
    /// "proto2" or "proto3", from the `syntax` line; nil when the file has none (protoc then reads proto2).
    public var syntax: String?
    /// The `edition` line ("2023"), for editions files.
    public var edition: String?
    public var package: String?
    public var imports: [Import]
    public var options: [Option]
    public var messages: [Message]
    public var enums: [Enumeration]
    public var services: [Service]
    /// `extend` blocks at the top level.
    public var extensions: [Extension]
    /// Totals over the whole file, nested definitions included.
    public var messageCount: Int
    public var enumCount: Int
    public var fieldCount: Int
    public var rpcCount: Int
    public var warnings: [APISpecWarning]
    public var truncated: Bool

    /// One `import` line. roadmap: S-22
    public struct Import: Sendable, Equatable {
        public var path: String
        /// "public" or "weak" when written.
        public var modifier: String?
    }

    /// One `option name = value;` line; aggregate values show as `{…}`. roadmap: S-22
    public struct Option: Sendable, Equatable {
        public var name: String
        public var value: String
    }

    /// One message (or proto2 group). roadmap: S-22
    public struct Message: Sendable, Equatable {
        public var name: String
        /// Package and enclosing messages joined with dots.
        public var fullName: String
        /// Every field in file order, oneof members included (see `Field.oneof`).
        public var fields: [Field]
        public var oneofs: [Oneof]
        public var messages: [Message]
        public var enums: [Enumeration]
        /// `reserved` numbers and ranges as written ("2", "9 to 11", "100 to max").
        public var reservedNumbers: [String]
        public var reservedNames: [String]
        /// Nested definitions past the depth limit were skipped.
        public var nestingCut: Bool
    }

    /// One field of a message. roadmap: S-22
    public struct Field: Sendable, Equatable {
        /// The label as written. roadmap: S-22
        public enum Label: String, Sendable, Equatable { case none = "", optional, required, repeated }

        public var label: Label
        /// The type as written, or `map<K, V>` for a map field.
        public var type: String
        public var name: String
        public var number: Int?
        /// The oneof this field belongs to.
        public var oneof: String?
        public var mapKey: String?
        public var mapValue: String?
        /// `[deprecated = true]`.
        public var deprecated: Bool

        public var isMap: Bool { mapKey != nil }
    }

    /// One `oneof` block. roadmap: S-22
    public struct Oneof: Sendable, Equatable {
        public var name: String
        public var fieldNames: [String]
    }

    /// One enum. roadmap: S-22
    public struct Enumeration: Sendable, Equatable {
        public var name: String
        public var fullName: String
        public var values: [Value]
        /// `option allow_alias = true;`
        public var allowAlias: Bool

        /// One enum value. roadmap: S-22
        public struct Value: Sendable, Equatable {
            public var name: String
            public var number: Int?
            public var deprecated: Bool
        }
    }

    /// One service. roadmap: S-22
    public struct Service: Sendable, Equatable {
        public var name: String
        public var rpcs: [RPC]
    }

    /// One RPC of a service. roadmap: S-22
    public struct RPC: Sendable, Equatable {
        public var name: String
        public var requestType: String
        public var responseType: String
        public var clientStreaming: Bool
        public var serverStreaming: Bool
        public var deprecated: Bool

        /// `Name(stream Request) returns (Response)`.
        public var signature: String {
            "\(name)(\(clientStreaming ? "stream " : "")\(requestType)) returns (\(serverStreaming ? "stream " : "")\(responseType))"
        }
    }

    /// One `extend Target { … }` block. roadmap: S-22
    public struct Extension: Sendable, Equatable {
        public var target: String
        public var fields: [Field]
    }
}

// MARK: - JSON Schema

/// A JSON Schema document: its title, draft, a tree of properties to depth 6, its definitions and every `$ref` it
/// makes. roadmap: S-22
public struct JSONSchemaSummary: Sendable, Equatable {
    public var title: String?
    public var description: String?
    /// "draft-04", "draft-06", "draft-07", "2019-09", "2020-12", from `$schema`; nil when it names none of these.
    public var draft: String?
    /// The `$schema` value as written.
    public var schemaURI: String?
    /// `$id` (or draft-04's `id`).
    public var id: String?
    /// The root's `type` (several for a type array).
    public var rootTypes: [String]
    /// The root's properties (or, for an array root, its items' properties), nested to depth 6.
    public var properties: [Property]
    /// `$defs` plus `definitions` entries.
    public var definitionCount: Int
    public var definitionNames: [String]
    /// Every distinct `$ref` target in file order.
    public var refs: [String]
    /// "oneOf (3)" and the like, for a root that combines schemas.
    public var rootCombinators: [String]
    public var warnings: [APISpecWarning]
    public var truncated: Bool

    /// One property of an object schema. roadmap: S-22
    public struct Property: Sendable, Equatable {
        public var name: String
        /// `type`, an array's item type as `array<string>`, or empty when the property has only a `$ref`.
        public var types: [String]
        public var required: Bool
        public var description: String?
        public var enumValues: [String]
        public var format: String?
        public var ref: String?
        /// "oneOf (2)", "allOf (3)" when the property combines schemas.
        public var combinators: [String]
        public var deprecated: Bool
        /// Its own properties, or its items' properties for an array of objects.
        public var children: [Property]
        /// It has nested properties that the depth limit (6) left out.
        public var childrenCut: Bool
    }
}

// MARK: - Avro

/// An Avro schema (`.avsc`), protocol (`.avpr`) or IDL file (`.avdl`, read best effort): its named types — records,
/// errors, enums and fixed types, nested ones included — with fields, types, defaults and logical types, and a
/// protocol's messages. roadmap: S-22
public struct AvroSummary: Sendable, Equatable {
    /// Where the summary came from. roadmap: S-22
    public enum Source: String, Sendable, Equatable { case schema, protocolJSON, idl }

    public var source: Source
    public var protocolName: String?
    public var namespace: String?
    public var doc: String?
    /// The top-level type rendered: "record acme.harbor.Ship", "null | string", "protocol HarborService".
    public var rootType: String
    /// Every named type in definition order, nested ones included (see `NamedType.definedIn`).
    public var namedTypes: [NamedType]
    public var messages: [Message]
    /// IDL `import` paths.
    public var imports: [String]
    public var warnings: [APISpecWarning]
    public var truncated: Bool

    /// A named Avro type. roadmap: S-22
    public struct NamedType: Sendable, Equatable {
        /// What kind of named type. roadmap: S-22
        public enum Kind: String, Sendable, Equatable { case record, error, enumeration = "enum", fixed }

        public var kind: Kind
        public var name: String
        public var namespace: String?
        public var doc: String?
        public var fields: [Field]
        /// An enum's symbols.
        public var symbols: [String]
        /// A fixed type's size in bytes.
        public var size: Int?
        public var aliases: [String]
        /// The full name of the record whose field defined it, for a nested type.
        public var definedIn: String?

        public var fullName: String { namespace.map { "\($0).\(name)" } ?? name }
    }

    /// One field of a record, or one parameter of a message. roadmap: S-22
    public struct Field: Sendable, Equatable {
        public var name: String
        /// "string", "null | long", "array<acme.Ship>", "timestamp-millis (long)", "decimal(9,2) (bytes)".
        public var type: String
        public var doc: String?
        /// The default as written (JSON).
        public var defaultValue: String?
        /// The type is a union that includes null.
        public var optional: Bool
        public var logicalType: String?
    }

    /// One protocol message. roadmap: S-22
    public struct Message: Sendable, Equatable {
        public var name: String
        public var parameters: [Field]
        public var response: String
        public var errors: [String]
        public var oneWay: Bool
    }
}
