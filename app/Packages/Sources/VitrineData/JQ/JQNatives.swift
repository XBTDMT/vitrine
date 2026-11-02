import Foundation

/// A built-in implemented in Swift. roadmap: S-5
struct JQNative: Sendable {
    enum Body: Sendable {
        /// `$`-parameters (every combination of argument outputs, the first varying slowest); one output each.
        case value(@Sendable (JQInterpreter, JQValue, [JQValue]) throws -> JQValue)
        /// `$`-parameters; any number of outputs.
        case stream(@Sendable (JQInterpreter, JQValue, [JQValue], (JQValue) throws -> Void) throws -> Void)
        /// Closure parameters, evaluated by the built-in itself (in path mode too, where that makes sense).
        case special(@Sendable (JQInterpreter, [JQNode], JQCursor, JQEnv, JQEmit) throws -> Void)
    }

    let name: String
    let arity: Int
    let body: Body

    func call(_ interp: JQInterpreter, _ args: [JQNode], _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        switch body {
        case .value(let f):
            try interp.cartesian(args, cur, env, []) { values in
                let v = try f(interp, cur.value, values)
                try interp.checkDepth(v)
                try out(try interp.result(v, cur))
            }
        case .stream(let f):
            try interp.cartesian(args, cur, env, []) { values in
                try f(interp, cur.value, values) { v in
                    try interp.tick()
                    try interp.checkDepth(v)
                    try out(try interp.result(v, cur))
                }
            }
        case .special(let f):
            try f(interp, args, cur, env, out)
        }
    }
}

/// Every Swift built-in, by "name/arity". roadmap: S-5
enum JQNatives {
    static let table: [String: JQNative] = build()

    private static func numberRequired(_ v: JQValue) throws -> Double {
        guard case .number(let d) = v else { throw JQThrown("\(JQOps.described(v)) number required") }
        return d
    }

    private static func string(_ v: JQValue, _ message: String) throws -> String {
        guard case .string(let s) = v else { throw JQThrown(message) }
        return s
    }

    /// The elements `.[]` would produce for array or object input.
    private static func elements(_ v: JQValue) throws -> [JQValue] {
        switch v {
        case .array(let items): return items
        case .object(let object): return object.storage.values
        default: throw JQThrown("Cannot iterate over \(JQOps.described(v))")
        }
    }

