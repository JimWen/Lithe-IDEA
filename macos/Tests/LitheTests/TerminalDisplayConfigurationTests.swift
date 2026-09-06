import AppKit
import LitheTerminalModule
import Testing
@testable import Lithe

@Suite("Terminal display configuration", .serialized)
@MainActor
struct TerminalDisplayConfigurationTests {
    @Test
    func fontCatalogLoadsOnlyWhenRequestedAndRefreshesExplicitly() {
        let catalog = DisplayTestFontCatalog()
        let settings = AppSettings(store: TerminalConfigurationTestStore(),
                                   logDirectoryProvider: TestLogDirectoryProvider(), terminalFontCatalog: catalog)
        #expect(catalog.readCount == 0)
        settings.terminalDisplayConfiguration.fontSize = 20
        settings.terminalDisplayConfiguration.fontName = "FixtureMissing"
        #expect(catalog.readCount == 0)
        #expect(settings.terminalFontAvailabilityDiagnostic == nil)
        settings.loadTerminalFontsIfNeeded()
        settings.loadTerminalFontsIfNeeded()
        #expect(catalog.readCount == 1)
        #expect(settings.terminalFonts.map(\.id) == ["FixtureMono-Regular"])
        #expect(settings.terminalFontAvailabilityDiagnostic != nil)
        #expect(settings.terminalDisplayConfiguration.fontName == "FixtureMissing")
        catalog.fonts.append(.init(id: "FixtureMissing", displayName: "Newly installed", isMonospaced: true))
        settings.refreshTerminalFonts()
        #expect(catalog.readCount == 2)
        #expect(settings.terminalFontAvailabilityDiagnostic == nil)
    }

    @Test
    func rejectsNonfiniteSizesAndInvalidFontLists() throws {
        let defaults = TerminalDisplayConfiguration()
        #expect(try JSONDecoder().decode(TerminalDisplayConfiguration.self, from: Data("{}".utf8)) == defaults)
        for size in [Double.nan, .infinity, -.infinity, 7, 49] {
            var value = defaults; value.fontSize = size
            #expect(value.validationMessage != nil)
        }
        for spacing in [Double.nan, .infinity, 0.9, 2.1] {
            var value = defaults; value.lineSpacing = spacing
            #expect(value.validationMessage != nil)
        }
        for names in [[""], ["font\0name"], [String(repeating: "x", count: 257)], ["A", "A"], (0..<9).map { "Font\($0)" }] {
            var value = defaults; value.fallbackFontNames = names
            #expect(value.validationMessage != nil)
        }
        var duplicate = defaults; duplicate.fontName = "A"; duplicate.fallbackFontNames = ["A"]
        #expect(duplicate.validationMessage != nil)
        for size in [8.0, 48.0] {
            var valid = defaults; valid.fontSize = size; valid.lineSpacing = 2
            #expect(valid.validationMessage == nil)
        }
    }

