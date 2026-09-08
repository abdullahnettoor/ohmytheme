import SwiftUI

enum NavigationSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case themes = "Themes"
    case apps = "Apps"

    var id: String { rawValue }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview:
            return "gauge"
        case .themes:
            return "paintpalette"
        case .apps:
            return "square.stack.3d.up"
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var presenceController: AppPresenceController
    @ObservedObject var model: WorkspacePresentationModel
    @State private var selectedSection: NavigationSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $selectedSection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
                .accessibilityIdentifier("nav-\(section.rawValue.lowercased())")
            }
            .navigationTitle("Oh My Theme")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selectedSection ?? .overview {
            case .overview:
                OverviewView(model: model)
            case .themes:
                ThemesView(model: model)
            case .apps:
                AppsView(model: model)
            }
        }
        .frame(minWidth: 700, idealWidth: 800, minHeight: 480, idealHeight: 560)
        .sheet(
            item: Binding(
                get: { model.setupPlan },
                set: { if $0 == nil { model.dismissSetupPlan() } }
            )
        ) { plan in
            SetupPlanReviewView(model: model, plan: plan)
                .interactiveDismissDisabled(model.isExecutingSetup)
        }
        .onAppear {
            presenceController.mainWindowDidOpen()
        }
        .onDisappear {
            presenceController.mainWindowDidClose()
        }
    }
}
