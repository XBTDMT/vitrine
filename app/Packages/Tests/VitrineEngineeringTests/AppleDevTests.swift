import Foundation
import Testing
import VitrineBinary
@testable import VitrineEngineering

// The Apple development reader (E-5) on invented fixtures: every app name, bundle ID, team, key and path below is
// made up (Notes Lite, Harbor Maps, com.example.*, team ABCDE12345), written by hand in each format's shape.
// Folders for .xcassets and .xcarchive are built in a temporary directory and removed afterwards. Nothing here
// copies a real catalog or crash report, runs a process or touches the network. roadmap: S-22

private func read(_ text: String, _ name: String) -> AppleDevDocument? {
    AppleDevReader.read(data: Data(text.utf8), fileName: name)
}

private func plistData(_ object: Any, _ format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
}

/// A scratch folder removed when the test ends.
private final class Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-appledev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func dir(_ path: String) throws -> URL {
        let u = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func file(_ path: String, _ text: String) throws { try file(path, Data(text.utf8)) }

    func file(_ path: String, _ data: Data) throws {
        let u = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
    }
}

// MARK: - String Catalogs

@Suite("String Catalogs")
struct StringCatalogTests {
    static let catalog = """
    {
      "sourceLanguage" : "en",
      "version" : "1.0",
      "strings" : {
        "greeting %@" : {
          "comment" : "Shown on the home screen of Notes Lite.",
          "localizations" : {
            "de" : { "stringUnit" : { "state" : "translated", "value" : "Hallo %@" } },
            "fr" : { "stringUnit" : { "state" : "needs_review", "value" : "Bonjour %@" } }
          }
        },
        "files_count" : {
          "localizations" : {
            "en" : { "variations" : { "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld file" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld files" } } } } },
            "de" : { "variations" : { "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "Eine Datei" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld Dateien" } } } } }
          }
        },
        "Harbor" : { "shouldTranslate" : false },
        "old_banner" : {
          "extractionState" : "stale",
          "localizations" : {
            "en" : { "stringUnit" : { "state" : "translated", "value" : "Old banner" } },
            "de" : { "stringUnit" : { "state" : "stale", "value" : "Altes Banner" } },
            "fr" : { "stringUnit" : { "state" : "new", "value" : "" } }
          }
        },
        "tap_hint" : {
          "localizations" : {
            "en" : { "variations" : { "device" : {
              "mac" : { "stringUnit" : { "state" : "translated", "value" : "Click to open" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "Tap to open" } } } } },
            "de" : { "stringUnit" : { "state" : "translated", "value" : "Zum Öffnen tippen" } },
            "fr" : { "stringUnit" : { "state" : "translated", "value" : "Touchez pour ouvrir" } }
          }
        },
        "score" : {
          "localizations" : {
            "en" : { "stringUnit" : { "state" : "translated", "value" : "Score: %lld" } },
            "de" : { "stringUnit" : { "state" : "translated", "value" : "Punkte: %@" } },
            "fr" : { "stringUnit" : { "state" : "translated", "value" : "Points : %1$lld" } }
          }
        },
        "photos_in_albums" : {
          "localizations" : {
            "en" : {
              "stringUnit" : { "state" : "translated", "value" : "%#@photos@ in %#@albums@" },
              "substitutions" : {
                "photos" : { "argNum" : 1, "formatSpecifier" : "lld", "variations" : { "plural" : {
                  "one" : { "stringUnit" : { "state" : "translated", "value" : "%arg photo" } },
                  "other" : { "stringUnit" : { "state" : "translated", "value" : "%arg photos" } } } } },
                "albums" : { "argNum" : 2, "formatSpecifier" : "lld", "variations" : { "plural" : {
                  "other" : { "stringUnit" : { "state" : "translated", "value" : "%arg albums" } } } } }
              }
            },
            "de" : { "stringUnit" : { "state" : "translated", "value" : "%#@photos@ in %#@albums@" } }
          }
        }
      }
    }
    """

    @Test func readsLanguagesCoverageVariationsAndRows() throws {
        guard case .stringCatalog(let s) = try #require(read(Self.catalog, "Localizable.xcstrings")) else {
            Issue.record("not a string catalog"); return
        }
        #expect(s.sourceLanguage == "en" && s.version == "1.0")
        #expect(s.languages == ["en", "de", "fr"])
        #expect(s.keyCount == 7 && s.rows.count == 7 && !s.truncated)
        #expect(s.doNotTranslateCount == 1 && s.staleKeyCount == 1)
        #expect(s.pluralKeyCount == 2)          // files_count, photos_in_albums (through its substitutions)
        #expect(s.deviceKeyCount == 1)
        #expect(s.substitutionKeyCount == 1 && s.substitutionCount == 2)

        let de = try #require(s.coverage.first { $0.language == "de" })
        #expect(de.total == 6 && de.translated == 5 && de.stale == 1 && de.missing == 0)
        let fr = try #require(s.coverage.first { $0.language == "fr" })
        #expect(fr.translated == 2 && fr.needsReview == 1 && fr.new == 1 && fr.missing == 2 && fr.total == 6)
        let en = try #require(s.coverage.first { $0.language == "en" })
        #expect(en.translated == 6 && en.fraction == 1)

