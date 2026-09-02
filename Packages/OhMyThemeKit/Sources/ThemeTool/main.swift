import Foundation
import ThemeCompiler

do {
    try run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}

private func run(arguments: [String]) throws {
    let compiler = ThemePackCompiler()
    guard let command = arguments.first else { throw ThemeToolError.usage }

    switch command {
    case "validate":
        let paths = arguments.dropFirst()
        guard !paths.isEmpty else { throw ThemeToolError.usage }
        let packs = try paths.map { try compiler.loadPack(at: URL(fileURLWithPath: $0)) }
        try compiler.validateCatalog(packs)
    case "catalog":
        guard arguments.count == 3 else { throw ThemeToolError.usage }
        let packs = try compiler.loadPacks(at: URL(fileURLWithPath: arguments[1]))
        try compiler.renderCatalog(for: packs).write(
            to: URL(fileURLWithPath: arguments[2]),
            options: .atomic
        )
    default:
        throw ThemeToolError.usage
    }
}

private enum ThemeToolError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: ThemeTool validate <pack.json>... | ThemeTool catalog <packs-directory> <output.json>"
    }
}
