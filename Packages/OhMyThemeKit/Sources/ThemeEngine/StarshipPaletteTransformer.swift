import Foundation
import ThemeModel

public enum StarshipPaletteTransformer {
    public static let ownedPaletteName = "oh_my_theme"
    public static let ownedPaletteTable = "palettes.oh_my_theme"
    public static let topLevelPaletteKey = "palette"

    public static func paletteEntries(for variant: ThemeVariant) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: variant.roles.map { role, color in
                (role.rawValue.replacingOccurrences(of: "-", with: "_"), color.rawValue)
            }
        )
    }

    public static func validate(_ bytes: Data) throws {
        _ = try StarshipTOMLDocument(bytes: bytes)
    }

    public static func applyTheme(to bytes: Data, variant: ThemeVariant) throws -> Data {
        var document = try StarshipTOMLDocument(bytes: bytes)
        try document.selectPalette(ownedPaletteName)
        document = try StarshipTOMLDocument(bytes: document.renderedData)
        try document.replaceOwnedPalette(entries: paletteEntries(for: variant))
        return document.renderedData
    }
}

private struct StarshipTOMLDocument {
    private struct Line: Equatable {
        var content: String
        var terminator: String
    }

    private struct Assignment {
        let tablePath: [String]
        let keyPath: [String]
        let startLine: Int
        let endLine: Int
        let valueStartColumn: Int?
        let valueEndColumn: Int?
    }

    private struct Table {
        let path: [String]
        let line: Int
    }

    private struct ArrayContext: Hashable {
        let path: [String]
        let occurrence: Int
    }

    private struct TableIdentity: Hashable {
        let path: [String]
        let arrayContext: ArrayContext?
    }

    private struct AssignmentIdentity: Hashable {
        let tablePath: [String]
        let arrayContext: ArrayContext?
        let keyPath: [String]
    }

    private var lines: [Line]
    private var assignments: [Assignment]
    private var tables: [Table]
    private let preferredTerminator: String

    init(bytes: Data) throws {
        guard let text = String(data: bytes, encoding: .utf8),
            !text.unicodeScalars.contains(where: Self.isForbiddenRawControl)
        else {
            throw StarshipAdapterError.malformedConfiguration(
                "configuration is not valid UTF-8 or contains a forbidden control character"
            )
        }
        lines = Self.splitLines(text)
        preferredTerminator = lines.lazy.map(\.terminator).first(where: { !$0.isEmpty }) ?? "\n"
        assignments = []
        tables = []
        try parse()
    }

    var renderedData: Data {
        Data(lines.map { $0.content + $0.terminator }.joined().utf8)
    }

    mutating func selectPalette(_ name: String) throws {
        let matches = assignments.filter { $0.tablePath.isEmpty && $0.keyPath == ["palette"] }
        guard matches.count <= 1 else {
            throw StarshipAdapterError.ambiguousConfiguration("multiple top-level palette assignments")
        }
        if let assignment = matches.first {
            guard let start = assignment.valueStartColumn,
                let end = assignment.valueEndColumn
            else {
                throw StarshipAdapterError.ambiguousConfiguration(
                    "top-level palette assignment has no replaceable value"
                )
            }
            if assignment.startLine == assignment.endLine {
                replaceValue(on: assignment.startLine, from: start, to: end, with: Self.quoted(name))
            } else {
                let firstLine = lines[assignment.startLine].content
                let lastLine = lines[assignment.endLine]
                let startIndex = firstLine.index(firstLine.startIndex, offsetBy: start)
                let endIndex = lastLine.content.index(lastLine.content.startIndex, offsetBy: end)
                lines.replaceSubrange(
                    assignment.startLine...assignment.endLine,
                    with: [
                        Line(
                            content: String(firstLine[..<startIndex]) + Self.quoted(name)
                                + String(lastLine.content[endIndex...]),
                            terminator: lastLine.terminator
                        )
                    ]
                )
            }
            return
        }

        let namespaceOccupied =
            tables.contains { $0.path.first == StarshipPaletteTransformer.topLevelPaletteKey }
            || assignments.contains {
                ($0.tablePath + $0.keyPath).first == StarshipPaletteTransformer.topLevelPaletteKey
            }
        guard !namespaceOccupied else {
            throw StarshipAdapterError.ambiguousConfiguration(
                "the top-level palette key conflicts with an existing TOML namespace"
            )
        }

        let insertion = tables.first?.line ?? lines.count
        insertTopLevelPalette(Self.quoted(name), at: insertion)
    }

