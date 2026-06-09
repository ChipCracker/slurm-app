import SwiftUI
#if DEBUG
import Inject
#endif

#if DEBUG && os(macOS)
/// On macOS the injection bundle is NOT auto-loaded the way it is in the iOS
/// simulator — the app must load it itself at startup. Called once from
/// `SlurmApp.init()`. The bundle then connects to a running InjectionIII.app, or
/// — with `INJECTION_DIRECTORIES` set (see scripts/dev.sh) — falls back to
/// standalone hot reloading and watches the sources directly. No-op in Release.
func loadInjectionBundleIfAvailable() {
    let path = "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle"
    if Bundle(path: path)?.load() == true {
        NSLog("💉 InjectionIII bundle loaded — hot reload armed")
    } else {
        NSLog("💉 InjectionIII not installed — hot reload off")
    }
}
#endif

extension View {
    /// Macht die View live hot-reloadbar (Inject): in einem Debug-Build, der mit
    /// `-Xlinker -interposable` gelinkt wurde *und* mit laufender InjectionIII-App
    /// (bzw. `INJECTION_DIRECTORIES` für Standalone), werden beim Speichern die
    /// Methodenrümpfe getauscht und diese View neu gezeichnet — ohne App-Neustart.
    ///
    /// Im Release-Build ist es ein No-op (kein Inject, keine Laufzeitkosten).
    /// Auf den jeweiligen Bildschirm-Wurzeln aufrufen; sollte der **letzte**
    /// Modifier in `body` sein. Siehe README „Hot Reloading“.
    @ViewBuilder
    func hotReloadable() -> some View {
        #if DEBUG
        modifier(InjectionModifier())
        #else
        self
        #endif
    }
}

#if DEBUG
/// Bündelt `@ObserveInjection` + `.enableInjection()` an einer Stelle, damit die
/// Bildschirme nur `.hotReloadable()` aufrufen müssen.
private struct InjectionModifier: ViewModifier {
    @ObserveInjection var inject
    func body(content: Content) -> some View {
        content.enableInjection()
    }
}
#endif