    @Test
    func displayPersistenceIsIndependentAndCorruptPayloadsRemainRecoverable() {
        let store = TerminalConfigurationTestStore()
        let settings = AppSettings(store: store)
        settings.terminalConfiguration.arguments = ["literal shell snapshot"]
        let shellBytes = store.data(forKey: "settings.terminalConfiguration")
        settings.terminalDisplayConfiguration.fontName = "FixtureMono-Regular"
        settings.terminalDisplayConfiguration.fontSize = 19
        settings.terminalDisplayConfiguration.fallbackFontNames = ["FixtureSymbols", "FixtureCJK"]
        #expect(AppSettings(store: store).terminalDisplayConfiguration == settings.terminalDisplayConfiguration)
        #expect(store.data(forKey: "settings.terminalConfiguration") == shellBytes)
        for data in [Data("bad JSON".utf8), Data(#"{"version":99,"configuration":{}}"#.utf8),
                     Data(#"{"version":1,"configuration":{"fontSize":999}}"#.utf8)] {
            store.set(data, forKey: "settings.terminalDisplayConfiguration")
            let restored = AppSettings(store: store)
            #expect(restored.terminalDisplayConfiguration == TerminalDisplayConfiguration())
            #expect(restored.terminalDisplayConfigurationLoadError != nil)
            #expect(restored.terminalConfigurationLoadError == nil)
            #expect(store.data(forKey: "settings.terminalDisplayConfiguration") == data)
            restored.terminalDisplayConfiguration.fontSize = 16
            #expect(restored.terminalDisplayConfigurationLoadError == nil)
            #expect(AppSettings(store: store).terminalDisplayConfiguration.fontSize == 16)
        }
        settings.restoreDefaults()
        #expect(settings.terminalDisplayConfiguration == TerminalDisplayConfiguration())
    }

    @Test
    func allSessionKindsApplyDisplayBeforeLaunchAndRetryWithoutStopping() throws {
        var transports: [ConfigurationTestTransport] = []
        let feature = TerminalFeatureModel(terminalFactory: {
            let transport = ConfigurationTestTransport(); transports.append(transport); return transport
        })
        defer { feature.stopAllSessions() }
        var display = TerminalDisplayConfiguration(); display.fontSize = 18
        feature.applyDisplayConfiguration(display)
        let root = URL(fileURLWithPath: "/fixture/project")
        _ = feature.createSession(in: root)
        _ = feature.createSession(configuration: .init(), context: .init(projectURL: root))
        _ = try feature.createProcessSession(.init(title: "Run", executablePath: "/fixture/tool", arguments: [], workingDirectory: root.path))
        for transport in transports {
            #expect(transport.displayConfigurations == [display])
            #expect(transport.lifecycleEvents.first == "display")
            #expect(transport.lifecycleEvents.last == "start")
        }
        let sessions = feature.terminalSessions.map(\.id)
        let launchCounts = transports.map { $0.launches.count }
        let stopCounts = transports.map { $0.lifecycleEvents.filter { $0 == "stop" }.count }
        transports[0].displayDiagnostics = ["Font unavailable"]
        display.lineSpacing = 1.4
        feature.applyDisplayConfiguration(display)
        #expect(feature.displayDiagnostics == ["Font unavailable"])
        #expect(feature.terminalSessions.allSatisfy { $0.isRunning && $0.lastError == nil })
        #expect(feature.terminalSessions.map(\.id) == sessions)
        #expect(transports.map { $0.launches.count } == launchCounts)
        #expect(transports.map { $0.lifecycleEvents.filter { $0 == "stop" }.count } == stopCounts)
        transports[0].displayDiagnostics = []
        feature.applyDisplayConfiguration(display)
        #expect(feature.displayDiagnostics.isEmpty)
        #expect(transports.allSatisfy { $0.displayConfigurations.last == display })
        feature.terminalSessions[0].restart()
        #expect(transports[0].launches.count == launchCounts[0] + 1)
        #expect(transports[0].displayConfigurations.last == display)
    }

    @Test
    func nativeFontFailureKeepsAtomicTypographyAndValidRecoveryUpdatesIt() throws {
        let transport = MacTerminalTransport()
        defer { transport.stop() }
        transport.view.setFrameSize(NSSize(width: 800, height: 480))
        var display = TerminalDisplayConfiguration()
        display.fontName = try #require(NSFont(name: "Menlo", size: 15)).fontName
        display.fontSize = 15; display.lineSpacing = 1.2
        display.fallbackFontNames = [try #require(NSFont(name: "Apple Color Emoji", size: 15)).fontName]
        #expect(transport.applyDisplayConfiguration(display).isEmpty)
        let view = transport.nativeView
        let terminal = transport.view.getTerminal()
        let font = transport.view.font
        #expect(font.pointSize == 15)
        #expect(transport.view.lineSpacing == 1.2)
        let cascade = try #require(font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        #expect(cascade.compactMap(\.postscriptName) == display.fallbackFontNames)
        var unavailable = display
        unavailable.fallbackFontNames = ["LitheFixtureMissingFont-7C5F"]
        unavailable.fontSize = 21; unavailable.lineSpacing = 1.5
        #expect(!transport.applyDisplayConfiguration(unavailable).isEmpty)
        #expect(transport.view.font == font)
        #expect(transport.view.lineSpacing == 1.2)
        unavailable.fallbackFontNames = []
        #expect(transport.applyDisplayConfiguration(unavailable).isEmpty)
        #expect(transport.view.font.pointSize == 21)
        #expect(transport.view.lineSpacing == 1.5)
        // Keep the AnyObject identity expression outside the Testing macro:
        // Swift 6.2's SIL reabstraction can assert while lowering that macro.
        let sameSurface = transport.nativeView === view
        #expect(sameSurface)
        #expect(transport.view.getTerminal() === terminal)
    }
}

@MainActor
private final class DisplayTestFontCatalog: TerminalFontCatalogProviding {
    var readCount = 0
    var fonts = [TerminalFontChoice(id: "FixtureMono-Regular", displayName: "Fixture Mono", isMonospaced: true)]
    func availableFonts() -> [TerminalFontChoice] {
        readCount += 1
        return fonts
    }
}
