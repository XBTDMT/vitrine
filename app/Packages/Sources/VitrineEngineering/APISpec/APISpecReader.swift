import Foundation
import VitrineData

/// Reads an API or schema file into an `APISpec` for the docs-style card (E-3). GraphQL, Protocol Buffers and Avro
/// are chosen by extension; JSON and YAML files only by their content (an `openapi` or `swagger` key, a JSON Schema
/// `$schema`, an Avro record), so an ordinary config file is never mistaken for a spec. Specs are untrusted input:
/// at most `maxBytes` are read, every list keeps at most `maxListItems` entries (and the summary says `truncated`),
/// nesting is bounded, nothing is fetched, started or written, and malformed input gives nil or a partial summary
/// with a warning, never a crash. roadmap: S-22
public enum APISpecReader {
    /// The most bytes read from one file; past this the summary is marked `truncated`.
    public static let maxBytes = 8 * 1024 * 1024
    /// The most entries kept in any one list (operations, types, fields, properties, outline rows …).
    public static let maxListItems = 2_000
    /// The longest description kept, in characters.
    public static let maxDescriptionLength = 1_000
    /// The longest one-line text kept (summaries, docs, field descriptions), in characters.
    public static let maxTextLength = 300
    /// How deep nested definitions are followed (protobuf messages, Avro types, GraphQL list types).
    public static let maxNesting = 32
    /// How deep the JSON Schema properties tree goes.
    public static let maxPropertyDepth = 6
    public static let maxWarnings = 50

    /// Extensions (lowercased, without the dot) that are spec files by themselves: GraphQL (`graphql`, `gql`,
    /// `graphqls`), Protocol Buffers (`proto`) and Avro (`avsc`, `avpr`, `avdl`).
    public static let knownExtensions: Set<String> = ["graphql", "gql", "graphqls", "proto", "avsc", "avpr", "avdl"]

    /// Extensions whose files are specs only by content (`json`, `yaml`, `yml`): `read` returns nil for the
    /// ordinary ones. Files with any other extension are tried only for an OpenAPI or Swagger key.
    public static let contentSniffedExtensions: Set<String> = ["json", "yaml", "yml"]

    /// nil when the bytes are not a spec this reader knows, or are too broken to say anything about.
    public static func read(data: Data, fileName: String) -> APISpec? {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let cut = data.count > maxBytes
        var input = cut ? Data(data.prefix(maxBytes)) : data
        guard !input.isEmpty || knownExtensions.contains(ext) else { return nil }
        guard !looksBinary(input) else { return nil }

        switch ext {
        case "graphql", "gql", "graphqls":
            if cut { input = wholeLines(input) }
            return GraphQLReader.read([UInt8](input), cut: cut).map(APISpec.graphQL)
        case "proto":
            if cut { input = wholeLines(input) }
            return ProtobufReader.read([UInt8](input), cut: cut).map(APISpec.protobuf)
        case "avdl":
            if cut { input = wholeLines(input) }
            return AvroIDLReader.read([UInt8](input), cut: cut).map(APISpec.avro)
        case "avsc", "avpr":
            guard let doc = SpecDocument.parse(input, format: .json, inputCut: cut) else { return nil }
            return AvroJSONReader.read(doc, isProtocolFile: ext == "avpr").map(APISpec.avro)
        case "json", "yaml", "yml":
            guard hasMarker(input, name: name) else { return nil }
            let format: StructuredFormat = ext == "json" ? .json : .yaml
            guard let doc = SpecDocument.parse(input, format: format, inputCut: cut) else { return nil }
            return sniffStructured(doc, name: name)
        default:
            // Any other name: only an OpenAPI or Swagger document, recognised by its key.
            guard input.range(of: Data("openapi".utf8)) != nil || input.range(of: Data("swagger".utf8)) != nil else { return nil }
            let head = input.prefix(4096).drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF }
            let format: StructuredFormat = head.first == UInt8(ascii: "{") ? .json : .yaml
            guard let doc = SpecDocument.parse(input, format: format, inputCut: cut), isOpenAPI(doc.root) else { return nil }
            return OpenAPIReader.read(doc).map(APISpec.openAPI)
        }
    }

    // MARK: Routing

    /// The content shape decides: OpenAPI first (a 3.1 document may carry JSON Schema keys), then JSON Schema, then
    /// Avro.
    static func sniffStructured(_ doc: SpecDocument.Parsed, name: String) -> APISpec? {
        let root = doc.root
        guard root.isObject || root.isArray else { return nil }
        if isOpenAPI(root) { return OpenAPIReader.read(doc).map(APISpec.openAPI) }
        if isJSONSchema(root, name: name) { return JSONSchemaReader.read(doc).map(APISpec.jsonSchema) }
        if isAvro(root) { return AvroJSONReader.read(doc, isProtocolFile: false).map(APISpec.avro) }
        return nil
    }

    static func isOpenAPI(_ root: SpecNode) -> Bool {
        guard root.isObject else { return false }
        if let v = root["openapi"]?.scalar, v.first?.isNumber == true { return true }
        if let v = root["swagger"]?.scalar, v.first?.isNumber == true { return true }
        return false
    }

    /// A `$schema` naming a json-schema.org meta-schema; or a `*.schema.json` (or `.schema.yaml`) name; or a
    /// `$schema` together with schema keywords. A config file that only points at its own schema (`$schema` plus
    /// settings) does not count.
    static func isJSONSchema(_ root: SpecNode, name: String) -> Bool {
        guard root.isObject else { return false }
        if let s = root["$schema"]?.string, s.contains("json-schema.org") { return true }
        if name.hasSuffix(".schema.json") || name.hasSuffix(".schema.yaml") || name.hasSuffix(".schema.yml") {
            return root["type"] != nil || root["properties"] != nil || root["$defs"] != nil || root["definitions"] != nil
                || root["$ref"] != nil || root["oneOf"] != nil || root["anyOf"] != nil || root["allOf"] != nil
        }
        if root["$schema"]?.string != nil {
            let keywords = ["properties", "$defs", "definitions", "items", "oneOf", "anyOf", "allOf"]
            return root["type"]?.scalar != nil && keywords.contains { root[$0] != nil }
        }
        return false
    }

    static func isAvro(_ root: SpecNode) -> Bool {
        if root.isObject {
            if let type = root["type"]?.string, ["record", "error"].contains(type) {
                return root["name"]?.string != nil && root["fields"]?.isArray == true
            }
            if root["type"]?.string == "enum" { return root["name"]?.string != nil && root["symbols"]?.isArray == true }
            if root["protocol"]?.string != nil { return root["types"]?.isArray == true || root["messages"]?.isObject == true }
        }
        return false
    }

    /// A quick byte search before parsing a JSON or YAML file in full, so ordinary data files cost little.
    static func hasMarker(_ data: Data, name: String) -> Bool {
        if name.hasSuffix(".schema.json") || name.hasSuffix(".schema.yaml") || name.hasSuffix(".schema.yml") { return true }
        for marker in ["openapi", "swagger", "$schema", "\"record\"", "protocol"] {
            if data.range(of: Data(marker.utf8)) != nil { return true }
        }
        return false
    }

    /// A NUL byte in the first 8 KB means a binary file, never a text spec.
    static func looksBinary(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }   // UTF-16 text
        return head.contains(0)
    }

    /// The input up to its last newline, so a cut text file ends on a whole line.
    static func wholeLines(_ data: Data) -> Data {
        guard let last = data.lastIndex(of: 0x0A) else { return data }
        return Data(data[data.startIndex...last])
    }
}
