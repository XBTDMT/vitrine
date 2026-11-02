import XCTest
import VitrineEngineering
@testable import VitrinePreviewKit

/// The Settings window's model (S-10, parity H-1): every row writes a key its reader reads, with the reader's own
/// default, and a value the window writes is the value the preview sees. SettingsModel.swift is compiled into this
/// bundle on its own (project.yml). Private defaults suites only; the real settings are never touched.
/// roadmap: S-10
@MainActor
final class SettingsModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "vitrine.tests.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func row(_ key: String) throws -> SettingsRow {
        try XCTUnwrap(SettingsCatalog.rows.first { $0.key == key }, "no row writes \(key)")
    }

    private var context: RenderContext { RenderContext(appearance: .light, defaultsSuite: suiteName) }

    // MARK: Keys and their readers

    func testKeysAreTheReadersOwn() {
        XCTAssertEqual(SettingsKey.folderIconStyle, FolderContentIcons.styleKey)
        XCTAssertEqual(SettingsKey.folderIconList, FolderContentIcons.listKey)
        XCTAssertEqual(SettingsKey.codeImportedThemes, CodeThemeImport.key)
        XCTAssertEqual(SettingsKey.recordRecents, RecentPreviews.recordingKey)
        // PreviewHostController and MenuBarController spell these out; the app's tests cannot import the menu.
        XCTAssertEqual(SettingsKey.resumePosition, "general.resumePosition")
        XCTAssertEqual(SettingsKey.showMenuBarIcon, "general.showMenuBarIcon")
        for row in SettingsCatalog.rows {
            guard let key = row.key, key.hasPrefix("code.") else { continue }
            XCTAssertTrue(CodeOptions.keys.contains(String(key.dropFirst(5))), "\(key) is not a CodeOptions key")
        }
    }

    /// File Types (I-3): every row offers exactly the views its kind's preview names, in the renderer's order, and
    /// the metadata strip's keys are MetadataStrip's (I-13).
    func testFileTypesRowsAreTheRenderersViews() throws {
        let rows = SettingsCatalog.rows.filter { $0.key?.hasPrefix(OpensAs.keyPrefix) == true }
        XCTAssertEqual(Set(rows.compactMap(\.key)), Set(OpensAs.views.keys.map { OpensAs.keyPrefix + $0 }), "one row per kind with a choice")
        for row in rows {
            let group = String(row.key!.dropFirst(OpensAs.keyPrefix.count))
            guard case .menu(let options) = row.control else { XCTFail("\(row.id) is a menu"); continue }
            XCTAssertEqual(options.compactMap(\.value.string), OpensAs.views[group], "\(row.id) offers its preview's views")
            XCTAssertEqual(row.defaultValue?.string, OpensAs.views[group]?.first, "\(row.id) defaults to the first view")
        }
        XCTAssertEqual(try row(MetadataStrip.showKey).defaultValue?.string, MetadataStrip.Settings.standard.show.rawValue)
    }

    @MainActor
    func testAPreviewOpensOnTheChosenView() throws {
        let d = UserDefaults(suiteName: suiteName)!
        XCTAssertNil(OpensAs.preferredIndex(kind: .csv(delimiter: ","), titles: ["Table", "Text"], defaults: d), "first view by default")
        d.set("Text", forKey: OpensAs.keyPrefix + "csv")
        XCTAssertEqual(OpensAs.preferredIndex(kind: .csv(delimiter: ","), titles: ["Table", "Text"], defaults: d), 1)
        d.set("Schema", forKey: OpensAs.keyPrefix + "sqlite")
        XCTAssertNil(OpensAs.preferredIndex(kind: .sqlite, titles: ["Rows"], defaults: d), "a database with no schema view stays on its rows")
        XCTAssertEqual(OpensAs.group(for: .code(language: "json")), "structured")
        XCTAssertEqual(OpensAs.group(for: .code(language: "claude-code-session")), "session")
        XCTAssertNil(OpensAs.group(for: .archive(.zip)), "one view, no choice")
    }

    func testEveryKeyedRowHasADefaultAndUniqueKey() {
        let keyed = SettingsCatalog.rows.filter { $0.key != nil }
        XCTAssertEqual(Set(keyed.compactMap(\.key)).count, keyed.count, "two rows write one key")
        XCTAssertEqual(Set(SettingsCatalog.rows.map(\.id)).count, SettingsCatalog.rows.count, "two rows share an id")
        for row in keyed { XCTAssertNotNil(row.defaultValue, "\(row.id) has no default") }
        for row in SettingsCatalog.rows where row.key == nil { XCTAssertEqual(row.control, .custom, "\(row.id) writes nothing") }
        for pane in SettingsPane.allCases { XCTAssertFalse(SettingsCatalog.rows(in: pane).isEmpty, "\(pane) is empty") }
    }

    func testDefaultsMatchTheReaders() throws {
        let code = CodeOptions()
        let expected: [String: SettingsValue] = [
            SettingsKey.codeTheme: .string(code.theme), SettingsKey.codeFont: .string(code.font), SettingsKey.codeFontSize: .int(code.fontSize),
            SettingsKey.codeTabSize: .int(code.tabSize), SettingsKey.codeWrap: .bool(code.wrap), SettingsKey.codeLineNumbers: .bool(code.lineNumbers),
            SettingsKey.codeIndentGuides: .bool(code.indentGuides), SettingsKey.codeChangedLines: .bool(code.changedLines),
            SettingsKey.codeSticky: .bool(code.sticky), SettingsKey.codeMinimap: .bool(code.minimap),
        ]
        for (key, value) in expected { XCTAssertEqual(try row(key).defaultValue, value, key) }

        let md = MarkdownRenderer.options(context)
        XCTAssertEqual(try row(SettingsKey.markdownMath).defaultValue, .bool(md.math))
        XCTAssertEqual(try row(SettingsKey.markdownEmoji).defaultValue, .bool(md.emoji))
        XCTAssertEqual(try row(SettingsKey.markdownSmart).defaultValue, .bool(md.smartPunctuation))
        XCTAssertEqual(try row(SettingsKey.markdownHideFrontMatter).defaultValue, .bool(md.hideFrontMatter))
        XCTAssertEqual(try row(SettingsKey.markdownDiagramTheme).defaultValue, .string("theme"), "diagrams follow the page unless set")
        XCTAssertEqual(try row(SettingsKey.markdownTheme).defaultValue, .string(MarkdownRenderer.theme(context).id))
        XCTAssertEqual(try row(SettingsKey.markdownTextScale).defaultValue, .double(MarkdownTheme.textScale(nil)))
        XCTAssertEqual(try row(SettingsKey.folderIconStyle).defaultValue, .string(FolderContentIcons.style(defaults).rawValue))
        XCTAssertEqual(try row(SettingsKey.recordRecents).defaultValue,
                       .bool(RecentPreviews(directories: [], writeDirectory: nil, suite: suiteName).isRecording))
        // MarkdownRenderer.buildPage: `imageMaxWidth as? Int ?? 100`, `tocEnabled as? Bool ?? true`.
        XCTAssertEqual(try row(SettingsKey.markdownImageWidth).defaultValue, .int(100))
        XCTAssertEqual(try row(SettingsKey.markdownTOC).defaultValue, .bool(true))
    }

    // MARK: What the window writes is what the preview sees

    func testCodeRowsReachCodeOptions() throws {
        let store = SettingsStore(defaults: defaults)
        store.set(.string("nord"), for: try row(SettingsKey.codeTheme))
        store.set(.string("Menlo"), for: try row(SettingsKey.codeFont))
        store.set(.int(15), for: try row(SettingsKey.codeFontSize))
        store.set(.int(2), for: try row(SettingsKey.codeTabSize))
        store.set(.bool(true), for: try row(SettingsKey.codeWrap))
        store.set(.bool(false), for: try row(SettingsKey.codeLineNumbers))
        store.set(.bool(false), for: try row(SettingsKey.codeIndentGuides))
        store.set(.bool(false), for: try row(SettingsKey.codeChangedLines))
        store.set(.bool(false), for: try row(SettingsKey.codeSticky))
        store.set(.bool(true), for: try row(SettingsKey.codeMinimap))
        let seen = CodeOptions(defaults: defaults)
        XCTAssertEqual(seen.theme, "nord")
        XCTAssertEqual(seen.font, "Menlo")
        XCTAssertEqual(seen.fontSize, 15)
        XCTAssertEqual(seen.tabSize, 2)
        XCTAssertTrue(seen.wrap)
        XCTAssertFalse(seen.lineNumbers)
        XCTAssertFalse(seen.indentGuides)
        XCTAssertFalse(seen.changedLines)
        XCTAssertFalse(seen.sticky)
        XCTAssertTrue(seen.minimap)
    }

    func testMarkdownRowsReachTheRenderer() throws {
        let store = SettingsStore(defaults: defaults)
        store.set(.bool(false), for: try row(SettingsKey.markdownMath))
        store.set(.bool(false), for: try row(SettingsKey.markdownEmoji))
        store.set(.bool(true), for: try row(SettingsKey.markdownSmart))
        store.set(.bool(false), for: try row(SettingsKey.markdownHideFrontMatter))
        store.set(.string("paper"), for: try row(SettingsKey.markdownTheme))
        store.set(.double(1.2), for: try row(SettingsKey.markdownTextScale))
        store.set(.int(60), for: try row(SettingsKey.markdownImageWidth))
        store.set(.bool(false), for: try row(SettingsKey.markdownTOC))
        let o = MarkdownRenderer.options(context)
        XCTAssertFalse(o.math)
        XCTAssertFalse(o.emoji)
        XCTAssertTrue(o.smartPunctuation)
        XCTAssertFalse(o.hideFrontMatter)
        XCTAssertEqual(MarkdownRenderer.theme(context).id, "paper")
        let d = context.defaults
        XCTAssertEqual(MarkdownTheme.textScale(d.object(forKey: MarkdownRenderer.Keys.textScale) as? Double), 1.2)
        XCTAssertEqual(d.object(forKey: MarkdownRenderer.Keys.imageMaxWidth) as? Int, 60)
        XCTAssertEqual(d.object(forKey: MarkdownRenderer.Keys.toc) as? Bool, false)
    }

    func testFolderAndRecentsRowsReachTheirReaders() throws {
        let store = SettingsStore(defaults: defaults)
        store.set(.string("grid"), for: try row(SettingsKey.folderIconStyle))
        XCTAssertEqual(FolderContentIcons.style(defaults), .grid)
        store.set(.bool(false), for: try row(SettingsKey.recordRecents))
        XCTAssertFalse(RecentPreviews(directories: [], writeDirectory: nil, suite: suiteName).isRecording)
        store.set(.bool(false), for: try row(SettingsKey.resumePosition))
        XCTAssertEqual(defaults.object(forKey: "general.resumePosition") as? Bool, false)
    }

    /// Every choice a row offers is one its reader accepts (CodeOptions drops a tab width outside 2, 4, 8; the folder
    /// look must be a FolderThumbnail.Style).
    func testEveryChoiceIsAccepted() throws {
        for row in SettingsCatalog.rows {
            let options: [SettingsOption]
            switch row.control {
            case .segmented(let o), .menu(let o): options = o
            default: continue
            }
            XCTAssertTrue(options.contains { $0.value == row.defaultValue }, "\(row.id) does not offer its default")
            let store = SettingsStore(defaults: defaults)
            for option in options {
                store.set(option.value, for: row)
                XCTAssertEqual(store.value(row), option.value, row.id)
                switch row.key {
                case SettingsKey.codeTabSize: XCTAssertEqual(SettingsValue.int(CodeOptions(defaults: defaults).tabSize), option.value)
                case SettingsKey.codeFontSize: XCTAssertEqual(SettingsValue.int(CodeOptions(defaults: defaults).fontSize), option.value)
                case SettingsKey.folderIconStyle: XCTAssertEqual(SettingsValue.string(FolderContentIcons.style(defaults).rawValue), option.value)
                default: break
                }
            }
        }
    }

    // MARK: The store

    func testChangedAndReset() throws {
        let store = SettingsStore(defaults: defaults)
        let wrap = try row(SettingsKey.codeWrap)
        XCTAssertFalse(store.isChanged(wrap))
        store.set(.bool(false), for: wrap)
        XCTAssertFalse(store.isChanged(wrap), "the default stored is not a change")
        store.set(.bool(true), for: wrap)
        XCTAssertTrue(store.isChanged(wrap))
        XCTAssertEqual(store.changedRows.map(\.id), [wrap.id])
        store.reset(wrap)
        XCTAssertNil(defaults.object(forKey: SettingsKey.codeWrap), "Reset removes the key so the reader's default applies")
        XCTAssertTrue(store.changedRows.isEmpty)
    }

    func testAForeignValueReadsAsTheDefault() throws {
        let store = SettingsStore(defaults: defaults)
        defaults.set("yes", forKey: SettingsKey.codeWrap)
        defaults.set(12.5, forKey: SettingsKey.codeTabSize)
        defaults.set(true, forKey: SettingsKey.codeFontSize)
        XCTAssertEqual(store.value(try row(SettingsKey.codeWrap)), .bool(false))
        XCTAssertEqual(store.value(try row(SettingsKey.codeTabSize)), .int(4))
        XCTAssertEqual(store.value(try row(SettingsKey.codeFontSize)), .int(12))
        XCTAssertFalse(store.isChanged(try row(SettingsKey.codeWrap)))
    }

    func testSearch() {
        XCTAssertTrue(SettingsCatalog.search("line num").map(\.id).contains(SettingsKey.codeLineNumbers))
        XCTAssertTrue(SettingsCatalog.search("EMOJI").map(\.id).contains(SettingsKey.markdownEmoji))
        XCTAssertTrue(SettingsCatalog.search("menu bar").map(\.id).contains(SettingsKey.showMenuBarIcon))
        XCTAssertTrue(SettingsCatalog.search("   ").isEmpty)
        XCTAssertTrue(SettingsCatalog.search("zzzz").isEmpty)
    }

    // MARK: Lists kept in step with the code view

    /// The theme menu lists the code page's own choices, in its order (web-src/code/appearance.js).
    func testCodeThemesMatchTheCodePage() throws {
        let js = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web-src/code/appearance.js")
        let source = try String(contentsOf: js, encoding: .utf8)
        func ids(_ list: String) throws -> [String] {
            let start = try XCTUnwrap(source.range(of: "export const \(list) = ["))
            let end = try XCTUnwrap(source.range(of: "];", range: start.upperBound..<source.endIndex))
            let body = String(source[start.upperBound..<end.lowerBound])
            let regex = try NSRegularExpression(pattern: #"id: '([^']+)', name: '([^']+)'"#)
            return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).map {
                String(body[Range($0.range(at: 1), in: body)!]) + "|" + String(body[Range($0.range(at: 2), in: body)!])
            }
        }
        XCTAssertEqual(SettingsCatalog.codeThemes.map { "\($0.id)|\($0.name)" }, try ids("BUILT_IN"))
        XCTAssertEqual(SettingsCatalog.moreCodeThemes.map { "\($0.id)|\($0.name)" }, try ids("MORE"))
    }

    func testCodeFontsMatchTheCodeView() {
        XCTAssertEqual(SettingsCatalog.installedCodeFonts(), CodeOptions.installedFonts())
        XCTAssertEqual(SettingsCatalog.installedCodeFonts(families: ["Menlo", "Comic Sans MS"]), ["SF Mono", "Menlo"])
    }

    func testImportedThemesAreListedByName() throws {
        let theme = CodeThemeImport.Imported(id: "imported-1", name: "Harbour Night", theme: Data("{}".utf8))
        CodeThemeImport.store([theme], in: defaults)
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.importedCodeThemes.map(\.name), ["Harbour Night"])
        XCTAssertEqual(store.codeThemeName("imported-1"), "Harbour Night")
        XCTAssertEqual(store.codeThemeName("no-such-theme"), "Vitrine (auto)")
    }

    /// G-26: Settings › Privacy offers exactly the ecosystems AdvisoryStore reads, under its keys, all off by default.
    func testVulnerabilityHintKeysMatchTheStore() {
        let rows = SettingsCatalog.rows(in: .privacy)
        XCTAssertEqual(rows.first { $0.id == AdvisoryStore.enabledKey }?.defaultValue, .bool(false))
        XCTAssertEqual(rows.first { $0.id == AdvisoryStore.weeklyKey }?.defaultValue, .bool(false))
        let ecosystems = rows.compactMap { $0.key }.filter { $0.hasPrefix("advisories.eco.") }
        XCTAssertEqual(ecosystems, AdvisoryStore.offered.map(AdvisoryStore.ecosystemKey))
        XCTAssertTrue(rows.filter { ecosystems.contains($0.key ?? "") }.allSatisfy { $0.defaultValue == .bool(false) })
    }

}
