import Foundation

/// Compile-time checks over a parsed program: every call is bound (to a definition in scope, a built-in jq
/// definition or a native built-in), every `$variable` and `break $label` exists, and anything Vitrine does not run
/// is refused by name. The bound program never looks a built-in up by name at run time. roadmap: S-5
struct JQResolver {
    /// Deeper than this the program is refused: it would only be a hostile one, and evaluation recursion follows it.
    static let maxProgramDepth = 1000

    private final class Scope {
        enum Entry {
            case function(String, Int)
            case variable(String)
            case label(String)
        }

        let parent: Scope?
        let entry: Entry

        init(_ parent: Scope?, _ entry: Entry) { self.parent = parent; self.entry = entry }

        func hasFunction(_ name: String, _ arity: Int) -> Bool {
            var s: Scope? = self
            while let current = s {
                if case .function(let n, let a) = current.entry, a == arity, n == name { return true }
                s = current.parent
            }
            return false
        }

        func hasVariable(_ name: String) -> Bool {
            var s: Scope? = self
            while let current = s {
                if case .variable(let n) = current.entry, n == name { return true }
                s = current.parent
            }
            return false
        }

        func hasLabel(_ name: String) -> Bool {
            var s: Scope? = self
            while let current = s {
                if case .label(let n) = current.entry, n == name { return true }
                s = current.parent
            }
            return false
        }
    }

    let source: [UInt8]
    /// The built-in jq definitions visible to the code being resolved.
    let builtins: [String: JQFuncDef]

    static func resolveProgram(_ root: JQNode, source: String) throws {
        let resolver = JQResolver(source: Array(source.utf8), builtins: JQBuiltinDefs.table)
        try resolver.resolve(root, nil, 0)
    }

    /// Binds the bodies of the built-in definitions, which see each other and the natives.
    static func resolveBuiltins(_ defs: [String: JQFuncDef], source: String) throws {
        let resolver = JQResolver(source: Array(source.utf8), builtins: defs)
        for def in defs.values {
            // A top-level built-in reaches itself (and the others) through `builtins`, not the environment.
            try resolver.resolveDefinition(def, nil, 0, bindSelf: false)
        }
    }

    private func syntax(_ reason: String, _ offset: Int) -> JQError {
        JQError(.syntax, "\(reason) at line \(JQError.position(of: offset, in: source).0), column "
                    + "\(JQError.position(of: offset, in: source).1)", offset: offset)
    }

    private func resolveDefinition(_ def: JQFuncDef, _ scope: Scope?, _ depth: Int, bindSelf: Bool = true) throws {
        var inner: Scope? = bindSelf ? Scope(scope, .function(def.name, def.params.count)) : scope
        for param in def.params {
            inner = Scope(inner, .function(param.name, 0))
            if param.isValue { inner = Scope(inner, .variable(param.name)) }
        }
        try resolve(def.body, inner, depth + 1)
    }

    private func resolve(_ node: JQNode, _ scope: Scope?, _ depth: Int) throws {
        if depth > Self.maxProgramDepth {
            throw JQError(.limit, "the program nests more than \(Self.maxProgramDepth) levels deep")
        }
        let d = depth + 1
        switch node {
        case .identity, .recurseAll, .literal, .format:
            return
        case .index(let target, let key):
            try resolve(target, scope, d)
            try resolve(key, scope, d)
        case .slice(let target, let from, let to):
            try resolve(target, scope, d)
            if let from { try resolve(from, scope, d) }
            if let to { try resolve(to, scope, d) }
        case .iterate(let target), .negate(let target):
            try resolve(target, scope, d)
        case .tryCatch(let body, let handler):
            try resolve(body, scope, d)
            if let handler { try resolve(handler, scope, d) }
        case .pipe(let a, let b), .comma(let a, let b), .binary(_, let a, let b), .and(let a, let b), .or(let a, let b),
             .alternative(let a, let b), .assign(_, let a, let b):
            try resolve(a, scope, d)
            try resolve(b, scope, d)
        case .ifElse(let c, let t, let e):
            try resolve(c, scope, d)
            try resolve(t, scope, d)
            if let e { try resolve(e, scope, d) }
        case .reduce(let source, let pattern, let initial, let update):
            try resolve(source, scope, d)
            try resolve(initial, scope, d)
            let inner = try bindPattern(pattern, scope, d)
            try resolve(update, inner, d)
        case .foreach(let source, let pattern, let initial, let update, let extract):
            try resolve(source, scope, d)
            try resolve(initial, scope, d)
            let inner = try bindPattern(pattern, scope, d)
            try resolve(update, inner, d)
            if let extract { try resolve(extract, inner, d) }
        case .bind(let source, let pattern, let body):
            try resolve(source, scope, d)
            let inner = try bindPattern(pattern, scope, d)
            try resolve(body, inner, d)
        case .funcDef(let def, let rest):
            try resolveDefinition(def, scope, d)
            try resolve(rest, Scope(scope, .function(def.name, def.params.count)), d)
        case .call(let call):
            for arg in call.args { try resolve(arg, scope, d) }
            try bind(call, scope)
        case .variable(let name, let offset):
            if name == "ENV" {
                throw JQError(.unsupported, "`$ENV` is not supported: the environment is not available in Vitrine", offset: offset)
            }
            if name == "__loc__" || name == "__prog_args" {
                throw JQError(.unsupported, "`$\(name)` is not supported in Vitrine yet", offset: offset)
            }
            guard scope?.hasVariable(name) == true else { throw syntax("$\(name) is not defined", offset) }
        case .array(let inner):
            if let inner { try resolve(inner, scope, d) }
        case .object(let entries):
            for entry in entries {
                try resolve(entry.key, scope, d)
                try resolve(entry.value, scope, d)
            }
        case .string(let parts, _):
            for case .interpolation(let inner) in parts { try resolve(inner, scope, d) }
        case .label(let name, let body):
            try resolve(body, Scope(scope, .label(name)), d)
        case .breakLabel(let name, let offset):
            guard scope?.hasLabel(name) == true else { throw syntax("$*label-\(name) is not defined", offset) }
        }
    }

