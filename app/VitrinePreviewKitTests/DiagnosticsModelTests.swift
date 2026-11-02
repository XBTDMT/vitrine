import XCTest

// The Diagnostics window's model (S-10; parity B-8 and H-4), fed recorded and invented tool output. No test runs
// pluginkit, qlmanage, lsregister or git, and none changes registration state: DiagnosticsModel.swift is compiled
// into this bundle on its own (project.yml), without the probe or the repair actions.

final class DiagnosticsModelTests: XCTestCase {

    // MARK: pluginkit

    /// The shape of `pluginkit -m -A -D -v -p com.apple.quicklook.preview` on macOS 27.2 (paths invented).
    static let pluginkitAll = """
         com.apple.Safari.SafariQuickLookPreview(27.2)\t17EB4BB9-D732-5BAF-B8DF-CE13029D4849\t2026-10-28 18:20:05 +0000\t/System/Applications/Safari.app/Contents/PlugIns/SafariQuickLookPreview.appex
    +    io.github.xbtdmt.vitrine.quicklook.code(0.1.0)\t71B87D79-E1BA-4514-85D2-139A35EE18CD\t2026-10-30 23:06:22 +0000\t/Applications/Vitrine.app/Contents/PlugIns/VitrineCode.appex
    +    io.github.xbtdmt.vitrine.quicklook.code(0.1.0)\t2DCAA192-AA49-4042-9B9C-9C4FE9FF7F0D\t2026-10-30 00:47:40 +0000\t/Users/sample/Downloads/Vitrine.app/Contents/PlugIns/VitrineCode.appex
    +    io.github.xbtdmt.vitrine.quicklook.markdown(0.1.0)\tC6122A2C-6D04-4AE9-BBAF-98CDEC0FC611\t2026-10-30 00:47:40 +0000\t/Users/sample/Downloads/Vitrine.app/Contents/PlugIns/VitrineMarkdown.appex
    -    io.github.xbtdmt.vitrine.quicklook.data(0.1.0)\t59AE426D-31B8-4BD1-8F17-7A14C8685AC2\t2026-10-30 23:06:22 +0000\t/Applications/Vitrine.app/Contents/PlugIns/VitrineData.appex
    =    com.xbtdmt.spacebar.quicklook.code(0.1.0)\tA336CD98-82EC-4ADD-9F1A-62781ED2B0EF\t2026-10-29 03:40:56 +0000\t/Users/sample/Builds/Spacebar.app/Contents/PlugIns/SpacebarCode.appex
    +    com.example.inkwell.quicklook(3.2)\t11111111-2222-3333-4444-555555555555\t2026-10-26 09:00:00 +0000\t/Applications/Inkwell Markdown.app/Contents/PlugIns/Inkwell Quick Look.appex
     (7 plug-ins)
    """

    func testPluginKitLinesParse() {
        let records = PluginKitParser.records(from: Self.pluginkitAll)
        XCTAssertEqual(records.count, 7, "the summary line is not a record")
        XCTAssertEqual(records[0].election, .none)
        XCTAssertEqual(records[0].identifier, "com.apple.Safari.SafariQuickLookPreview")
        XCTAssertEqual(records[0].version, "27.2")
        XCTAssertEqual(records[1].election, .use)
        XCTAssertEqual(records[1].uuid, "71B87D79-E1BA-4514-85D2-139A35EE18CD")
        XCTAssertEqual(records[1].timestamp, "2026-10-30 23:06:22 +0000")
        XCTAssertEqual(records[1].parentAppPath, "/Applications/Vitrine.app")
        XCTAssertEqual(records[4].election, .ignore)
        XCTAssertFalse(records[4].isEligible)
        XCTAssertEqual(records[5].election, .superseded)
        XCTAssertFalse(records[5].isEligible)
        XCTAssertEqual(records[6].path, "/Applications/Inkwell Markdown.app/Contents/PlugIns/Inkwell Quick Look.appex", "spaces in paths survive")
        XCTAssertEqual(records[6].parentAppPath, "/Applications/Inkwell Markdown.app")
    }

