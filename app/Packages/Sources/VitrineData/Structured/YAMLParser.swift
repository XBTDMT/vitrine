import Foundation

enum YAMLEventKind {
    case streamStart, streamEnd
    case documentStart(explicit: Bool)
    case documentEnd
    case alias(String)
    case scalar(value: String, style: YAMLScalarStyle, anchor: String?, tag: String?)
    case sequenceStart(anchor: String?, tag: String?)
    case sequenceEnd
    case mappingStart(anchor: String?, tag: String?)
    case mappingEnd
}

struct YAMLEvent {
    var kind: YAMLEventKind
    var start: YAMLMark
    var end: YAMLMark
}

/// Tokens to events, after libyaml's parser: a state machine whose "call stack" is the `states` array, so nesting
/// never touches the thread's stack.
struct YAMLParser {
    var scanner: YAMLScanner
    private var state = State.streamStart
    private var states: [State] = []

    private enum State {
        case streamStart, implicitDocumentStart, documentStart, documentEnd, documentContent
        case blockNode, blockNodeOrIndentlessSequence, flowNode
        case blockSequenceFirstEntry, blockSequenceEntry, indentlessSequenceEntry
        case blockMappingFirstKey, blockMappingKey, blockMappingValue
        case flowSequenceFirstEntry, flowSequenceEntry
        case flowSequenceEntryMappingKey, flowSequenceEntryMappingValue, flowSequenceEntryMappingEnd
        case flowMappingFirstKey, flowMappingKey, flowMappingValue, flowMappingEmptyValue
        case end
    }

    init(bytes: UnsafeBufferPointer<UInt8>) { scanner = YAMLScanner(bytes: bytes) }

    // MARK: Tokens

    private mutating func peek() throws -> YAMLToken {
        if let token = try scanner.peekToken() { return token }
        return YAMLToken(kind: .streamEnd, start: scanner.mark, end: scanner.mark)
    }

    @discardableResult
    private mutating func take() throws -> YAMLToken {
        if let token = try scanner.nextToken() { return token }
        return YAMLToken(kind: .streamEnd, start: scanner.mark, end: scanner.mark)
    }

    private func error(_ reason: String, _ token: YAMLToken) -> YAMLError {
        var atEnd = false
        if case .streamEnd = token.kind { atEnd = true }
        return YAMLError(reason: reason, mark: token.start, atEnd: atEnd)
    }

    private mutating func pop() { state = states.popLast() ?? .end }

    private func empty(_ mark: YAMLMark, anchor: String? = nil, tag: String? = nil) -> YAMLEvent {
        YAMLEvent(kind: .scalar(value: "", style: .plain, anchor: anchor, tag: tag), start: mark, end: mark)
    }

    // MARK: Events

