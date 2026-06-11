import SwiftUI

extension Notification.Name {
    static let switchSection = Notification.Name("SlurmIOS.switchSection")
    /// Posted with a job id (object: String) to jump to that job in the list.
    static let openJob = Notification.Name("SlurmIOS.openJob")
}

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case jobs, bookmarks, settings

    var id: String { rawValue }
    var label: String {
        switch self {
        case .jobs:       "Jobs"
        case .bookmarks:  "Marken"
        case .settings:   "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .jobs:       "list.bullet.rectangle.portrait"
        case .bookmarks:  "bookmark"
        case .settings:   "gearshape"
        }
    }
}

struct MainTabView: View {
    @StateObject private var bookmarks = BookmarksStore()
    @StateObject private var dashboard = DashboardStore()
    /// Lebt auf Tab-Ebene, damit Jobs-Daten + Lade-Status den Wechsel zwischen
    /// Jobs/Marken/Settings überstehen (Cache statt Neuladen).
    @StateObject private var jobsVM = JobsViewModel()

    var body: some View {
        platformRoot
            .environmentObject(bookmarks)
            .environmentObject(dashboard)
            .environmentObject(jobsVM)
            .tint(Theme.accent)
    }

    @ViewBuilder
    private var platformRoot: some View {
        #if os(macOS)
        MacRootView()
        #else
        PhoneRootView()
        #endif
    }
}

#if os(iOS)
/// iPhone/iPad: klassische TabView. Jede Sektion (`JobsView`/`BookmarksView`/
/// `SettingsView`) bringt ihren eigenen `NavigationStack` + Titel mit, daher
/// hier bewusst KEIN zusätzlicher Stack.
private struct PhoneRootView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: MainSection = .jobs

    var body: some View {
        TabView(selection: $selection) {
            JobsView()
                .tabItem { Label(MainSection.jobs.label, systemImage: MainSection.jobs.symbol) }
                .tag(MainSection.jobs)
            BookmarksView()
                .tabItem { Label(MainSection.bookmarks.label, systemImage: MainSection.bookmarks.symbol) }
                .tag(MainSection.bookmarks)
            SettingsView()
                .tabItem { Label(MainSection.settings.label, systemImage: MainSection.settings.symbol) }
                .tag(MainSection.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchSection)) { note in
            if let sec = note.object as? MainSection { selection = sec }
        }
    }
}
#endif

#if os(macOS)
private struct MacRootView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: MainSection? = .jobs
    @FocusState private var sidebarFocused: Bool
    /// Sidebar starts collapsed for more room — reveal it via the toolbar
    /// sidebar toggle or the section shortcuts (1/2/3, b, …).
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                .navigationTitle("Slurmy")
                .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            detailView
                .frame(minWidth: 600, minHeight: 500)
                .navigationTitle(selection?.label ?? "Slurmy")
                .navigationSubtitle(connectionLabel)
        }
        .navigationSplitViewStyle(.balanced)
        .background(sectionShortcuts)
        .onReceive(NotificationCenter.default.publisher(for: .switchSection)) { note in
            if let sec = note.object as? MainSection { selection = sec }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSidebar)) { _ in
            sidebarFocused = true
        }
    }

    /// Hidden buttons that map digit keys (and ⌘1/⌘2/⌘3 as Mac convention)
    /// to the corresponding sidebar section, plus ⌘I to focus the sidebar.
    private var sectionShortcuts: some View {
        ZStack {
            Button { selection = .jobs }      label: { EmptyView() }
                .keyboardShortcut(Shortcut.sectionJobs.key, modifiers: [])
            Button { selection = .jobs }      label: { EmptyView() }
                .keyboardShortcut("1", modifiers: .command)
            Button { selection = .bookmarks } label: { EmptyView() }
                .keyboardShortcut(Shortcut.sectionBookmarks.key, modifiers: [])
            Button { selection = .bookmarks } label: { EmptyView() }
                .keyboardShortcut("2", modifiers: .command)
            Button { selection = .settings }  label: { EmptyView() }
                .keyboardShortcut(Shortcut.sectionSettings.key, modifiers: [])
            Button { selection = .settings }  label: { EmptyView() }
                .keyboardShortcut("3", modifiers: .command)
            Button { sidebarFocused = true } label: { EmptyView() }
                .keyboardShortcut(Shortcut.focusSidebar.key, modifiers: Shortcut.focusSidebar.modifiers)
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Cluster") {
                ForEach(MainSection.allCases) { section in
                    Label(section.label, systemImage: section.symbol)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .focusable()
        .focusEffectDisabled()
        .focused($sidebarFocused)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image("SlurmyMascot")
                .resizable()
                .scaledToFit()
                .frame(height: 30)
                .accessibilityHidden(true)
                .help("Slurmy – die leuchtende Cluster Raupe")
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.connectionStatus.label)
                    .font(.caption.bold())
                if let c = appState.credentials {
                    Text("\(c.username)@\(c.host)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var connectionLabel: String {
        guard let c = appState.credentials else { return appState.connectionStatus.label }
        return "\(c.username)@\(c.host)"
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connected:    return Theme.success
        case .connecting:   return Theme.warning
        case .degraded:     return Theme.warning
        case .failed:       return Theme.danger
        case .disconnected: return Theme.textSecondary
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .jobs:       JobsView()
        case .bookmarks:  BookmarksView()
        case .settings:   SettingsView()
        case .none:       EmptyView()
        }
    }
}
#endif
