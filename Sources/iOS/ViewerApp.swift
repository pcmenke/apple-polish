import SwiftUI

@main
struct ApplePolishViewerApp: App {
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).onOpenURL { model.handle(url: $0) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        TabView {
            NavigationStack {
                switch model.state {
                case .needsKey: PairingView()
                case .disconnected, .connecting: ConnectView()
                case .connected: SourcesView()
                }
            }
            .tabItem { Label("Mac", systemImage: "laptopcomputer") }

            LocalLibraryView()
                .tabItem { Label("This iPhone", systemImage: "iphone") }
        }
        .alert("Apple Polish", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.message ?? "") }
    }
}