    func testPluginKitLineWithoutVerboseFields() {
        let r = PluginKitParser.record(from: "+    io.github.xbtdmt.vitrine.quicklook.folders(0.1.0)")
        XCTAssertEqual(r?.identifier, "io.github.xbtdmt.vitrine.quicklook.folders")
        XCTAssertNil(r?.path)
        XCTAssertNil(r?.parentAppPath)
        XCTAssertNil(PluginKitParser.record(from: " (22 plug-ins)"))
        XCTAssertNil(PluginKitParser.record(from: ""))
        XCTAssertEqual(PluginKitParser.record(from: "!    com.example.debug(1)")?.election, .debug)
        XCTAssertEqual(PluginKitParser.record(from: "?    com.example.unknown(1)")?.election, .unknown)
    }

    func testMakerOfAnExtension() {
        XCTAssertEqual(InstalledExtension.maker(of: "io.github.xbtdmt.vitrine.quicklook.code", path: nil), .vitrine)
        XCTAssertEqual(InstalledExtension.maker(of: "com.xbtdmt.spacebar.quicklook.code", path: nil), .vitrine, "the working name's copies are Vitrine's")
        XCTAssertEqual(InstalledExtension.maker(of: "com.apple.Notes.QuickLookExtension", path: nil), .apple)
        XCTAssertEqual(InstalledExtension.maker(of: "org.example.thing", path: "/System/Library/Thing.appex"), .apple)
        XCTAssertEqual(InstalledExtension.maker(of: "com.example.inkwell.quicklook", path: "/Applications/Inkwell.app/x.appex"), .other)
    }

    func testClaimsFromInfoPlist() {
        let info: [String: Any] = ["NSExtension": ["NSExtensionAttributes": ["QLSupportedContentTypes": ["public.yaml", "public.json"]]]]
        XCTAssertEqual(InstalledExtension.claims(fromInfo: info), ["public.yaml", "public.json"])
        XCTAssertEqual(InstalledExtension.claims(fromInfo: [:]), [])
    }

    // MARK: qlmanage

    func testGeneratorListParses() {
        let output = """
        server: living for 0s (0 requests handled) - instant off: yes - arch: ARM64 - user id: 501
        memory used: 0 MB (680352 bytes) - used descriptors: 19/256
        plugins:
          public.comma-separated-values-text -> /System/Library/QuickLook/Office.qlgenerator (48)
          public.json -> /System/Library/QuickLook/Text.qlgenerator (1114.1.11)
          public.svg-image -> /System/Library/QuickLook/Web.qlgenerator (1114.1.11)
        """
        let map = QuickLookParser.generators(from: output)
        XCTAssertEqual(map.count, 3)
        XCTAssertEqual(map["public.json"], "/System/Library/QuickLook/Text.qlgenerator")
        XCTAssertEqual(OwnerResolver.generatorName(map["public.comma-separated-values-text"]!), "Office")
    }

    func testProbeOutputParses() {
        // What qlmanage -p -o printed on macOS 27.2 for invented files, with the exception it raises on some.
        let output = """
        2026-10-30 16:18:00.485 qlmanage[89773:13533171] Processing Preview.html
        Testing Quick Look preview with files:
        \t/private/var/folders/xx/T/vitrine-diagnostics-1/samples/t3.csv
        \t/private/var/folders/xx/T/vitrine-diagnostics-1/samples/t4.md
        * /var/folders/xx/T/vitrine-diagnostics-1/samples/t4.md did not produce any preview
        * /var/folders/xx/T/vitrine-diagnostics-1/samples/t3.csv produced a preview with data of type public.html
        * /var/folders/xx/T/vitrine-diagnostics-1/samples/t9.ts produced a preview with a URL of type public.mpeg-2-transport-stream
        *** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil'
        """
        let lines = QuickLookParser.probeLines(from: output)
        XCTAssertEqual(lines.count, 3, "the exception line is not an answer")
        XCTAssertEqual(lines["t4.md"], .nothing)
        XCTAssertEqual(lines["t3.csv"], .produced(kind: "public.html"))
        XCTAssertEqual(lines["t9.ts"], .produced(kind: "public.mpeg-2-transport-stream"))
    }

    // MARK: Who answers Space

