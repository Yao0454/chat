import SwiftUI

@main
struct ChatClientApp: App {
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}

struct RootView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        switch store.phase {
        case .restoring:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await store.restore() }
        case .loggedOut:
            LoginView()
        case .loggedIn:
            MainView()
        }
    }
}
