import Foundation

/// Every phrase the API spec summaries show, translatable through VitrineEngineering's String Catalog. Counts are
/// interpolated as Int so the catalog can give them plural forms; names, paths and code words as String; warnings
/// are phrased so that English reads right before any plural variants exist. Stable identifiers (HTTP methods,
/// type kinds, `record`, `oneof`, …) stay plain where they are used. roadmap: S-22
enum L {

    // MARK: Shared

    static func more(_ shown: String, _ count: Int) -> String {
        String(localized: "\(shown) and \(count) more", bundle: .module, comment: "A shortened list of examples in a warning: the first few names, then how many more were left out.")
    }
    static var unnamed: String {
        String(localized: "(unnamed)", bundle: .module, comment: "Placeholder for an item in an API spec that has no name.")
    }
    static func syntaxError(_ detail: String) -> String {
        String(localized: "The file has a syntax error (\(detail)); what is shown was read before it.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is the parser's line and reason.")
    }
    static func skippedAt(_ line: Int, _ token: String) -> String {
        String(localized: "Line \(line) could not be read (at “\(token)”), so that definition was skipped.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a line number and the text where reading failed.")
    }
    static func skippedAtEnd(_ line: Int) -> String {
        String(localized: "Line \(line): the file ends in the middle of a definition, so it was skipped.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is a line number.")
    }
    static var endsInsideString: String {
        String(localized: "The file ends inside a string or comment, so its end may be missing.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period.")
    }
    static var idlBestEffort: String {
        String(localized: "Avro IDL is read best effort: parts this reader does not follow were skipped.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period.")
    }

    // MARK: OpenAPI warnings

    static func unsecuredOperations(_ unsecured: Int, _ total: Int, _ examples: String) -> String {
        String(localized: "Operations with no security requirement while the others have one: \(unsecured) of \(total) (\(examples)). Check that they are meant to be public.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are two counts and example operations such as GET /health.")
    }
    static var schemesUnused: String {
        String(localized: "Security schemes are defined but no operation requires one, so every operation reads as public.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period.")
    }
    static func plainHTTP(_ urls: String) -> String {
        String(localized: "Plain HTTP server (\(urls)): requests travel unencrypted.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is one or more server URLs.")
    }
    static func plainHTTPWithCredentials(_ urls: String) -> String {
        String(localized: "Plain HTTP server (\(urls)) for an API that takes credentials: keys and tokens would travel unencrypted.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is one or more server URLs.")
    }
    static func basicAuth(_ scheme: String) -> String {
        String(localized: "Security scheme \(scheme) is HTTP Basic: the password goes with every request, so it is only safe over HTTPS.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is the scheme's name in the file.")
    }
    static func apiKeyInQuery(_ scheme: String) -> String {
        String(localized: "Security scheme \(scheme) puts the API key in the URL query, where server logs and browser history keep it.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is the scheme's name in the file.")
    }
    static func implicitFlow(_ scheme: String) -> String {
        String(localized: "Security scheme \(scheme) offers the OAuth implicit flow, which current OAuth security advice says not to use.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is the scheme's name in the file.")
    }
    static func duplicateOperationIds(_ ids: String) -> String {
        String(localized: "Operation IDs used more than once: \(ids). Code generators need each one to be unique.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is a list of operationId values.")
    }

    // MARK: GraphQL warnings

    static func definedTwice(_ names: String) -> String {
        String(localized: "Defined more than once: \(names). A GraphQL server rejects a schema like this; additions belong in extend.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is a list of type names; extend is a GraphQL keyword.")
    }
    static func gqlDeprecated(_ count: Int, _ examples: String) -> String {
        String(localized: "Marked @deprecated (\(count) in all): \(examples). Clients should move off them.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a count and example names such as Ship.oldName.")
    }
    static var anonymousWithOthers: String {
        String(localized: "An anonymous operation shares the document with other operations; GraphQL allows an unnamed operation only when it is the only one.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period.")
    }
    static func duplicateOperationNames(_ names: String) -> String {
        String(localized: "Operation names used more than once: \(names). Names must be unique in a document.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is a list of operation names.")
    }

    // MARK: Protocol Buffers warnings