        let greeting = try #require(s.rows.first { $0.key == "greeting %@" })
        #expect(greeting.comment == "Shown on the home screen of Notes Lite.")
        #expect(greeting.cells["en"] == .init(state: .translated, value: "greeting %@"))   // the key is the source text
        #expect(greeting.cells["fr"] == .init(state: .needsReview, value: "Bonjour %@"))
        let files = try #require(s.rows.first { $0.key == "files_count" })
        #expect(files.cells["de"] == .init(state: .translated, value: "%lld Dateien", hasVariations: true))
        #expect(files.cells["fr"]?.state == .missing)
        #expect(s.rows.first { $0.key == "Harbor" }?.shouldTranslate == false)
    }

    @Test func warnsAboutPlaceholdersCoverageAndStaleKeys() throws {
        guard case .stringCatalog(let s) = try #require(read(Self.catalog, "Localizable.xcstrings")) else { return }
        // "Punkte: %@" puts an object where the source has an integer; "Eine Datei" leaving %lld out is fine, and so
        // is French's positional %1$lld.
        #expect(s.placeholderMismatchCount == 1)
        #expect(s.warnings.first?.level == .danger)
        #expect(s.warnings.first?.reason.contains("score") == true)
        #expect(s.warnings.contains { $0.level == .caution && $0.reason.contains("(fr)") && $0.reason.contains("2 missing") })
        #expect(s.warnings.contains { $0.reason.contains("(de)") && $0.reason.contains("1 stale") })
        // The singular wording ("1 key is stale") comes from the String Catalog's plural variation, not the code.
        #expect(s.warnings.contains { $0.reason.hasPrefix("1 ") && $0.reason.contains("stale: the code no longer uses") })
        // The language's name follows the reader's locale; its code is always there.
        #expect(s.facts.contains { $0.label == "Source language" && $0.value.hasSuffix("(en)") })
    }

    @Test func placeholderParsing() {
        #expect(StringCatalogReader.placeholders("%@ has %lld items, 100%% done") == ["1:object", "2:int"])
        #expect(StringCatalogReader.placeholders("%2$@ — %1$.2f") == ["2:object", "1:float"])
        #expect(StringCatalogReader.placeholders("%#@photos@ and %-5d") == ["sub:photos", "1:int"])
        #expect(StringCatalogReader.placeholders("ends with %") == [])
    }

    @Test func capsTheTranslationTable() throws {
        var entries: [String] = []
        for i in 0..<(StringCatalogSummary.maxRows + 100) {
            entries.append("\"key_\(String(format: "%05d", i))\" : { \"localizations\" : { \"de\" : { \"stringUnit\" : { \"state\" : \"translated\", \"value\" : \"Wert\" } } } }")
        }
        let text = "{ \"sourceLanguage\" : \"en\", \"strings\" : { \(entries.joined(separator: ",\n")) } }"
        guard case .stringCatalog(let s) = try #require(read(text, "Big.xcstrings")) else { return }
        #expect(s.keyCount == StringCatalogSummary.maxRows + 100)
        #expect(s.rows.count == StringCatalogSummary.maxRows && s.truncated)
        #expect(s.coverage.first { $0.language == "de" }?.translated == StringCatalogSummary.maxRows + 100)
    }

    @Test func malformedCatalogsGiveNil() {
        #expect(read("{ not json", "Localizable.xcstrings") == nil)
        #expect(read("{ \"sourceLanguage\" : \"en\" }", "Localizable.xcstrings") == nil)
        #expect(read("[1, 2, 3]", "Localizable.xcstrings") == nil)
        // Wrong shapes inside are skipped, not trusted.
        let odd = "{ \"strings\" : { \"a\" : 5, \"b\" : { \"localizations\" : { \"de\" : \"text\" } } } }"
        guard case .stringCatalog(let s)? = read(odd, "Odd.xcstrings") else { Issue.record("expected a summary"); return }
        #expect(s.keyCount == 2 && s.sourceLanguage == nil)
        #expect(s.warnings.contains { $0.reason.contains("source language") })
    }
}

// MARK: - Info.plist

@Suite("Info.plist")
struct InfoPlistTests {
    static var info: [String: Any] { [
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": "Harbor Maps",
        "CFBundleDisplayName": "Harbor",
        "CFBundleExecutable": "HarborMaps",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "2.4",
        "CFBundleVersion": "118",
        "MinimumOSVersion": "17.0",
        "UIDeviceFamily": [1, 2],
        "LSApplicationCategoryType": "public.app-category.navigation",
        "NSCameraUsageDescription": "Scan harbor signs to find your berth.",
        "NSMicrophoneUsageDescription": "",
        "NSLocationWhenInUseUsageDescription": "Show where your boat is.",
        "NSSonarPingUsageDescription": "Invented key for the fallback wording.",
        "CFBundleURLTypes": [["CFBundleURLName": "com.example.harbor", "CFBundleURLSchemes": ["harbor", "harbor-maps"]]],
        "LSApplicationQueriesSchemes": ["tide-tables"],
        "CFBundleDocumentTypes": [["CFBundleTypeName": "Harbor Route", "CFBundleTypeRole": "Editor",
                                   "LSItemContentTypes": ["com.example.harbor.route"]]],
        "UTExportedTypeDeclarations": [["UTTypeIdentifier": "com.example.harbor.route"]],
        "UIBackgroundModes": ["location", "audio", "something-new"],
        "UIRequiredDeviceCapabilities": ["arm64", "gps"],
        "NSAppTransportSecurity": [
            "NSAllowsArbitraryLoads": true,
            "NSExceptionDomains": [
                "tides.example.org": ["NSExceptionAllowsInsecureHTTPLoads": true, "NSIncludesSubdomains": true],
                "old.example.net": ["NSExceptionMinimumTLSVersion": "TLSv1.0"],
            ],
        ],
    ] }