    private static func sortable(_ v: JQValue) throws -> [JQValue] {
        guard case .array(let items) = v else { throw JQThrown("\(JQOps.described(v)) cannot be sorted, as it is not an array") }
        return items
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func build() -> [String: JQNative] {
        var t: [String: JQNative] = [:]
        func value(_ name: String, _ arity: Int, _ f: @escaping @Sendable (JQInterpreter, JQValue, [JQValue]) throws -> JQValue) {
            t["\(name)/\(arity)"] = JQNative(name: name, arity: arity, body: .value(f))
        }
        func stream(_ name: String, _ arity: Int,
                    _ f: @escaping @Sendable (JQInterpreter, JQValue, [JQValue], (JQValue) throws -> Void) throws -> Void) {
            t["\(name)/\(arity)"] = JQNative(name: name, arity: arity, body: .stream(f))
        }
        func special(_ name: String, _ arity: Int, _ f: @escaping @Sendable (JQInterpreter, [JQNode], JQCursor, JQEnv, JQEmit) throws -> Void) {
            t["\(name)/\(arity)"] = JQNative(name: name, arity: arity, body: .special(f))
        }

        // MARK: Control

        special("empty", 0) { _, _, _, _, _ in }
        value("error", 0) { _, input, _ in throw JQThrown(input) }
        value("error", 1) { _, _, a in throw JQThrown(a[0]) }
        value("not", 0) { _, input, _ in .bool(!input.isTruthy) }
        special("path", 1) { interp, args, cur, env, out in
            try interp.eval(args[0], JQCursor(value: cur.value, path: []), env) { p in
                try out(try interp.result(.array(p.path ?? []), cur))
            }
        }
        special("getpath", 1) { interp, args, cur, env, out in
            try interp.eval(args[0], cur.valueMode, env) { p in
                guard case .array(let components) = p.value else { throw JQThrown("Path must be specified as an array") }
                let v = try JQPaths.get(cur.value, components)
                try out(JQCursor(value: v, path: cur.path.map { $0 + components }))
            }
        }
        value("setpath", 2) { interp, input, a in
            guard case .array(let path) = a[0] else { throw JQThrown("Path must be specified as an array") }
            return try JQPaths.set(input, path, a[1], interp)
        }
        value("delpaths", 1) { interp, input, a in
            guard case .array(let paths) = a[0] else { throw JQThrown("Paths must be specified as an array") }
            var list: [[JQValue]] = []
            for p in paths {
                guard case .array(let path) = p else { throw JQThrown("Path must be specified as an array") }
                list.append(path)
            }
            return try JQPaths.delete(input, list, interp)
        }
        special("limit", 2) { interp, args, cur, env, out in
            try interp.eval(args[0], cur.valueMode, env) { nv in
                guard case .number(let n) = nv.value else { throw JQThrown("Invalid limit: \(JQOps.described(nv.value))") }
                if n < 0 {
                    try interp.eval(args[1], cur, env, out)
                    return
                }
                if n == 0 { return }
                var count = 0.0
                let token = interp.newToken()
                do {
                    try interp.eval(args[1], cur, env) { v in
                        count += 1
                        try out(v)
                        if count >= n { throw JQBreak(token: token) }
                    }
                } catch let b as JQBreak where b.token == token {}
            }
        }
        special("first", 1) { interp, args, cur, env, out in
            let token = interp.newToken()
            do {
                try interp.eval(args[0], cur, env) { v in
                    try out(v)
                    throw JQBreak(token: token)
                }
            } catch let b as JQBreak where b.token == token {}
        }
        special("last", 1) { interp, args, cur, env, out in
            var last: JQCursor?
            try interp.eval(args[0], cur, env) { last = $0 }
            try out(try last ?? interp.result(.null, cur))
        }
        special("until", 2) { interp, args, cur, env, out in try interp.loop(isUntil: true, args[0], args[1], cur, env, out) }
        special("while", 2) { interp, args, cur, env, out in try interp.loop(isUntil: false, args[0], args[1], cur, env, out) }
        special("repeat", 1) { interp, args, cur, env, out in try interp.recurse(args[0], nil, cur, env, out) }
        special("recurse", 0) { interp, _, cur, env, out in try interp.recurse(nil, nil, cur, env, out) }
        special("recurse", 1) { interp, args, cur, env, out in try interp.recurse(args[0], nil, cur, env, out) }
        special("recurse", 2) { interp, args, cur, env, out in try interp.recurse(args[0], args[1], cur, env, out) }
        stream("range", 1) { interp, _, a, emit in try range(interp, .number(0), a[0], .number(1), emit) }
        stream("range", 2) { interp, _, a, emit in try range(interp, a[0], a[1], .number(1), emit) }
        stream("range", 3) { interp, _, a, emit in try range(interp, a[0], a[1], a[2], emit) }
        special("debug", 0) { _, _, cur, _, out in try out(cur) }
        special("debug", 1) { interp, args, cur, env, out in
            try interp.eval(args[0], cur.valueMode, env) { _ in }
            try out(cur)
        }
        special("stderr", 0) { _, _, cur, _, out in try out(cur) }
        value("builtins", 0) { _, _, _ in
            let names = Set(JQNatives.table.keys).union(JQBuiltinDefs.table.keys).filter { !$0.hasPrefix("_") }
            return .array(names.sorted().map(JQValue.string))
        }

        // MARK: Inspection

        value("length", 0) { _, input, _ in
            switch input {
            case .null: return .number(0)
            case .bool: throw JQThrown("\(JQOps.described(input)) has no length")
            case .number(let d): return .number(abs(d))
            case .string(let s): return .number(Double(s.unicodeScalars.count))
            case .array(let a): return .number(Double(a.count))
            case .object(let o): return .number(Double(o.count))
            }
        }
        value("utf8bytelength", 0) { _, input, _ in
            guard case .string(let s) = input else { throw JQThrown("\(JQOps.described(input)) only strings have UTF-8 byte length") }
            return .number(Double(s.utf8.count))
        }
        value("type", 0) { _, input, _ in .string(input.typeName) }
        value("keys", 0) { _, input, _ in
            switch input {
            case .object(let o): return .array(o.sortedKeys.map(JQValue.string))
            case .array(let a): return .array(a.indices.map { .number(Double($0)) })
            default: throw JQThrown("\(JQOps.described(input)) has no keys")
            }
        }
        value("keys_unsorted", 0) { _, input, _ in
            switch input {
            case .object(let o): return .array(o.keys.map(JQValue.string))
            case .array(let a): return .array(a.indices.map { .number(Double($0)) })
            default: throw JQThrown("\(JQOps.described(input)) has no keys")
            }
        }
        value("has", 1) { _, input, a in
            switch (input, a[0]) {
            case (.object(let o), .string(let k)): return .bool(o[k] != nil)
            case (.array(let items), .number(let n)): return .bool(n >= 0 && n < Double(items.count))
            default: throw JQThrown("Cannot check whether \(input.typeName) has a \(a[0].typeName) key")
            }
        }
        value("contains", 1) { _, input, a in .bool(try contains(input, a[0])) }
        value("add", 0) { interp, input, _ in
            if case .null = input { return .null }
            return try add(try elements(input), interp)
        }
        value("any", 0) { _, input, _ in .bool(try elements(input).contains { $0.isTruthy }) }
        value("all", 0) { _, input, _ in .bool(try elements(input).allSatisfy { $0.isTruthy }) }
        value("infinite", 0) { _, _, _ in .number(.infinity) }
        value("nan", 0) { _, _, _ in .number(.nan) }
        value("isinfinite", 0) { _, input, _ in .bool(try numberRequired(input).isInfinite) }
        value("isnan", 0) { _, input, _ in .bool(try numberRequired(input).isNaN) }
        value("isnormal", 0) { _, input, _ in .bool(try numberRequired(input).isNormal) }
        value("abs", 0) { _, input, _ in
            guard case .number(let d) = input else { throw JQThrown("\(JQOps.described(input)) has no absolute value") }
            return .number(d < 0 ? -d : d)
        }
        value("toarray", 0) { _, input, _ in
            if case .array = input { return input }
            return .array([input])
        }

        // MARK: Conversion

        value("tostring", 0) { interp, input, _ in .string(try JQFormats.toString(input, interp)) }
        value("tojson", 0) { interp, input, _ in .string(try JQFormats.toJSON(input, interp)) }
        value("fromjson", 0) { interp, input, _ in
            guard case .string(let s) = input else { throw JQThrown("\(JQOps.described(input)) only strings can be parsed") }
            do {
                return try JQJSONReader.parse(Array(s.utf8), maxDepth: interp.valueDepthLimit)
            } catch let failure as JQJSONReader.Failure {
                throw JQThrown("\(failure.message) (while parsing '\(s)')")
            }
        }
        value("tonumber", 0) { _, input, _ in
            switch input {
            case .number: return input
            case .string(let s):
                let allowed = Set("0123456789+-.eE".utf8)
                guard !s.isEmpty, s.utf8.allSatisfy({ allowed.contains($0) }), let d = Double(s) else {
                    throw JQThrown("Cannot parse '\(s)' as JSON")
                }
                return .number(d)
            default:
                throw JQThrown("\(JQOps.described(input)) cannot be parsed as a number")
            }
        }
        value("ascii_downcase", 0) { _, input, _ in
            let s = try string(input, "ascii_downcase input must be a string")
            return .string(String(decoding: s.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self))
        }
        value("ascii_upcase", 0) { _, input, _ in
            let s = try string(input, "ascii_upcase input must be a string")
            return .string(String(decoding: s.utf8.map { $0 >= 97 && $0 <= 122 ? $0 - 32 : $0 }, as: UTF8.self))
        }
        value("explode", 0) { _, input, _ in
            let s = try string(input, "explode input must be a string")
            return .array(s.unicodeScalars.map { .number(Double($0.value)) })
        }
        value("implode", 0) { interp, input, _ in
            guard case .array(let items) = input else { throw JQThrown("implode input must be an array") }
            var out = String.UnicodeScalarView()
            for item in items {
                guard case .number(let d) = item else { throw JQThrown("Unicode codepoint must be numeric") }
                guard d.isFinite, d >= 0, d <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(d)) else {
                    throw JQThrown("Invalid codepoint literal")
                }
                out.append(scalar)
            }
            try interp.checkStringSize(out.count)
            return .string(String(out))
        }
        value("ascii", 0) { _, input, _ in
            guard case .number(let d) = input, d >= 0, d < 128 else { throw JQThrown("ascii requires a number from 0 to 127") }
            return .string(String(Character(Unicode.Scalar(UInt8(d)))))
        }
        value("ltrimstr", 1) { _, input, a in
            guard case .string(let s) = input, case .string(let prefix) = a[0], s.utf8.starts(with: prefix.utf8) else { return input }
            return .string(String(decoding: s.utf8.dropFirst(prefix.utf8.count), as: UTF8.self))
        }
        value("rtrimstr", 1) { _, input, a in
            guard case .string(let s) = input, case .string(let suffix) = a[0], s.utf8.count >= suffix.utf8.count,
                  s.utf8.reversed().starts(with: suffix.utf8.reversed()) else { return input }
            return .string(String(decoding: s.utf8.dropLast(suffix.utf8.count), as: UTF8.self))
        }
        value("startswith", 1) { _, input, a in
            guard case .string(let s) = input, case .string(let prefix) = a[0] else { throw JQThrown("startswith() requires string inputs") }
            return .bool(s.utf8.starts(with: prefix.utf8))
        }
        value("endswith", 1) { _, input, a in
            guard case .string(let s) = input, case .string(let suffix) = a[0] else { throw JQThrown("endswith() requires string inputs") }
            return .bool(s.utf8.count >= suffix.utf8.count && s.utf8.reversed().starts(with: suffix.utf8.reversed()))
        }
        for (name, leading, trailing) in [("trim", true, true), ("ltrim", true, false), ("rtrim", false, true)] {
            value(name, 0) { _, input, _ in
                let s = try string(input, "\(name) input must be a string")
                var scalars = Substring(s).unicodeScalars[...]
                let space: (Unicode.Scalar) -> Bool = { $0 == " " || ($0.value >= 0x09 && $0.value <= 0x0D) }
                if leading { while let f = scalars.first, space(f) { scalars = scalars.dropFirst() } }
                if trailing { while let l = scalars.last, space(l) { scalars = scalars.dropLast() } }
                return .string(String(scalars))
            }
        }
        value("split", 1) { _, input, a in
            guard case .string(let s) = input, case .string(let sep) = a[0] else {
                throw JQThrown("split input and separator must be strings")
            }
            return JQOps.split(s, by: sep)
        }
        value("join", 1) { interp, input, a in try join(try elements(input), a[0], interp) }

        // MARK: Arrays

        value("sort", 0) { _, input, _ in
            let items = try sortable(input)
            return .array(JQOrder.stableSortIndices(items).map { items[$0] })
        }
        value("unique", 0) { _, input, _ in
            let items = try sortable(input)
            return .array(JQOrder.groupIndices(items).map { items[$0[0]] })
        }
        value("min", 0) { _, input, _ in
            let items = try sortable(input)
            guard var best = items.first else { return .null }
            for item in items.dropFirst() where JQOrder.compare(item, best) < 0 { best = item }
            return best
        }
        value("max", 0) { _, input, _ in
            let items = try sortable(input)
            guard var best = items.first else { return .null }
            for item in items.dropFirst() where JQOrder.compare(item, best) >= 0 { best = item }
            return best
        }
        value("reverse", 0) { _, input, _ in
            switch input {
            case .null: return .array([])
            case .array(let items): return .array(items.reversed())
            case .string(let s): return .string(String(String.UnicodeScalarView(s.unicodeScalars.reversed())))
            case .object(let o): if o.isEmpty { return .array([]) }; throw JQThrown("Cannot index object with number")
            default: throw JQThrown("Cannot index \(input.typeName) with number")
            }
        }
        value("flatten", 0) { interp, input, _ in try flatten(try elements(input), depth: 1_000_000, interp) }
        value("flatten", 1) { interp, input, a in
            guard case .number(let d) = a[0] else { throw JQThrown("flatten depth must not be negative") }
            if d < 0 { throw JQThrown("flatten depth must not be negative") }
            return try flatten(try elements(input), depth: d, interp)
        }
        value("indices", 1) { _, input, a in try indices(input, a[0]) }
        for (name, kind) in [("sort_by", 0), ("group_by", 1), ("unique_by", 2), ("min_by", 3), ("max_by", 4)] {
            special(name, 1) { interp, args, cur, env, out in
                let items = try sortable(cur.value)
                var keys: [JQValue] = []
                keys.reserveCapacity(items.count)
                for item in items {
                    var key: [JQValue] = []
                    try interp.eval(args[0], JQCursor(value: item, path: nil), env) { key.append($0.value) }
                    keys.append(.array(key))
                }
                let result: JQValue
                switch kind {
                case 0:
                    result = .array(JQOrder.stableSortIndices(keys).map { items[$0] })
                case 1, 2:
                    let groups = JQOrder.groupIndices(keys)
                    result = kind == 1 ? .array(groups.map { .array($0.map { items[$0] }) }) : .array(groups.map { items[$0[0]] })
                default:
                    guard !items.isEmpty else { result = .null; break }
                    var best = 0
                    for i in 1..<items.count {
                        let c = JQOrder.compare(keys[i], keys[best])
                        if kind == 3 ? c < 0 : c >= 0 { best = i }
                    }
                    result = items[best]
                }
                try interp.checkDepth(result)
                try out(try interp.result(result, cur))
            }
        }

        // MARK: Regular expressions

        value("test", 1) { interp, input, a in try JQRegex.test(input, a[0], .null, interp) }
        value("test", 2) { interp, input, a in try JQRegex.test(input, a[0], a[1], interp) }
        stream("match", 1) { interp, input, a, emit in try JQRegex.match(input, a[0], .null, interp, emit) }
        stream("match", 2) { interp, input, a, emit in try JQRegex.match(input, a[0], a[1], interp, emit) }
        stream("capture", 1) { interp, input, a, emit in try JQRegex.capture(input, a[0], .null, interp, emit) }
        stream("capture", 2) { interp, input, a, emit in try JQRegex.capture(input, a[0], a[1], interp, emit) }
        stream("scan", 1) { interp, input, a, emit in try JQRegex.scan(input, a[0], .null, interp, emit) }
        stream("scan", 2) { interp, input, a, emit in try JQRegex.scan(input, a[0], a[1], interp, emit) }
        value("split", 2) { interp, input, a in try JQRegex.split(input, a[0], a[1], interp) }
        for (name, global) in [("sub", false), ("gsub", true)] {
            for arity in [2, 3] {
                special(name, arity) { interp, args, cur, env, out in
                    // $re and $flags are value parameters; the replacement is a filter over the capture object.
                    var valueArgs = [args[0]]
                    if arity == 3 { valueArgs.append(args[2]) }
                    try interp.cartesian(valueArgs, cur, env, []) { a in
                        try JQRegex.substitute(cur.value, a[0], arity == 3 ? a[1] : .null, global: global, interp, { captures, emit in
                            try interp.eval(args[1], JQCursor(value: captures, path: nil), env) { try emit($0.value) }
                        }, { v in try out(try interp.result(v, cur)) })
                    }
                }
            }
        }

        // MARK: Dates (UTC only)

        value("gmtime", 0) { _, input, _ in try JQDates.gmtime(input) }
        value("mktime", 0) { _, input, _ in try JQDates.mktime(input) }
        value("strftime", 1) { _, input, a in try JQDates.strftime(input, a[0]) }
        value("strptime", 1) { _, input, a in try JQDates.strptime(input, a[0]) }

        // MARK: Math

        let unary: [(String, @Sendable (Double) -> Double)] = [
            ("floor", { $0.rounded(.down) }), ("ceil", { $0.rounded(.up) }), ("round", { $0.rounded(.toNearestOrAwayFromZero) }),
            ("fabs", { Swift.abs($0) }), ("sqrt", { $0.squareRoot() }), ("cbrt", { Foundation.cbrt($0) }),
            ("exp", { Foundation.exp($0) }), ("exp2", { Foundation.exp2($0) }), ("exp10", { Foundation.pow(10, $0) }),
            ("pow10", { Foundation.pow(10, $0) }), ("expm1", { Foundation.expm1($0) }),
            ("log", { Foundation.log($0) }), ("log2", { Foundation.log2($0) }), ("log10", { Foundation.log10($0) }),
            ("log1p", { Foundation.log1p($0) }), ("logb", { Foundation.logb($0) }),
            ("gamma", { Foundation.lgamma($0) }), ("lgamma", { Foundation.lgamma($0) }), ("tgamma", { Foundation.tgamma($0) }),
            ("sin", { Foundation.sin($0) }), ("cos", { Foundation.cos($0) }), ("tan", { Foundation.tan($0) }),
            ("asin", { Foundation.asin($0) }), ("acos", { Foundation.acos($0) }), ("atan", { Foundation.atan($0) }),
            ("sinh", { Foundation.sinh($0) }), ("cosh", { Foundation.cosh($0) }), ("tanh", { Foundation.tanh($0) }),
            ("asinh", { Foundation.asinh($0) }), ("acosh", { Foundation.acosh($0) }), ("atanh", { Foundation.atanh($0) }),
            ("trunc", { $0.rounded(.towardZero) }), ("rint", { $0.rounded(.toNearestOrEven) }),
            ("nearbyint", { $0.rounded(.toNearestOrEven) }),
            ("significand", { $0 == 0 || !$0.isFinite ? $0 : $0.significand * ($0 < 0 ? -1 : 1) }),
            ("j0", { Foundation.j0($0) }), ("j1", { Foundation.j1($0) }), ("y0", { Foundation.y0($0) }), ("y1", { Foundation.y1($0) }),
        ]
        for (name, f) in unary {
            value(name, 0) { _, input, _ in .number(f(try numberRequired(input))) }
        }
        let binaryMath: [(String, @Sendable (Double, Double) -> Double)] = [
            ("pow", { Foundation.pow($0, $1) }), ("atan2", { Foundation.atan2($0, $1) }), ("fmin", { Foundation.fmin($0, $1) }),
            ("fmax", { Foundation.fmax($0, $1) }), ("fmod", { Foundation.fmod($0, $1) }), ("hypot", { Foundation.hypot($0, $1) }),
            ("copysign", { Foundation.copysign($0, $1) }), ("drem", { Foundation.remainder($0, $1) }),
            ("nextafter", { Foundation.nextafter($0, $1) }), ("nexttoward", { Foundation.nextafter($0, $1) }),
            ("fdim", { Foundation.fdim($0, $1) }),
            ("ldexp", { Foundation.scalbn($0, Int(clamping: Int64($1.rounded(.towardZero).jqClamped(-1e6, 1e6)))) }),
            ("scalb", { Foundation.scalbn($0, Int(clamping: Int64($1.rounded(.towardZero).jqClamped(-1e6, 1e6)))) }),
            ("scalbln", { Foundation.scalbn($0, Int(clamping: Int64($1.rounded(.towardZero).jqClamped(-1e6, 1e6)))) }),
        ]
        for (name, f) in binaryMath {
            value(name, 2) { _, _, a in .number(f(try numberRequired(a[0]), try numberRequired(a[1]))) }
        }
        value("fma", 3) { _, _, a in
            .number(Foundation.fma(try numberRequired(a[0]), try numberRequired(a[1]), try numberRequired(a[2])))
        }
        value("frexp", 0) { _, input, _ in
            let d = try numberRequired(input)
            let r = Foundation.frexp(d)
            return .array([.number(r.0), .number(Double(r.1))])
        }
        value("modf", 0) { _, input, _ in
            let d = try numberRequired(input)
            let r = Foundation.modf(d)
            return .array([.number(r.1), .number(r.0)])
        }
        return t
    }

