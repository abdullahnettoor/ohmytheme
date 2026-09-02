import Foundation
import Testing

@testable import ThemeCompiler

@Suite("Theme pack validation")
struct ThemeCompilerTests {
    @Test("A complete trusted pack decodes into its qualified Theme Variant")
    func completeTrustedPackDecodes() throws {
        let pack = try ThemePackCompiler().decodePack(Data(validPack.utf8))

        #expect(pack.id == "catppuccin")
        #expect(pack.variants.map(\.qualifiedID) == ["catppuccin/mocha"])
    }

    @Test("Validation rejects unsupported schema, incomplete roles, malformed colors, and digest drift")
    func validationRejectsInvalidPackData() {
        let compiler = ThemePackCompiler()

        #expect(throws: ThemePackValidationError.unsupportedSchema(2)) {
            try compiler.decodePack(
                Data(validPack.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2").utf8))
        }
        #expect(throws: ThemePackValidationError.missingSemanticRoles(["syntax-string"])) {
            try compiler.decodePack(
                Data(
                    validPack.replacingOccurrences(
                        of: ",\n        \"syntax-string\": \"#a6e3a1\"",
                        with: ""
                    ).utf8
                )
            )
        }
        #expect(throws: ThemePackValidationError.malformedColor("#abc")) {
            try compiler.decodePack(Data(validPack.replacingOccurrences(of: "#1e1e2e", with: "#abc").utf8))
        }
        #expect(throws: ThemePackValidationError.forbiddenAlpha("#1e1e2eff")) {
            try compiler.decodePack(Data(validPack.replacingOccurrences(of: "#1e1e2e", with: "#1e1e2eff").utf8))
        }
        #expect(throws: ThemePackValidationError.contentDigestMismatch("catppuccin/mocha")) {
            try compiler.decodePack(
                Data(
                    validPack.replacingOccurrences(
                        of: "b8320c15be4b668fa55eb1908fd5ba7c653a76e13a2a4b9c068cb35f6c6ff62b",
                        with: "0000000000000000000000000000000000000000000000000000000000000000"
                    ).utf8))
        }
    }

    @Test("Validation rejects an empty pack and duplicate pack identifiers")
    func validationRejectsEmptyAndDuplicatePacks() throws {
        let compiler = ThemePackCompiler()
        var emptyPackObject = try #require(
            JSONSerialization.jsonObject(with: Data(validPack.utf8)) as? [String: Any]
        )
        emptyPackObject["variants"] = []
        let emptyPack = try JSONSerialization.data(withJSONObject: emptyPackObject)
        #expect(throws: ThemePackValidationError.emptyVariants("catppuccin")) {
            try compiler.decodePack(emptyPack)
        }

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(validPack.utf8).write(to: directory.appending(path: "one.json"))
        try Data(validPack.utf8).write(to: directory.appending(path: "two.json"))

        #expect(throws: ThemePackValidationError.duplicatePackIdentifier("catppuccin")) {
            try compiler.loadPacks(at: directory)
        }
    }

    @Test("The committed catalog is the deterministic output of the bundled Theme Packs")
    func bundledCatalogMatchesGoldenOutput() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compiler = ThemePackCompiler()

        let generated = try compiler.renderCatalog(
            for: compiler.loadPacks(at: repositoryRoot.appending(path: "Themes/Packs"))
        )
        let expected = try Data(contentsOf: repositoryRoot.appending(path: "Themes/catalog.json"))

        #expect(generated == expected)
    }
}

private let validPack = """
    {
      "schemaVersion": 1,
      "id": "catppuccin",
      "displayName": "Catppuccin",
      "author": "Catppuccin",
      "source": {
        "type": "upstream",
        "url": "https://github.com/catppuccin/palette",
        "revision": "4e2f5d6c10b94bda1fc1a1ed8d5ac5b6f5e42d3b",
        "license": "MIT",
        "attribution": "Catppuccin contributors"
      },
      "variants": [
        {
          "id": "mocha",
          "displayName": "Mocha",
          "appearance": "dark",
          "contentDigest": "sha256:b8320c15be4b668fa55eb1908fd5ba7c653a76e13a2a4b9c068cb35f6c6ff62b",
          "roles": {
            "canvas": "#1e1e2e",
            "primary-text": "#cdd6f4",
            "secondary-text": "#bac2de",
            "surface": "#313244",
            "overlay": "#6c7086",
            "selection": "#45475a",
            "accent": "#89b4fa",
            "ansi-black": "#45475a",
            "ansi-red": "#f38ba8",
            "ansi-green": "#a6e3a1",
            "ansi-yellow": "#f9e2af",
            "ansi-blue": "#89b4fa",
            "ansi-magenta": "#cba6f7",
            "ansi-cyan": "#89dceb",
            "ansi-white": "#bac2de",
            "syntax-comment": "#6c7086",
            "syntax-keyword": "#cba6f7",
            "syntax-string": "#a6e3a1"
          }
        }
      ]
    }
    """
