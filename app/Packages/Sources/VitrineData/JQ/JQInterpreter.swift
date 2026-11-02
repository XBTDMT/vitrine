import Foundation

/// The value an expression is applied to, and in path mode (`path(f)`, assignments, `del`) where it sits in the
/// original input. roadmap: S-5
struct JQCursor {
    var value: JQValue
    /// nil when evaluating values; the path from the root when evaluating paths.
    var path: [JQValue]?

    var valueMode: JQCursor { JQCursor(value: value, path: nil) }
}

typealias JQEmit = (JQCursor) throws -> Void

/// A jq error value in flight (from `error(...)` or a type error); `try`/`catch` and `?` catch it. roadmap: S-5
struct JQThrown: Error {
    var value: JQValue

    init(_ value: JQValue) { self.value = value }
    init(_ message: String) { value = .string(message) }

    var message: String {
        if case .string(let s) = value { return s }
        return "\(JQJSONWriter.compact(value, budget: 1024) ?? JQJSONWriter.errorDump(value)) (not a string)"
    }
}

/// A limit stopped the run; never caught by `try`. roadmap: S-5
struct JQStop: Error {
    var reason: String
}

/// `break $label`, `limit`, `first`: unwinds to the frame holding the same token; never caught by `try`.
/// roadmap: S-5
struct JQBreak: Error {
    let token: Int
}

/// An error raised downstream of a `try` (or `//`) travels through it unchanged: jq 1.7's `try` only catches errors
/// raised by its own body. roadmap: S-5
struct JQPassthrough: Error {
    let token: Int
    let error: JQThrown
}

/// Variables, function definitions, closure parameters and labels in scope, as a linked list. roadmap: S-5
final class JQEnv: Sendable {
    enum Binding: Sendable {
        case value(JQValue)
        case function(JQFuncDef)
        case closure(JQNode, JQEnv)
        case label(Int)
    }

    static let variableArity = -1
    static let labelArity = -2
    static let root = JQEnv(parent: nil, name: "", arity: -3, binding: .value(.null))

    let parent: JQEnv?
    let name: String
    let arity: Int
    let binding: Binding

    init(parent: JQEnv?, name: String, arity: Int, binding: Binding) {
        self.parent = parent; self.name = name; self.arity = arity; self.binding = binding
    }

    func lookup(_ name: String, arity: Int) -> JQEnv? {
        var e: JQEnv? = self
        while let current = e {
            if current.arity == arity, current.name == name { return current }
            e = current.parent
        }
        return nil
    }
}

/// Evaluates a resolved program in continuation-passing style: each expression hands its outputs one by one to the
/// rest of the program, so generators, backtracking and `limit` cost no buffering. Every evaluation is counted
/// against the run's limits. roadmap: S-5
final class JQInterpreter {
    let limits: JQLimits
    /// A value nesting deeper than this stops the run (it also bounds the recursion of comparing and freeing values).
    let valueDepthLimit: Int
    let maxEvalDepth: Int
    private var steps = 0
    private var evalDepth = 0
    private var callDepth = 0
    private var nextToken = 0
    private let deadline: UInt64
    var regexCache: [String: NSRegularExpression] = [:]

    init(limits: JQLimits) {
        self.limits = limits
        valueDepthLimit = max(1, limits.maxDepth) + 64
        maxEvalDepth = max(1, limits.maxDepth) * 64
        let nanos = limits.timeLimit.components.seconds * 1_000_000_000 + limits.timeLimit.components.attoseconds / 1_000_000_000
        deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(clamping: max(0, nanos))
    }

    // MARK: Running

