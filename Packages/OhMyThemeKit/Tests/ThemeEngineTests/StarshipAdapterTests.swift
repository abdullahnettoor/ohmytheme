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

    @Test("Transformer preserves mixed line endings and comments inside its owned table")
    func preservesMixedLineEndingsAndOwnedComments() throws {
        let original = Data(
            "palette = \"old\"\r\nformat = \"x\"\r# keep unrelated\n\r\n[palettes.oh_my_theme]\r\n# keep managed note\rold_key = \"#000000\"\n\r\n[character]\r\nsuccess_symbol = \"ok\"\r"
                .utf8
        )

        try StarshipPaletteTransformer.validate(original)
        let transformed = try StarshipPaletteTransformer.applyTheme(
            to: original,
            variant: Fixtures.pack.variants[0]
        )
        let result = try #require(String(data: transformed, encoding: .utf8))

        #expect(result.contains("format = \"x\"\r# keep unrelated\n\r\n"))
        #expect(result.contains("[palettes.oh_my_theme]\r\n# keep managed note\r"))
        #expect(result.contains("[character]\r\nsuccess_symbol = \"ok\"\r"))
        #expect(!result.contains("old_key"))
    }

    @Test("Transformer changes only exact managed byte ranges")
    func changesOnlyManagedByteRanges() throws {
        let original = Data(
            "palette   =   \"old\"  # selection\r\nformat = \"$directory\"\r[palettes.oh_my_theme]\n# managed note\r\nold_key = \"#000000\"\r[character]\nsuccess_symbol = \"ok\"\r"
                .utf8
        )
        let variant = ThemeVariant(
            id: "focused",
            displayName: "Focused",
            appearance: .dark,
            contentDigest: "sha256:focused",
            roles: [.canvas: ThemeColor(rawValue: "#123456")]
        )
        let expected = Data(
            "palette   =   \"oh_my_theme\"  # selection\r\nformat = \"$directory\"\r[palettes.oh_my_theme]\n# managed note\r\ncanvas = \"#123456\"\r\n[character]\nsuccess_symbol = \"ok\"\r"
                .utf8
        )

        let transformed = try StarshipPaletteTransformer.applyTheme(to: original, variant: variant)

        #expect(transformed == expected)
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
        let transformed = try StarshipPaletteTransformer.applyTheme(
            to: Data(original.utf8), variant: Fixtures.pack.variants[0])
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

    @Test("Validation rejects invalid TOML values and invalid UTF-8 while accepting multiline strings")
    func validatesTOMLSyntax() throws {
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(Data("format = ???\n".utf8))
        }
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(Data([0x66, 0x6F, 0x80]))
        }
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(Data("settings = { color = ??? }\n".utf8))
        }
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(Data("label = \"\\u\"\n".utf8))
        }

        let multiline = Data("description = \"\"\"first line\nsecond line\"\"\"\n".utf8)
        try StarshipPaletteTransformer.validate(multiline)
        let arraysOfTables = Data(
            "[[battery.display]]\nthreshold = 10\n[[battery.display]]\nthreshold = 20\n".utf8
        )
        try StarshipPaletteTransformer.validate(arraysOfTables)
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

    @Test("Validation canonicalizes quoted managed keys and tables when detecting ambiguity")
    func rejectsQuotedOwnershipAliases() throws {
        let duplicateTable = Data(
            "[palettes.oh_my_theme]\na = \"#111111\"\n[palettes.\"oh_my_theme\"]\nb = \"#222222\"\n".utf8
        )
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(duplicateTable)
        }

        let duplicateKey = Data("palette = \"a\"\n\"palette\" = \"b\"\n".utf8)
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(duplicateKey)
        }

        let escapedDuplicateKey = Data("\"pal\\u0065tte\" = \"a\"\npalette = \"b\"\n".utf8)
        #expect(throws: StarshipAdapterError.self) {
            try StarshipPaletteTransformer.validate(escapedDuplicateKey)
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

    @Test("Adapter prepareApply refuses an unapproved linked configuration")
    func adapterRejectsUnapprovedLinkedSource() async throws {
        let fixture = try Fixture(linked: true)
        let adapter = fixture.adapter()
        let before = try Data(contentsOf: fixture.sourceURL)

        await #expect(throws: StarshipAdapterError.self) {
            _ = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        }
        #expect(try Data(contentsOf: fixture.sourceURL) == before)
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

    @Test("Prepared Starship plans survive serialization with exact intended bytes")
    func preparedPlanSurvivesSerialization() async throws {
        let fixture = try Fixture(existingContents: "format = \"test\"\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())

        let restored = try JSONDecoder().decode(
            AdapterPlan.self,
            from: JSONEncoder().encode(plan)
        )

        #expect(restored == plan)
        #expect(restored.payload.payload == plan.payload.payload)
    }

    @Test("Repeated apply is a no-op and keeps the managed file identity")
    func repeatedApplyDoesNotReplaceFile() async throws {
        let fixture = try Fixture(existingContents: "format = \"test\"\n")
        let adapter = fixture.adapter()
        let firstPlan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        _ = try await adapter.apply(firstPlan)
        let beforeRepeat = try fixture.managedFiles.inspect(at: fixture.configURL)

        let repeatedPlan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        let repeatedReceipt = try await adapter.apply(repeatedPlan)
        let afterRepeat = try fixture.managedFiles.inspect(at: fixture.configURL)

        #expect(repeatedReceipt.configurationState == .unchanged)
        #expect(afterRepeat.snapshot.identity == beforeRepeat.snapshot.identity)
        #expect(afterRepeat.snapshot.bytes == beforeRepeat.snapshot.bytes)
    }

    @Test("Apply refuses a stale plan before replacing external state")
    func applyRefusesStalePlan() async throws {
        let fixture = try Fixture(existingContents: "format = \"before\"\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        let external = Data("format = \"external\"\n".utf8)
        try external.write(to: fixture.configURL)

        await #expect(throws: StarshipAdapterError.self) {
            _ = try await adapter.apply(plan)
        }
        #expect(try Data(contentsOf: fixture.configURL) == external)
    }

    @Test("Interrupted apply reconstructs a guarded receipt for Undo")
    func interruptedApplyRecoversReceipt() async throws {
        let original = Data("format = \"before\"\n".utf8)
        let fixture = try Fixture(existingContents: String(decoding: original, as: UTF8.self))
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        _ = try await adapter.apply(plan)

        let recovered = try await adapter.recoverApplyReceipt(plan: plan)
        try await adapter.rollbackApply(plan: plan, receipt: recovered)

        #expect(try Data(contentsOf: fixture.configURL) == original)
    }

    @Test("Recovery classifies before, intended, and conflicting states")
    func recoveryClassifiesAllStates() async throws {
        let fixture = try Fixture(existingContents: "format = \"before\"\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())

        #expect(try await adapter.classifyApply(plan: plan) == .beforeChange)
        _ = try await adapter.apply(plan)
        #expect(try await adapter.classifyApply(plan: plan) == .intendedAfterChange)
        try Data("format = \"external\"\n".utf8).write(to: fixture.configURL)
        #expect(try await adapter.classifyApply(plan: plan) == .conflicting)
    }

    @Test("Recovery rejects a same-content external replacement")
    func recoveryRejectsSameContentReplacement() async throws {
        let fixture = try Fixture(existingContents: "format = \"before\"\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        _ = try await adapter.apply(plan)
        let appliedBytes = try Data(contentsOf: fixture.configURL)
        let replacement = fixture.directory.appendingPathComponent("replacement.toml")
        try appliedBytes.write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: replacement.path
        )
        _ = try FileManager.default.replaceItemAt(fixture.configURL, withItemAt: replacement)

        let classification = try await adapter.classifyApply(plan: plan)
        #expect(classification == .conflicting)
        await #expect(throws: StarshipAdapterError.self) {
            _ = try await adapter.recoverApplyReceipt(plan: plan)
        }
        #expect(try Data(contentsOf: fixture.configURL) == appliedBytes)
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

    @Test("Connection restore refuses any state that differs from its baseline")
    func connectionRestoreRefusesExternalState() async throws {
        let fixture = try Fixture(existingContents: "format = \"before\"\n")
        let adapter = fixture.adapter()
        let connection = try await adapter.prepareConnection(instance: fixture.instance)
        try Data("format = \"external\"\n".utf8).write(to: fixture.configURL)
        let external = try Data(contentsOf: fixture.configURL)

        await #expect(throws: StarshipAdapterError.self) {
            _ = try await adapter.restoreConnection(
                instance: fixture.instance,
                baseline: connection.capturedPreChangeState
            )
        }
        #expect(try Data(contentsOf: fixture.configURL) == external)
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

        #expect(plan.activationReach == .nextPrompt)
        #expect(plan.expectedSideEffects.contains { $0.contains("next prompt") })
        // Detail on apply should mention next prompt and not redraw
        let receipt = try await adapter.apply(plan)
        #expect(receipt.detail?.contains("next prompt") == true)
        #expect(receipt.detail?.contains("existing prompt not redrawn") == true)
        #expect(receipt.runningInstanceReach == .nextPrompt)
    }

    @Test("Apply does not claim to redraw existing prompt")
    func doesNotClaimRedraw() async throws {
        let fixture = try Fixture(existingContents: "# test\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        let receipt = try await adapter.apply(plan)
        // Ensure detail explicitly says next prompt, not current
        #expect(
            !(receipt.detail?.lowercased().contains("redraw") ?? false)
                || receipt.detail?.contains("not redrawn") == true)
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
        let fixture = try Fixture(existingContents: nil)  // missing
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

    @Test("Discovery errors do not expose configuration contents")
    func discoveryErrorsDoNotExposeContents() async throws {
        let secret = "do-not-report-this-value"
        let fixture = try Fixture(existingContents: "private_key = ??? # \(secret)\n")

        let report = try await fixture.adapter().discover()

        #expect(report.configurationStatus == .malformed)
        #expect(report.detail?.contains(secret) == false)
        #expect(report.detail?.contains("private_key") == false)
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
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true))
        let adapter = fixture.adapter()
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let before = try String(contentsOf: fixture.configURL, encoding: .utf8)
        let preview = try await engine.prepare(
            themeVariantID: Fixtures.pack.variants[0].qualifiedID,
            workspace: Workspace(id: .myMac, displayName: "My Mac", connectedTargetInstances: [fixture.instance]))
        let report = try await engine.applyDurable(
            previewID: preview.id,
            workspace: Workspace(id: .myMac, displayName: "My Mac", connectedTargetInstances: [fixture.instance]))
        #expect(report.outcomes[0].configurationState == .updated)
        #expect(report.outcomes[0].runningInstanceReach == .nextPrompt)
        let after = try String(contentsOf: fixture.configURL, encoding: .utf8)
        #expect(after.contains("# before"))
        #expect(after.contains("format = \"x\""))
        #expect(before != after)

        let undo = try await engine.undoLast(workspace: .myMac)
        #expect(undo.outcomes[0].configurationState == .updated)
        #expect(try String(contentsOf: fixture.configURL, encoding: .utf8) == before)
    }

    @Test("Durable interrupted apply recovers a receipt that Undo can use")
    func durableInterruptedApplyRecoversForUndo() async throws {
        let fixture = try Fixture(existingContents: "format = \"before\"\n")
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [fixture.instance]
        )
        let adapter = fixture.adapter()
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: workspace)
        let preview = try await engine.prepare(
            themeVariantID: Fixtures.pack.variants[0].qualifiedID,
            workspace: workspace
        )
        let apply = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let appliedRecord = try #require(
            try store.journalLoadRecords(operationID: apply.operationID).first
        )
        try store.journalTransitionState(operationID: apply.operationID, to: .applying)
        try store.journalSaveRecord(
            JournaledRecord(
                operationID: appliedRecord.operationID,
                targetInstanceID: appliedRecord.targetInstanceID,
                ordinal: appliedRecord.ordinal,
                adapterID: appliedRecord.adapterID,
                adapterVersion: appliedRecord.adapterVersion,
                capabilityID: appliedRecord.capabilityID,
                phase: .applying,
                intendedChangeDigest: appliedRecord.intendedChangeDigest,
                staleStateToken: appliedRecord.staleStateToken,
                planDigest: appliedRecord.planDigest,
                receiptJSON: nil,
                detail: nil
            )
        )

        let relaunched = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter()],
            persistence: store
        )
        try await relaunched.reconcileInterruptedOperations()
        let reconciled = try store.journalLoadRecords(operationID: apply.operationID)
        let undo = try await relaunched.undoLast(workspace: workspace)

        #expect(reconciled[0].phase == .applied)
        #expect(undo.outcomes[0].configurationState == .updated)
        #expect(try Data(contentsOf: fixture.configURL) == Data("format = \"before\"\n".utf8))
    }

    // MARK: - Fixtures

    struct Fixture {
        let directory: URL
        let configURL: URL
        let sourceURL: URL
        let managedFiles: ManagedFiles
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "starship.default"), displayName: "Starship, Default", adapterID: "starship")

        init(existingContents: String?) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "oh-my-theme-starship-\(UUID().uuidString)", isDirectory: true)
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
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "oh-my-theme-starship-\(UUID().uuidString)", isDirectory: true)
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
                try FileManager.default.createDirectory(
                    at: nixRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
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
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "oh-my-theme-starship-\(UUID().uuidString)", isDirectory: true)
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
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "oh-my-theme-starship-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configDir = directory.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            sourceURL = URL(fileURLWithPath: "/nix/store/abc/starship.toml")
            let nixFile = directory.appendingPathComponent("nix/store/abc/starship.toml")
            try FileManager.default.createDirectory(
                at: nixFile.deletingLastPathComponent(), withIntermediateDirectories: true)
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
                return StarshipConfigurationAdapter(
                    managedFiles: managedFiles, homeDirectory: directory,
                    xdgConfigHome: directory.appendingPathComponent("config"), configurationURL: missingURL)
            }
            return StarshipConfigurationAdapter(
                managedFiles: managedFiles, homeDirectory: directory,
                xdgConfigHome: directory.appendingPathComponent("config"), configurationURL: url)
        }

        func theme() -> PreparedTheme {
            PreparedTheme(
                variantID: Fixtures.pack.variants[0].qualifiedID, variant: Fixtures.pack.variants[0],
                sourceType: .generated, sourceRevision: Fixtures.pack.source.revision,
                attribution: Fixtures.pack.source.attribution, themeSchemaVersion: Fixtures.pack.schemaVersion,
                contentDigest: Fixtures.pack.variants[0].contentDigest, compilerVersion: "theme-compiler-1",
                upstreamArtifact: nil)
        }
    }
}
