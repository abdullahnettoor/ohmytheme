import Foundation
import ThemeModel

public enum StarshipPaletteTransformer {
    public static let ownedPaletteName = "oh_my_theme"
    public static let ownedPaletteTable = "palettes.oh_my_theme"
    public static let topLevelPaletteKey = "palette"

    public static func paletteEntries(for variant: ThemeVariant) -> [String: String] {
        // Map semantic roles to palette keys (hyphens -> underscores for TOML safety)
        var entries: [String: String] = [:]
        for (role, color) in variant.roles {
            let key = role.rawValue.replacingOccurrences(of: "-", with: "_")
            entries[key] = color.rawValue
        }
        return entries
    }

    public static func validate(_ bytes: Data) throws {
        let text = String(decoding: bytes, as: UTF8.self)
        // TOML is UTF-8 text; if bytes contain non-UTF8, decoding will lossily replace, but we treat as malformed if contains null?
        if bytes.contains(0) {
            throw StarshipAdapterError.malformedConfiguration("contains null byte")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var currentTable: String? = nil
        var ownedTableCount = 0
        var topLevelPaletteCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("[") {
                // Table header
                guard let header = parseTableHeader(trimmed) else {
                    throw StarshipAdapterError.malformedConfiguration("invalid table header: \(line)")
                }
                currentTable = header
                if header == ownedPaletteTable {
                    ownedTableCount += 1
                    if ownedTableCount > 1 {
                        throw StarshipAdapterError.ambiguousConfiguration("multiple \(ownedPaletteTable) tables")
                    }
                }
                continue
            }
            if line.contains("=") {
                // Key = value
                guard let eqIndex = line.firstIndex(of: "=") else {
                    throw StarshipAdapterError.malformedConfiguration("missing = in line: \(line)")
                }
                let keyPart = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let valuePartRaw = String(line[line.index(after: eqIndex)...])
                // Extract value before comment (outside quotes)
                let valueBeforeComment = stripTrailingComment(from: valuePartRaw)
                let valueTrimmed = valueBeforeComment.trimmingCharacters(in: .whitespaces)
                if keyPart.isEmpty || valueTrimmed.isEmpty {
                    throw StarshipAdapterError.malformedConfiguration("invalid key/value: \(line)")
                }
                // Basic key validation: must not contain brackets or unexpected chars
                if keyPart.contains("[") || keyPart.contains("]") {
                    throw StarshipAdapterError.malformedConfiguration("invalid key: \(keyPart)")
                }
                // Quote balance check for string values
                if !isValueBalanced(valueTrimmed) {
                    throw StarshipAdapterError.malformedConfiguration("unbalanced quotes: \(line)")
                }
                // Count top-level palette keys (only when not inside a table)
                if currentTable == nil && keyPart == topLevelPaletteKey {
                    topLevelPaletteCount += 1
                    if topLevelPaletteCount > 1 {
                        throw StarshipAdapterError.ambiguousConfiguration("multiple top-level palette assignments")
                    }
                }
                continue
            }
            // Line with no = and not comment/table is malformed
            throw StarshipAdapterError.malformedConfiguration("invalid line: \(line)")
        }
    }

    public static func applyTheme(to bytes: Data, variant: ThemeVariant) throws -> Data {
        let entries = paletteEntries(for: variant)
        return try applyTheme(to: bytes, paletteName: ownedPaletteName, entries: entries, topLevelPalette: ownedPaletteName)
    }

    public static func applyTheme(to bytes: Data, paletteName: String, entries: [String: String], topLevelPalette: String) throws -> Data {
        try validate(bytes)
        let text = String(decoding: bytes, as: UTF8.self)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Determine if original ended with newline
        let endsWithNewline = normalized.hasSuffix("\n")

        // Track table boundaries to find insertion points
        var currentTable: String? = nil
        var tableHeaderIndices: [Int] = []
        var ownedTableHeaderIndex: Int? = nil
        var ownedTableEndIndex: Int? = nil // exclusive
        var topLevelPaletteIndices: [Int] = []

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("[") {
                if let header = parseTableHeader(trimmed) {
                    // record all table headers
                    tableHeaderIndices.append(idx)
                    if currentTable == ownedPaletteTable && ownedTableHeaderIndex != nil && ownedTableEndIndex == nil {
                        ownedTableEndIndex = idx
                    }
                    currentTable = header
                    if header == ownedPaletteTable {
                        ownedTableHeaderIndex = idx
                        // reset end, will be set when next table found or EOF
                        ownedTableEndIndex = nil
                    }
                }
                continue
            }
            if line.contains("=") {
                let keyPart = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                if currentTable == nil && keyPart == topLevelPaletteKey {
                    topLevelPaletteIndices.append(idx)
                }
            }
        }
        if let headerIdx = ownedTableHeaderIndex, ownedTableEndIndex == nil {
            ownedTableEndIndex = lines.count
        }