    /// A small conformance table standing in for UTType.
    static let parents: [String: [String]] = [
        "net.daringfireball.markdown": ["public.plain-text", "public.text"],
        "public.yaml": ["public.plain-text", "public.text"],
        "public.json": ["public.text"],
        "public.swift-source": ["public.source-code", "public.plain-text", "public.text"],
        "public.comma-separated-values-text": ["public.plain-text", "public.text"],
        "io.github.xbtdmt.vitrine.csv": ["public.comma-separated-values-text", "public.plain-text", "public.text"],
        "com.microsoft.typescript": ["public.source-code", "public.plain-text", "public.text"],
        "public.mpeg-2-transport-stream": ["public.movie", "public.audiovisual-content"],
        "org.7-zip.7-zip-archive": ["public.archive", "public.data"],
        "com.apple.binary-property-list": ["com.apple.property-list", "public.data"],
    ]
    static let conforms: @Sendable (String, String) -> Bool = { a, b in a == b || (parents[a] ?? []).contains(b) }
    static let describe: @Sendable (String) -> String? = { ["public.mpeg-2-transport-stream": "MPEG-2 Transport Stream",
                                                            "org.khronos.glsl.fragment-shader": "OpenGL fragment shader source"][$0] }

    static func ext(_ id: String, _ election: PluginRecord.Election = .use, app: String = "Vitrine", version: String = "0.1.0",
                    claims: [String]) -> InstalledExtension {
        let path = id.hasPrefix("io.github") ? "/Applications/Vitrine.app/Contents/PlugIns/X.appex" : "/Applications/\(app).app/Contents/PlugIns/X.appex"
        return InstalledExtension(record: PluginRecord(election: election, identifier: id, version: version, uuid: nil, timestamp: nil, path: path),
                                  displayName: id.hasPrefix("io.github") ? "Vitrine Code" : "\(app) Quick Look",
                                  appName: app, appVersion: version, claims: claims)
    }

    static let vitrineCode = ext("io.github.xbtdmt.vitrine.quicklook.code",
                                 claims: ["public.yaml", "public.json", "public.swift-source", "com.microsoft.typescript", "com.apple.binary-property-list"])
    static let vitrineMarkdown = ext("io.github.xbtdmt.vitrine.quicklook.markdown", claims: ["net.daringfireball.markdown"])
    static let vitrineData = ext("io.github.xbtdmt.vitrine.quicklook.data",
                                 claims: ["public.comma-separated-values-text", "io.github.xbtdmt.vitrine.csv", "org.7-zip.7-zip-archive"])
    static let generators = ["public.comma-separated-values-text": "/System/Library/QuickLook/Office.qlgenerator",
                             "public.plain-text": "/System/Library/QuickLook/Text.qlgenerator",
                             "com.apple.property-list": "/System/Library/QuickLook/Text.qlgenerator",
                             "public.movie": "/System/Library/QuickLook/Movie.qlgenerator"]

    func resolver(_ extensions: [InstalledExtension], generators: [String: String] = DiagnosticsModelTests.generators) -> OwnerResolver {
        OwnerResolver(extensions: extensions, generators: generators, conforms: Self.conforms, describe: Self.describe,
                      vitrineClaims: Set(extensions.filter { $0.maker == .vitrine }.flatMap(\.claims)))
    }

    func claim(_ uti: String, _ ext: String = "io.github.xbtdmt.vitrine.quicklook.code") -> ClaimedType {
        ClaimedType(uti: uti, extensionID: ext, family: "Code")
    }

    func probe(_ uti: String, ext: String?, resolved: String? = nil, wellFormed: Bool = true,
               _ answer: QuickLookParser.ProbeLine?, skipped: String? = nil) -> TypeProbe {
        TypeProbe(uti: uti, sampleExtension: ext, resolvedType: resolved ?? uti, wellFormed: wellFormed, answer: answer, skippedBecause: skipped)
    }

    func testNothingDrawnAndOnlyVitrineClaimsIsVitrine() {
        let r = resolver([Self.vitrineCode])
        XCTAssertEqual(r.owner(of: claim("public.yaml"), probe: probe("public.yaml", ext: "yaml", .nothing)),
                       .vitrine(extensionID: "io.github.xbtdmt.vitrine.quicklook.code"))
    }

    func testAnotherAppThatClaimsTheTypeIsAConflict() {
        let other = Self.ext("com.example.syntaxpeek.preview", app: "SyntaxPeek", version: "2.0", claims: ["public.yaml"])
        let owner = resolver([Self.vitrineCode, other]).owner(of: claim("public.yaml"), probe: probe("public.yaml", ext: "yaml", .nothing))
        XCTAssertEqual(owner, .otherApp(extensionID: "com.example.syntaxpeek.preview", extensionName: "SyntaxPeek Quick Look",
                                        appName: "SyntaxPeek", appVersion: "2.0"))
    }

