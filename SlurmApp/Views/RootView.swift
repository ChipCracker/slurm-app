import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.connectionStatus {
            case .connected:
                MainTabView()
            case .connecting:
                ZStack {
                    Theme.background.ignoresSafeArea()
                    SlurmyLoadingState(caption: "Verbinde mit dem Cluster…")
                }
            default:
                ConnectionSetupView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .hotReloadable()
    }
}