        // Build new lines mutable
        var newLines = lines

        // Handle top-level palette key
        let paletteLine = "palette = \"\(topLevelPalette)\""
        if let idx = topLevelPaletteIndices.first {
            let original = newLines[idx]
            newLines[idx] = replaceValuePreservingFormat(originalLine: original, newValue: "\"\(topLevelPalette)\"")
        } else {
            // Insert before first table header if exists, otherwise at end
            if let firstTableIdx = tableHeaderIndices.first {
                // Insert before first table, ensure separation
                let insertIdx = firstTableIdx
                // Ensure there's an empty line before insertion if needed? Preserve formatting by inserting palette line and an empty line separator if previous line not empty
                newLines.insert(paletteLine, at: insertIdx)
                // Adjust indices for owned table if it was after insertion
                if let headerIdx = ownedTableHeaderIndex, headerIdx >= insertIdx {
                    ownedTableHeaderIndex = headerIdx + 1
                    if let end = ownedTableEndIndex {
                        ownedTableEndIndex = end + 1
                    }
                }
                tableHeaderIndices = tableHeaderIndices.map { $0 >= insertIdx ? $0 + 1 : $0 }
            } else {
                // No tables, append
                if !newLines.isEmpty && !newLines.last!.isEmpty {
                    newLines.append("")
                }
                // If file was empty and had one empty element from split, handle
                if newLines.count == 1 && newLines[0].isEmpty && bytes.isEmpty {
                    newLines = [paletteLine]
                } else {
                    if newLines.last?.isEmpty == true {
                        // insert before final empty if endsWithNewline logic? Simplified: just before last empty
                        // For split with trailing newline, last element is empty. Append before it.
                        newLines.insert(paletteLine, at: newLines.count - 1)
                        if newLines.last?.isEmpty == false {
                            newLines.append("")
                        }
                    } else {
                        newLines.append(paletteLine)
                    }
                }
            }
        }