    @Test func summarisesAnXMLInfoPlist() throws {
        let data = try plistData(Self.info)
        guard case .infoPlist(let s) = try #require(AppleDevReader.read(data: data, fileName: "Info.plist")) else {
            Issue.record("not an Info.plist"); return
        }
        #expect(s.format == .xml)
        #expect(s.bundleIdentifier == "$(PRODUCT_BUNDLE_IDENTIFIER)" && s.usesBuildSettings)
        #expect(s.displayName == "Harbor" && s.shortVersion == "2.4" && s.buildVersion == "118")
        #expect(s.minimumOSVersion == "17.0" && s.deviceFamilies == ["iPhone", "iPad"] && s.category == "Navigation")
        #expect(s.privacyUsages.map(\.what) == ["Camera", "Location while in use", "Microphone", "Sonar ping"])
        #expect(s.privacyUsages.first?.reason == "Scan harbor signs to find your berth.")
        #expect(s.urlTypes.first?.schemes == ["harbor", "harbor-maps"] && s.queriedSchemes == ["tide-tables"])
        #expect(s.documentTypes.first?.name == "Harbor Route" && s.exportedTypes == ["com.example.harbor.route"])
        #expect(s.backgroundModes.map(\.what) == ["location updates", "plays audio in the background", "something-new"])
        #expect(s.requiredCapabilities == ["arm64", "gps"])
        let ats = try #require(s.transportSecurity)
        #expect(ats.allowsArbitraryLoads && ats.exceptionDomains.count == 2)
        #expect(ats.exceptionDomains.first { $0.name == "tides.example.org" }?.allowsInsecureHTTP == true)
        #expect(s.headline == "Info.plist — Harbor 2.4 (118)")
        #expect(s.facts.contains(.init("URL schemes", "harbor, harbor-maps")))
    }

    @Test func warnsAboutTransportSecurityAndEmptyReasons() throws {
        guard case .infoPlist(let s)? = AppleDevReader.read(data: try plistData(Self.info), fileName: "Info.plist") else { return }
        #expect(s.warnings.contains { $0.level == .caution && $0.reason.contains("NSAllowsArbitraryLoads") })
        #expect(s.warnings.contains { $0.reason.contains("tides.example.org") && $0.reason.contains("Plain HTTP") })
        #expect(s.warnings.contains { $0.reason.contains("old.example.net") && $0.reason.contains("TLS") })
        #expect(s.warnings.contains { $0.reason.contains("NSMicrophoneUsageDescription") })
        #expect(s.warnings.count == 4)
    }

    @Test func readsBinaryPlistsByKeysWhateverTheName() throws {
        let data = try plistData(["CFBundleIdentifier": "com.example.noteslite", "CFBundleExecutable": "Notes Lite",
                                  "LSMinimumSystemVersion": "14.0", "LSUIElement": true], .binary)
        guard case .infoPlist(let s)? = AppleDevReader.read(data: data, fileName: "NotesLite-Info.plist") else {
            Issue.record("expected an Info.plist"); return
        }
        #expect(s.format == .binary && s.minimumOSVersion == "14.0" && s.isAgent && s.warnings.isEmpty && !s.usesBuildSettings)
        guard case .infoPlist? = AppleDevReader.read(data: data, fileName: "whatever.plist") else {
            Issue.record("bundle keys should decide"); return
        }
    }

    @Test func malformedOrUnrelatedPlistsGiveNil() throws {
        #expect(read("not a plist at all <<<", "Info.plist") == nil)
        #expect(AppleDevReader.read(data: try plistData(["a", "b"]), fileName: "Info.plist") == nil)
        #expect(AppleDevReader.read(data: try plistData(["WindowWidth": 800, "Theme": "dark"]), fileName: "Settings.plist") == nil)
        #expect(AppleDevReader.read(data: Data(), fileName: "Info.plist") == nil)
        #expect(AppleDevReader.read(data: Data(count: AppleDevReader.maxBytes + 1), fileName: "Info.plist") == nil)
    }
}

// MARK: - Entitlements

@Suite("Entitlements")
struct EntitlementsTests {
    static var entitlements: [String: Any] { [
        "com.apple.security.app-sandbox": true,
        "com.apple.security.network.client": true,
        "com.apple.security.files.user-selected.read-write": true,
        "com.apple.security.application-groups": ["ABCDE12345.com.example.harbor"],
        "keychain-access-groups": ["ABCDE12345.com.example.shared"],
        "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.harbor"],
        "com.apple.security.cs.disable-library-validation": true,
        "com.apple.security.cs.allow-dyld-environment-variables": true,
        "com.apple.security.cs.allow-jit": false,
        "com.apple.security.get-task-allow": true,
        "com.apple.security.temporary-exception.mach-lookup.global-name": ["com.example.helper"],
        "com.apple.private.tcc.allow": ["kTCCServiceCamera"],
        "com.example.custom-flag": "on",
    ] }

    @Test func describesEveryKeyInPlainWords() throws {
        guard case .entitlements(let s) = try #require(AppleDevReader.read(data: try plistData(Self.entitlements),
                                                                          fileName: "Harbor.entitlements")) else {
            Issue.record("not entitlements"); return
        }
        #expect(s.entries.count == 13 && !s.truncated)
        #expect(s.isSandboxed == true)
        let client = try #require(s.entries.first { $0.key == "com.apple.security.network.client" })
        #expect(client.name == "Outgoing network connections" && client.category == .network && client.valueText == "yes")
        let groups = try #require(s.entries.first { $0.key == "com.apple.security.application-groups" })
        #expect(groups.name == "App groups" && groups.valueText == "ABCDE12345.com.example.harbor")
        #expect(s.entries.first { $0.key == "com.apple.security.temporary-exception.mach-lookup.global-name" }?.category == .sandboxException)
        #expect(s.entries.first { $0.key == "com.apple.private.tcc.allow" }?.category == .privateApple)
        #expect(s.unknownKeys == ["com.example.custom-flag"])
        #expect(s.entries.first?.category == .sandbox)        // grouped in category order
        // allow-jit is present but off, so it is not an exception in force.
        #expect(s.hardenedRuntimeExceptions == ["com.apple.security.cs.allow-dyld-environment-variables",
                                                "com.apple.security.cs.disable-library-validation"])
        #expect(s.facts.first == .init("App Sandbox", "on"))
    }

    @Test func warnsAboutRuntimeExceptionsDebuggingAndPrivateKeys() throws {
        guard case .entitlements(let s)? = AppleDevReader.read(data: try plistData(Self.entitlements), fileName: "Harbor.entitlements") else { return }
        #expect(s.warnings.first?.level == .danger)
        #expect(s.warnings.filter { $0.level == .danger }.count == 1)
        #expect(s.warnings.contains { $0.reason.contains("allow-dyld-environment-variables") && $0.level == .danger })
        #expect(s.warnings.contains { $0.reason.contains("disable-library-validation") && $0.level == .caution })
        #expect(s.warnings.contains { $0.reason.contains("get-task-allow") })
        #expect(s.warnings.contains { $0.reason.contains("sandbox exception") })
        #expect(s.warnings.contains { $0.reason.contains("Apple-private") })
    }

    @Test func plainPlistOfEntitlementsAndSandboxOff() throws {
        let data = try plistData(["com.apple.security.app-sandbox": false, "com.apple.security.device.camera": true])
        guard case .entitlements(let s)? = AppleDevReader.read(data: data, fileName: "Signing.plist") else {
            Issue.record("expected entitlements"); return
        }
        #expect(s.isSandboxed == false && s.warnings.contains { $0.reason.contains("switched off") })
    }

    @Test func malformedEntitlementsGiveNil() {
        #expect(read("<?xml version=\"1.0\"?><plist><dict><key>broken", "App.entitlements") == nil)
        #expect(read("hello", "App.entitlements") == nil)
    }
}