    mutating func replaceOwnedPalette(entries: [String: String]) throws {
        let path = ["palettes", StarshipPaletteTransformer.ownedPaletteName]
        let ownedTables = tables.filter { $0.path == path }
        guard ownedTables.count <= 1 else {
            throw StarshipAdapterError.ambiguousConfiguration(
                "multiple \(StarshipPaletteTransformer.ownedPaletteTable) tables"
            )
        }
        guard let table = ownedTables.first else {
            appendOwnedPalette(entries: entries)
            return
        }

        let nextTableLine = tables.lazy.map(\.line).first(where: { $0 > table.line }) ?? lines.count
        let tableAssignments = assignments.filter {
            $0.tablePath == path && $0.startLine > table.line && $0.startLine < nextTableLine
        }
        let assignmentByStart = Dictionary(uniqueKeysWithValues: tableAssignments.map { ($0.startLine, $0) })
        var found: Set<String> = []
        var body: [Line] = []
        var lineIndex = table.line + 1

        while lineIndex < nextTableLine {
            guard let assignment = assignmentByStart[lineIndex] else {
                body.append(lines[lineIndex])
                lineIndex += 1
                continue
            }
            let key = assignment.keyPath.count == 1 ? assignment.keyPath[0] : nil
            if let key, let color = entries[key] {
                found.insert(key)
                if assignment.startLine == assignment.endLine,
                    let start = assignment.valueStartColumn,
                    let end = assignment.valueEndColumn
                {
                    var line = lines[assignment.startLine]
                    line.content = Self.replacingCharacters(
                        in: line.content,
                        from: start,
                        to: end,
                        with: Self.quoted(color)
                    )
                    body.append(line)
                } else if let start = assignment.valueStartColumn,
                    let end = assignment.valueEndColumn
                {
                    let firstLine = lines[assignment.startLine].content
                    let lastLine = lines[assignment.endLine]
                    let startIndex = firstLine.index(firstLine.startIndex, offsetBy: start)
                    let endIndex = lastLine.content.index(lastLine.content.startIndex, offsetBy: end)
                    body.append(
                        Line(
                            content: String(firstLine[..<startIndex]) + Self.quoted(color)
                                + String(lastLine.content[endIndex...]),
                            terminator: lastLine.terminator.isEmpty
                                ? preferredTerminator
                                : lastLine.terminator
                        )
                    )
                }
            }
            lineIndex = assignment.endLine + 1
        }

        let missing = entries.keys.filter { !found.contains($0) }.sorted()
        if !missing.isEmpty {
            if let last = body.indices.last, body[last].terminator.isEmpty {
                body[last].terminator = preferredTerminator
            }
            let insertion = body.endIndex
            let generated = missing.map {
                Line(
                    content: "\(Self.renderKey($0)) = \(Self.quoted(entries[$0] ?? ""))",
                    terminator: preferredTerminator)
            }
            body.insert(contentsOf: generated, at: insertion)
        }
        lines.replaceSubrange((table.line + 1)..<nextTableLine, with: body)
    }

