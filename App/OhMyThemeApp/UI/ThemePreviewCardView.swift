import SwiftUI
import ThemeModel

extension Color {
    init(themeColor: ThemeColor) {
        let rawValue = themeColor.rawValue
        precondition(rawValue.count == 7 && rawValue.first == "#", "ThemeColor must use #rrggbb")
        guard let value = UInt64(rawValue.dropFirst(), radix: 16) else {
            preconditionFailure("ThemeColor must contain hexadecimal digits")
        }
        self.init(
            .sRGB,
            red: Double(value >> 16) / 255,
            green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

struct ThemePreviewData: Equatable, Identifiable, Sendable {

    var id: String { variantID }
    let variantID: String
    let displayName: String
    let appearance: ThemeAppearance
    let source: ThemeSource
    let roles: [SemanticRole: ThemeColor]

    init(pack: ThemePack, variant: ThemeVariant) {
        variantID = variant.qualifiedID
        displayName = "\(pack.displayName) \(variant.displayName)"
        appearance = variant.appearance
        source = pack.source
        roles = variant.roles
    }

    func color(for role: SemanticRole) -> ThemeColor {
        guard let color = roles[role] else {
            preconditionFailure("Validated Theme Variant is missing the \(role.rawValue) Semantic Role")
        }
        return color
    }

    var ansiColors: [ThemeColor] {
        [.ansiRed, .ansiGreen, .ansiYellow, .ansiBlue, .ansiMagenta, .ansiCyan]
            .map(color(for:))
    }
}

struct ThemeSwatchStrip: View {
    let preview: ThemePreviewData

    var body: some View {
        HStack(spacing: 3) {
            ForEach(
                [SemanticRole.canvas, .surface, .accent, .primaryText],
                id: \.rawValue
            ) { role in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(themeColor: preview.color(for: role)))
                    .frame(width: 12, height: 28)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

struct ThemePreviewCardView: View {
    let preview: ThemePreviewData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Circle().fill(.yellow).frame(width: 10, height: 10)
                    Circle().fill(.green).frame(width: 10, height: 10)

                    Spacer()

                    Text(preview.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(themeColor: preview.color(for: .secondaryText)))

                    Text(preview.appearance.rawValue.capitalized)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(themeColor: preview.color(for: .accent)).opacity(0.15), in: Capsule())
                        .foregroundStyle(Color(themeColor: preview.color(for: .accent)))

                    Spacer()

                    Spacer().frame(width: 30)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(themeColor: preview.color(for: .surface)))

                Divider().opacity(0.15)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        codeLine(
                            number: 1,
                            code: [
                                (text: "// Theme: ", color: preview.color(for: .syntaxComment)),
                                (text: preview.displayName, color: preview.color(for: .syntaxComment)),
                            ]
                        )
                        codeLine(
                            number: 2,
                            code: [
                                (text: "import ", color: preview.color(for: .syntaxKeyword)),
                                (text: "ThemeModel", color: preview.color(for: .primaryText)),
                            ]
                        )
                        codeLine(
                            number: 3,
                            code: [
                                (text: "struct ", color: preview.color(for: .syntaxKeyword)),
                                (text: "WorkspaceConfig ", color: preview.color(for: .primaryText)),
                                (text: "{", color: preview.color(for: .secondaryText)),
                            ]
                        )
                        codeLine(
                            number: 4,
                            code: [
                                (text: "    let ", color: preview.color(for: .syntaxKeyword)),
                                (text: "assignment = ", color: preview.color(for: .primaryText)),
                                (text: "\"\(preview.variantID)\"", color: preview.color(for: .syntaxString)),
                            ]
                        )
                        codeLine(
                            number: 5,
                            code: [
                                (text: "    let ", color: preview.color(for: .syntaxKeyword)),
                                (text: "status = ", color: preview.color(for: .primaryText)),
                                (text: "\"Preview\"", color: preview.color(for: .syntaxString)),
                            ]
                        )
                        codeLine(
                            number: 6,
                            code: [
                                (text: "}", color: preview.color(for: .secondaryText))
                            ]
                        )
                    }
                    .padding(.top, 4)

                    Divider().opacity(0.15)

                    HStack(spacing: 6) {
                        Text("~ ❯")
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                            .foregroundStyle(Color(themeColor: preview.color(for: .accent)))

                        Text("omt preview --theme \"\(preview.displayName)\"")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color(themeColor: preview.color(for: .primaryText)))
                    }

                    HStack(spacing: 6) {
                        Text("Preview only. No Target Instances changed.")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Color(themeColor: preview.color(for: .syntaxString)))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(themeColor: preview.color(for: .canvas)))

                HStack(spacing: 8) {
                    swatch(name: "Canvas", color: preview.color(for: .canvas))
                    swatch(name: "Surface", color: preview.color(for: .surface))
                    swatch(name: "Accent", color: preview.color(for: .accent))
                    swatch(name: "Text", color: preview.color(for: .primaryText))
                    swatch(name: "Keyword", color: preview.color(for: .syntaxKeyword))
                    swatch(name: "String", color: preview.color(for: .syntaxString))
                    swatch(name: "Comment", color: preview.color(for: .syntaxComment))

                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(preview.ansiColors, id: \.self) { ansiColor in
                            Circle()
                                .fill(Color(themeColor: ansiColor))
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(themeColor: preview.color(for: .surface)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
            .accessibilityIdentifier("theme-preview-card")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(preview.source.type.rawValue.capitalized) source")
                        .font(.caption.weight(.semibold))
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Revision: \(preview.source.revision)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text(preview.source.attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 4)
        }
    }

    private func codeLine(number: Int, code: [(text: String, color: ThemeColor)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(themeColor: preview.color(for: .secondaryText)).opacity(0.6))
                .frame(width: 14, alignment: .trailing)

            HStack(spacing: 0) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, item in
                    Text(item.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color(themeColor: item.color))
                }
            }
        }
    }

    private func swatch(name: String, color: ThemeColor) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(themeColor: color))
                .frame(width: 22, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )

            Text(name)
                .font(.system(size: 9))
                .foregroundStyle(Color(themeColor: preview.color(for: .secondaryText)))
        }
    }
}
