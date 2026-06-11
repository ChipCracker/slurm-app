import SwiftUI

/// Single source of truth for every keyboard binding the app exposes —
/// drives both the actual `.keyboardShortcut(…)` modifiers AND the help
/// overlay so they can never drift apart.
///
/// Mapped 1:1 to slurm-tui's keymap where it makes sense; additional
/// macOS-conventions (`⌘F`, `⌘1/2/3`, `⌘⌥0`) live alongside.
enum Shortcut: String, CaseIterable, Identifiable {
    // App-wide
    case quitApp           // ⌘Q — Standard-Quit über das System-Menü (bewusst KEIN bare `q`)
    case help
    case helpAlt           // `?`
    case focusSearch
    case focusSidebar
    case toggleInspector

    // Sidebar sections
    case sectionJobs
    case sectionBookmarks
    case sectionSettings
    case openBookmarks     // `b` — TUI alias for "Show bookmarks"

    // Jobs dashboard
    case refresh
    case toggleAllUsers
    case toggleAllUsersCmd  // ⌘⇧U alias
    case toggleRunningOnly
    case submitJob
    case interactiveSession
    case attachSelected
    case cancelSelected
    case bookmarkSelected
    case clearSelection
    case cyclePartition
    case nodesOverview         // `G` — Knoten-Übersicht (alle Partitionen)
    case editScript
    case openTerminal
    case batchQos          // `p` — QoS der Auswahl ändern
    case batchPartition    // `P` — Partition der Auswahl ändern

    // Sort controls
    case prevSortColumn        // `y`
    case prevSortColumnArrow   // `←`
    case nextSortColumn        // `c`
    case nextSortColumnArrow   // `→`
    case toggleSortDir         // `x`
    case toggleSortDirAltS     // `s`
    case toggleSortDirAltD     // `d`

    // Job detail
    case toggleFollow          // `f`
    case focusLiveGpu          // `v`
    case focusLogs             // `l`
    case copyActiveLog         // `Y`
    case toggleLogStream       // `w` — stderr/stdout im Log-Vollbild umschalten

    // Cursor navigation (table)
    case cursorDownVim         // `j`
    case cursorUpVim           // `k`
    case cursorTop             // Home
    case cursorBottom          // End
    case cursorTopCmd          // ⌘↑
    case cursorBottomCmd       // ⌘↓

    var id: String { rawValue }

    // MARK: – Category

    var category: Category {
        switch self {
        case .quitApp, .help, .helpAlt, .focusSearch, .focusSidebar,
             .toggleInspector, .sectionJobs, .sectionBookmarks,
             .sectionSettings, .openBookmarks:
            return .navigation
        case .refresh, .toggleAllUsers, .toggleAllUsersCmd, .toggleRunningOnly,
             .submitJob, .interactiveSession, .attachSelected, .cancelSelected,
             .bookmarkSelected, .clearSelection, .cyclePartition, .nodesOverview,
             .editScript, .openTerminal, .batchQos, .batchPartition:
            return .jobs
        case .prevSortColumn, .prevSortColumnArrow,
             .nextSortColumn, .nextSortColumnArrow,
             .toggleSortDir, .toggleSortDirAltS, .toggleSortDirAltD:
            return .sort
        case .toggleFollow, .focusLiveGpu, .focusLogs, .copyActiveLog, .toggleLogStream:
            return .detail
        case .cursorDownVim, .cursorUpVim,
             .cursorTop, .cursorBottom,
             .cursorTopCmd, .cursorBottomCmd:
            return .tableNav
        }
    }

    // MARK: – Key + modifiers

    var key: KeyEquivalent {
        switch self {
        case .quitApp:                  return "q"
        case .help:                     return "h"
        case .helpAlt:                  return "?"
        case .focusSearch:              return "f"
        case .focusSidebar:             return "i"
        case .toggleInspector:          return "0"
        case .sectionJobs:              return "1"
        case .sectionBookmarks:         return "2"
        case .sectionSettings:          return "3"
        case .openBookmarks:            return "b"
        case .refresh:                  return "r"
        case .toggleAllUsers:           return "u"
        case .toggleAllUsersCmd:        return "U"   // ⌘⇧U
        case .toggleRunningOnly:        return "o"
        case .submitJob:                return "n"
        case .interactiveSession:       return "i"
        case .attachSelected:           return "a"
        case .cancelSelected:           return "C"
        case .bookmarkSelected:         return "B"
        case .clearSelection:           return .escape
        case .cyclePartition:           return "g"
        case .nodesOverview:            return "G"   // ⇧G
        case .editScript:               return "e"
        case .openTerminal:             return "t"
        case .batchQos:                 return "p"
        case .batchPartition:           return "P"   // ⇧P
        case .prevSortColumn:           return "y"
        case .prevSortColumnArrow:      return .leftArrow
        case .nextSortColumn:           return "c"
        case .nextSortColumnArrow:      return .rightArrow
        case .toggleSortDir:            return "x"
        case .toggleSortDirAltS:        return "s"
        case .toggleSortDirAltD:        return "d"
        case .toggleFollow:             return "f"   // shadowed by focusSearch when ⌘F? No: focusSearch uses ⌘; bare 'f' is free.
        case .focusLiveGpu:             return "v"
        case .focusLogs:                return "l"
        case .copyActiveLog:            return "Y"
        case .toggleLogStream:          return "w"
        case .cursorDownVim:            return "j"
        case .cursorUpVim:              return "k"
        case .cursorTop:                return .home
        case .cursorBottom:             return .end
        case .cursorTopCmd:             return .upArrow
        case .cursorBottomCmd:          return .downArrow
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .toggleInspector:                              return [.command, .option]
        // ⌘Q statt bare `q`: Ein einzelner versehentlicher Tastendruck darf
        // nie die ganze App (samt SSH-Session) beenden — Quit läuft über die
        // Standard-Konvention des System-Menüs.
        case .quitApp:                                      return [.command]
        case .focusSearch:                                  return [.command]
        case .focusSidebar:                                 return [.command]
        case .toggleAllUsersCmd:                            return [.command, .shift]
        case .cancelSelected, .bookmarkSelected,
             .copyActiveLog, .batchPartition, .nodesOverview: return [.shift]
        case .cursorTopCmd, .cursorBottomCmd:              return [.command]
        default:                                            return []
        }
    }