// MARK: - Crash reports

@Suite("Crash reports")
struct CrashReportTests {
    static func ips(frames: Int = 35, symbolicated: Bool = true, namespace: String = "SIGNAL") -> String {
        let header = #"{"app_name":"Notes Lite","timestamp":"2026-03-14 09:26:53.00 +0100","app_version":"3.1","build_version":"412","bug_type":"309","os_version":"macOS 15.3 (24D60)","bundleID":"com.example.noteslite","incident_id":"0F1E2D3C-AAAA-BBBB-CCCC-123456789ABC","name":"Notes Lite","roots_installed":0}"#
        let frameList = (0..<frames).map { i -> String in
            let image = i % 2 == 0 ? 0 : 2
            return symbolicated
                ? #"{"imageOffset":\#(1000 + i),"symbol":"NotesLite.render(page:) \#(i)","symbolLocation":\#(i * 4),"imageIndex":\#(image),"sourceFile":"Render.swift","sourceLine":\#(10 + i)}"#
                : #"{"imageOffset":\#(1000 + i),"imageIndex":0}"#
        }.joined(separator: ",")
        return header + "\n" + """
        {
          "uptime" : 1200, "procRole" : "Foreground", "pid" : 4242, "procName" : "Notes Lite",
          "procPath" : "/Applications/Notes Lite.app/Contents/MacOS/Notes Lite", "parentProc" : "launchd",
          "cpuType" : "ARM-64", "modelCode" : "Mac15,3",
          "osVersion" : { "train" : "macOS 15.3", "build" : "24D60", "releaseType" : "User" },
          "bundleInfo" : { "CFBundleShortVersionString" : "3.1", "CFBundleVersion" : "412", "CFBundleIdentifier" : "com.example.noteslite" },
          "exception" : { "codes" : "0x0000000000000001, 0x0000000000000000", "type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV",
                          "subtype" : "KERN_INVALID_ADDRESS at 0x0000000000000000" },
          "termination" : { "flags" : 0, "code" : 11, "namespace" : "\(namespace)", "indicator" : "Segmentation fault: 11", "byProc" : "exc handler" },
          "asi" : { "libsystem_c.dylib" : ["invented message from the fixture"] },
          "faultingThread" : 1,
          "threads" : [
            { "id" : 1, "queue" : "com.apple.main-thread", "frames" : [ { "imageOffset" : 5, "imageIndex" : 1 } ] },
            { "id" : 2, "triggered" : true, "name" : "render-worker", "frames" : [ \(frameList) ] }
          ],
          "usedImages" : [
            { "name" : "Notes Lite", "path" : "/Applications/Notes Lite.app/Contents/MacOS/Notes Lite" },
            { "path" : "/usr/lib/system/libsystem_kernel.dylib" },
            { "name" : "NotesKit" }
          ],
          "lastExceptionBacktrace" : [ { "imageOffset" : 77, "symbol" : "objc_exception_throw", "symbolLocation" : 60, "imageIndex" : 1 } ]
        }
        """
    }