    func run(_ root: JQNode, input: JQValue) -> Result<JQRun, JQError> {
        var outputs: [JQValue] = []
        var bytes = 0
        do {
            try eval(root, JQCursor(value: input, path: nil), .root) { cursor in
                if outputs.count >= self.limits.maxOutputs {
                    throw JQStop(reason: "the output limit of \(self.limits.maxOutputs) results was reached")
                }
                bytes += JQSize.estimate(cursor.value, budget: self.limits.maxResultBytes - bytes + 1)
                if bytes > self.limits.maxResultBytes {
                    throw JQStop(reason: "the result size limit of \(self.limits.maxResultBytes) bytes was reached")
                }
                outputs.append(cursor.value)
            }
            return .success(JQRun(outputs: outputs, isComplete: true, stoppedReason: nil))
        } catch let stop as JQStop {
            return .success(JQRun(outputs: outputs, isComplete: false, stoppedReason: stop.reason))
        } catch let thrown as JQThrown {
            return .failure(JQError(.runtime, thrown.message))
        } catch let passthrough as JQPassthrough {
            return .failure(JQError(.runtime, passthrough.error.message))
        } catch is JQBreak {
            return .failure(JQError(.runtime, "break escaped its label"))
        } catch let error as JQError {
            return .failure(error)
        } catch {
            return .failure(JQError(.runtime, "\(error)"))
        }
    }

    // MARK: Accounting

    @inline(__always)
    func tick() throws {
        steps &+= 1
        if steps > limits.maxSteps { throw JQStop(reason: "the step limit of \(limits.maxSteps) steps was reached") }
        if steps & 1023 == 0 { try checkTime() }
    }

    func checkTime() throws {
        if DispatchTime.now().uptimeNanoseconds > deadline {
            throw JQStop(reason: "the time limit of \(limits.timeLimit) was reached")
        }
    }

    func newToken() -> Int {
        nextToken += 1
        return nextToken
    }

    /// Stops the run when `value` nests deeper than the value depth limit.
    func checkDepth(_ value: JQValue) throws {
        switch value {
        case .array, .object:
            if JQDepth.of(value) > valueDepthLimit {
                throw JQStop(reason: "a value nested deeper than the depth limit of \(valueDepthLimit) levels")
            }
        default: return
        }
    }

    func checkStringSize(_ bytes: Int) throws {
        if bytes > limits.maxResultBytes {
            throw JQStop(reason: "a string grew past the result size limit of \(limits.maxResultBytes) bytes")
        }
    }

    func checkArraySize(_ count: Int) throws {
        if count > limits.maxResultBytes / 8 {
            throw JQStop(reason: "an array grew past the result size limit of \(limits.maxResultBytes) bytes")
        }
    }

    /// A computed value as an output: fine when evaluating values, an error when evaluating paths.
    func result(_ value: JQValue, _ cursor: JQCursor) throws -> JQCursor {
        if cursor.path != nil {
            throw JQThrown("Invalid path expression with result \(JQJSONWriter.errorDump(value))")
        }
        return JQCursor(value: value, path: nil)
    }

    // MARK: Evaluation