    func testAnotherAppClaimingASupertypeIsAConflictButABroadClaimIsNot() {
        let specific = Self.ext("com.example.code", app: "Coder", claims: ["public.source-code"])
        XCTAssertEqual(resolver([Self.vitrineCode, specific]).owner(of: claim("public.swift-source"), probe: probe("public.swift-source", ext: "swift", .nothing)).category,
                       .otherApp)
        let broad = Self.ext("com.example.text", app: "Texty", claims: ["public.plain-text", "public.data"])
        XCTAssertEqual(resolver([Self.vitrineCode, broad]).owner(of: claim("public.swift-source"), probe: probe("public.swift-source", ext: "swift", .nothing)).category,
                       .vitrine, "a claim on public.plain-text says nothing about Swift")
    }

    func testAnIgnoredOtherAppNoLongerCounts() {
        let other = Self.ext("com.example.syntaxpeek.preview", .ignore, app: "SyntaxPeek", claims: ["public.yaml"])
        XCTAssertEqual(resolver([Self.vitrineCode, other]).owner(of: claim("public.yaml"), probe: probe("public.yaml", ext: "yaml", .nothing)).category, .vitrine)
    }

    func testMacOSDrawingItIsKeptByMacOS() {
        let owner = resolver([Self.vitrineData]).owner(of: claim("public.comma-separated-values-text", "io.github.xbtdmt.vitrine.quicklook.data"),
                                                       probe: probe("public.comma-separated-values-text", ext: "csv", .produced(kind: "public.html")))
        XCTAssertEqual(owner, .macOS(reason: "previews spreadsheets and documents itself"), "named by the generator, not by the HTML it drew")
    }

    func testAMirrorTypeIsNotAReservation() {
        // Vitrine's own CSV type and Apple's share .csv; macOS types the test file as Apple's.
        let owner = resolver([Self.vitrineData]).owner(of: claim("io.github.xbtdmt.vitrine.csv", "io.github.xbtdmt.vitrine.quicklook.data"),
                                                       probe: probe("io.github.xbtdmt.vitrine.csv", ext: "csv", resolved: "public.comma-separated-values-text",
                                                                    .produced(kind: "public.html")))
        XCTAssertEqual(owner, .macOS(reason: "previews spreadsheets and documents itself"))
    }

    func testAnExtensionMacOSReservesSaysSo() {
        let owner = resolver([Self.vitrineCode]).owner(of: claim("com.microsoft.typescript"),
                                                       probe: probe("com.microsoft.typescript", ext: "ts", resolved: "public.mpeg-2-transport-stream",
                                                                    .produced(kind: "public.mpeg-2-transport-stream")))
        XCTAssertEqual(owner, .macOS(reason: "reserves .ts for MPEG-2 transport stream"))
    }

    func testReasonWithoutTheGeneratorListFallsBackToTheType() {
        let owner = resolver([Self.vitrineData], generators: [:]).owner(of: claim("public.comma-separated-values-text", "io.github.xbtdmt.vitrine.quicklook.data"),
                                                                        probe: probe("public.comma-separated-values-text", ext: "csv", .produced(kind: "public.html")))
        XCTAssertEqual(owner, .macOS(reason: "previews spreadsheets and documents itself"))
    }

    func testAPlaceholderFileIsTrustedOnlyWhereMacOSHasNoPreviewerOfItsOwn() {
        let r = resolver([Self.vitrineCode, Self.vitrineData])
        // A binary property list covered by Text.qlgenerator through com.apple.property-list: unknown.
        XCTAssertEqual(r.owner(of: claim("com.apple.binary-property-list"),
                               probe: probe("com.apple.binary-property-list", ext: "plist", wellFormed: false, .nothing)).category, .notAsked)
        // A 7-Zip placeholder: macOS has nothing for archives, so the extension answers.
        XCTAssertEqual(r.owner(of: claim("org.7-zip.7-zip-archive", "io.github.xbtdmt.vitrine.quicklook.data"),
                               probe: probe("org.7-zip.7-zip-archive", ext: "7z", wellFormed: false, .nothing)).category, .vitrine)
    }

    func testNoClaimantLeavesMacOSFallback() {
        let off = Self.ext("io.github.xbtdmt.vitrine.quicklook.markdown", .ignore, claims: ["net.daringfireball.markdown"])
        let owner = resolver([off]).owner(of: claim("net.daringfireball.markdown", "io.github.xbtdmt.vitrine.quicklook.markdown"),
                                          probe: probe("net.daringfireball.markdown", ext: "md", .nothing))
        XCTAssertEqual(owner, .fallback(extensionID: "io.github.xbtdmt.vitrine.quicklook.markdown"))
    }

