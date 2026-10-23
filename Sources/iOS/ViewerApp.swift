import SwiftUI

@main
struct ApplePolishViewerApp: App {
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        NavigationStack {
            switch model.state {
            case .needsKey: PairingView()
            case .disconnected, .connecting: ConnectView()
            case .connected: SourcesView()
            }
        }
        .alert("Apple Polish", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.message ?? "") }
    }
}