    func eval(_ node: JQNode, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        try tick()
        evalDepth += 1
        defer { evalDepth -= 1 }
        if evalDepth > maxEvalDepth {
            throw JQStop(reason: "evaluation nested deeper than \(maxEvalDepth) levels")
        }
        switch node {
        case .identity:
            try out(cur)
        case .recurseAll:
            try recurse(nil, nil, cur, env, out)
        case .literal(let value):
            try out(try result(value, cur))
        case .index(let target, let key):
            try evalIndex(target, key, cur, env, out)
        case .slice(let target, let from, let to):
            try evalSlice(target, from, to, cur, env, out)
        case .iterate(let target):
            try eval(target, cur, env) { base in try self.iterate(base, optional: false, out) }
        case .tryCatch(let body, let handler):
            try evalTry(body, handler, cur, env, out)
        case .pipe(let a, let b):
            try eval(a, cur, env) { mid in try self.eval(b, mid, env, out) }
        case .comma(let a, let b):
            try eval(a, cur, env, out)
            try eval(b, cur, env, out)
        case .negate(let operand):
            try evalNegate(operand, cur, env, out)
        case .binary(let op, let lhs, let rhs):
            try evalBinary(op, lhs, rhs, cur, env, out)
        case .and(let lhs, let rhs):
            try evalLogic(isAnd: true, lhs, rhs, cur, env, out)
        case .or(let lhs, let rhs):
            try evalLogic(isAnd: false, lhs, rhs, cur, env, out)
        case .alternative(let lhs, let rhs):
            try evalAlternative(lhs, rhs, cur, env, out)
        case .assign(let op, let lhs, let rhs):
            try evalAssign(op, lhs, rhs, cur, env, out)
        case .ifElse(let condition, let then, let otherwise):
            try evalIf(condition, then, otherwise, cur, env, out)
        case .reduce(let source, let pattern, let initial, let update):
            try evalReduce(source, pattern, initial, update, cur, env, out)
        case .foreach(let source, let pattern, let initial, let update, let extract):
            try evalForeach(source, pattern, initial, update, extract, cur, env, out)
        case .bind(let source, let pattern, let body):
            try eval(source, cur.valueMode, env) { v in
                try self.bindPattern(pattern, v.value, env) { inner in try self.eval(body, cur, inner, out) }
            }
        case .funcDef(let def, let rest):
            let inner = JQEnv(parent: env, name: def.name, arity: def.params.count, binding: .function(def))
            try eval(rest, cur, inner, out)
        case .call(let call):
            try evalCall(call, cur, env, out)
        case .variable(let name, _):
            guard let binding = env.lookup(name, arity: JQEnv.variableArity), case .value(let value) = binding.binding else {
                throw JQThrown("$\(name) is not defined")
            }
            try out(try result(value, cur))
        case .array(let inner):
            try evalArray(inner, cur, env, out)
        case .object(let entries):
            try evalObject(entries, cur, env, out)
        case .string(let parts, let format):
            try evalString(parts, format, cur, env, out)
        case .format(let name):
            try out(try result(.string(try JQFormats.apply(name, cur.value, self)), cur))
        case .label(let name, let body):
            let token = newToken()
            let inner = JQEnv(parent: env, name: name, arity: JQEnv.labelArity, binding: .label(token))
            do {
                try eval(body, cur, inner, out)
            } catch let b as JQBreak where b.token == token {
                return
            }
        case .breakLabel(let name, _):
            guard let binding = env.lookup(name, arity: JQEnv.labelArity), case .label(let token) = binding.binding else {
                throw JQThrown("$*label-\(name) is not defined")
            }
            throw JQBreak(token: token)
        }
    }

    /// Every output of `node` in value mode, gathered before they are combined with anything else. Operands that are
    /// combined (binary operators, object entries, interpolations, `$`-arguments, conditions, index keys) are gathered
    /// this way: the outputs come in jq's order, and a generator left suspended no longer holds stack while its
    /// partner runs, so recursion through `+` costs stack linear in its depth.
    func collect(_ node: JQNode, _ cur: JQCursor, _ env: JQEnv) throws -> [JQValue] {
        if case .literal(let value) = node { return [value] }
        var values: [JQValue] = []
        try eval(node, cur.valueMode, env) { values.append($0.value) }
        return values
    }

    private func evalIndex(_ target: JQNode, _ key: JQNode, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        for k in try collect(key, cur, env) {
            try eval(target, cur, env) { base in
                let value = try JQOps.index(base.value, k)
                try out(JQCursor(value: value, path: base.path.map { $0 + [k] }))
            }
        }
    }

    private func evalSlice(_ target: JQNode, _ from: JQNode?, _ to: JQNode?, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        let starts = try from.map { try collect($0, cur, env) } ?? [.null]
        let ends = try to.map { try collect($0, cur, env) } ?? [.null]
        for start in starts {
            for end in ends {
                try eval(target, cur, env) { base in
                    let value = try JQOps.slice(base.value, start, end)
                    let key = JQValue.object(JQObject([("start", start), ("end", end)]))
                    try out(JQCursor(value: value, path: base.path.map { $0 + [key] }))
                }
            }
        }
    }

    /// `.[]`: each element (array) or value (object) with its path.
    func iterate(_ base: JQCursor, optional: Bool, _ out: JQEmit) throws {
        switch base.value {
        case .array(let items):
            for (i, item) in items.enumerated() {
                try tick()
                try out(JQCursor(value: item, path: base.path.map { $0 + [.number(Double(i))] }))
            }
        case .object(let object):
            let keys = object.storage.keys, values = object.storage.values
            for i in keys.indices {
                try tick()
                try out(JQCursor(value: values[i], path: base.path.map { $0 + [.string(keys[i])] }))
            }
        default:
            if optional { return }
            throw JQThrown("Cannot iterate over \(base.value.typeName) (\(JQJSONWriter.errorDump(base.value)))")
        }
    }

