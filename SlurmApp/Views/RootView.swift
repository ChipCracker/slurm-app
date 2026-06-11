import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.connectionStatus {
            case .connected, .degraded:
                // .degraded bleibt in der MainTabView: Footer-Label + Warn-Punkt
                // zeigen die Störung über den weiterhin sichtbaren Daten an, und
                // der laufende Poll kann den Zustand via reportConnectionHealthy()
                // wieder auf .connected heben. Ein Wechsel zur Setup-View würde
                // die Daten verwerfen und den Poll (und damit die Selbstheilung)
                // unmounten.
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