    // MARK: Helpers

    static func range(_ interp: JQInterpreter, _ from: JQValue, _ upto: JQValue, _ by: JQValue, _ emit: (JQValue) throws -> Void) throws {
        guard case .number(let start) = from, case .number(let end) = upto, case .number(let step) = by else {
            throw JQThrown("Range bounds must be numeric")
        }
        var x = start
        if step > 0 {
            while x < end { try emit(.number(x)); x += step }
        } else if step < 0 {
            while x > end { try emit(.number(x)); x += step }
        }
    }

    static func contains(_ a: JQValue, _ b: JQValue) throws -> Bool {
        if JQOrder.rank(a) != JQOrder.rank(b) {
            throw JQThrown("\(JQOps.described(a)) and \(JQOps.described(b)) cannot have their containment checked")
        }
        switch (a, b) {
        case (.object(let x), .object(let y)):
            for (key, value) in zip(y.storage.keys, y.storage.values) {
                guard let mine = x[key], try contains(mine, value) else { return false }
            }
            return true
        case (.array(let x), .array(let y)):
            for needle in y {
                var found = false
                for item in x where JQOrder.rank(item) == JQOrder.rank(needle) {
                    if try contains(item, needle) { found = true; break }
                }
                if !found { return false }
            }
            return true
        case (.string(let x), .string(let y)):
            if y.isEmpty { return true }
            let hay = Array(x.utf8), needle = Array(y.utf8)
            guard needle.count <= hay.count else { return false }
            for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle {
                return true
            }
            return false
        default:
            return a == b
        }
    }