    private mutating func parse() throws {
        var tablePath: [String] = []
        var arrayContext: ArrayContext?
        var seenTables: Set<TableIdentity> = []
        var arrayTableCounts: [[String]: Int] = [:]
        var activeArrayOccurrences: [[String]: Int] = [:]
        var seenKeys: Set<AssignmentIdentity> = []
        var valuePaths: Set<[String]> = []
        var arrayValuePaths: [ArrayContext: Set<[String]>] = [:]
        var lineIndex = 0

        while lineIndex < lines.count {
            let content = lines[lineIndex].content
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                lineIndex += 1
                continue
            }
            if trimmed.hasPrefix("[") {
                let parsed = try Self.parseTableHeader(trimmed, line: lineIndex)
                let prospectiveArrayContext =
                    activeArrayOccurrences
                    .filter { path, _ in
                        path.count < parsed.path.count && parsed.path.starts(with: path)
                    }
                    .max { lhs, rhs in lhs.key.count < rhs.key.count }
                    .map { ArrayContext(path: $0.key, occurrence: $0.value) }
                let contextualValuePaths = prospectiveArrayContext.flatMap { arrayValuePaths[$0] } ?? []
                guard
                    !valuePaths.contains(where: { path in
                        parsed.path.starts(with: path) || path.starts(with: parsed.path)
                    }),
                    !contextualValuePaths.contains(where: { path in
                        parsed.path.starts(with: path) || path.starts(with: parsed.path)
                    })
                else {
                    throw StarshipAdapterError.malformedConfiguration(
                        "TOML key conflicts with a table at line \(lineIndex + 1)"
                    )
                }
                let managedPalettePath = ["palettes", StarshipPaletteTransformer.ownedPaletteName]
                if parsed.path == managedPalettePath, prospectiveArrayContext != nil {
                    throw StarshipAdapterError.ambiguousConfiguration(
                        "the managed palette must be a root TOML table"
                    )
                }
                if parsed.path.count > managedPalettePath.count,
                    parsed.path.starts(with: managedPalettePath)
                {
                    throw StarshipAdapterError.ambiguousConfiguration(
                        "the managed palette cannot contain nested TOML tables"
                    )
                }
                tablePath = parsed.path
                if parsed.isArray {
                    let standardIdentity = TableIdentity(
                        path: parsed.path,
                        arrayContext: prospectiveArrayContext
                    )
                    guard parsed.path != ["palettes", StarshipPaletteTransformer.ownedPaletteName],
                        !seenTables.contains(standardIdentity),
                        !(arrayTableCounts[parsed.path] == nil
                            && seenTables.contains(where: { identity in
                                identity.path.count > parsed.path.count
                                    && identity.path.starts(with: parsed.path)
                            }))
                    else {
                        throw StarshipAdapterError.ambiguousConfiguration(
                            "the managed palette must be one standard TOML table"
                        )
                    }
                    let occurrence = (arrayTableCounts[parsed.path] ?? 0) + 1
                    arrayTableCounts[parsed.path] = occurrence
                    activeArrayOccurrences = activeArrayOccurrences.filter { path, _ in
                        !path.starts(with: parsed.path)
                    }
                    activeArrayOccurrences[parsed.path] = occurrence
                    arrayContext = ArrayContext(path: parsed.path, occurrence: occurrence)
                    seenTables.insert(TableIdentity(path: parsed.path, arrayContext: arrayContext))
                } else {
                    arrayContext =
                        activeArrayOccurrences
                        .filter { path, _ in parsed.path.starts(with: path) }
                        .max { lhs, rhs in lhs.key.count < rhs.key.count }
                        .map { ArrayContext(path: $0.key, occurrence: $0.value) }
                    let identity = TableIdentity(path: parsed.path, arrayContext: arrayContext)
                    guard arrayTableCounts[parsed.path] == nil, seenTables.insert(identity).inserted else {
                        throw StarshipAdapterError.ambiguousConfiguration(
                            parsed.path == ["palettes", StarshipPaletteTransformer.ownedPaletteName]
                                ? "multiple \(StarshipPaletteTransformer.ownedPaletteTable) tables"
                                : "duplicate TOML table at line \(lineIndex + 1)"
                        )
                    }
                }
                tables.append(Table(path: parsed.path, line: lineIndex))
                lineIndex += 1
                continue
            }

            let assignment = try parseAssignment(startingAt: lineIndex, tablePath: tablePath)
            let fullPath = tablePath + assignment.keyPath
            let managedPalettePath = ["palettes", StarshipPaletteTransformer.ownedPaletteName]
            if tablePath.isEmpty, assignment.keyPath == ["palettes"] {
                throw StarshipAdapterError.ambiguousConfiguration(
                    "the managed palette namespace must use TOML tables"
                )
            }
            if tablePath == managedPalettePath, assignment.keyPath.count != 1 {
                throw StarshipAdapterError.ambiguousConfiguration(
                    "the managed palette cannot contain dotted keys"
                )
            }
            if tablePath != managedPalettePath,
                Array(fullPath.prefix(managedPalettePath.count)) == managedPalettePath
            {
                throw StarshipAdapterError.ambiguousConfiguration(
                    "the managed palette must use one standard TOML table"
                )
            }
            let currentTableIdentity = TableIdentity(path: fullPath, arrayContext: arrayContext)
            let contextValuePaths = arrayContext.flatMap { arrayValuePaths[$0] } ?? valuePaths
            guard
                !contextValuePaths.contains(where: { path in
                    path != fullPath && (fullPath.starts(with: path) || path.starts(with: fullPath))
                }),
                !seenTables.contains(where: { identity in
                    identity.arrayContext == arrayContext && identity.path.starts(with: fullPath)
                }),
                !seenTables.contains(currentTableIdentity), arrayTableCounts[fullPath] == nil
            else {
                throw StarshipAdapterError.malformedConfiguration(
                    "TOML key conflicts with an existing namespace at line \(lineIndex + 1)"
                )
            }
            if let arrayContext {
                arrayValuePaths[arrayContext, default: []].insert(fullPath)
            } else {
                valuePaths.insert(fullPath)
            }
            let identity = AssignmentIdentity(
                tablePath: tablePath,
                arrayContext: arrayContext,
                keyPath: assignment.keyPath
            )
            if !seenKeys.insert(identity).inserted {
                if tablePath.isEmpty && assignment.keyPath == ["palette"] {
                    throw StarshipAdapterError.ambiguousConfiguration("multiple top-level palette assignments")
                }
                throw StarshipAdapterError.malformedConfiguration(
                    "duplicate TOML key at line \(lineIndex + 1)"
                )
            }
            assignments.append(assignment)
            lineIndex = assignment.endLine + 1
        }
    }

    private func parseAssignment(startingAt startLine: Int, tablePath: [String]) throws -> Assignment {
        let content = lines[startLine].content
        guard let equalsColumn = Self.firstUnquotedEquals(in: content) else {
            throw StarshipAdapterError.malformedConfiguration("invalid TOML statement at line \(startLine + 1)")
        }
        let equalsIndex = content.index(content.startIndex, offsetBy: equalsColumn)
        let keySource = String(content[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        let keyPath = try Self.parseKeyPath(keySource, line: startLine)
        let valueColumn = equalsColumn + 1
        let source = Self.valueSource(lines: lines, startLine: startLine, startColumn: valueColumn)
        let parsedValue = try Self.parseValue(source, line: startLine)
        let endLine = startLine + parsedValue.consumedNewlines
        guard endLine < lines.count else {
            throw StarshipAdapterError.malformedConfiguration("unterminated TOML value at line \(startLine + 1)")
        }

        let valueStart = valueColumn + parsedValue.leadingWhitespace
        let valueEnd =
            endLine == startLine
            ? valueColumn + parsedValue.valueEnd
            : parsedValue.valueEnd
        return Assignment(
            tablePath: tablePath,
            keyPath: keyPath,
            startLine: startLine,
            endLine: endLine,
            valueStartColumn: valueStart,
            valueEndColumn: valueEnd
        )
    }

    private mutating func replaceValue(on line: Int, from start: Int, to end: Int, with value: String) {
        lines[line].content = Self.replacingCharacters(
            in: lines[line].content,
            from: start,
            to: end,
            with: value
        )
    }

    private mutating func insertTopLevelPalette(_ value: String, at index: Int) {
        let palette = Line(content: "palette = \(value)", terminator: preferredTerminator)
        if index < lines.count {
            var inserted = [palette]
            if index == 0 || !lines[index - 1].content.trimmingCharacters(in: .whitespaces).isEmpty {
                inserted.append(Line(content: "", terminator: preferredTerminator))
            }
            lines.insert(contentsOf: inserted, at: index)
            return
        }
        appendBlock([palette])
    }

    private mutating func appendOwnedPalette(entries: [String: String]) {
        var block = [
            Line(
                content: "[\(StarshipPaletteTransformer.ownedPaletteTable)]",
                terminator: preferredTerminator
            )
        ]
        block.append(
            contentsOf: entries.keys.sorted().map {
                Line(
                    content: "\(Self.renderKey($0)) = \(Self.quoted(entries[$0] ?? ""))",
                    terminator: preferredTerminator)
            }
        )
        appendBlock(block)
    }

    private mutating func appendBlock(_ block: [Line]) {
        if lines.count == 1, lines[0].content.isEmpty, lines[0].terminator.isEmpty {
            lines = block
            return
        }
        if let last = lines.indices.last, lines[last].terminator.isEmpty {
            lines[last].terminator = preferredTerminator
        }
        if let last = lines.last, !last.content.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(Line(content: "", terminator: preferredTerminator))
        }
        lines.append(contentsOf: block)
    }

    private static func splitLines(_ text: String) -> [Line] {
        guard !text.isEmpty else { return [Line(content: "", terminator: "")] }
        let scalars = text.unicodeScalars
        var result: [Line] = []
        var start = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if scalars[index].value == 10 {
                result.append(Line(content: String(scalars[start..<index]), terminator: "\n"))
                index = scalars.index(after: index)
                start = index
            } else if scalars[index].value == 13 {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next].value == 10 {
                    result.append(Line(content: String(scalars[start..<index]), terminator: "\r\n"))
                    index = scalars.index(after: next)
                } else {
                    result.append(Line(content: String(scalars[start..<index]), terminator: "\r"))
                    index = next
                }
                start = index
            } else {
                index = scalars.index(after: index)
            }
        }
        if start < scalars.endIndex {
            result.append(Line(content: String(scalars[start...]), terminator: ""))
        }
        return result
    }

    private static func parseTableHeader(
        _ source: String,
        line: Int
    ) throws -> (path: [String], isArray: Bool) {
        let arrayTable = source.hasPrefix("[[")
        let openingCount = arrayTable ? 2 : 1
        let closing = arrayTable ? "]]" : "]"
        let keyStart = source.index(source.startIndex, offsetBy: openingCount)
        var index = keyStart
        var quote: Character?
        var escaped = false
        var closingRange: Range<String.Index>?
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
                index = source.index(after: index)
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
            } else if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
            } else if quote == nil, source[index...].hasPrefix(closing) {
                closingRange = index..<source.index(index, offsetBy: closing.count)
                break
            }
            index = source.index(after: index)
        }
        guard source.count > openingCount, let closingRange else {
            throw StarshipAdapterError.malformedConfiguration("invalid TOML table at line \(line + 1)")
        }
        let after = source[closingRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("#") else {
            throw StarshipAdapterError.malformedConfiguration("invalid TOML table at line \(line + 1)")
        }
        let keySource = String(source[keyStart..<closingRange.lowerBound])
        let path = try parseKeyPath(keySource, line: line)
        guard !path.isEmpty else {
            throw StarshipAdapterError.malformedConfiguration("invalid TOML table at line \(line + 1)")
        }
        return (path, arrayTable)
    }

    private static func parseKeyPath(_ source: String, line: Int) throws -> [String] {
        var components: [String] = []
        var index = source.startIndex

        func skipWhitespace(_ index: inout String.Index) {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
        }

        skipWhitespace(&index)
        while index < source.endIndex {
            let component: String
            if source[index] == "\"" || source[index] == "'" {
                let quote = source[index]
                index = source.index(after: index)
                var value = ""
                var closed = false
                while index < source.endIndex {
                    let character = source[index]
                    if quote == "\"", character == "\\" {
                        index = source.index(after: index)
                        value += try decodeEscape(in: source, index: &index, line: line)
                    } else if character == quote {
                        index = source.index(after: index)
                        closed = true
                        break
                    } else {
                        guard !character.unicodeScalars.contains(where: isForbiddenRawControl) else {
                            throw StarshipAdapterError.malformedConfiguration(
                                "raw control character in TOML key at line \(line + 1)"
                            )
                        }
                        value.append(character)
                        index = source.index(after: index)
                    }
                }
                guard closed else {
                    throw StarshipAdapterError.malformedConfiguration("invalid TOML key at line \(line + 1)")
                }
                component = value
            } else {
                let start = index
                while index < source.endIndex, isBareKeyCharacter(source[index]) {
                    index = source.index(after: index)
                }
                guard start != index else {
                    throw StarshipAdapterError.malformedConfiguration("invalid TOML key at line \(line + 1)")
                }
                component = String(source[start..<index])
            }
            components.append(component)
            skipWhitespace(&index)
            guard index < source.endIndex else { break }
            guard source[index] == "." else {
                throw StarshipAdapterError.malformedConfiguration("invalid TOML key at line \(line + 1)")
            }
            index = source.index(after: index)
            skipWhitespace(&index)
            guard index < source.endIndex else {
                throw StarshipAdapterError.malformedConfiguration("invalid TOML key at line \(line + 1)")
            }
        }
        return components
    }

    private static func isBareKeyCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
            || (48...57).contains(scalar.value)
            || scalar.value == 95
            || scalar.value == 45
    }

    private static func decodeEscape<Source: StringProtocol>(
        in source: Source,
        index: inout Source.Index,
        line: Int
    ) throws -> String {
        guard index < source.endIndex else {
            throw StarshipAdapterError.malformedConfiguration("invalid TOML escape at line \(line + 1)")
        }
        let escape = source[index]
        index = source.index(after: index)
        switch escape {
        case "b": return "\u{8}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{C}"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "u", "U":
            let count = escape == "u" ? 4 : 8
            var digits = ""
            for _ in 0..<count {
                guard index < source.endIndex, source[index].isHexDigit else {
                    throw StarshipAdapterError.malformedConfiguration(
                        "invalid TOML Unicode escape at line \(line + 1)"
                    )
                }
                digits.append(source[index])
                index = source.index(after: index)
            }
            guard let value = UInt32(digits, radix: 16), let scalar = UnicodeScalar(value) else {
                throw StarshipAdapterError.malformedConfiguration(
                    "invalid TOML Unicode escape at line \(line + 1)"
                )
            }
            return String(scalar)
        default:
            throw StarshipAdapterError.malformedConfiguration("invalid TOML escape at line \(line + 1)")
        }
    }

    private static func firstUnquotedEquals(in source: String) -> Int? {
        var quote: Character?
        var escaped = false
        for (offset, character) in source.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if character == "=", quote == nil {
                return offset
            } else if character == "#", quote == nil {
                return nil
            }
        }
        return nil
    }

    private static func valueSource(lines: [Line], startLine: Int, startColumn: Int) -> String {
        let first = lines[startLine].content
        let firstStart = first.index(first.startIndex, offsetBy: startColumn)
        var result = String(first[firstStart...])
        if startLine + 1 < lines.count {
            for line in lines[(startLine + 1)...] {
                result += "\n" + line.content
            }
        }
        return result
    }

    private static func parseValue(
        _ source: String,
        line: Int
    ) throws -> (consumedNewlines: Int, leadingWhitespace: Int, valueEnd: Int) {
        let leading = source.prefix { $0 == " " || $0 == "\t" }.count
        let start = source.index(source.startIndex, offsetBy: leading)
        guard start < source.endIndex else {
            throw StarshipAdapterError.malformedConfiguration("missing TOML value at line \(line + 1)")
        }
        let remainder = source[start...]
        let consumedCharacters: Int
        switch remainder.first {
        case "\"":
            consumedCharacters = try consumeString(remainder, quote: "\"", line: line)
        case "'":
            consumedCharacters = try consumeString(remainder, quote: "'", line: line)
        case "[":
            consumedCharacters = try consumeComposite(remainder, opening: "[", line: line)
        case "{":
            consumedCharacters = try consumeComposite(remainder, opening: "{", line: line)
        default:
            consumedCharacters = try consumeScalar(remainder, line: line)
        }
        let consumedEnd = source.index(start, offsetBy: consumedCharacters)
        let consumedPrefix = source[..<consumedEnd]
        let newlines = consumedPrefix.filter { $0 == "\n" }.count
        let lineTailStart =
            source[..<consumedEnd].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let endOnLastLine = source.distance(from: lineTailStart, to: consumedEnd)
        let valueEnd = newlines == 0 ? leading + consumedCharacters : endOnLastLine

        let restOfLineEnd = source[consumedEnd...].firstIndex(of: "\n") ?? source.endIndex
        let trailing = source[consumedEnd..<restOfLineEnd].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else {
            throw StarshipAdapterError.malformedConfiguration("invalid TOML value at line \(line + newlines + 1)")
        }
        return (newlines, leading, valueEnd)
    }

    private static func consumeString(
        _ source: Substring,
        quote: Character,
        line: Int
    ) throws -> Int {
        let triple = source.hasPrefix(String(repeating: String(quote), count: 3))
        let delimiterLength = triple ? 3 : 1
        var index = source.index(source.startIndex, offsetBy: delimiterLength)
        while index < source.endIndex {
            if triple, source[index...].hasPrefix(String(repeating: String(quote), count: 3)) {
                var delimiterLength = 3
                var delimiterEnd = source.index(index, offsetBy: delimiterLength)
                while delimiterLength < 5,
                    delimiterEnd < source.endIndex,
                    source[delimiterEnd] == quote
                {
                    delimiterLength += 1
                    delimiterEnd = source.index(after: delimiterEnd)
                }
                return source.distance(from: source.startIndex, to: index) + delimiterLength
            }
            let character = source[index]
            if character.unicodeScalars.contains(where: isForbiddenRawControl) {
                throw StarshipAdapterError.malformedConfiguration(
                    "raw control character in TOML string at line \(line + 1)"
                )
            }
            if !triple, character == "\n" {
                break
            }
            if quote == "\"", character == "\\" {
                index = source.index(after: index)
                if triple {
                    var continuation = index
                    while continuation < source.endIndex,
                        source[continuation] == " " || source[continuation] == "\t"
                    {
                        continuation = source.index(after: continuation)
                    }
                    if continuation < source.endIndex, source[continuation] == "\n" {
                        index = source.index(after: continuation)
                        while index < source.endIndex,
                            source[index] == " " || source[index] == "\t" || source[index] == "\n"
                        {
                            index = source.index(after: index)
                        }
                        continue
                    }
                }
                _ = try decodeEscape(in: source, index: &index, line: line)
                continue
            }
            if !triple, character == quote {
                return source.distance(from: source.startIndex, to: index) + 1
            }
            index = source.index(after: index)
        }
        throw StarshipAdapterError.malformedConfiguration("unterminated TOML string at line \(line + 1)")
    }

    private static func consumeComposite(
        _ source: Substring,
        opening: Character,
        line: Int
    ) throws -> Int {
        var index = source.index(after: source.startIndex)

        func skipHorizontalWhitespace() {
            while index < source.endIndex, source[index] == " " || source[index] == "\t" {
                index = source.index(after: index)
            }
        }

        func skipArrayTrivia() {
            while index < source.endIndex {
                if source[index].isWhitespace {
                    index = source.index(after: index)
                } else if source[index] == "#" {
                    while index < source.endIndex, source[index] != "\n" {
                        index = source.index(after: index)
                    }
                } else {
                    return
                }
            }
        }

        func consumeNestedValue() throws {
            guard index < source.endIndex else {
                throw StarshipAdapterError.malformedConfiguration(
                    "missing TOML value at line \(line + 1)"
                )
            }
            let character = source[index]
            if character == "\"" || character == "'" {
                let consumed = try consumeString(source[index...], quote: character, line: line)
                index = source.index(index, offsetBy: consumed)
                return
            }
            if character == "[" || character == "{" {
                let consumed = try consumeComposite(source[index...], opening: character, line: line)
                index = source.index(index, offsetBy: consumed)
                return
            }
            let start = index
            while index < source.endIndex,
                source[index] != ",",
                source[index] != "]",
                source[index] != "}",
                source[index] != "#",
                source[index] != "\n"
            {
                index = source.index(after: index)
            }
            let scalar = source[start..<index].trimmingCharacters(in: .whitespaces)
            guard isValidScalar(scalar) else {
                throw StarshipAdapterError.malformedConfiguration(
                    "invalid TOML value at line \(line + 1)"
                )
            }
        }

        if opening == "[" {
            skipArrayTrivia()
            if index < source.endIndex, source[index] == "]" {
                return source.distance(from: source.startIndex, to: index) + 1
            }
            while index < source.endIndex {
                try consumeNestedValue()
                skipArrayTrivia()
                guard index < source.endIndex else { break }
                if source[index] == "]" {
                    return source.distance(from: source.startIndex, to: index) + 1
                }
                guard source[index] == "," else {
                    throw StarshipAdapterError.malformedConfiguration(
                        "TOML array values require commas at line \(line + 1)"
                    )
                }
                index = source.index(after: index)
                skipArrayTrivia()
                if index < source.endIndex, source[index] == "]" {
                    return source.distance(from: source.startIndex, to: index) + 1
                }
            }
        } else {
            skipHorizontalWhitespace()
            if index < source.endIndex, source[index] == "}" {
                return source.distance(from: source.startIndex, to: index) + 1
            }
            var keys: Set<[String]> = []
            while index < source.endIndex {
                let keyStart = index
                var quote: Character?
                var escaped = false
                var equals: Substring.Index?
                while index < source.endIndex {
                    let character = source[index]
                    if escaped {
                        escaped = false
                    } else if quote == "\"", character == "\\" {
                        escaped = true
                    } else if character == "\"" || character == "'" {
                        quote = quote == character ? nil : (quote ?? character)
                    } else if quote == nil, character == "=" {
                        equals = index
                        break
                    } else if quote == nil,
                        character == "}" || character == "," || character == "#" || character == "\n"
                    {
                        break
                    }
                    index = source.index(after: index)
                }
                guard let equals else {
                    throw StarshipAdapterError.malformedConfiguration(
                        "invalid inline TOML table at line \(line + 1)"
                    )
                }
                let key = try parseKeyPath(
                    String(source[keyStart..<equals]).trimmingCharacters(in: .whitespaces),
                    line: line
                )
                guard
                    !keys.contains(where: { existing in
                        key.starts(with: existing) || existing.starts(with: key)
                    })
                else {
                    throw StarshipAdapterError.malformedConfiguration(
                        "conflicting inline TOML table key at line \(line + 1)"
                    )
                }
                keys.insert(key)
                index = source.index(after: equals)
                skipHorizontalWhitespace()
                try consumeNestedValue()
                skipHorizontalWhitespace()
                guard index < source.endIndex else { break }
                if source[index] == "}" {
                    return source.distance(from: source.startIndex, to: index) + 1
                }
                guard source[index] == "," else {
                    throw StarshipAdapterError.malformedConfiguration(
                        "inline TOML table values require commas at line \(line + 1)"
                    )
                }
                index = source.index(after: index)
                skipHorizontalWhitespace()
                guard index < source.endIndex, source[index] != "}" else {
                    throw StarshipAdapterError.malformedConfiguration(
                        "inline TOML tables cannot have a trailing comma"
                    )
                }
            }
        }
        throw StarshipAdapterError.malformedConfiguration("unterminated TOML value at line \(line + 1)")
    }

    private static func consumeScalar(_ source: Substring, line: Int) throws -> Int {
        let end = source.firstIndex(where: { $0 == "#" || $0 == "\n" }) ?? source.endIndex
        let raw = String(source[..<end])
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard isValidScalar(trimmed) else {
            throw StarshipAdapterError.malformedConfiguration("invalid TOML value at line \(line + 1)")
        }
        let trailing = raw.reversed().prefix { $0 == " " || $0 == "\t" }.count
        return raw.count - trailing
    }

    private static func isValidScalar(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if ["true", "false", "inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(value) {
            return true
        }
        let dateTimePattern =
            #"^\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})?)?$"#
        if matches(value, pattern: dateTimePattern) {
            return isValidDateTime(value)
        }
        let timePattern = #"^\d{2}:\d{2}:\d{2}(?:\.\d+)?$"#
        if matches(value, pattern: timePattern) {
            return isValidTime(String(value.prefix(8)))
        }
        let decimalIntegerPattern = #"^[+-]?(0|[1-9](?:_?\d)*)$"#
        if matches(value, pattern: decimalIntegerPattern) {
            return Int64(value.replacingOccurrences(of: "_", with: "")) != nil
        }
        let numericPatterns = [
            #"^0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*$"#,
            #"^0o[0-7](?:_?[0-7])*$"#,
            #"^0b[01](?:_?[01])*$"#,
            #"^[+-]?(?:0|[1-9](?:_?\d)*)\.\d(?:_?\d)*(?:[eE][+-]?\d(?:_?\d)*)?$"#,
            #"^[+-]?(?:0|[1-9](?:_?\d)*)[eE][+-]?\d(?:_?\d)*$"#,
        ]
        return numericPatterns.contains { matches(value, pattern: $0) }
    }

    private static func isValidDateTime(_ value: String) -> Bool {
        let dateParts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return false }
        let year = dateParts[0]
        let month = dateParts[1]
        let day = dateParts[2]
        let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let daysPerMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...daysPerMonth[month - 1]).contains(day) else {
            return false
        }
        guard value.count > 10 else { return true }
        let timeStart = value.index(value.startIndex, offsetBy: 11)
        let timeAndZone = value[timeStart...]
        guard isValidTime(String(timeAndZone.prefix(8))) else { return false }
        if let offsetStart = timeAndZone.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let offset = timeAndZone[timeAndZone.index(after: offsetStart)...].split(separator: ":")
            guard offset.count == 2,
                let hour = Int(offset[0]),
                let minute = Int(offset[1]),
                (0...23).contains(hour),
                (0...59).contains(minute)
            else {
                return false
            }
        }
        return true
    }

    private static func isValidTime(_ value: String) -> Bool {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        return parts.count == 3
            && (0...23).contains(parts[0])
            && (0...59).contains(parts[1])
            && (0...60).contains(parts[2])
    }

    private static func isForbiddenRawControl(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value <= 0x08)
            || scalar.value == 0x0B
            || scalar.value == 0x0C
            || (0x0E...0x1F).contains(scalar.value)
            || scalar.value == 0x7F
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacingCharacters(
        in source: String,
        from start: Int,
        to end: Int,
        with replacement: String
    ) -> String {
        let startIndex = source.index(source.startIndex, offsetBy: start)
        let endIndex = source.index(source.startIndex, offsetBy: end)
        return String(source[..<startIndex]) + replacement + String(source[endIndex...])
    }

    private static func renderKey(_ key: String) -> String {
        key.allSatisfy(isBareKeyCharacter) ? key : quoted(key)
    }

    private static func quoted(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