    mutating func next() throws -> YAMLEvent? {
        switch state {
        case .end:
            return nil
        case .streamStart:
            let t = try take()
            state = .implicitDocumentStart
            return YAMLEvent(kind: .streamStart, start: t.start, end: t.end)
        case .implicitDocumentStart, .documentStart:
            return try documentStart()
        case .documentEnd:
            let t = try peek()
            var end = t.start
            if case .documentEnd = t.kind { try take(); end = t.end }
            state = .documentStart
            return YAMLEvent(kind: .documentEnd, start: t.start, end: end)
        case .documentContent:
            let t = try peek()
            switch t.kind {
            case .directive, .documentStart, .documentEnd, .streamEnd:
                pop()
                return empty(t.start)
            default:
                return try node(block: true, indentless: false)
            }
        case .blockNode: return try node(block: true, indentless: false)
        case .blockNodeOrIndentlessSequence: return try node(block: true, indentless: true)
        case .flowNode: return try node(block: false, indentless: false)
        case .blockSequenceFirstEntry:
            try take()
            return try blockSequenceEntry()
        case .blockSequenceEntry: return try blockSequenceEntry()
        case .indentlessSequenceEntry: return try indentlessSequenceEntry()
        case .blockMappingFirstKey:
            try take()
            return try blockMappingKey()
        case .blockMappingKey: return try blockMappingKey()
        case .blockMappingValue: return try blockMappingValue()
        case .flowSequenceFirstEntry:
            try take()
            return try flowSequenceEntry(first: true)
        case .flowSequenceEntry: return try flowSequenceEntry(first: false)
        case .flowSequenceEntryMappingKey:
            try take()
            let n = try peek()
            switch n.kind {
            case .value, .flowEntry, .flowSequenceEnd:
                state = .flowSequenceEntryMappingValue
                return empty(n.start)
            default:
                states.append(.flowSequenceEntryMappingValue)
                return try node(block: false, indentless: false)
            }
        case .flowSequenceEntryMappingValue:
            let t = try peek()
            if case .value = t.kind {
                try take()
                let n = try peek()
                switch n.kind {
                case .flowEntry, .flowSequenceEnd:
                    state = .flowSequenceEntryMappingEnd
                    return empty(n.start)
                default:
                    states.append(.flowSequenceEntryMappingEnd)
                    return try node(block: false, indentless: false)
                }
            }
            state = .flowSequenceEntryMappingEnd
            return empty(t.start)
        case .flowSequenceEntryMappingEnd:
            state = .flowSequenceEntry
            let t = try peek()
            return YAMLEvent(kind: .mappingEnd, start: t.start, end: t.start)
        case .flowMappingFirstKey:
            try take()
            return try flowMappingKey(first: true)
        case .flowMappingKey: return try flowMappingKey(first: false)
        case .flowMappingValue:
            let t = try peek()
            if case .value = t.kind {
                try take()
                let n = try peek()
                switch n.kind {
                case .flowEntry, .flowMappingEnd:
                    state = .flowMappingKey
                    return empty(n.start)
                default:
                    states.append(.flowMappingKey)
                    return try node(block: false, indentless: false)
                }
            }
            state = .flowMappingKey
            return empty(t.start)
        case .flowMappingEmptyValue:
            state = .flowMappingKey
            return empty(try peek().start)
        }
    }