    static func add(_ items: [JQValue], _ interp: JQInterpreter) throws -> JQValue {
        if items.isEmpty { return .null }
        if items.allSatisfy({ if case .string = $0 { true } else { false } }) {
            var total = 0
            var out = ""
            for case .string(let s) in items {
                total += s.utf8.count
                try interp.checkStringSize(total)
                out += s
            }
            return .string(out)
        }
        if items.allSatisfy({ if case .array = $0 { true } else { false } }) {
            var out: [JQValue] = []
            for case .array(let a) in items {
                try interp.checkArraySize(out.count + a.count)
                out += a
            }
            return .array(out)
        }
        var acc = JQValue.null
        for item in items {
            try interp.tick()
            acc = try JQOps.add(acc, item, interp)
        }
        return acc
    }

    static func join(_ items: [JQValue], _ separator: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        if items.isEmpty { return .string("") }
        var sep = ""
        switch separator {
        case .string(let s): sep = s
        case .null: sep = ""
        default:
            if items.count > 1 { _ = try JQOps.add(.string(""), separator, interp) }
        }
        var out = ""
        for (i, item) in items.enumerated() {
            if i > 0 { out += sep }
            switch item {
            case .null: break
            case .string(let s): out += s
            case .number, .bool: out += try JQFormats.toJSON(item, interp)
            case .array, .object: throw JQThrown("Cannot join with \(item.typeName)")
            }
            try interp.checkStringSize(out.utf8.count)
        }
        return .string(out)
    }