    @Test func readsAJSONReport() throws {
        guard case .crashReport(let s) = try #require(read(Self.ips(), "Notes Lite-2026-03-14-092653.ips")) else {
            Issue.record("not a crash report"); return
        }
        #expect(s.format == .json && s.bugType == "309" && s.kind == "Crash")
        #expect(s.appName == "Notes Lite" && s.bundleIdentifier == "com.example.noteslite")
        #expect(s.appVersion == "3.1" && s.buildVersion == "412" && s.osVersion == "macOS 15.3 (24D60)")
        #expect(s.incidentIdentifier == "0F1E2D3C-AAAA-BBBB-CCCC-123456789ABC" && s.processID == 4242)
        #expect(s.exceptionType == "EXC_BAD_ACCESS" && s.signal == "SIGSEGV")
        #expect(s.exceptionExplanation?.contains("null pointer") == true)
        #expect(s.terminationReason == "Namespace SIGNAL, Code 11, Segmentation fault: 11, by exc handler")
        #expect(s.crashedThread == 1 && s.crashedThreadName == "render-worker")
        #expect(s.frames.count == 30 && s.framesTruncated)
        #expect(s.frames[0] == .init(index: 0, image: "Notes Lite", symbol: "NotesLite.render(page:) 0", symbolOffset: 0,
                                     imageOffset: 1000, address: nil, sourceFile: "Render.swift", sourceLine: 10))
        #expect(s.frames[1].image == "NotesKit")
        #expect(s.lastExceptionFrames.first?.image == "libsystem_kernel.dylib")
        #expect(s.threadCount == 2 && s.binaryImageCount == 3)
        #expect(s.applicationSpecificInformation == ["libsystem_c.dylib: invented message from the fixture"])
        #expect(s.warnings.isEmpty)
        #expect(s.headline == "Crash — Notes Lite: EXC_BAD_ACCESS (SIGSEGV)")
    }

    @Test func warnsAboutCodeSigningAndMissingSymbols() throws {
        guard case .crashReport(let s)? = read(Self.ips(frames: 3, symbolicated: false, namespace: "CODESIGNING"), "a.ips") else {
            Issue.record("expected a crash report"); return
        }
        #expect(s.warnings.first?.level == .danger && s.warnings.first?.reason.contains("code signature") == true)
        #expect(s.warnings.contains { $0.reason.contains("not symbolicated") })
        #expect(!s.framesTruncated && s.frames.count == 3)
    }

    @Test func damagedJSONReports() throws {
        let header = #"{"app_name":"Notes Lite","bug_type":"309","os_version":"macOS 15.3 (24D60)"}"#
        guard case .crashReport(let headerOnly)? = read(header + "\n", "x.ips") else { Issue.record("header only"); return }
        #expect(headerOnly.appName == "Notes Lite" && headerOnly.warnings.contains { $0.reason.contains("only its header") })
        guard case .crashReport(let cut)? = read(header + "\n{ \"threads\" : [", "x.ips") else { Issue.record("cut body"); return }
        #expect(cut.osVersion == "macOS 15.3 (24D60)" && cut.warnings.contains { $0.reason.contains("damaged") })
        #expect(read("{", "x.ips") == nil)
        #expect(read("garbage", "x.ips") == nil)
        #expect(AppleDevReader.read(data: Data([0x7B, 0x00, 0x7D]), fileName: "x.ips") == nil)
        // Every prefix of a valid report reads without trapping.
        let full = Array(Self.ips().utf8)
        for cut in stride(from: 1, to: full.count, by: 97) {
            _ = AppleDevReader.read(data: Data(full.prefix(cut)), fileName: "cut.ips")
        }
    }

    static let legacy = """
    Process:               Notes Lite [811]
    Path:                  /Applications/Notes Lite.app/Contents/MacOS/Notes Lite
    Identifier:            com.example.noteslite
    Version:               2.0 (200)
    Code Type:             X86-64 (Native)
    Parent Process:        launchd [1]
    Date/Time:             2021-05-02 18:04:11.123 +0200
    OS Version:            macOS 11.3 (20E232)
    Report Version:        12
    Incident Identifier:   11112222-3333-4444-5555-666677778888

    Crashed Thread:        0  Dispatch queue: com.apple.main-thread

    Exception Type:        EXC_CRASH (SIGABRT)
    Exception Codes:       0x0000000000000000, 0x0000000000000000
    Termination Reason:    Namespace SIGNAL, Code 0x6

    Application Specific Information:
    *** Invented assertion text for the fixture

    Thread 0 Crashed:: Dispatch queue: com.apple.main-thread
    0   libsystem_kernel.dylib        \t0x00007fff2033b92e __pthread_kill + 10
    1   Notes Lite                    \t0x0000000100001234 NotesLite.save() + 40 (Store.swift:88)
    2   Notes Lite                    \t0x00000001000f1234 0x100000000 + 987700

    Thread 1:
    0   libsystem_pthread.dylib       \t0x00007fff2036c458 start_wqthread + 0

    Thread 0 crashed with X86 Thread State (64-bit):
      rax: 0x0000000000000000  rbx: 0x0000000000000001

    Binary Images:
           0x100000000 -        0x100ffffff +com.example.noteslite (2.0 - 200) <00000000-1111-2222-3333-444444444444> /Applications/Notes Lite.app/Contents/MacOS/Notes Lite
        0x7fff20330000 -     0x7fff2035efff  libsystem_kernel.dylib (7195.101.1) <55555555-6666-7777-8888-999999999999> /usr/lib/system/libsystem_kernel.dylib
    """

    @Test func readsALegacyTextReport() throws {
        guard case .crashReport(let s) = try #require(read(Self.legacy, "Notes Lite_2021-05-02.crash")) else {
            Issue.record("not a crash report"); return
        }
        #expect(s.format == .legacyText && s.kind == "Crash")
        #expect(s.appName == "Notes Lite" && s.processID == 811 && s.bundleIdentifier == "com.example.noteslite")
        #expect(s.appVersion == "2.0" && s.buildVersion == "200" && s.osVersion == "macOS 11.3 (20E232)")
        #expect(s.exceptionType == "EXC_CRASH" && s.signal == "SIGABRT" && s.exceptionExplanation?.contains("abort()") == true)
        #expect(s.terminationReason == "Namespace SIGNAL, Code 0x6")
        #expect(s.crashedThread == 0 && s.crashedThreadName == "com.apple.main-thread")
        #expect(s.frames.count == 3 && s.threadCount == 2 && s.binaryImageCount == 2)
        #expect(s.frames[0].image == "libsystem_kernel.dylib" && s.frames[0].symbol == "__pthread_kill" && s.frames[0].symbolOffset == 10)
        #expect(s.frames[1] == .init(index: 1, image: "Notes Lite", symbol: "NotesLite.save()", symbolOffset: 40, imageOffset: nil,
                                     address: "0x0000000100001234", sourceFile: "Store.swift", sourceLine: 88))
        #expect(s.frames[2].symbol == nil && s.frames[2].imageOffset == 987700)
        #expect(s.applicationSpecificInformation == ["*** Invented assertion text for the fixture"])
        #expect(s.warnings.isEmpty)
    }

    @Test func legacyBodyAfterAnIPSHeaderAndSniffing() throws {
        let header = #"{"app_name":"Notes Lite","bug_type":"109","app_version":"2.0","bundleID":"com.example.noteslite"}"#
        guard case .crashReport(let s)? = read(header + "\n" + Self.legacy, "old.ips") else { Issue.record("expected"); return }
        #expect(s.format == .legacyText && s.bugType == "109" && s.frames.count == 3)
        guard case .crashReport? = read(Self.legacy, "report") else { Issue.record("legacy text should be sniffed"); return }
        guard case .crashReport? = read(Self.ips(), "report.txt") else { Issue.record("JSON .ips should be sniffed"); return }
        #expect(read("Process: but nothing else that matters\n", "random.crash")?.headline.isEmpty == false)
        #expect(read("Hello there, this is a note.", "notes") == nil)
    }
}