    private func evalTry(_ body: JQNode, _ handler: JQNode?, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        let token = newToken()
        do {
            try eval(body, cur, env) { v in
                do {
                    try out(v)
                } catch let thrown as JQThrown {
                    throw JQPassthrough(token: token, error: thrown)
                }
            }
        } catch let passthrough as JQPassthrough where passthrough.token == token {
            throw passthrough.error
        } catch let thrown as JQThrown {
            guard let handler else { return }
            try eval(handler, JQCursor(value: thrown.value, path: nil), env) { h in
                try out(try self.result(h.value, cur))
            }
        }
    }

    private func evalNegate(_ operand: JQNode, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        try eval(operand, cur.valueMode, env) { v in
            guard case .number(let d) = v.value else {
                throw JQThrown("\(v.value.typeName) (\(JQJSONWriter.errorDump(v.value))) cannot be negated")
            }
            try out(try self.result(.number(-d), cur))
        }
    }

    /// jq evaluates the right operand in the outer loop: `(1,2) + (10,20)` is 11, 12, 21, 22.
    private func evalBinary(_ op: JQBinaryOp, _ lhs: JQNode, _ rhs: JQNode, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        for r in try collect(rhs, cur, env) {
            if case .literal(let l) = lhs {
                try out(try result(try JQOps.binary(op, l, r, self), cur))
                continue
            }
            try eval(lhs, cur.valueMode, env) { l in
                try out(try self.result(try JQOps.binary(op, l.value, r, self), cur))
            }
        }
    }

    private func evalLogic(isAnd: Bool, _ lhs: JQNode, _ rhs: JQNode, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        for l in try collect(lhs, cur, env) {
            if isAnd, !l.isTruthy { try out(try result(.bool(false), cur)); continue }
            if !isAnd, l.isTruthy { try out(try result(.bool(true), cur)); continue }
            for r in try collect(rhs, cur, env) {
                try out(try result(.bool(r.isTruthy), cur))
            }
        }
    }

    /// `a // b`: a's truthy outputs (an error in `a` ends them quietly); `b`'s outputs when there were none.
    private func evalAlternative(_ lhs: JQNode, _ rhs: JQNode, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        var found = false
        let token = newToken()
        do {
            try eval(lhs, cur, env) { v in
                guard v.value.isTruthy else { return }
                found = true
                do {
                    try out(v)
                } catch let thrown as JQThrown {
                    throw JQPassthrough(token: token, error: thrown)
                }
            }
        } catch let passthrough as JQPassthrough where passthrough.token == token {
            throw passthrough.error
        } catch is JQThrown {
            // jq: errors in the left side count as "no value".
        }
        if !found { try eval(rhs, cur, env, out) }
    }

    private func evalIf(_ condition: JQNode, _ then: JQNode, _ otherwise: JQNode?, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        for c in try collect(condition, cur, env) {
            if c.isTruthy {
                try eval(then, cur, env, out)
            } else if let otherwise {
                try eval(otherwise, cur, env, out)
            } else {
                try out(cur)
            }
        }
    }

    private func evalReduce(_ source: JQNode, _ pattern: JQPattern, _ initial: JQNode, _ update: JQNode,
                            _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        try eval(initial, cur.valueMode, env) { start in
            var state: JQValue = start.value
            try self.eval(source, cur.valueMode, env) { item in
                try self.bindPattern(pattern, item.value, env) { inner in
                    var last: JQValue?
                    try self.eval(update, JQCursor(value: state, path: nil), inner) { u in last = u.value }
                    state = last ?? .null
                }
            }
            try out(try self.result(state, cur))
        }
    }