    static func flatten(_ items: [JQValue], depth: Double, _ interp: JQInterpreter) throws -> JQValue {
        var out: [JQValue] = []
        func walk(_ list: [JQValue], _ remaining: Double) throws {
            for item in list {
                if case .array(let inner) = item, remaining > 0 {
                    try walk(inner, remaining - 1)
                } else {
                    out.append(item)
                }
            }
            try interp.checkArraySize(out.count)
        }
        try walk(items, depth)
        return .array(out)
    }

    static func indices(_ input: JQValue, _ needle: JQValue) throws -> JQValue {
        switch (input, needle) {
        case (.null, _):
            return .null
        case (.string(let s), .string(let n)):
            guard !n.isEmpty else { return .null }
            let hay = Array(s.utf8), sub = Array(n.utf8)
            var out: [JQValue] = []
            var codePoints = 0
            var i = 0
            while i + sub.count <= hay.count {
                if hay[i] == sub[0], Array(hay[i..<(i + sub.count)]) == sub { out.append(.number(Double(codePoints))) }
                if hay[i] & 0xC0 != 0x80 { codePoints += 1 }
                i += 1
            }
            return .array(out)
        case (.array(let items), .array(let sub)):
            return JQOps.indices(of: sub, in: items)
        case (.array(let items), _):
            return JQOps.indices(of: [needle], in: items)
        default:
            return try JQOps.index(input, needle)
        }
    }
}
