import SwiftUI
import ThemeModel

struct ThemesView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Themes")
                        .font(.title2.weight(.bold))
                    Text("Browse themes and choose your desired Theme Assignment.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let preview = model.selectedThemePreview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Theme Preview")
                            .font(.headline)
                        ThemePreviewCardView(preview: preview)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Bundled Theme Variants")
                        .font(.headline)

                    if model.bundledThemeVariants.isEmpty {
                        Text("No theme variants found.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(model.bundledThemeVariants) { variant in
                                ThemeVariantRow(
                                    variant: variant,
                                    isSelected: model.selectedThemeVariantID == variant.variantID,
                                    onSelect: {
                                        model.selectThemeVariant(variant.variantID)
                                    }
                                )
                            }
                        }
                        .accessibilityIdentifier("theme-variants-list")
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Themes")
    }
}

struct ThemeVariantRow: View {
    let variant: WorkspacePresentationModel.BundledThemeVariant
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ThemeSwatchStrip(preview: variant.preview)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(variant.name)
                        .font(.headline)

                    Text(variant.appearance.rawValue.capitalized)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())

                    Text(variant.source.type.rawValue.capitalized)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Text(variant.source.attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("Revision: \(variant.source.revision)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Desired")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityIdentifier("desired-badge-\(variant.variantID)")
            } else {
                Button("Select") {
                    onSelect()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("select-theme-\(variant.variantID)")
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            if !isSelected {
                onSelect()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("theme-variant-\(variant.variantID)")
    }
}
