import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.connectionStatus {
            case .connected:
                MainTabView()
            default:
                ConnectionSetupView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}
