import SwiftUI
import ThemeModel

struct ThemesView: View {
    @ObservedObject var model: WorkspaceMenuModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Themes")
                        .font(.title2.weight(.bold))
                    Text("Browse themes and select your desired theme variant.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if model.bundledThemeVariants.isEmpty {
                    Text("No theme variants found.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.bundledThemeVariants, id: \.variantID) { variant in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(variant.name)
                                        .font(.headline)
                                    Text(variant.attribution)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedThemeVariantID == variant.variantID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                } else {
                                    Button("Select") {
                                        model.selectThemeVariant(variant.variantID)
                                    }
                                }
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Themes")
    }
}