        // Recompute indices after palette insertion for table handling if file was empty case already handled
        // For simplicity, if we inserted palette line, we already adjusted. Now handle palette table
        // Need to re-evaluate if owned table exists
        // For table replacement/insertion, operate on current newLines
        // Find again owned table header in newLines (to handle inserted palette)
        var finalOwnedHeaderIdx: Int? = nil
        var finalOwnedEndIdx: Int? = nil
        var finalTableIndices: [Int] = []
        var curTable: String? = nil
        var tempOwnedStart: Int? = nil
        for (idx, line) in newLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if let header = parseTableHeader(trimmed) {
                    finalTableIndices.append(idx)
                    if curTable == ownedPaletteTable, let start = tempOwnedStart {
                        finalOwnedEndIdx = idx
                    }
                    curTable = header
                    if header == ownedPaletteTable {
                        finalOwnedHeaderIdx = idx
                        tempOwnedStart = idx
                        finalOwnedEndIdx = nil
                    }
                }
            }
        }
        if let start = tempOwnedStart, finalOwnedEndIdx == nil {
            finalOwnedEndIdx = newLines.count
        }

        let sortedEntries = entries.sorted { $0.key < $1.key }
        let entryLines = sortedEntries.map { "\($0.key) = \"\($0.value)\"" }

        if let headerIdx = finalOwnedHeaderIdx, let endIdx = finalOwnedEndIdx {
            // Replace body between headerIdx+1 ..< endIdx with entryLines
            let headerLine = newLines[headerIdx]
            var replacement: [String] = [headerLine]
            replacement.append(contentsOf: entryLines)
            // Replace range
            newLines.replaceSubrange((headerIdx)...(endIdx - 1), with: replacement)
        } else {
            // Insert new table at end
            // Ensure separation with empty line if needed
            if !newLines.isEmpty {
                // If last line is not empty, add empty separator
                if newLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    newLines.append("")
                } else if newLines.count >= 2 && newLines[newLines.count - 2].trimmingCharacters(in: .whitespaces).isEmpty == false {
                    // already has empty
                }
            }
            // Remove trailing empty that came from split if needed to avoid double
            // We'll just ensure we have header and entries at end
            // If file ends with empty string element due to trailing newline, insert before it
            if newLines.last?.isEmpty == true {
                // Insert before last empty
                let insertPos = newLines.count - 1
                newLines.insert("[\(ownedPaletteTable)]", at: insertPos)
                for (offset, entry) in entryLines.enumerated() {
                    newLines.insert(entry, at: insertPos + 1 + offset)
                }
            } else {
                newLines.append("[\(ownedPaletteTable)]")
                newLines.append(contentsOf: entryLines)
            }
        }

        // Reconstruct text with LF, handle trailing newline based on original
        var result = newLines.joined(separator: "\n")
        // The split/join logic already handles trailing newline via empty last element.
        // Ensure result ends with newline if original did
        if endsWithNewline && !result.hasSuffix("\n") {
            result += "\n"
        }
        if !endsWithNewline && result.hasSuffix("\n") && !bytes.isEmpty {
            // If original didn't end with newline but we added one via logic, keep as is? For now ensure we don't add extra.
            // This is edge; we will keep result as joined which may have added newline if we inserted table.
            // It's okay to end with newline for TOML; preserve original's ending if we can.
        }
        // If original was empty, ensure result ends with newline
        if bytes.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }

        return Data(result.utf8)
    }

    // MARK: - Helpers

    private static func parseTableHeader(_ trimmed: String) -> String? {
        // Matches [header] with optional trailing comment
        // Use regex: ^\[([^\]]+)\]\s*(?:#.*)?$
        guard trimmed.hasPrefix("[") else { return nil }
        guard let closeIdx = trimmed.firstIndex(of: "]") else { return nil }
        let headerContent = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx]).trimmingCharacters(in: .whitespaces)
        let trailing = String(trimmed[trimmed.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty && !trailing.hasPrefix("#") {
            return nil
        }
        if headerContent.isEmpty { return nil }
        return headerContent
    }

    private static func stripTrailingComment(from valuePart: String) -> String {
        // TOML comments start with # outside quotes. Simplified: find # not inside quotes.
        var inSingle = false
        var inDouble = false
        var escaped = false
        for (idx, ch) in valuePart.enumerated() {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && inDouble {
                escaped = true
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch == "#" && !inSingle && !inDouble {
                let strIdx = valuePart.index(valuePart.startIndex, offsetBy: idx)
                return String(valuePart[..<strIdx])
            }
        }
        return valuePart
    }

    private static func isValueBalanced(_ value: String) -> Bool {
        var inSingle = false
        var inDouble = false
        var escaped = false
        for ch in value {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && inDouble {
                escaped = true
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            }
        }
        return !inSingle && !inDouble
    }

    private static func replaceValuePreservingFormat(originalLine: String, newValue: String) -> String {
        // Preserve leading whitespace, key, spacing around =, and trailing comment
        guard let eqIdx = originalLine.firstIndex(of: "=") else {
            return "palette = \(newValue)"
        }
        let beforeEq = String(originalLine[..<eqIdx])
        // Extract key part for palette, but we just keep beforeEq as is up to =
        let afterEqRaw = String(originalLine[originalLine.index(after: eqIdx)...])
        // Find comment outside quotes in afterEqRaw
        var comment = ""
        var valuePart = afterEqRaw
        // Detect comment
        var inSingle = false
        var inDouble = false
        var escaped = false
        var commentStartIdx: String.Index? = nil
        for (offset, ch) in afterEqRaw.enumerated() {
            let idx = afterEqRaw.index(afterEqRaw.startIndex, offsetBy: offset)
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && inDouble {
                escaped = true
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch == "#" && !inSingle && !inDouble {
                commentStartIdx = idx
                break
            }
        }
        if let cIdx = commentStartIdx {
            comment = String(afterEqRaw[cIdx...])
            valuePart = String(afterEqRaw[..<cIdx])
        }
        // Preserve spacing before value: capture leading spaces in valuePart up to first non-space
        let trimmedValue = valuePart.trimmingCharacters(in: .whitespaces)
        // Determine spacing between = and value
        let eqToValueSpacing: String
        if let firstNonSpace = valuePart.firstIndex(where: { !$0.isWhitespace }) {
            eqToValueSpacing = String(valuePart[..<firstNonSpace])
        } else {
            eqToValueSpacing = " "
        }
        // Determine spacing before comment (valuePart trailing spaces)
        let trailingSpaces: String
        if !comment.isEmpty {
            // valuePart may have trailing spaces before comment; they are in valuePart's suffix
            // For simplicity, ensure one space before comment if comment exists
            trailingSpaces = " "
        } else {
            trailingSpaces = ""
        }
        // Reconstruct: beforeEq includes up to =, so do beforeEq + spacing + newValue + trailingSpaces + comment
        // beforeEq already contains key and spaces up to =, but we need to ensure we have "=" from originalLine
        // beforeEq is substring before "=", so we need to add "="
        let prefix = beforeEq + "="
        return prefix + eqToValueSpacing + newValue + trailingSpaces + comment
    }
}
