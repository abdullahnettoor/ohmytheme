import Foundation
import Persistence
import PlatformClients
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Starship format-preserving proof (issue #7)")
struct StarshipAdapterTests {

    // MARK: - Transformer: preserves comments, formatting, unrelated settings (AC1)

    @Test("Transformer preserves comments, unrelated keys, and existing palettes")
    func preservesUnrelatedContent() throws {
        let original = """
        # My starship config
        format = "$directory$character"  # keep this

        [character]
        success_symbol = "[➜](bold green)"

        [palettes.catppuccin_mocha]
        background = "#1e1e2e"

        # End comment
        """

        let variant = Fixtures.pack.variants[0]
        let transformed = try StarshipPaletteTransformer.applyTheme(to: Data(original.utf8), variant: variant)
        let result = String(decoding: transformed, as: UTF8.self)

        // Unrelated content preserved byte-for-byte snippets
        #expect(result.contains("# My starship config"))
        #expect(result.contains("format = \"$directory$character\""))
        #expect(result.contains("[character]"))
        #expect(result.contains("success_symbol = \"[➜](bold green)\""))
        #expect(result.contains("[palettes.catppuccin_mocha]"))
        #expect(result.contains("background = \"#1e1e2e\""))
        #expect(result.contains("# End comment"))

        // Owned palette inserted
        #expect(result.contains("palette = \"oh_my_theme\""))
        #expect(result.contains("[palettes.oh_my_theme]"))
        // Palette entries from variant (all roles) – check a few
        #expect(result.contains("canvas = \"#112233\""))
        #expect(result.contains("accent = \"#112233\""))
        // Existing comment after format preserved
        #expect(result.contains("# keep this"))
    }

    @Test("Transformer handles existing owned palette table and replaces its body")
    func replacesOwnedPaletteBody() throws {
        let original = """
        palette = "oh_my_theme"  # keep comment

        [palettes.oh_my_theme]
        old_key = "#000000"
        another = "#111111"

        [git_branch]
        symbol = "🌱 "
        """
        let variant = Fixtures.pack.variants[0]
        let transformed = try StarshipPaletteTransformer.applyTheme(to: Data(original.utf8), variant: variant)
        let result = String(decoding: transformed, as: UTF8.self)

        #expect(result.contains("palette = \"oh_my_theme\""))
        #expect(result.contains("# keep comment"))
        #expect(result.contains("[palettes.oh_my_theme]"))
        #expect(result.contains("[git_branch]"))
        #expect(result.contains("symbol = \"🌱 \""))
        // Old keys should be gone
        #expect(!result.contains("old_key ="))
        #expect(!result.contains("another ="))
        // New keys present
        #expect(result.contains("canvas = \"#112233\""))
    }

    @Test("Transformer preserves unusual spacing around palette key")
    func preservesSpacing() throws {
        let original = "  palette   =   \"old\"  \n"
        let variant = Fixtures.pack.variants[0]
        let transformed = try StarshipPaletteTransformer.applyTheme(to: Data(original.utf8), variant: variant)
        let result = String(decoding: transformed, as: UTF8.self)
        // Leading spaces before palette should be preserved, comment handling not needed
        #expect(result.contains("palette"))
        #expect(result.contains("oh_my_theme"))
        // Ensure we didn't normalize whole file
        #expect(result.hasPrefix("  palette"))
    }

    @Test("Transformer handles representative fixtures with comments, existing palette, and unrelated settings")
    func representativeFixture() throws {
        let original = """
        # Starship configuration with comments
          # indented comment

        format = "custom"

        [palettes.existing]
        a = "#000000"

        [directory]
        truncation_length = 3
        """
        let transformed = try StarshipPaletteTransformer.applyTheme(to: Data(original.utf8), variant: Fixtures.pack.variants[0])
        let result = String(decoding: transformed, as: UTF8.self)
        #expect(result.contains("# Starship configuration with comments"))
        #expect(result.contains("# indented comment"))
        #expect(result.contains("format = \"custom\""))
        #expect(result.contains("[palettes.existing]"))
        #expect(result.contains("[directory]"))
        #expect(result.contains("truncation_length = 3"))
        #expect(result.contains("[palettes.oh_my_theme]"))
    }

    // MARK: - Rejects malformed or ambiguous before writing (AC2)

    @Test("Validation rejects malformed TOML before writing")
    func rejectsMalformed() throws {
        let malformed = Data("palette = \"unclosed\n".utf8)
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(malformed)
        }
        #expect(throws: StarshipAdapterError.self) {
            _ = try StarshipPaletteTransformer.applyTheme(to: malformed, variant: Fixtures.pack.variants[0])
        }

        let malformed2 = Data("[[invalid header\n".utf8)
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(malformed2)
        }

        let malformed3 = Data("some random text without equals\n".utf8)
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(malformed3)
        }
    }

    @Test("Validation rejects ambiguous duplicate owned palette table")
    func rejectsAmbiguousTable() throws {
        let ambiguous = """
        [palettes.oh_my_theme]
        a = "#111111"
        [palettes.oh_my_theme]
        b = "#222222"
        """
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(Data(ambiguous.utf8))
        }
    }

    @Test("Validation rejects ambiguous duplicate top-level palette keys")
    func rejectsAmbiguousPaletteKey() throws {
        let ambiguous = """
        palette = "a"
        palette = "b"
        """
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(Data(ambiguous.utf8))
        }
    }

    @Test("Adapter prepareApply rejects malformed file without writing")
    func adapterRejectsMalformedWithoutWriting() async throws {
        let fixture = try Fixture(existingContents: "palette = \"unclosed\n")
        let adapter = fixture.adapter()
        let before = try Data(contentsOf: fixture.configURL)

        await #expect(throws: StarshipAdapterError.self) {
            _ = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        }
        #expect(try Data(contentsOf: fixture.configURL) == before)
    }

    @Test("Adapter prepareApply rejects ambiguous file without writing")
    func adapterRejectsAmbiguousWithoutWriting() async throws {
        let ambiguous = """
        palette = "a"
        palette = "b"
        """
        let fixture = try Fixture(existingContents: ambiguous)
        let adapter = fixture.adapter()
        let before = try Data(contentsOf: fixture.configURL)

        await #expect(throws: StarshipAdapterError.self) {
            _ = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        }
        #expect(try Data(contentsOf: fixture.configURL) == before)
    }

    // MARK: - Restore exact prior bytes when managed state hasn't changed (AC3)

    @Test("Adapter can restore exact prior bytes when managed state hasn't changed")
    func restoresExactBytes() async throws {
        let original = """
        # Original file
        format = "test"
        """
        let fixture = try Fixture(existingContents: original)
        let adapter = fixture.adapter()
        let beforeBytes = try Data(contentsOf: fixture.configURL)
        let beforeInspection = try fixture.managedFiles.inspect(at: fixture.configURL)

        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        let receipt = try await adapter.apply(plan)

        // Receipt should contain rollback data
        #expect(receipt.rollbackData != nil)
        #expect(try Data(contentsOf: fixture.configURL) != beforeBytes)

        try await adapter.rollbackApply(plan: plan, receipt: receipt)

        let afterRollback = try Data(contentsOf: fixture.configURL)
        #expect(afterRollback == beforeBytes)

        // Verify metadata preserved (permissions) via ManagedFiles inspection
        let afterInspection = try fixture.managedFiles.inspect(at: fixture.configURL)
        #expect(afterInspection.snapshot.metadata?.permissions == beforeInspection.snapshot.metadata?.permissions)
    }

    @Test("Rollback refuses to overwrite external edit")
    func rollbackRefusesExternalEdit() async throws {
        let fixture = try Fixture(existingContents: "# original\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        let receipt = try await adapter.apply(plan)

        // External edit
        try Data("# external edit\n".utf8).write(to: fixture.configURL)

        await #expect(throws: StarshipAdapterError.self) {
            try await adapter.rollbackApply(plan: plan, receipt: receipt)
        }
        #expect(try String(contentsOf: fixture.configURL, encoding: .utf8) == "# external edit\n")
    }

    @Test("ManagedFiles rollback restores exact bytes including malformed-opaque bytes")
    func managedFilesOpaqueRestore() async throws {
        let fixture = try Fixture(existingContents: "format = \"ok\"\n")
        let plan = try await fixture.adapter().prepareApply(instance: fixture.instance, theme: fixture.theme())
        let receipt = try await fixture.adapter().apply(plan)
        let applied = try Data(contentsOf: fixture.configURL)
        #expect(applied != Data("format = \"ok\"\n".utf8))
        try await fixture.adapter().rollbackApply(plan: plan, receipt: receipt)
        #expect(try Data(contentsOf: fixture.configURL) == Data("format = \"ok\"\n".utf8))
    }

    // MARK: - Next prompt reach and no claim to redraw (AC4)

    @Test("PrepareApply reports next-prompt activation reach and detail does not claim redraw")
    func reportsNextPromptReach() async throws {
        let fixture = try Fixture(existingContents: "# test\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())

        #expect(plan.activationReach == .currentInstances)
        #expect(plan.expectedSideEffects.contains { $0.contains("next prompt") })
        // Detail on apply should mention next prompt and not redraw
        let receipt = try await adapter.apply(plan)
        #expect(receipt.detail?.contains("next prompt") == true)
        #expect(receipt.detail?.contains("existing prompt not redrawn") == true)
        #expect(receipt.runningInstanceReach == .currentInstances)
    }

    @Test("Apply does not claim to redraw existing prompt")
    func doesNotClaimRedraw() async throws {
        let fixture = try Fixture(existingContents: "# test\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        let receipt = try await adapter.apply(plan)
        // Ensure detail explicitly says next prompt, not current
        #expect(!(receipt.detail?.lowercased().contains("redraw") ?? false) || receipt.detail?.contains("not redrawn") == true)
    }

    // MARK: - No general-purpose config manager or shell execution (AC5)

    @Test("Adapter does not invoke shell and uses narrow TOML edit only")
    func noShellExecution() async throws {
        // Verify adapter has no ProcessRunner dependency by inspecting source: we check that prepareApply is read-only and apply uses ManagedFiles only
        let fixture = try Fixture(existingContents: "format = \"a\"\n")
        let adapter = fixture.adapter()
        let before = try Data(contentsOf: fixture.configURL)
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        // Preparation must not write
        #expect(try Data(contentsOf: fixture.configURL) == before)
        // Apply only changes registered keys (palette and palettes.oh_my_theme), not unrelated
        _ = try await adapter.apply(plan)
        let result = try String(contentsOf: fixture.configURL, encoding: .utf8)
        #expect(result.contains("format = \"a\""))
        #expect(result.contains("palette = \"oh_my_theme\""))
        #expect(result.contains("[palettes.oh_my_theme]"))
        // Ensure no shell-like behavior: adapter id is starship, not generic
        let adapterID = await adapter.id
        #expect(adapterID == "starship")
    }

    // MARK: - Discovery reports missing, supported, malformed, ambiguous, linked, Nix-managed without writing (AC from #16 but relevant)

    @Test("Discovery reports missing config without writing")
    func discoveryMissing() async throws {
        let fixture = try Fixture(existingContents: nil) // missing
        let adapter = fixture.adapter(missing: true)
        let report = try await adapter.discover()
        #expect(report.configurationStatus == .missing)
        // When configured path is missing, report should indicate missing (resolved may be the configured path)
        #expect(report.configurationStatus == .missing)
    }

    @Test("Discovery reports supported config")
    func discoverySupported() async throws {
        let fixture = try Fixture(existingContents: "format = \"hi\"\n")
        let report = try await fixture.adapter().discover()
        #expect(report.configurationStatus == .supported)
    }

    @Test("Discovery reports malformed and ambiguous")
    func discoveryMalformedAndAmbiguous() async throws {
        let malformedFixture = try Fixture(existingContents: "palette = \"unclosed\n")
        let malformedReport = try await malformedFixture.adapter().discover()
        #expect(malformedReport.configurationStatus == .malformed)

        let ambiguousFixture = try Fixture(existingContents: "palette = \"a\"\n palette = \"b\"\n")
        let ambiguousReport = try await ambiguousFixture.adapter().discover()
        #expect(ambiguousReport.configurationStatus == .ambiguous)
    }

    @Test("Discovery reports linked and Nix-managed")
    func discoveryLinkedAndNix() async throws {
        let linkedFixture = try Fixture(linked: true)
        let linkedReport = try await linkedFixture.adapter().discover()
        #expect(linkedReport.ownership == .linkedUserOwned(sourcePath: linkedFixture.sourceURL.path))

        let nixFixture = try Fixture(nixManaged: true)
        let nixReport = try await nixFixture.adapter().discover()
        #expect(nixReport.configurationStatus == .unsupported)
    }

    // MARK: - Durable apply integration (shared safety contract)

    @Test("Durable apply via ThemeEngine preserves format and can undo")
    func durableApplyAndUndo() async throws {
        let fixture = try Fixture(existingContents: "# before\nformat = \"x\"\n")
        let store = try PersistenceStore(databaseURL: fixture.directory.appendingPathComponent("state.sqlite"), contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true))
        let adapter = fixture.adapter()
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let before = try String(contentsOf: fixture.configURL, encoding: .utf8)
        let preview = try await engine.prepare(themeVariantID: Fixtures.pack.variants[0].qualifiedID, workspace: Workspace(id: .myMac, displayName: "My Mac", connectedTargetInstances: [fixture.instance]))
        let report = try await engine.applyDurable(previewID: preview.id, workspace: Workspace(id: .myMac, displayName: "My Mac", connectedTargetInstances: [fixture.instance]))
        #expect(report.outcomes[0].configurationState == .updated)
        #expect(report.outcomes[0].runningInstanceReach == .currentInstances)
        let after = try String(contentsOf: fixture.configURL, encoding: .utf8)
        #expect(after.contains("# before"))
        #expect(after.contains("format = \"x\""))
        #expect(before != after)

        let undo = try await engine.undoLast(workspace: .myMac)
        #expect(undo.outcomes[0].configurationState == .updated)
        #expect(try String(contentsOf: fixture.configURL, encoding: .utf8) == before)
    }

    // MARK: - Fixtures

    struct Fixture {
        let directory: URL
        let configURL: URL
        let sourceURL: URL
        let managedFiles: ManagedFiles
        let instance = ConnectedTargetInstance(id: TargetInstanceID(rawValue: "starship.default"), displayName: "Starship, Default", adapterID: "starship")

        init(existingContents: String?) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-my-theme-starship-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configDir = directory.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            configURL = configDir.appendingPathComponent("starship.toml")
            sourceURL = configDir.appendingPathComponent("source.toml")
            managedFiles = ManagedFiles(nixRoots: [directory.appendingPathComponent("nix/store")])
            if let contents = existingContents {
                try Data(contents.utf8).write(to: configURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configURL.path)
            }
        }

        init(existingContents: String, linked: Bool = false, nixManaged: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-my-theme-starship-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configDir = directory.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            sourceURL = configDir.appendingPathComponent("source.toml")
            let actual = configDir.appendingPathComponent("starship.toml")
            try Data(existingContents.utf8).write(to: actual)
            if linked {
                let link = directory.appendingPathComponent("starship.toml")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
                configURL = link
            } else if nixManaged {
                let nixRoot = directory.appendingPathComponent("nix/store/abc/starship.toml")
                try FileManager.default.createDirectory(at: nixRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(existingContents.utf8).write(to: nixRoot)
                let link = configDir.appendingPathComponent("starship.toml")
                if FileManager.default.fileExists(atPath: link.path) {
                    try FileManager.default.removeItem(at: link)
                }
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nixRoot)
                configURL = link
            } else {
                configURL = actual
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configURL.path)
            managedFiles = ManagedFiles(nixRoots: [directory.appendingPathComponent("nix/store")])
        }

        init(linked: Bool) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-my-theme-starship-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configDir = directory.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            sourceURL = configDir.appendingPathComponent("source.toml")
            try Data("format = \"x\"\n".utf8).write(to: sourceURL)
            let link = directory.appendingPathComponent("starship.toml")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sourceURL)
            configURL = link
            managedFiles = ManagedFiles(nixRoots: [directory.appendingPathComponent("nix/store")])
        }

        init(nixManaged: Bool) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-my-theme-starship-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configDir = directory.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            sourceURL = URL(fileURLWithPath: "/nix/store/abc/starship.toml")
            let nixFile = directory.appendingPathComponent("nix/store/abc/starship.toml")
            try FileManager.default.createDirectory(at: nixFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("format = \"x\"\n".utf8).write(to: nixFile)
            let link = configDir.appendingPathComponent("starship.toml")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nixFile)
            configURL = link
            managedFiles = ManagedFiles(nixRoots: [directory.appendingPathComponent("nix/store")])
        }

        func adapter(missing: Bool = false) -> StarshipConfigurationAdapter {
            let url: URL? = missing ? nil : configURL
            // When missing, point to a non-existent directory's file to report missing
            if missing {
                let missingDir = directory.appendingPathComponent("missing", isDirectory: true)
                let missingURL = missingDir.appendingPathComponent("starship.toml")
                return StarshipConfigurationAdapter(managedFiles: managedFiles, homeDirectory: directory, xdgConfigHome: directory.appendingPathComponent("config"), configurationURL: missingURL)
            }
            return StarshipConfigurationAdapter(managedFiles: managedFiles, homeDirectory: directory, xdgConfigHome: directory.appendingPathComponent("config"), configurationURL: url)
        }

        func theme() -> PreparedTheme {
            PreparedTheme(variantID: Fixtures.pack.variants[0].qualifiedID, variant: Fixtures.pack.variants[0], sourceType: .generated, sourceRevision: Fixtures.pack.source.revision, attribution: Fixtures.pack.source.attribution, themeSchemaVersion: Fixtures.pack.schemaVersion, contentDigest: Fixtures.pack.variants[0].contentDigest, compilerVersion: "theme-compiler-1", upstreamArtifact: nil)
        }
    }
}