    /// Resolves a pattern's key expressions and returns the scope with its variables bound. Variables become visible
    /// to the key expressions that follow them, as in jq.
    private func bindPattern(_ pattern: JQPattern, _ scope: Scope?, _ depth: Int) throws -> Scope? {
        var current = scope
        switch pattern {
        case .variable(let name):
            current = Scope(current, .variable(name))
        case .array(let items):
            for item in items { current = try bindPattern(item, current, depth + 1) }
        case .object(let entries):
            for entry in entries {
                switch entry.key {
                case .variable(let name): current = Scope(current, .variable(name))
                case .expression(let key): try resolve(key, current, depth + 1)
                }
                if let sub = entry.pattern { current = try bindPattern(sub, current, depth + 1) }
            }
        }
        return current
    }

    private func bind(_ call: JQCall, _ scope: Scope?) throws {
        let arity = call.args.count
        if scope?.hasFunction(call.name, arity) == true {
            call.target = .local
        } else if let def = builtins[call.key] {
            call.target = .builtinDef(def)
        } else if let native = JQNatives.table[call.key] {
            call.target = .native(native)
        } else if let message = JQUnsupported.message(for: call.name) {
            throw JQError(.unsupported, message, offset: call.offset)
        } else {
            throw syntax("\(call.name)/\(arity) is not defined", call.offset)
        }
    }
}

/// jq 1.7 built-ins Vitrine refuses, each with why. roadmap: S-5
enum JQUnsupported {
    static let refused: [String: String] = [
        "env": "`env` is not supported: the environment is not available in Vitrine",
        "input": "`input` is not supported in Vitrine: a query runs on one value, with no input stream",
        "inputs": "`inputs` is not supported in Vitrine: a query runs on one value, with no input stream",
        "input_filename": "`input_filename` is not supported in Vitrine: a query does not see file names",
        "input_line_number": "`input_line_number` is not supported in Vitrine: a query runs on one value",
        "now": "`now` is not supported in Vitrine: results must not depend on the clock",
        "localtime": "`localtime` is not supported in Vitrine: results must not depend on the time zone (use `gmtime`)",
        "strflocaltime": "`strflocaltime` is not supported in Vitrine: results must not depend on the time zone (use `strftime`)",
        "halt": "`halt` is not supported in Vitrine: a query cannot end the process",
        "halt_error": "`halt_error` is not supported in Vitrine: a query cannot end the process",
        "get_search_list": "`get_search_list` is not supported in Vitrine: modules are not supported",
        "get_prog_origin": "`get_prog_origin` is not supported in Vitrine: modules are not supported",
        "get_jq_origin": "`get_jq_origin` is not supported in Vitrine: modules are not supported",
        "modulemeta": "`modulemeta` is not supported in Vitrine: modules are not supported",
        "have_literal_numbers": "`have_literal_numbers` is not supported in Vitrine yet",
        "have_decnum": "`have_decnum` is not supported in Vitrine yet",
        "lgamma_r": "`lgamma_r` is not supported in Vitrine yet",
        "jn": "`jn` is not supported in Vitrine yet",
        "yn": "`yn` is not supported in Vitrine yet",
    ]

    static func message(for name: String) -> String? { refused[name] }
}