    static var noSyntaxLine: String {
        String(localized: "The file has no syntax line, so protoc reads it as proto2.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. protoc and proto2 are names; keep them.")
    }
    static func numberOutOfRange(_ field: String, _ number: String, _ max: String) -> String {
        String(localized: "Field \(field) has number \(number), outside the allowed 1 to \(max).", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a field name and numbers.")
    }
    static func numberInImplementationRange(_ field: String, _ number: String) -> String {
        String(localized: "Field \(field) uses number \(number), which protobuf reserves for itself (19000 to 19999).", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a field name and its number.")
    }
    static func reservedNumberUsed(_ field: String, _ number: String) -> String {
        String(localized: "Field \(field) uses number \(number), which its message marks reserved.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a field name and its number.")
    }
    static func reservedNameUsed(_ field: String) -> String {
        String(localized: "Field \(field) uses a name its message marks reserved.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is a field name.")
    }
    static func duplicateFieldNumber(_ message: String, _ number: String, _ fields: String) -> String {
        String(localized: "Message \(message) uses field number \(number) more than once (\(fields)); protoc rejects this.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a message name, a number and field names.")
    }
    static func enumFirstNotZero(_ enumName: String, _ value: String) -> String {
        String(localized: "Enum \(enumName) starts with \(value); proto3 needs the first value to be 0.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are an enum name and its first value such as UNKNOWN = 1.")
    }
    static func enumDuplicateNumber(_ enumName: String, _ first: String, _ second: String, _ number: String) -> String {
        String(localized: "Enum \(enumName) gives \(first) and \(second) the same number \(number) without allow_alias; protoc rejects this.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. allow_alias is an option name; keep it.")
    }
    static func requiredFields(_ count: Int, _ examples: String) -> String {
        String(localized: "Required fields (\(count) in all): \(examples). A required field can never be removed without breaking older readers.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a count and example field names.")
    }
    static func deprecatedRPCs(_ count: Int, _ examples: String) -> String {
        String(localized: "RPCs marked deprecated (\(count) in all): \(examples).", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a count and example RPC names.")
    }

    // MARK: JSON Schema warnings

    static func unresolvedRefs(_ count: Int, _ examples: String) -> String {
        String(localized: "References to parts of this file that do not exist (\(count) in all): \(examples).", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a count and $ref values such as #/$defs/Ship.")
    }
    static func requiredNotDefined(_ names: String) -> String {
        String(localized: "required lists properties that the schema next to it does not define: \(names).", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. required is a JSON Schema keyword; keep it. The argument is a list of property names.")
    }
    static func plainHTTPId(_ id: String) -> String {
        String(localized: "The schema's $id uses plain http (\(id)); tools that fetch it would do so unencrypted.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. $id is a JSON Schema keyword; keep it.")
    }

    // MARK: Avro warnings

    static func duplicateFieldNames(_ record: String, _ names: String) -> String {
        String(localized: "Record \(record) has field names used more than once (\(names)); Avro rejects this.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a record name and field names.")
    }
    static func nullDefaultNotFirst(_ field: String, _ union: String) -> String {
        String(localized: "Field \(field) defaults to null, but null is not the first type of its union (\(union)); Avro requires the default to match the first type.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. null is a type name; keep it.")
    }
    static func defaultButNullFirst(_ field: String) -> String {
        String(localized: "Field \(field) has a non-null default, but its union starts with null; Avro requires the default to match the first type, so readers reject it.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. null is a type name; keep it.")
    }
    static func undefinedTypes(_ count: Int, _ examples: String) -> String {
        String(localized: "Types used but not defined in this file (\(count) in all): \(examples).", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are a count and type names.")
    }
    static func avroDefinedTwice(_ names: String) -> String {
        String(localized: "Defined more than once: \(names). Avro rejects a schema that redefines a name.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is a list of type names.")
    }
    static func unnamedType(_ kind: String) -> String {
        String(localized: "A \(kind) has no name; Avro requires every \(kind) to be named.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The argument is an Avro keyword: record, error, enum or fixed.")
    }
    static func enumDefaultNotSymbol(_ enumName: String, _ value: String) -> String {
        String(localized: "Enum \(enumName) defaults to \(value), which is not one of its symbols.", bundle: .module, comment: "A warning on the API spec preview card (OpenAPI, GraphQL, Protocol Buffers, JSON Schema, Avro); one or two plain sentences ending with a period. The arguments are an enum name and a symbol.")
    }

    // MARK: Headlines

    static var swaggerDocument: String { String(localized: "Swagger document", bundle: .module, comment: "Headline of an API spec card when the Swagger file has no title.") }
    static var openAPIDocument: String { String(localized: "OpenAPI document", bundle: .module, comment: "Headline of an API spec card when the OpenAPI file has no title.") }
    static func graphQLSchema(_ types: Int) -> String {
        String(localized: "GraphQL schema · \(types) types", bundle: .module, comment: "Headline of a GraphQL schema card with the number of types.")
    }
    static func graphQLOperations(_ count: Int) -> String {
        String(localized: "GraphQL operations · \(count) operations", bundle: .module, comment: "Headline of a GraphQL query document card with the number of operations.")
    }
    static var graphQLDocument: String { String(localized: "GraphQL document", bundle: .module, comment: "Headline of an empty GraphQL file's card.") }
    static var protocolBuffers: String { String(localized: "Protocol Buffers", bundle: .module, comment: "Headline of a .proto card when the file names no package.") }
    static var jsonSchema: String { String(localized: "JSON Schema", bundle: .module, comment: "Headline of a JSON Schema card when the schema has no title or id.") }

    // MARK: Fact labels and values

    static var format: String { String(localized: "Format", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var apiVersion: String { String(localized: "API version", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var servers: String { String(localized: "Servers", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var operations: String { String(localized: "Operations", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var paths: String { String(localized: "Paths", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var schemas: String { String(localized: "Schemas", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var security: String { String(localized: "Security", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var deprecated: String { String(localized: "Deprecated", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var webhooks: String { String(localized: "Webhooks", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var objectTypes: String { String(localized: "Object types", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var inputTypes: String { String(localized: "Input types", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var enums: String { String(localized: "Enums", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var interfaces: String { String(localized: "Interfaces", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var unions: String { String(localized: "Unions", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var scalars: String { String(localized: "Scalars", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var queryFields: String { String(localized: "Query fields", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var mutationFields: String { String(localized: "Mutation fields", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var subscriptionFields: String { String(localized: "Subscription fields", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var directives: String { String(localized: "Directives", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var fragments: String { String(localized: "Fragments", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var syntax: String { String(localized: "Syntax", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var package: String { String(localized: "Package", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var imports: String { String(localized: "Imports", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var messages: String { String(localized: "Messages", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var services: String { String(localized: "Services", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var rpcs: String { String(localized: "RPCs", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var draft: String { String(localized: "Draft", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var type: String { String(localized: "Type", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var properties: String { String(localized: "Properties", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var required: String { String(localized: "Required", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var definitions: String { String(localized: "Definitions", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case. Also the heading of the definitions group in the outline.") }
    static var references: String { String(localized: "References", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case. The number of distinct $ref targets.") }
    static var combines: String { String(localized: "Combines", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case. The schema's allOf / anyOf / oneOf.") }
    static var source: String { String(localized: "Source", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var namespace: String { String(localized: "Namespace", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var records: String { String(localized: "Records", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var fixedTypes: String { String(localized: "Fixed types", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var fields: String { String(localized: "Fields", bundle: .module, comment: "A fact label on the API spec preview card; a short noun phrase in title case.") }
    static var avroIDL: String { String(localized: "Avro IDL", bundle: .module, comment: "A fact value: the file is Avro IDL.") }
    static var avroProtocol: String { String(localized: "Avro protocol", bundle: .module, comment: "A fact value: the file is an Avro protocol in JSON.") }
    static var avroSchema: String { String(localized: "Avro schema", bundle: .module, comment: "A fact value: the file is an Avro schema in JSON.") }
    static func firstAndMore(_ first: String, _ more: Int) -> String {
        String(localized: "\(first) and \(more) more", bundle: .module, comment: "A fact value: the first server URL and how many others there are.")
    }

    // MARK: Outline

    static var untagged: String { String(localized: "Untagged", bundle: .module, comment: "Outline group on an OpenAPI card for operations without a tag.") }
    static var anonymous: String { String(localized: "(anonymous)", bundle: .module, comment: "Outline row on a GraphQL card for an operation without a name.") }
    static func operationCount(_ n: Int) -> String {
        String(localized: "\(n) operations", bundle: .module, comment: "Outline detail on an API spec card: how many operations a group holds.")
    }
    static func fieldCount(_ n: Int) -> String {
        String(localized: "\(n) fields", bundle: .module, comment: "Outline detail on an API spec card: how many fields a type or message has.")
    }
    static func valueCount(_ n: Int) -> String {
        String(localized: "\(n) values", bundle: .module, comment: "Outline detail on an API spec card: how many values an enum has.")
    }
    static func rpcCount(_ n: Int) -> String {
        String(localized: "\(n) RPCs", bundle: .module, comment: "Outline detail on a Protocol Buffers card: how many RPCs a service has.")
    }
    static func byteCount(_ n: Int) -> String {
        String(localized: "\(n) bytes", bundle: .module, comment: "Outline detail on an Avro card: the size of a fixed type.")
    }
    static var requiredMark: String { String(localized: "required", bundle: .module, comment: "Outline detail on a JSON Schema card: the property is required; lower-case.") }
    static var oneWay: String { String(localized: "one-way", bundle: .module, comment: "Outline detail on an Avro card: the message expects no response; lower-case.") }
}