    // MARK: – Help-overlay grouping

    /// Multiple cases with the same `helpGroup` collapse into one help row
    /// with a combined key label (e.g. `y/← / c/→ / x/s/d` for sort). nil
    /// means "render its own row".
    var helpGroup: String? {
        switch self {
        case .prevSortColumn, .prevSortColumnArrow,
             .nextSortColumn, .nextSortColumnArrow,
             .toggleSortDir, .toggleSortDirAltS, .toggleSortDirAltD:
            return "sortCluster"
        case .help, .helpAlt:
            return "helpCluster"
        case .sectionBookmarks, .openBookmarks:
            return "bookmarksCluster"
        case .toggleAllUsers, .toggleAllUsersCmd:
            return "allUsersCluster"
        case .cursorDownVim, .cursorUpVim:
            return "vimNavCluster"
        case .cursorTop, .cursorBottom, .cursorTopCmd, .cursorBottomCmd:
            return "jumpCluster"
        default:
            return nil
        }
    }

    // MARK: – Display strings

    var humanKey: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .escape:     s += "Esc"
        case .return:     s += "↩"
        case .upArrow:    s += "↑"
        case .downArrow:  s += "↓"
        case .leftArrow:  s += "←"
        case .rightArrow: s += "→"
        case .home:       s += "Home"
        case .end:        s += "End"
        default:          s += String(key.character).uppercased()
        }
        return s
    }

    var description: String {
        switch self {
        case .quitApp:              return "App beenden"
        case .help, .helpAlt:       return "Hilfe anzeigen"
        case .focusSearch:          return "Suche fokussieren"
        case .focusSidebar:         return "Sidebar fokussieren"
        case .toggleInspector:      return "Inspector ein-/ausklappen"
        case .sectionJobs:          return "Sektion: Jobs"
        case .sectionBookmarks,
             .openBookmarks:        return "Sektion: Lesezeichen"
        case .sectionSettings:      return "Sektion: Einstellungen"
        case .refresh:              return "Aktualisieren"
        case .toggleAllUsers,
             .toggleAllUsersCmd:    return "Alle / meine Jobs"
        case .toggleRunningOnly:    return "Nur laufende"
        case .submitJob:            return "Neuer Batch-Job"
        case .interactiveSession:   return "Interaktive Session"
        case .attachSelected:       return "Attach zum Job"
        case .cancelSelected:       return "Job beenden (scancel)"
        case .bookmarkSelected:     return "Lesezeichen setzen"
        case .clearSelection:       return "Auswahl / Modal schliessen"
        case .cyclePartition:       return "Nächste Partition (Sheet)"
        case .nodesOverview:        return "Knoten-Übersicht (alle Partitionen)"
        case .editScript:           return "Skript editieren (Terminal)"
        case .openTerminal:         return "SSH-Shell in Terminal"
        case .batchQos:             return "QoS ändern (Auswahl)"
        case .batchPartition:       return "Partition ändern (Auswahl)"
        case .prevSortColumn,
             .prevSortColumnArrow:  return "Sort-Spalte zurück"
        case .nextSortColumn,
             .nextSortColumnArrow:  return "Sort-Spalte vor"
        case .toggleSortDir,
             .toggleSortDirAltS,
             .toggleSortDirAltD:    return "Sort-Richtung toggle"
        case .toggleFollow:         return "Log Follow-Mode"
        case .focusLiveGpu:         return "Zur Live-GPU-Card"
        case .focusLogs:            return "Zur Log-Card"
        case .copyActiveLog:        return "Active Log kopieren"
        case .toggleLogStream:      return "stderr/stdout umschalten"
        case .cursorDownVim,
             .cursorUpVim:          return "Cursor ↑/↓ (Vim)"
        case .cursorTop, .cursorBottom,
             .cursorTopCmd, .cursorBottomCmd:
                                    return "Erster / letzter Job"
        }
    }

    enum Category: String, CaseIterable {
        case navigation = "Navigation"
        case tableNav   = "Tabelle"
        case jobs       = "Jobs"
        case sort       = "Sortieren"
        case detail     = "Job-Detail"
    }
}

extension Shortcut {
    /// Layout-neutral button that triggers the shortcut on key press.
    /// `condition` lets the caller disable the shortcut conditionally.
    static func hiddenButton(_ s: Shortcut, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(s.key, modifiers: s.modifiers)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// Help-overlay rows: groups identical-helpGroup cases into one logical
    /// row so the user doesn't see three duplicated "Sort toggle" lines.
    static func helpRows(in category: Category) -> [(humanKey: String, description: String)] {
        var rows: [(String, String)] = []
        var seenGroups: Set<String> = []
        for sc in Shortcut.allCases where sc.category == category {
            if let g = sc.helpGroup {
                if seenGroups.contains(g) { continue }
                seenGroups.insert(g)
                let combined = Shortcut.allCases
                    .filter { $0.helpGroup == g }
                    .map(\.humanKey)
                rows.append((combined.joined(separator: " · "), sc.description))
            } else {
                rows.append((sc.humanKey, sc.description))
            }
        }
        return rows
    }
}
