import AppIntents

/// Vitrine's App Shortcuts (X-6): the five actions with the phrases Siri, Spotlight and the Shortcuts app offer
/// without the person building a shortcut first. On macOS 26 and later Spotlight lists them as actions too: every
/// intent runs in the background (`supportedModes`) and has a parameter summary, which is all Spotlight asks for.
/// roadmap: S-10
struct VitrineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DescribeFileIntent(),
                    phrases: ["Describe a file with \(.applicationName)",
                              "What is this file in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Describe File", comment: "App Shortcut tile: Describe File."),
                    systemImageName: "doc.text.magnifyingglass")
        AppShortcut(intent: ExtractTableIntent(),
                    phrases: ["Extract a table with \(.applicationName)",
                              "Get the rows of a table with \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Extract Table", comment: "App Shortcut tile: Extract Table."),
                    systemImageName: "tablecells")
        AppShortcut(intent: CountTokensIntent(),
                    phrases: ["Count tokens with \(.applicationName)",
                              "How many tokens in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Count Tokens", comment: "App Shortcut tile: Count Tokens."),
                    systemImageName: "number")
        AppShortcut(intent: CheckSignatureIntent(),
                    phrases: ["Check a signature with \(.applicationName)",
                              "Who signed this app in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Check Signature", comment: "App Shortcut tile: Check Signature."),
                    systemImageName: "checkmark.seal")
        AppShortcut(intent: ConvertIntent(),
                    phrases: ["Convert a file with \(.applicationName)",
                              "Make a picture of a file with \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Convert File", comment: "App Shortcut tile: Convert File."),
                    systemImageName: "arrow.triangle.2.circlepath")
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