// MARK: - Asset catalogs

@Suite("Asset catalogs")
struct AssetCatalogTests {
    fileprivate static func makeCatalog(_ s: Scratch) throws -> URL {
        let root = try s.dir("Media.xcassets")
        try s.file("Media.xcassets/Contents.json", #"{"info":{"author":"xcode","version":1}}"#)
        try s.file("Media.xcassets/AppIcon.appiconset/Contents.json", """
        {"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"},
                   {"filename":"icon-512@2x.png","idiom":"mac","scale":"2x","size":"512x512"},
                   {"idiom":"mac","scale":"1x","size":"16x16"}],"info":{"author":"xcode","version":1}}
        """)
        try s.file("Media.xcassets/AppIcon.appiconset/icon-1024.png", "png")
        try s.file("Media.xcassets/Logo.imageset/Contents.json", """
        {"images":[{"filename":"logo.png","idiom":"universal","scale":"1x"},
                   {"appearances":[{"appearance":"luminosity","value":"dark"}],"filename":"logo-dark.png","idiom":"universal","scale":"1x"},
                   {"appearances":[{"appearance":"luminosity","value":"dark"},{"appearance":"contrast","value":"high"}],"idiom":"universal","scale":"2x"}],
         "properties":{"template-rendering-intent":"template","preserves-vector-representation":true}}
        """)
        try s.file("Media.xcassets/Logo.imageset/logo.png", "png")
        try s.file("Media.xcassets/Logo.imageset/Logo-Dark.PNG", "png")   // case differs: still present
        try s.file("Media.xcassets/Logo.imageset/leftover.png", "png")
        try s.file("Media.xcassets/Brand/Contents.json", #"{"properties":{"provides-namespace":true}}"#)
        try s.file("Media.xcassets/Brand/Accent.colorset/Contents.json", """
        {"colors":[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0.250","green":"0.500","red":"1.000"}},"idiom":"universal"},
                   {"appearances":[{"appearance":"luminosity","value":"dark"}],"color":{"color-space":"display-p3","components":{"alpha":"0.800","blue":"0x40","green":"0x80","red":"0xFF"}},"idiom":"universal"},
                   {"appearances":[{"appearance":"contrast","value":"high"}],"color":{"color-space":"srgb","components":{"alpha":"1","blue":"64","green":"128","red":"255"}},"idiom":"universal"},
                   {"color":{"color-space":"gray-gamma-22","components":{"alpha":"1.000","white":"0.500"}},"idiom":"mac"},
                   {"color":{"platform":"ios","reference":"systemBlueColor"},"idiom":"iphone"}]}
        """)
        try s.file("Media.xcassets/Plain Group/Config.dataset/Contents.json", """
        {"data":[{"filename":"config.json","idiom":"universal","universal-type-identifier":"public.json"}]}
        """)
        try s.file("Media.xcassets/Plain Group/Config.dataset/config.json", "{}")
        try s.file("Media.xcassets/Star.symbolset/Contents.json", #"{"symbols":[{"filename":"star.fill.svg","idiom":"universal"}]}"#)
        try s.file("Media.xcassets/Star.symbolset/star.fill.svg", "<svg/>")
        try s.file("Media.xcassets/Broken.imageset/Contents.json", "{ this is not json")
        try s.file("Media.xcassets/Empty.imageset/Contents.json", #"{"images":[{"idiom":"universal","scale":"1x"}]}"#)
        try s.file("Media.xcassets/Splash.launchimage/Contents.json", #"{"images":[]}"#)
        return root
    }

    @Test func readsEveryKindWithVariantsColorsAndMissingFiles() throws {
        let s = try Scratch()
        let root = try Self.makeCatalog(s)
        guard case .assetCatalog(let c) = try #require(AppleDevReader.read(directory: root)) else {
            Issue.record("not an asset catalog"); return
        }
        #expect(!c.truncated)
        #expect(c.kindCounts == [.appIcon: 1, .image: 3, .color: 1, .data: 1, .symbol: 1, .other: 1])
        #expect(c.groupCount == 2)
        #expect(c.assets.map(\.name) == ["AppIcon", "Brand/Accent", "Broken", "Empty", "Logo", "Config", "Splash", "Star"])

        let icon = try #require(c.assets.first { $0.name == "AppIcon" })
        #expect(icon.kind == .appIcon && icon.variants.count == 3)
        #expect(icon.missingFiles == ["icon-512@2x.png"])
        #expect(icon.variants[0].size == "1024x1024" && icon.variants[0].fileExists == true)
        #expect(icon.variants[2].filename == nil && icon.variants[2].fileExists == nil)

        let logo = try #require(c.assets.first { $0.name == "Logo" })
        #expect(logo.variants.map(\.appearances) == [[], ["dark"], ["dark", "high contrast"]])
        #expect(logo.missingFiles.isEmpty && logo.unreferencedFiles == ["leftover.png"])
        #expect(logo.properties["template-rendering-intent"] == "template")
        #expect(logo.properties["preserves-vector-representation"] == "true")

        let accent = try #require(c.assets.first { $0.name == "Brand/Accent" })
        #expect(accent.path == "Brand/Accent.colorset")
        #expect(accent.colors.map(\.hex) == ["#FF8040", "#FF8040", "#FF8040", "#808080", nil])
        #expect(accent.colors[1].appearances == ["dark"] && accent.colors[1].colorSpace == "display-p3" && accent.colors[1].alpha == 0.8)
        #expect(accent.colors[2].alpha == 1 && accent.colors[4].systemColor == "systemBlueColor")

        #expect(c.assets.first { $0.name == "Config" }?.variants.first?.contentType == "public.json")
        #expect(c.assets.first { $0.name == "Star" }?.files == ["star.fill.svg"])
        #expect(c.missingFileCount == 1)
        #expect(c.facts.contains(.init("Missing files", "1")))
    }

    @Test func warnsAboutMissingBrokenAndEmptyAssets() throws {
        let s = try Scratch()
        guard case .assetCatalog(let c)? = AppleDevReader.read(directory: try Self.makeCatalog(s)) else { return }
        #expect(c.warnings.contains { $0.reason.contains("“AppIcon”") && $0.reason.contains("icon-512@2x.png") })
        #expect(c.warnings.contains { $0.reason.contains("Broken.imageset/Contents.json") && $0.reason.contains("not valid JSON") })
        #expect(c.warnings.contains { $0.reason.contains("“Empty”") && $0.reason.contains("no image files") })
        #expect(c.warnings.allSatisfy { $0.level == .caution })
        #expect(c.warnings.count == 3)
    }

    @Test func neverFollowsLinksOutOfTheCatalog() throws {
        let s = try Scratch()
        let root = try Self.makeCatalog(s)
        // A folder outside the catalog with a Contents.json, linked in two ways.
        try s.file("Outside/Secret.imageset/Contents.json", #"{"images":[{"filename":"x.png","idiom":"universal"}]}"#)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.imageset"),
                                                   withDestinationURL: s.url.appendingPathComponent("Outside/Secret.imageset"))
        try s.dir("Media.xcassets/Sneaky.imageset")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Sneaky.imageset/Contents.json"),
                                                   withDestinationURL: s.url.appendingPathComponent("Outside/Secret.imageset/Contents.json"))
        guard case .assetCatalog(let c)? = AppleDevReader.read(directory: root) else { Issue.record("expected"); return }
        #expect(!c.assets.contains { $0.name == "Linked" })
        let sneaky = try #require(c.assets.first { $0.name == "Sneaky" })
        #expect(sneaky.variants.isEmpty)
        #expect(c.warnings.contains { $0.reason.contains("Sneaky.imageset/Contents.json") && $0.reason.contains("not a regular file") })
        #expect(c.warnings.contains { $0.reason.contains("symbolic link") })
    }

    @Test func boundsDepthEntriesAndContentsSize() throws {
        let s = try Scratch()
        let root = try s.dir("Deep.xcassets")
        try s.file("Deep.xcassets/Contents.json", "{}")
        var path = "Deep.xcassets"
        for i in 0..<12 { path += "/g\(i)" }
        try s.file(path + "/Far.imageset/Contents.json", #"{"images":[]}"#)
        try s.file("Deep.xcassets/Huge.imageset/Contents.json", Data(repeating: 0x20, count: AppleDevReader.maxSmallFileBytes + 1))
        guard case .assetCatalog(let deep)? = AppleDevReader.read(directory: root) else { Issue.record("expected"); return }
        #expect(deep.truncated && !deep.assets.contains { $0.name == "Far" })
        #expect(deep.warnings.contains { $0.reason.contains("Huge.imageset/Contents.json") && $0.reason.contains("more than the preview reads") })

        let wide = try s.dir("Wide.xcassets")
        for i in 0..<(AppleDevReader.maxEntries + 50) { try s.dir("Wide.xcassets/i\(i).imageset") }
        guard case .assetCatalog(let w)? = AppleDevReader.read(directory: wide) else { Issue.record("expected"); return }
        #expect(w.truncated && w.assets.count <= AppleDevReader.maxEntries)
        #expect(w.warnings.count <= AssetCatalogReader.maxWarnings + 2)
    }

    @Test func sniffsFoldersAndRefusesOthers() throws {
        let s = try Scratch()
        _ = try Self.makeCatalog(s)
        let renamed = s.url.appendingPathComponent("Copy of Media")
        try FileManager.default.copyItem(at: s.url.appendingPathComponent("Media.xcassets"), to: renamed)
        guard case .assetCatalog? = AppleDevReader.read(directory: renamed) else { Issue.record("should be sniffed"); return }
        let plain = try s.dir("Just a folder")
        try s.file("Just a folder/readme.txt", "hi")
        #expect(AppleDevReader.read(directory: plain) == nil)
        #expect(AppleDevReader.read(directory: s.url.appendingPathComponent("does-not-exist.xcassets")) == nil)
        #expect(AppleDevReader.read(directory: s.url.appendingPathComponent("Just a folder/readme.txt")) == nil)
    }
}

// MARK: - Xcode archives

@Suite("Xcode archives")
struct XcodeArchiveTests {
    static let created = Date(timeIntervalSince1970: 1_770_000_000)

    static func info(applicationPath: String = "Applications/Notes Lite.app") -> [String: Any] {
        [
            "ApplicationProperties": [
                "ApplicationPath": applicationPath, "CFBundleIdentifier": "com.example.noteslite",
                "CFBundleShortVersionString": "3.1", "CFBundleVersion": "412",
                "SigningIdentity": "Apple Distribution: Example Studio (ABCDE12345)", "Team": "ABCDE12345",
                "Architectures": ["arm64", "x86_64"],
            ],
            "ArchiveVersion": 2, "CreationDate": created, "Name": "Notes Lite", "SchemeName": "NotesLite",
        ]
    }

    fileprivate static func makeArchive(_ s: Scratch, name: String = "Notes Lite 2026-03-14.xcarchive", dsyms: Bool = true,
                            info: [String: Any]? = XcodeArchiveTests.info()) throws -> URL {
        let root = try s.dir(name)
        if let info { try s.file("\(name)/Info.plist", try plistData(info)) }
        try s.file("\(name)/Products/Applications/Notes Lite.app/Contents/Info.plist", try plistData(["CFBundleIdentifier": "com.example.noteslite"]))
        try s.dir("\(name)/Products/Applications/Notes Lite.app/Contents/PlugIns/Share.appex")
        try s.file("\(name)/Products/usr/local/bin/notes-tool", "#!")
        try s.file("\(name)/Products/Applications/Notes Lite.app/Contents/embedded.provisionprofile", "not a real profile")
        if dsyms {
            try s.dir("\(name)/dSYMs/Notes Lite.app.dSYM")
            try s.dir("\(name)/dSYMs/NotesKit.framework.dSYM")
        }
        return root
    }

    @Test func readsInfoProductsAndDSYMs() throws {
        let s = try Scratch()
        guard case .xcodeArchive(let a) = try #require(AppleDevReader.read(directory: try Self.makeArchive(s))) else {
            Issue.record("not an archive"); return
        }
        #expect(a.name == "Notes Lite" && a.schemeName == "NotesLite" && a.archiveVersion == 2 && a.creationDate == Self.created)
        #expect(a.bundleIdentifier == "com.example.noteslite" && a.shortVersion == "3.1" && a.buildVersion == "412")
        #expect(a.signingIdentity == "Apple Distribution: Example Studio (ABCDE12345)" && a.team == "ABCDE12345")
        #expect(a.architectures == ["arm64", "x86_64"])
        #expect(a.products == [.init(path: "Applications/Notes Lite.app", kind: .application),
                               .init(path: "usr/local/bin/notes-tool", kind: .tool)])
        #expect(a.dsymCount == 2 && a.dsyms == ["Notes Lite.app.dSYM", "NotesKit.framework.dSYM"])
        #expect(a.profile == nil)      // the invented profile is not a CMS message, and reading it does not trap
        #expect(a.warnings.isEmpty && !a.truncated)
        #expect(a.headline == "Xcode archive — Notes Lite 3.1 (412)")
        #expect(a.facts.contains(.init("dSYMs", "2")))
    }

    @Test func warnsAboutMissingDSYMsAppAndInfo() throws {
        let s = try Scratch()
        let root = try Self.makeArchive(s, dsyms: false, info: Self.info(applicationPath: "Applications/Gone.app"))
        guard case .xcodeArchive(let a)? = AppleDevReader.read(directory: root) else { Issue.record("expected"); return }
        #expect(a.warnings.contains { $0.reason.contains("no dSYMs") })
        #expect(a.warnings.contains { $0.reason.contains("Gone.app") })

        let bare = try Self.makeArchive(s, name: "Bare.xcarchive", info: nil)
        guard case .xcodeArchive(let b)? = AppleDevReader.read(directory: bare) else { Issue.record("expected"); return }
        #expect(b.bundleIdentifier == nil && b.warnings.contains { $0.reason.contains("no Info.plist") })

        let damaged = try s.dir("Damaged.xcarchive")
        try s.file("Damaged.xcarchive/Info.plist", "<plist><dict><key>Name")
        guard case .xcodeArchive(let d)? = AppleDevReader.read(directory: damaged) else { Issue.record("expected"); return }
        #expect(d.warnings.contains { $0.reason.contains("damaged") } && d.warnings.contains { $0.reason.contains("no products") })
    }

    @Test func pathsInInfoPlistCannotLeaveTheArchive() throws {
        let s = try Scratch()
        try s.file("Elsewhere/embedded.mobileprovision", "outside")
        let root = try Self.makeArchive(s, info: Self.info(applicationPath: "../../Elsewhere"))
        guard case .xcodeArchive(let a)? = AppleDevReader.read(directory: root) else { Issue.record("expected"); return }
        #expect(a.profile == nil && a.warnings.contains { $0.reason.contains("Products does not hold it") })
        let folder = AppleDevFolder(root: root)
        if case .notAFile = folder.read(s.url.appendingPathComponent("Elsewhere/embedded.mobileprovision")) {} else {
            Issue.record("a file outside the root must be refused")
        }
    }

    @Test func sniffsAnArchiveFolderWithoutItsExtension() throws {
        let s = try Scratch()
        let root = try Self.makeArchive(s, name: "Build Output")
        guard case .xcodeArchive(let a)? = AppleDevReader.read(directory: root) else { Issue.record("should be sniffed"); return }
        #expect(a.dsymCount == 2)
    }
}

// MARK: - Routing

@Suite("Apple development routing")
struct AppleDevRoutingTests {
    @Test func documentForwardsHeadlineFactsAndWarnings() throws {
        let doc = try #require(read(StringCatalogTests.catalog, "Localizable.xcstrings"))
        #expect(doc.headline == "String Catalog — 7 keys in 3 languages")
        #expect(!doc.facts.isEmpty && doc.warnings.first?.level == .danger)
        #expect(AppleDevWarning.Level.caution < .danger)
    }

    @Test func unknownNamesAndEmptyInputGiveNil() {
        #expect(read("", "Localizable.xcstrings") == nil)
        #expect(read("just text", "notes.md") == nil)
        #expect(read("{\"a\":1}", "config.json") == nil)
        #expect(AppleDevReader.fileExtensions.contains("xcstrings") && AppleDevReader.directoryExtensions.contains("xcarchive"))
    }
}