    func testNoAnswerIsNotAskedAndSaysWhatMacOSReadsTheFileAs() {
        let r = resolver([Self.vitrineCode])
        XCTAssertEqual(r.owner(of: claim("public.yaml"), probe: nil), .notAsked(reason: "The check has not run yet."))
        let skipped = r.owner(of: claim("io.github.xbtdmt.vitrine.skill"),
                              probe: TypeProbe(uti: "io.github.xbtdmt.vitrine.skill", sampleExtension: nil, resolvedType: nil, wellFormed: false,
                                               answer: nil, skippedBecause: "No filename extension gives a file this type."))
        XCTAssertEqual(skipped, .notAsked(reason: "No filename extension gives a file this type."))
        let stopped = r.owner(of: claim("com.microsoft.fsharp-source"),
                              probe: probe("com.microsoft.fsharp-source", ext: "fs", resolved: "org.khronos.glsl.fragment-shader", nil,
                                           skipped: "Quick Look stopped on the test file without an answer (qlmanage exit 6)."))
        XCTAssertEqual(stopped, .notAsked(reason: "Quick Look stopped on the test file without an answer (qlmanage exit 6). macOS reads .fs files as OpenGL fragment shader source."))
    }

    func testSentenceCaseKeepsAcronyms() {
        XCTAssertEqual(OwnerResolver.sentenceCase("MPEG-2 Transport Stream"), "MPEG-2 transport stream")
        XCTAssertEqual(OwnerResolver.sentenceCase("OpenGL fragment shader source"), "OpenGL fragment shader source")
    }

    // MARK: Kinds and rows