    private func evalForeach(_ source: JQNode, _ pattern: JQPattern, _ initial: JQNode, _ update: JQNode, _ extract: JQNode?,
                             _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        try eval(initial, cur.valueMode, env) { start in
            var state: JQValue = start.value
            try self.eval(source, cur.valueMode, env) { item in
                try self.bindPattern(pattern, item.value, env) { inner in
                    try self.eval(update, JQCursor(value: state, path: nil), inner) { u in
                        state = u.value
                        if let extract {
                            try self.eval(extract, JQCursor(value: u.value, path: nil), inner) { x in
                                try out(try self.result(x.value, cur))
                            }
                        } else {
                            try out(try self.result(u.value, cur))
                        }
                    }
                }
            }
        }
    }

    private func evalArray(_ inner: JQNode?, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        var items: [JQValue] = []
        var deepest = 0
        if let inner {
            try eval(inner, cur.valueMode, env) { v in
                items.append(v.value)
                switch v.value {
                case .array, .object: deepest = max(deepest, JQDepth.of(v.value))
                default: break
                }
            }
        }
        if deepest + 1 > valueDepthLimit {
            throw JQStop(reason: "a value nested deeper than the depth limit of \(valueDepthLimit) levels")
        }
        try out(try result(.array(items), cur))
    }

    /// The first entry varies slowest: `{a: (1,2), b: (3,4)}` gives a1b3, a1b4, a2b3, a2b4.
    private func evalObject(_ entries: [JQObjectEntry], _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        var choices: [[(String, JQValue)]] = []
        choices.reserveCapacity(entries.count)
        for entry in entries {
            var pairs: [(String, JQValue)] = []
            for k in try collect(entry.key, cur, env) {
                guard case .string(let key) = k else { throw JQThrown("Object keys must be strings") }
                for v in try collect(entry.value, cur, env) { pairs.append((key, v)) }
            }
            if pairs.isEmpty { return }
            choices.append(pairs)
        }
        try buildObject(choices, 0, JQObject(), cur, out)
    }

    private func buildObject(_ choices: [[(String, JQValue)]], _ i: Int, _ acc: JQObject, _ cur: JQCursor, _ out: JQEmit) throws {
        if i == choices.count {
            let value = JQValue.object(acc)
            try checkDepth(value)
            try out(try result(value, cur))
            return
        }
        for (key, value) in choices[i] {
            var object = acc
            object.set(key, value)
            try buildObject(choices, i + 1, object, cur, out)
        }
    }

    /// Interpolations vary right-to-left, as jq's string addition does.
    private func evalString(_ parts: [JQStringPart], _ format: String?, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        var texts: [[String]] = []
        texts.reserveCapacity(parts.count)
        for part in parts {
            switch part {
            case .literal(let text): texts.append([text])
            case .interpolation(let node):
                texts.append(try collect(node, cur, env).map { try JQFormats.apply(format ?? "text", $0, self) })
            }
        }
        try buildString(texts, texts.count - 1, "", cur, out)
    }

    private func buildString(_ texts: [[String]], _ i: Int, _ suffix: String, _ cur: JQCursor, _ out: JQEmit) throws {
        if i < 0 {
            try out(try result(.string(suffix), cur))
            return
        }
        for text in texts[i] {
            try checkStringSize(text.utf8.count + suffix.utf8.count)
            try buildString(texts, i - 1, text + suffix, cur, out)
        }
    }

    // MARK: Patterns

    func bindPattern(_ pattern: JQPattern, _ value: JQValue, _ env: JQEnv, _ body: (JQEnv) throws -> Void) throws {
        switch pattern {
        case .variable(let name):
            try body(JQEnv(parent: env, name: name, arity: JQEnv.variableArity, binding: .value(value)))
        case .array(let items):
            try bindArray(items, 0, value, env, body)
        case .object(let entries):
            try bindObject(entries, 0, value, env, body)
        }
    }

    private func bindArray(_ items: [JQPattern], _ i: Int, _ value: JQValue, _ env: JQEnv, _ body: (JQEnv) throws -> Void) throws {
        if i == items.count { try body(env); return }
        let element = try JQOps.index(value, .number(Double(i)))
        try bindPattern(items[i], element, env) { inner in try self.bindArray(items, i + 1, value, inner, body) }
    }

