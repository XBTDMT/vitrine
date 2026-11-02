// VitrineDetect — the catalogue: built-ins ∪ overrides ∪ custom rules, compiled once (DETECTORS.md §1 principle 6).
import Foundation

/// A detector with its patterns compiled. Built by `Catalogue.resolved`.
public struct CompiledDetector: Sendable {
    public let detector: Detector
    /// One matcher per pattern, in `detector.patterns` order.
    public let matchers: [ICURegexMatcher]
}

/// An allow rule with its pattern compiled.
public struct CompiledAllowRule: Sendable {
    public let rule: AllowRule
    public let matcher: ICURegexMatcher
}

/// What the Scanner runs. Only enabled detectors and rules are included.
public struct CompiledCatalogue: Sendable {
    /// In scan order: catalogue order (ai, cloud, payments, scm, messaging, databases, tokens, config, personal, network, custom).
    public let detectors: [CompiledDetector]
    public let allowRules: [CompiledAllowRule]
    /// Per custom or allow rule UUID string → user-facing message. That rule is not in the catalogue. Never thrown.
    public let compileErrors: [String: String]
    /// Per built-in detector id whose edited patterns (an override) did not compile → user-facing message. The detector
    /// is still in the catalogue with its built-in patterns: a broken edit never removes a detector (fails closed).
    public let overrideErrors: [String: String]

    public init(detectors: [CompiledDetector], allowRules: [CompiledAllowRule], compileErrors: [String: String],
                overrideErrors: [String: String] = [:]) {
        self.detectors = detectors
        self.allowRules = allowRules
        self.compileErrors = compileErrors
        self.overrideErrors = overrideErrors
    }
}

public struct Catalogue: Sendable {
    /// The 84 built-in detectors of §4, in catalogue order.
    public static let builtIn: [Detector] = BuiltInCatalogue.all

    public static let idPattern = #"^[a-z]+\.[a-z0-9]+\.[a-z0-9]+$"#

    public init() {}

    /// Builds the compiled catalogue.
    /// - overrides: detector id → replacement patterns. An override that does not compile is reported in
    ///   `overrideErrors` and the detector runs with its built-in patterns instead (fail closed, never dropped).
    /// - state: detector id → enabled; absent ids use `enabledByDefault`.
    /// - rules: custom rules (black-out → detector, allow → allow rule).
    /// - allowRules: additional allow rules (e.g. from the "Never black out this" entry points).
    /// Throws only when a BUILT-IN pattern fails to compile (a programming error caught by tests).
    public static func resolved(
        with overrides: [String: [PatternSpec]] = [:],
        state: [String: Bool] = [:],
        rules: [CustomRule] = [],
        allowRules: [AllowRule] = []
    ) throws -> CompiledCatalogue {
        var compiledDetectors: [CompiledDetector] = []
        var errors: [String: String] = [:]
        var overrideErrors: [String: String] = [:]

        for detector in builtIn {
            let enabled = state[detector.id] ?? detector.enabledByDefault
            guard enabled else { continue }
            if let replacement = overrides[detector.id] {
                var edited = detector
                edited.patterns = replacement
                edited.source = .override
                do {
                    compiledDetectors.append(try compile(edited))
                    continue
                } catch let error as PatternError {
                    // The edit is unusable: the detector keeps running with its built-in patterns (below).
                    overrideErrors[detector.id] = error.userMessage
                }
            }
            compiledDetectors.append(try compile(detector))   // built-in: throws
        }

        var compiledAllow: [CompiledAllowRule] = []
        for rule in rules where rule.isEnabled {
            if let detector = rule.asDetector {
                do {
                    compiledDetectors.append(try compile(detector))
                } catch let error as PatternError {
                    errors[rule.id.uuidString] = error.userMessage
                }
            } else if let allow = rule.asAllowRule {
                do {
                    compiledAllow.append(try compileAllow(allow))
                } catch let error as PatternError {
                    errors[rule.id.uuidString] = error.userMessage
                }
            }
        }
        for allow in allowRules where allow.isEnabled {
            do {
                compiledAllow.append(try compileAllow(allow))
            } catch let error as PatternError {
                errors[allow.id.uuidString] = error.userMessage
            }
        }

        if !errors.isEmpty || !overrideErrors.isEmpty {
            Log.detect.error("catalogue compiled with \(Count(errors.count), privacy: .public) rule error(s), \(Count(overrideErrors.count), privacy: .public) override(s) on built-in patterns")
        }
        return CompiledCatalogue(detectors: compiledDetectors, allowRules: compiledAllow, compileErrors: errors, overrideErrors: overrideErrors)
    }

    static func compile(_ detector: Detector) throws -> CompiledDetector {
        let matchers = try detector.patterns.map { try ICURegexMatcher(pattern: try $0.compiledPattern()) }
        return CompiledDetector(detector: detector, matchers: matchers)
    }

    static func compileAllow(_ rule: AllowRule) throws -> CompiledAllowRule {
        CompiledAllowRule(rule: rule, matcher: try ICURegexMatcher(pattern: try rule.pattern.compiledPattern()))
    }
}
