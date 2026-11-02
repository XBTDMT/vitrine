import Foundation

/// What the top of the menu says: the state sentence (with its dot) and one needs-you banner per problem.
/// Built from the extension table Diagnostics reads from pluginkit. roadmap: S-10 (H-2)
struct MenuBarState: Equatable {
    enum Dot: Equatable { case ok, needs, unknown }
    enum Fix: Equatable { case turnOn, diagnostics }

    struct Problem: Equatable {
        var title: String
        var detail: String
        var fix: Fix
        var fixTitle: String {
            fix == .turnOn ? String(localized: "Turn On…", comment: "Menu bar banner: button that opens the Quick Look extension settings")
                           : String(localized: "Diagnostics…", comment: "Opens the Diagnostics window")
        }
    }

    var dot: Dot
    var headline: String
    var subline: String
    var problems: [Problem]

    /// `known` is false until pluginkit has answered once; until then every part reads "not registered", which is
    /// not news, so the sentence says it is checking instead of raising a banner.
    static func make(from statuses: [Diagnostics.ExtensionStatus], known: Bool) -> MenuBarState {
        guard known else {
            return MenuBarState(dot: .unknown, headline: "Vitrine",
                                subline: String(localized: "Checking its parts…", comment: "Menu bar: Vitrine is asking macOS about its extensions"), problems: [])
        }
        let off = statuses.filter { $0.state == .disabled }.map(\.name)
        let missing = statuses.filter { $0.state == .missing }.map(\.name)
        var problems: [Problem] = []
        if !off.isEmpty {
            let list = ListFormatter.localizedString(byJoining: off)
            problems.append(Problem(title: off.count == 1 ? String(localized: "The \(list) part is off", comment: "Menu bar banner; one extension's short name (Markdown)")
                                                          : String(localized: "The \(list) parts are off", comment: "Menu bar banner; extensions' short names, as a list"),
                                    detail: String(localized: "System Settings › Login Items & Extensions › Quick Look.",
                                                   comment: "Menu bar banner: where to turn an extension on; use the System Settings names of this language"),
                                    fix: .turnOn))
        }
        if !missing.isEmpty {
            let list = ListFormatter.localizedString(byJoining: missing)
            problems.append(Problem(title: missing.count == 1 ? String(localized: "The \(list) part is not registered", comment: "Menu bar banner; one extension's short name")
                                                              : String(localized: "The \(list) parts are not registered", comment: "Menu bar banner; extensions' short names, as a list"),
                                    detail: String(localized: "macOS has not registered it yet. Open Vitrine from the Applications folder.", comment: "Menu bar banner"),
                                    fix: .diagnostics))
        }
        if problems.isEmpty {
            let all = statuses.count
            return MenuBarState(dot: .ok, headline: String(localized: "Vitrine is ready", comment: "Menu bar: headline when every extension is on"),
                                subline: String(localized: "All \(all) parts on", comment: "Menu bar: every extension is on; how many"), problems: [])
        }
        let headline = problems.count == 1 ? String(localized: "One thing needs you", comment: "Menu bar: headline when one problem needs the person")
                                           : String(localized: "Two things need you", comment: "Menu bar: headline when two problems need the person")
        return MenuBarState(dot: .needs, headline: headline,
                            subline: problems.map(\.title).joined(separator: " · "), problems: problems)
    }
}