    private func bindObject(_ entries: [JQObjectPatternEntry], _ i: Int, _ value: JQValue, _ env: JQEnv,
                            _ body: (JQEnv) throws -> Void) throws {
        if i == entries.count { try body(env); return }
        let entry = entries[i]
        switch entry.key {
        case .variable(let name):
            let element = try JQOps.index(value, .string(name))
            let bound = JQEnv(parent: env, name: name, arity: JQEnv.variableArity, binding: .value(element))
            if let sub = entry.pattern {
                try bindPattern(sub, element, bound) { inner in try self.bindObject(entries, i + 1, value, inner, body) }
            } else {
                try bindObject(entries, i + 1, value, bound, body)
            }
        case .expression(let keyNode):
            try eval(keyNode, JQCursor(value: value, path: nil), env) { k in
                guard case .string = k.value else {
                    throw JQThrown("Cannot index \(value.typeName) with \(k.value.typeName)")
                }
                let element = try JQOps.index(value, k.value)
                try self.bindPattern(entry.pattern ?? .variable("_"), element, env) { inner in
                    try self.bindObject(entries, i + 1, value, inner, body)
                }
            }
        }
    }

    // MARK: Calls

    private func evalCall(_ call: JQCall, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        switch call.target {
        case .local:
            guard let found = env.lookup(call.name, arity: call.args.count) else {
                throw JQThrown("\(call.name)/\(call.args.count) is not defined")
            }
            switch found.binding {
            case .closure(let node, let closureEnv):
                try eval(node, cur, closureEnv, out)
            case .function(let def):
                if !def.isBuiltin {
                    callDepth += 1
                    if callDepth > limits.maxDepth {
                        callDepth -= 1
                        throw JQStop(reason: "the recursion depth limit of \(limits.maxDepth) calls was reached")
                    }
                }
                defer { if !def.isBuiltin { callDepth -= 1 } }
                try invoke(def, found, call.args, cur, env, out)
            default:
                throw JQThrown("\(call.name)/\(call.args.count) is not defined")
            }
        case .builtinDef(let def):
            try invoke(def, .root, call.args, cur, env, out)
        case .native(let native):
            try native.call(self, call.args, cur, env, out)
        case .unresolved:
            throw JQThrown("\(call.name)/\(call.args.count) is not defined")
        }
    }

    /// Binds the arguments as closures over the caller's environment (and `$params` as variables, one binding per
    /// output, the first parameter varying slowest) and runs the body.
    private func invoke(_ def: JQFuncDef, _ defEnv: JQEnv, _ args: [JQNode], _ cur: JQCursor, _ callerEnv: JQEnv, _ out: JQEmit) throws {
        // The definition itself is visible to its body through defEnv (local) or the resolver (built-in).
        var inner = defEnv
        for (param, arg) in zip(def.params, args) {
            inner = JQEnv(parent: inner, name: param.name, arity: 0, binding: .closure(arg, callerEnv))
        }
        try bindValueParams(def, 0, args, inner, cur, callerEnv, out)
    }

    private func bindValueParams(_ def: JQFuncDef, _ i: Int, _ args: [JQNode], _ env: JQEnv, _ cur: JQCursor,
                                 _ callerEnv: JQEnv, _ out: JQEmit) throws {
        if i == def.params.count {
            try eval(def.body, cur, env, out)
            return
        }
        guard def.params[i].isValue else {
            try bindValueParams(def, i + 1, args, env, cur, callerEnv, out)
            return
        }
        for v in try collect(args[i], cur, callerEnv) {
            let inner = JQEnv(parent: env, name: def.params[i].name, arity: JQEnv.variableArity, binding: .value(v))
            try bindValueParams(def, i + 1, args, inner, cur, callerEnv, out)
        }
    }

    /// The argument values of a native with `$`-parameters, the first varying slowest.
    func cartesian(_ args: [JQNode], _ cur: JQCursor, _ env: JQEnv, _ prefix: [JQValue], _ body: ([JQValue]) throws -> Void) throws {
        if args.isEmpty { try body([]); return }
        let choices = try args.map { try collect($0, cur, env) }
        try product(choices, 0, prefix, body)
    }