    private mutating func documentStart() throws -> YAMLEvent {
        while case .documentEnd = try peek().kind { try take() }
        let t = try peek()
        switch t.kind {
        case .streamEnd:
            try take()
            state = .end
            return YAMLEvent(kind: .streamEnd, start: t.start, end: t.end)
        case .directive, .documentStart:
            while case .directive = try peek().kind { try take() }
            let start = try peek()
            guard case .documentStart = start.kind else {
                throw error(String(localized: "expected '---' after the directives, found \(start.kind.label)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), start)
            }
            try take()
            states.append(.documentEnd)
            state = .documentContent
            return YAMLEvent(kind: .documentStart(explicit: true), start: start.start, end: start.end)
        default:
            // A bare document: content with no '---' (the first document, or one after '...').
            states.append(.documentEnd)
            state = .blockNode
            return YAMLEvent(kind: .documentStart(explicit: false), start: t.start, end: t.start)
        }
    }

    private mutating func node(block: Bool, indentless: Bool) throws -> YAMLEvent {
        var t = try peek()
        if case .alias(let name) = t.kind {
            try take()
            pop()
            return YAMLEvent(kind: .alias(name), start: t.start, end: t.end)
        }
        var anchor: String?
        var tag: String?
        let start = t.start
        if case .anchor(let a) = t.kind {
            try take(); anchor = a; t = try peek()
            if case .tag(let g) = t.kind { try take(); tag = g; t = try peek() }
        } else if case .tag(let g) = t.kind {
            try take(); tag = g; t = try peek()
            if case .anchor(let a) = t.kind { try take(); anchor = a; t = try peek() }
        }
        if indentless, case .blockEntry = t.kind {
            state = .indentlessSequenceEntry
            return YAMLEvent(kind: .sequenceStart(anchor: anchor, tag: tag), start: start, end: t.end)
        }
        switch t.kind {
        case .scalar(let value, let style):
            try take()
            pop()
            return YAMLEvent(kind: .scalar(value: value, style: style, anchor: anchor, tag: tag), start: start, end: t.end)
        case .flowSequenceStart:
            state = .flowSequenceFirstEntry
            return YAMLEvent(kind: .sequenceStart(anchor: anchor, tag: tag), start: start, end: t.end)
        case .flowMappingStart:
            state = .flowMappingFirstKey
            return YAMLEvent(kind: .mappingStart(anchor: anchor, tag: tag), start: start, end: t.end)
        case .blockSequenceStart where block:
            state = .blockSequenceFirstEntry
            return YAMLEvent(kind: .sequenceStart(anchor: anchor, tag: tag), start: start, end: t.end)
        case .blockMappingStart where block:
            state = .blockMappingFirstKey
            return YAMLEvent(kind: .mappingStart(anchor: anchor, tag: tag), start: start, end: t.end)
        default:
            if anchor != nil || tag != nil {
                pop()
                return empty(start, anchor: anchor, tag: tag)
            }
            throw error(String(localized: "expected a value, found \(t.kind.label)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), t)
        }
    }

    private mutating func blockSequenceEntry() throws -> YAMLEvent {
        let t = try peek()
        if case .blockEntry = t.kind {
            try take()
            let n = try peek()
            switch n.kind {
            case .blockEntry, .blockEnd:
                state = .blockSequenceEntry
                return empty(t.end)
            default:
                states.append(.blockSequenceEntry)
                return try node(block: true, indentless: false)
            }
        }
        guard case .blockEnd = t.kind else { throw error(String(localized: "expected '-' or the end of the sequence, found \(t.kind.label)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), t) }
        try take()
        pop()
        return YAMLEvent(kind: .sequenceEnd, start: t.start, end: t.end)
    }

    private mutating func indentlessSequenceEntry() throws -> YAMLEvent {
        let t = try peek()
        if case .blockEntry = t.kind {
            try take()
            let n = try peek()
            switch n.kind {
            case .blockEntry, .key, .value, .blockEnd:
                state = .indentlessSequenceEntry
                return empty(t.end)
            default:
                states.append(.indentlessSequenceEntry)
                return try node(block: true, indentless: false)
            }
        }
        pop()
        return YAMLEvent(kind: .sequenceEnd, start: t.start, end: t.start)
    }

    private mutating func blockMappingKey() throws -> YAMLEvent {
        let t = try peek()
        if case .key = t.kind {
            try take()
            let n = try peek()
            switch n.kind {
            case .key, .value, .blockEnd:
                state = .blockMappingValue
                return empty(t.end)
            default:
                states.append(.blockMappingValue)
                return try node(block: true, indentless: true)
            }
        }
        guard case .blockEnd = t.kind else {
            throw error(String(localized: "expected a key ('key: value') or the end of the mapping, found \(t.kind.label)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), t)
        }
        try take()
        pop()
        return YAMLEvent(kind: .mappingEnd, start: t.start, end: t.end)
    }

    private mutating func blockMappingValue() throws -> YAMLEvent {
        let t = try peek()
        if case .value = t.kind {
            try take()
            let n = try peek()
            switch n.kind {
            case .key, .value, .blockEnd:
                state = .blockMappingKey
                return empty(t.end)
            default:
                states.append(.blockMappingKey)
                return try node(block: true, indentless: true)
            }
        }
        state = .blockMappingKey
        return empty(t.start)
    }

    private mutating func flowSequenceEntry(first: Bool) throws -> YAMLEvent {
        var t = try peek()
        if case .flowSequenceEnd = t.kind {} else {
            if !first {
                guard case .flowEntry = t.kind else { throw error(String(localized: "expected ',' or ']', found \(t.kind.label)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), t) }
                try take()
                t = try peek()
            }
            if case .key = t.kind {
                state = .flowSequenceEntryMappingKey
                return YAMLEvent(kind: .mappingStart(anchor: nil, tag: nil), start: t.start, end: t.end)
            }
            if case .flowSequenceEnd = t.kind {} else {
                states.append(.flowSequenceEntry)
                return try node(block: false, indentless: false)
            }
        }
        try take()
        pop()
        return YAMLEvent(kind: .sequenceEnd, start: t.start, end: t.end)
    }

    private mutating func flowMappingKey(first: Bool) throws -> YAMLEvent {
        var t = try peek()
        if case .flowMappingEnd = t.kind {} else {
            if !first {
                guard case .flowEntry = t.kind else { throw error(String(localized: "expected ',' or '}', found \(t.kind.label)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), t) }
                try take()
                t = try peek()
            }
            if case .key = t.kind {
                try take()
                let n = try peek()
                switch n.kind {
                case .value, .flowEntry, .flowMappingEnd:
                    state = .flowMappingValue
                    return empty(n.start)
                default:
                    states.append(.flowMappingValue)
                    return try node(block: false, indentless: false)
                }
            }
            if case .flowMappingEnd = t.kind {} else {
                states.append(.flowMappingEmptyValue)
                return try node(block: false, indentless: false)
            }
        }
        try take()
        pop()
        return YAMLEvent(kind: .mappingEnd, start: t.start, end: t.end)
    }
}

/// YAML into the tree: events become nodes, anchors are remembered by node index, and an alias is expanded by
/// copying the anchored subtree under a budget (`maxAliasExpansionNodes`), so nested aliases that would double a
/// tree a billion times stop at a few hundred thousand nodes with a coverage note. Scalars resolve by the YAML 1.2
/// core schema (so `yes` stays a string), plus ISO dates as `.date`; tags are kept as written and `!!str`,
/// `!!int`, `!!float`, `!!bool`, `!!null`, `!!binary` and `!!timestamp` decide the kind.
enum YAMLReader {
    static func read(_ data: Data, options: StructuredOptions, truncated: Bool) -> ReaderOutput {
        var input = data
        // A cut-short file ends mid-line; drop the partial line so the cut does not read as a syntax error.
        if truncated, let lastNewline = input.lastIndex(of: 0x0A) { input = input.prefix(upTo: lastNewline + 1) }
        return input.withUnsafeBytes { raw in
            var output = ReaderOutput(builder: StructuredTreeBuilder(options: options, pathStyle: .jsonPath), dialect: .yaml)
            output.documentCount = 0
            var parser = YAMLParser(bytes: raw.bindMemory(to: UInt8.self))
            var composer = Composer(options: options)
            do {
                while let event = try parser.next() { composer.handle(event, into: &output) }
            } catch let error as YAMLError {
                if error.atEnd && truncated {
                    output.endedEarly = true
                } else {
                    output.fail(StructuredDiagnostic(.error, error.reason, at: location(error.mark)), cap: options.maxDiagnostics)
                }
            } catch {}
            for directive in parser.scanner.directives {
                switch directive.name {
                case "YAML": break
                case "TAG":
                    output.note(StructuredDiagnostic(.unsupported, String(localized: "%TAG shorthands are not expanded; tags are shown as written", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")),
                                cap: options.maxDiagnostics)
                default:
                    output.note(StructuredDiagnostic(.warning, String(localized: "unknown directive %\(directive.name) ignored", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")), cap: options.maxDiagnostics)
                }
            }
            return output
        }
    }

    static func location(_ mark: YAMLMark) -> StructuredLocation {
        StructuredLocation(line: mark.line + 1, column: mark.column + 1, byteOffset: Int64(mark.offset))
    }

    private struct Frame {
        var isMapping: Bool
        var expectingKey = true
        var pendingKey: String?
    }

    private struct Composer {
        let options: StructuredOptions
        var frames: [Frame] = []
        var skipDepth = 0
        var anchors: [String: Int] = [:]
        var aliasBudget: Int
        var aliasLimitHit = false

        init(options: StructuredOptions) {
            self.options = options
            aliasBudget = max(0, options.maxAliasExpansionNodes)
        }

        private var expectingKey: Bool { frames.last.map { $0.isMapping && $0.expectingKey } ?? false }

        private mutating func takeName() -> String? {
            guard let last = frames.indices.last, frames[last].isMapping else { return nil }
            let name = frames[last].pendingKey ?? ""
            frames[last].pendingKey = nil
            frames[last].expectingKey = true
            return name
        }

        private mutating func setKey(_ key: String) {
            let last = frames.count - 1
            frames[last].pendingKey = key
            frames[last].expectingKey = false
        }

        private func span(_ event: YAMLEvent) -> StructuredSpan {
            StructuredSpan(byteOffset: Int64(event.start.offset), byteLength: Int64(event.end.offset - event.start.offset),
                           line: event.start.line + 1, column: event.start.column + 1)
        }

        private mutating func remember(_ index: Int?, anchor: String?, tag: String?, output: inout ReaderOutput) {
            if let anchor {
                anchors[anchor] = index ?? -1
                if let index { output.builder.anchors[Int32(index)] = anchor }
            }
            if let tag, let index { output.builder.tags[Int32(index)] = tag }
        }

        mutating func handle(_ event: YAMLEvent, into output: inout ReaderOutput) {
            if skipDepth > 0 {
                switch event.kind {
                case .sequenceStart, .mappingStart: skipDepth += 1
                case .sequenceEnd, .mappingEnd:
                    skipDepth -= 1
                    if skipDepth == 0 { setKey("<complex key>") }
                default: break
                }
                return
            }
            switch event.kind {
            case .streamStart, .streamEnd, .documentEnd:
                break
            case .documentStart:
                output.documentCount += 1
            case .scalar(let value, let style, let anchor, let tag):
                if expectingKey {
                    let (key, cut) = output.builder.previewText(value[...])
                    setKey(cut ? key + "…" : key)
                    return
                }
                let name = takeName()
                let (kind, preview) = YAMLReader.resolve(value, style: style, tag: tag)
                let (text, cut) = output.builder.previewText(preview[...])
                let index = output.builder.leaf(kind, name: name, preview: text, truncated: cut, span: span(event))
                remember(index, anchor: anchor, tag: tag, output: &output)
            case .alias(let alias):
                if expectingKey { setKey("*" + alias); return }
                let name = takeName()
                expand(alias, name: name, event: event, output: &output)
            case .sequenceStart(let anchor, let tag), .mappingStart(let anchor, let tag):
                var isMapping = false
                if case .mappingStart = event.kind { isMapping = true }
                if expectingKey {
                    output.note(StructuredDiagnostic(.unsupported, String(localized: "a collection used as a mapping key is not supported; shown as <complex key>", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."),
                                                     at: YAMLReader.location(event.start)), cap: options.maxDiagnostics)
                    skipDepth = 1
                    return
                }
                let name = takeName()
                let index = output.builder.open(isMapping ? .object : .array, name: name, span: span(event))
                remember(index, anchor: anchor, tag: tag, output: &output)
                frames.append(Frame(isMapping: isMapping))
            case .sequenceEnd, .mappingEnd:
                frames.removeLast()
                output.builder.close(endOffset: Int64(event.end.offset))
            }
        }

        private mutating func expand(_ alias: String, name: String?, event: YAMLEvent, output: inout ReaderOutput) {
            func placeholder() {
                output.builder.leaf(.string, role: .alias, name: name, preview: "*" + alias, span: span(event))
            }
            guard let target = anchors[alias] else {
                output.note(StructuredDiagnostic(.error, String(localized: "undefined alias '*\(alias)'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), at: YAMLReader.location(event.start)),
                            cap: options.maxDiagnostics)
                return placeholder()
            }
            guard target >= 0 else { return placeholder() }
            guard output.builder.isComplete(target) else {
                output.note(StructuredDiagnostic(.unsupported, String(localized: "recursive alias '*\(alias)' (it refers to a node that contains it) is not expanded", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."),
                                                 at: YAMLReader.location(event.start)), cap: options.maxDiagnostics)
                return placeholder()
            }
            if let added = output.builder.copySubtree(of: target, name: name, budget: aliasBudget) {
                aliasBudget -= added
            } else {
                if !aliasLimitHit {
                    aliasLimitHit = true
                    output.extraLimits.append(.aliasExpansionLimit(options.maxAliasExpansionNodes))
                }
                placeholder()
            }
        }
    }

    // MARK: Scalars

    /// The kind and display text of a scalar.
    static func resolve(_ value: String, style: YAMLScalarStyle, tag: String?) -> (StructuredNodeKind, String) {
        if let tag {
            let name = tag.hasPrefix("!!") ? String(tag.dropFirst(2))
                : tag.hasPrefix("tag:yaml.org,2002:") ? String(tag.dropFirst(18)) : nil
            switch name {
            case "str": return (.string, value)
            case "int", "float": return (.number, value)
            case "bool": return (.bool, value)
            case "null": return (.null, value.isEmpty ? "null" : value)
            case "timestamp": return (.date, value)
            case "binary":
                let compact = value.filter { !$0.isWhitespace }
                let bytes = Data(base64Encoded: compact)?.count
                return (.data, bytes.map { String(localized: "\($0.formatted()) bytes", bundle: .module, comment: "Preview of a YAML !!binary value: its decoded length in bytes.") } ?? String(localized: "invalid base64", bundle: .module, comment: "Preview of a YAML !!binary value that is not valid base64."))
            default:
                if tag == "!" { return (.string, value) }
            }
        }
        guard style == .plain else { return (.string, value) }
        switch value {
        case "", "~", "null", "Null", "NULL": return (.null, value.isEmpty ? "null" : value)
        case "true", "True", "TRUE", "false", "False", "FALSE": return (.bool, value)
        default: break
        }
        let bytes = Array(value.utf8)
        if isNumber(bytes) { return (.number, value) }
        if isTimestamp(bytes) { return (.date, value) }
        return (.string, value)
    }

    static func isNumber(_ s: [UInt8]) -> Bool {
        guard !s.isEmpty else { return false }
        func all(_ range: ArraySlice<UInt8>, _ ok: (UInt8) -> Bool) -> Bool { !range.isEmpty && range.allSatisfy(ok) }
        let digit: (UInt8) -> Bool = { $0 >= 48 && $0 <= 57 }
        if s.count > 2, s[0] == 48, s[1] == UInt8(ascii: "o") { return all(s[2...]) { $0 >= 48 && $0 <= 55 } }
        if s.count > 2, s[0] == 48, s[1] == UInt8(ascii: "x") {
            return all(s[2...]) { digit($0) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
        }
        var i = 0
        if s[0] == UInt8(ascii: "-") || s[0] == UInt8(ascii: "+") { i = 1 }
        let rest = String(decoding: s[i...], as: UTF8.self)
        if [".inf", ".Inf", ".INF"].contains(rest) { return true }
        if i == 0, [".nan", ".NaN", ".NAN"].contains(rest) { return true }
        var intDigits = 0, fracDigits = 0
        while i < s.count, digit(s[i]) { i += 1; intDigits += 1 }
        var sawDot = false
        if i < s.count, s[i] == UInt8(ascii: ".") {
            sawDot = true
            i += 1
            while i < s.count, digit(s[i]) { i += 1; fracDigits += 1 }
        }
        guard intDigits > 0 || (sawDot && fracDigits > 0) else { return false }
        if i < s.count, s[i] == UInt8(ascii: "e") || s[i] == UInt8(ascii: "E") {
            i += 1
            if i < s.count, s[i] == UInt8(ascii: "-") || s[i] == UInt8(ascii: "+") { i += 1 }
            var expDigits = 0
            while i < s.count, digit(s[i]) { i += 1; expDigits += 1 }
            if expDigits == 0 { return false }
        }
        return i == s.count
    }

    /// `2001-12-14`, `2001-12-14t21:59:43.10-05:00`, `2001-12-14 21:59:43.10 -5` (the YAML timestamp forms).
    static func isTimestamp(_ s: [UInt8]) -> Bool {
        var i = 0
        func digits(_ min: Int, _ max: Int) -> Bool {
            var n = 0
            while i < s.count, n < max, s[i] >= 48, s[i] <= 57 { i += 1; n += 1 }
            return n >= min
        }
        func char(_ c: Character) -> Bool {
            guard i < s.count, s[i] == c.asciiValue else { return false }
            i += 1
            return true
        }
        guard digits(4, 4), char("-"), digits(1, 2), char("-"), digits(1, 2) else { return false }
        if i == s.count { return true }
        if char("T") || char("t") {} else {
            guard i < s.count, s[i] == 0x20 || s[i] == 0x09 else { return false }
            while i < s.count, s[i] == 0x20 || s[i] == 0x09 { i += 1 }
        }
        guard digits(1, 2), char(":"), digits(2, 2), char(":"), digits(2, 2) else { return false }
        if char(".") { _ = digits(0, 64) }
        while i < s.count, s[i] == 0x20 || s[i] == 0x09 { i += 1 }
        if i == s.count { return true }
        if char("Z") { return i == s.count }
        guard char("+") || char("-"), digits(1, 2) else { return false }
        if char(":") { guard digits(2, 2) else { return false } }
        return i == s.count
    }
}