    func testEveryTypeInTheUTITableHasAKind() throws {
        // app/VitrinePreviewKitTests/ → app/Config/uti-table.json
        let table = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Config/uti-table.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: table)) as? [String: Any])
        let prefix = try XCTUnwrap(json["prefix"] as? String)
        let families = try XCTUnwrap(json["extensions"] as? [String: [String]])
        let named = Set(DiagnosticKind.catalogue.flatMap(\.types))
        var missing: [String] = []
        for (_, types) in families {
            for t in types {
                let uti = t.hasPrefix("$") ? "\(prefix).\(t.dropFirst())" : t
                if !named.contains(uti) { missing.append(uti) }
            }
        }
        XCTAssertEqual(missing, [], "add these to DiagnosticKind.catalogue so they show under a named kind")
        XCTAssertEqual(named.count, DiagnosticKind.catalogue.flatMap(\.types).count, "a type sits in one kind only")
    }

    func testUnnamedTypesGatherUnderTheirFamily() {
        let kinds = DiagnosticKind.kinds(for: [ClaimedType(uti: "public.yaml", extensionID: "x", family: "Code"),
                                         ClaimedType(uti: "org.example.new", extensionID: "x", family: "Code")])
        XCTAssertEqual(kinds.map(\.name), ["YAML", "Other Code types"])
        XCTAssertEqual(kinds.last?.types, ["org.example.new"])
    }

    func testRowsFoldNotAskedTypesIntoTheKind() {
        let claimed = ["public.swift-source", "com.microsoft.fsharp-source", "com.microsoft.typescript", "io.github.xbtdmt.vitrine.skill"]
            .map { ClaimedType(uti: $0, extensionID: "io.github.xbtdmt.vitrine.quicklook.code", family: "Code") }
        let owners: [String: TypeOwner] = [
            "public.swift-source": .vitrine(extensionID: "io.github.xbtdmt.vitrine.quicklook.code"),
            "com.microsoft.fsharp-source": .notAsked(reason: "stopped"),
            "com.microsoft.typescript": .macOS(reason: "reserves .ts for MPEG-2 transport stream"),
            "io.github.xbtdmt.vitrine.skill": .notAsked(reason: "no extension"),
        ]
        let summary = FileTypesSummary.make(claimed: claimed, owners: owners, extensionsOf: { ["public.swift-source": ["swift"], "com.microsoft.fsharp-source": ["fs"]][$0] ?? [] })
        XCTAssertEqual(summary.kindCount, 3)
        XCTAssertEqual(summary.typeCount, 4)
        XCTAssertEqual(summary.rows.count, 3, "one row per kind: the F# type folds into Source code")
        let code = summary.rows.first { $0.kind.id == "code" }!
        XCTAssertEqual(code.owner.category, .vitrine)
        XCTAssertEqual(code.types, ["public.swift-source"])
        XCTAssertEqual(code.unasked.map(\.uti), ["com.microsoft.fsharp-source"])
        XCTAssertEqual(code.subtitle, ".swift · 1 not asked")
        let skills = summary.rows.first { $0.kind.id == "skills" }!
        XCTAssertEqual(skills.owner.category, .notAsked)
        XCTAssertEqual(skills.subtitle, "Folders with a SKILL.md", "a Not asked row does not repeat itself")
        XCTAssertEqual(summary.count(.vitrine), 1)
        XCTAssertEqual(summary.count(.macOS), 1)
        XCTAssertEqual(summary.count(.notAsked), 1)
        XCTAssertEqual(summary.possible, 1)
    }

    func testKindsWithTwoOtherAppsGetTwoRows() {
        let claimed = ["net.daringfireball.markdown", "org.textbundle.package"].map { ClaimedType(uti: $0, extensionID: "m", family: "Markdown") }
        let owners: [String: TypeOwner] = [
            "net.daringfireball.markdown": .otherApp(extensionID: "a", extensionName: "A", appName: "A", appVersion: "1"),
            "org.textbundle.package": .otherApp(extensionID: "b", extensionName: "B", appName: "B", appVersion: "1"),
        ]
        let rows = FileTypesSummary.make(claimed: claimed, owners: owners, extensionsOf: { _ in [] }).rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].id, rows[1].id, "row ids stay unique for the list")
    }

    func testLongExtensionListsAreCounted() {
        let kind = DiagnosticKind.catalogue.first { $0.id == "code" }!
        let row = KindRow(kind: kind, types: Array(kind.types.prefix(8)), owner: .vitrine(extensionID: "c"),
                          extensions: ["swift", "m", "mm", "h", "hh", "c", "cpp", "py"])
        XCTAssertEqual(row.subtitle, "8 types · .swift .m .mm .h .hh …")
    }

    // MARK: Use Vitrine

    func testSetAsidePlanListsEveryTypeTheOtherExtensionClaims() {
        let inkwell = Self.ext("com.example.inkwell.quicklook", app: "Inkwell Markdown", version: "3.2",
                               claims: ["net.daringfireball.markdown", "com.example.inkwell.document"])
        let claimed = [ClaimedType(uti: "net.daringfireball.markdown", extensionID: "m", family: "Markdown")]
        let owners: [String: TypeOwner] = ["net.daringfireball.markdown": .otherApp(extensionID: inkwell.identifier, extensionName: inkwell.displayName,
                                                                                   appName: "Inkwell Markdown", appVersion: "3.2")]
        let summary = FileTypesSummary.make(claimed: claimed, owners: owners, extensionsOf: { $0 == "net.daringfireball.markdown" ? ["md", "markdown"] : ["inkwell"] })
        let plan = SetAsidePlan.make(rows: summary.rows(.otherApp), installed: [inkwell], summary: summary,
                                     describe: { $0 == "com.example.inkwell.document" ? "Inkwell documents" : nil },
                                     extensionsOf: { $0 == "com.example.inkwell.document" ? ["inkwell"] : [] })
        XCTAssertEqual(plan.title, "Use Vitrine for Markdown?")
        XCTAssertEqual(plan.extensions.map(\.identifier), ["com.example.inkwell.quicklook"])
        XCTAssertEqual(plan.changes.map(\.name), ["Markdown", "Inkwell documents"])
        XCTAssertEqual(plan.changes.map(\.toVitrine), [true, false])
        XCTAssertEqual(plan.changes.map(\.from), ["Inkwell", "Inkwell"])
        XCTAssertEqual(plan.changes[1].subtitle, ".inkwell · Vitrine does not preview this kind")
        XCTAssertEqual(plan.appNames, ["Inkwell Markdown"])
        XCTAssertEqual(plan.doneMessage, "Markdown now preview in Vitrine")
    }

    func testListWording() {
        // Lists follow the locale (S-12): British English has no comma before "and", US English does, German says "und".
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(SetAsidePlan.list([], locale: gb), "")
        XCTAssertEqual(SetAsidePlan.list(["A"], locale: gb), "A")
        XCTAssertEqual(SetAsidePlan.list(["A", "B"], locale: gb), "A and B")
        XCTAssertEqual(SetAsidePlan.list(["A", "B", "C"], locale: gb), "A, B and C")
        XCTAssertEqual(SetAsidePlan.list(["A", "B", "C"], locale: Locale(identifier: "en_US")), "A, B, and C")
        XCTAssertEqual(SetAsidePlan.list(["A", "B", "C"], locale: Locale(identifier: "de_DE")), "A, B und C")
    }

    // MARK: Extensions pane

    func testExtensionsSummary() {
        let all = PluginKitParser.records(from: Self.pluginkitAll)
        // Discovery returns the /Applications copy for Code, the Downloads copy for Markdown; Data is turned off.
        let elected = all.filter { [ "71B87D79-E1BA-4514-85D2-139A35EE18CD", "C6122A2C-6D04-4AE9-BBAF-98CDEC0FC611",
                                     "59AE426D-31B8-4BD1-8F17-7A14C8685AC2"].contains($0.uuid ?? "") }
        let expected = [("io.github.xbtdmt.vitrine.quicklook.markdown", "Markdown"), ("io.github.xbtdmt.vitrine.quicklook.code", "Code"),
                        ("io.github.xbtdmt.vitrine.quicklook.data", "Data"), ("io.github.xbtdmt.vitrine.quicklook.folders", "Folders")]
        let s = ExtensionsSummary.make(elected: elected, all: all, ownApp: "/Applications/Vitrine.app/", expected: expected)
        XCTAssertEqual(s.extensions.map(\.state), [.onElsewhere(version: "0.1.0", path: "/Users/sample/Downloads/Vitrine.app"),
                                                   .on(version: "0.1.0"), .off, .notRegistered])
        XCTAssertEqual(s.offCount, 1)
        XCTAssertEqual(s.otherCopies.map(\.appPath), ["/Users/sample/Downloads/Vitrine.app", "/Users/sample/Builds/Spacebar.app"],
                       "the copy macOS uses comes first; other apps' extensions are not copies")
        XCTAssertEqual(s.otherCopies[0].extensionPaths.count, 2)
        XCTAssertTrue(s.otherCopies[0].inUse)
        XCTAssertFalse(s.otherCopies[1].inUse)
        XCTAssertTrue(s.otherCopies[1].legacyName)
        XCTAssertEqual(s.problemCount, 4, "three extensions plus the copies")
    }

    // MARK: Report

    func testReportHasCountsAndKindsButNoPaths() {
        let all = PluginKitParser.records(from: Self.pluginkitAll)
        let ext = ExtensionsSummary.make(elected: all.filter { $0.uuid == "71B87D79-E1BA-4514-85D2-139A35EE18CD" }, all: all,
                                         ownApp: "/Applications/Vitrine.app", expected: [("io.github.xbtdmt.vitrine.quicklook.code", "Code")])
        let claimed = ["public.yaml", "com.microsoft.typescript"].map { ClaimedType(uti: $0, extensionID: "c", family: "Code") }
        let types = FileTypesSummary.make(claimed: claimed, owners: [
            "public.yaml": .otherApp(extensionID: "p", extensionName: "P", appName: "SyntaxPeek", appVersion: "2.0"),
            "com.microsoft.typescript": .macOS(reason: "reserves .ts for MPEG-2 transport stream"),
        ], extensionsOf: { _ in [] })
        let text = DiagnosticsReportText.make(appVersion: "0.1.0 (1)", macOS: "27.2 (26B123)", generated: Date(timeIntervalSince1970: 0),
                                              fileTypes: types, extensions: ext)
        XCTAssertTrue(text.hasPrefix("## Vitrine diagnostics\nVitrine 0.1.0 (1) · macOS 27.2 (26B123)\n"))
        XCTAssertTrue(text.contains("- YAML: SyntaxPeek 2.0 wins"))
        XCTAssertTrue(text.contains("- 1 kind kept by macOS (TypeScript)"))
        XCTAssertTrue(text.contains("- Other copy registered: Vitrine 0.1.0"))
        XCTAssertTrue(text.contains("- Other copy registered: Vitrine 0.1.0 (old name)"))
        XCTAssertTrue(text.contains("- 1 other: on"))
        XCTAssertFalse(text.contains("/Users"), "no paths")
        XCTAssertFalse(text.contains(".app"), "no app paths")
    }
}