    private func product(_ choices: [[JQValue]], _ i: Int, _ prefix: [JQValue], _ body: ([JQValue]) throws -> Void) throws {
        if i == choices.count { try body(prefix); return }
        for v in choices[i] { try product(choices, i + 1, prefix + [v], body) }
    }

    // MARK: Recursion built-ins

    /// `..`/`recurse` (f nil: `.[]?`), `recurse(f)`, `recurse(f; cond)`, and `repeat(f)`, which jq 1.7 defines the
    /// same way. Pre-order, depth first, with an explicit stack, so depth costs heap. Each node's children are
    /// computed before the first of them is visited.
    func recurse(_ f: JQNode?, _ condition: JQNode?, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        var stack: [JQCursor] = [cur]
        while let node = stack.popLast() {
            try tick()
            try out(node)
            var children: [JQCursor] = []
            if let f {
                try eval(f, node, env) { children.append($0) }
            } else {
                try iterate(node, optional: true) { children.append($0) }
            }
            if let condition {
                var kept: [JQCursor] = []
                for child in children {
                    try eval(condition, child.valueMode, env) { c in if c.value.isTruthy { kept.append(child) } }
                }
                children = kept
            }
            stack.append(contentsOf: children.reversed())
        }
    }

    private enum LoopTask {
        case visit(JQCursor)
        case emit(JQCursor)
    }

    /// `while(cond; update)` (`isUntil` false) and `until(cond; update)`, iteratively.
    func loop(isUntil: Bool, _ condition: JQNode, _ update: JQNode, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        var stack: [LoopTask] = [.visit(cur)]
        while let task = stack.popLast() {
            try tick()
            switch task {
            case .emit(let c):
                try out(c)
            case .visit(let c):
                var tasks: [LoopTask] = []
                try eval(condition, c.valueMode, env) { test in
                    if isUntil {
                        if test.value.isTruthy {
                            tasks.append(.emit(c))
                        } else {
                            try self.eval(update, c, env) { tasks.append(.visit($0)) }
                        }
                    } else if test.value.isTruthy {
                        tasks.append(.emit(c))
                        try self.eval(update, c, env) { tasks.append(.visit($0)) }
                    }
                }
                stack.append(contentsOf: tasks.reversed())
            }
        }
    }

    // MARK: Assignment

    func collectPaths(_ node: JQNode, _ cur: JQCursor, _ env: JQEnv) throws -> [[JQValue]] {
        var paths: [[JQValue]] = []
        try eval(node, JQCursor(value: cur.value, path: []), env) { p in paths.append(p.path ?? []) }
        return paths
    }

    private func evalAssign(_ op: JQAssignOp, _ lhs: JQNode, _ rhs: JQNode, _ cur: JQCursor, _ env: JQEnv, _ out: JQEmit) throws {
        switch op {
        case .update:
            // jq 1.7: reduce path(lhs) as $p (.; setpath($p; getpath($p) | first(rhs)) or delpaths([$p]) when empty)
            let paths = try collectPaths(lhs, cur, env)
            var state = cur.value
            for path in paths {
                try tick()
                let old = try JQPaths.get(state, path)
                var first: JQValue?
                let token = newToken()
                do {
                    try eval(rhs, JQCursor(value: old, path: nil), env) { v in
                        first = v.value
                        throw JQBreak(token: token)
                    }
                } catch let b as JQBreak where b.token == token {}
                if let first {
                    state = try JQPaths.set(state, path, first, self)
                } else {
                    state = try JQPaths.delete(state, [path], self)
                }
            }
            try out(try result(state, cur))
        case .set, .arithmetic, .alternative:
            try eval(rhs, cur.valueMode, env) { r in
                let paths = try self.collectPaths(lhs, cur, env)
                var state = cur.value
                for path in paths {
                    try self.tick()
                    let updated: JQValue
                    switch op {
                    case .set:
                        updated = r.value
                    case .arithmetic(let binary):
                        updated = try JQOps.binary(binary, try JQPaths.get(state, path), r.value, self)
                    default:
                        let old = try JQPaths.get(state, path)
                        updated = old.isTruthy ? old : r.value
                    }
                    state = try JQPaths.set(state, path, updated, self)
                }
                try out(try self.result(state, cur))
            }
        }
    }
}
