import Foundation

/// A parsed jq program. Generators everywhere: every node may produce any number of outputs. roadmap: S-5
indirect enum JQNode: Sendable {
    /// `.`
    case identity
    /// `..` (`recurse`)
    case recurseAll
    case literal(JQValue)
    /// `target[key]`, `.foo`, `."foo"`: the key is evaluated against the same input as the target.
    case index(JQNode, JQNode)
    /// `target[from:to]`
    case slice(JQNode, JQNode?, JQNode?)
    /// `target[]`
    case iterate(JQNode)
    /// `try body catch handler`; `body?` and `try body` have no handler.
    case tryCatch(JQNode, JQNode?)
    case pipe(JQNode, JQNode)
    case comma(JQNode, JQNode)
    case negate(JQNode)
    case binary(JQBinaryOp, JQNode, JQNode)
    case and(JQNode, JQNode)
    case or(JQNode, JQNode)
    /// `a // b`
    case alternative(JQNode, JQNode)
    case assign(JQAssignOp, JQNode, JQNode)
    /// `if c then a else b end`; `elif` nests; no `else` means `.`.
    case ifElse(JQNode, JQNode, JQNode?)
    case reduce(JQNode, JQPattern, JQNode, JQNode)
    case foreach(JQNode, JQPattern, JQNode, JQNode, JQNode?)
    /// `source as pattern | body`
    case bind(JQNode, JQPattern, JQNode)
    case funcDef(JQFuncDef, JQNode)
    case call(JQCall)
    /// `$name`, with its offset in the program for compile errors.
    case variable(String, Int)
    /// `[e]`; nil for `[]`.
    case array(JQNode?)
    case object([JQObjectEntry])
    /// A string literal with interpolations, optionally under a format (`@base64 "…\(.)…"`).
    case string([JQStringPart], format: String?)
    /// `@base64` and friends applied to `.`.
    case format(String)
    case label(String, JQNode)
    case breakLabel(String, Int)
}

/// A piece of a string literal: text, or an interpolated program. roadmap: S-5
enum JQStringPart: Sendable {
    case literal(String)
    case interpolation(JQNode)
}

/// One `key: value` of an object construction, both as programs. roadmap: S-5
struct JQObjectEntry: Sendable {
    var key: JQNode
    var value: JQNode
}

/// The arithmetic and comparison operators. roadmap: S-5
enum JQBinaryOp: String, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", modulo = "%"
    case equal = "==", notEqual = "!=", less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">="
}

/// The assignment operators. roadmap: S-5
enum JQAssignOp: Sendable {
    /// `=`
    case set
    /// `|=`
    case update
    /// `+=`, `-=`, `*=`, `/=`, `%=`
    case arithmetic(JQBinaryOp)
    /// `//=`
    case alternative
}

/// A destructuring pattern: `$x`, `[$a, $b]`, `{a: $x, $y, (expr): [$z]}`. roadmap: S-5
indirect enum JQPattern: Sendable {
    case variable(String)
    case array([JQPattern])
    case object([JQObjectPatternEntry])

    var variables: [String] {
        switch self {
        case .variable(let name): return [name]
        case .array(let items): return items.flatMap(\.variables)
        case .object(let entries):
            return entries.flatMap { entry -> [String] in
                var names: [String] = []
                if case .variable(let name) = entry.key { names.append(name) }
                if let pattern = entry.pattern { names += pattern.variables }
                return names
            }
        }
    }
}

/// One entry of an object pattern. roadmap: S-5
struct JQObjectPatternEntry: Sendable {
    enum Key: Sendable {
        /// `$name` (binds `$name` to `.name`, then destructures it with `pattern` when there is one).
        case variable(String)
        case expression(JQNode)
    }

    var key: Key
    var pattern: JQPattern?
}

/// A function parameter: a filter, or a `$value`. roadmap: S-5
struct JQParam: Sendable {
    var name: String
    /// `$name`: the argument's outputs are bound as a variable (and `name` stays callable).
    var isValue: Bool
}

/// `def name(params): body;` roadmap: S-5
final class JQFuncDef: Sendable {
    let name: String
    let params: [JQParam]
    let body: JQNode
    /// Defined by Vitrine's built-in jq definitions rather than the user's program (not counted for `maxDepth`).
    let isBuiltin: Bool

    init(name: String, params: [JQParam], body: JQNode, isBuiltin: Bool) {
        self.name = name; self.params = params; self.body = body; self.isBuiltin = isBuiltin
    }
}

/// A call site; the resolver binds it once at compile time. roadmap: S-5
final class JQCall: @unchecked Sendable {
    enum Target {
        case unresolved
        /// A definition or closure parameter in lexical scope, found through the environment at run time.
        case local
        case builtinDef(JQFuncDef)
        case native(JQNative)
    }

    let name: String
    let args: [JQNode]
    let offset: Int
    var target: Target = .unresolved

    init(name: String, args: [JQNode], offset: Int) {
        self.name = name; self.args = args; self.offset = offset
    }

    var key: String { "\(name)/\(args.count)" }
}
