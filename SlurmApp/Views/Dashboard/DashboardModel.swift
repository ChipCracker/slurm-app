import SwiftUI

/// Ein Panel, das auf dem konfigurierbaren Jobs-Dashboard platziert werden kann.
/// Bewusst klein gehalten: die Engine kennt nur diese Kennungen, die konkrete
/// SwiftUI-View wird in `JobsView` zugeordnet.
enum DashboardWidget: String, Codable, CaseIterable, Identifiable {
    case jobs            // Job-Tabelle + Filterleiste
    case detail          // Detail / Logs / GPU-Stats des gewählten Jobs
    case cluster         // Kombinierte Cluster-Spalte (Belegung + Quotas + Stunden)
    case gpuAllocation   // GPU-Belegung pro Partition (einzeln)
    case diskQuotas      // Speicher-Quota-Karten (einzeln)
    case gpuHours        // GPU-Stunden-Ranking (einzeln)

    var id: String { rawValue }

    var title: String {
        // String-Property ⇒ lokalisiert nicht automatisch wie Text-Literale.
        switch self {
        case .jobs:          String(localized: "Jobs")
        case .detail:         String(localized: "Job-Detail")
        case .cluster:        String(localized: "Cluster-Info")
        case .gpuAllocation:  String(localized: "GPU-Belegung")
        case .diskQuotas:     String(localized: "Speicher-Quota")
        case .gpuHours:       String(localized: "GPU-Stunden")
        }
    }

    var symbol: String {
        switch self {
        case .jobs:          "list.bullet.rectangle.portrait"
        case .detail:         "doc.text.magnifyingglass"
        case .cluster:        "server.rack"
        case .gpuAllocation:  "rectangle.split.3x1"
        case .diskQuotas:     "internaldrive"
        case .gpuHours:        "clock.arrow.circlepath"
        }
    }

    /// Kleinste sinnvolle Größe in Rasterzellen (Breite × Höhe).
    var minSpan: (w: Int, h: Int) {
        switch self {
        case .jobs:    (2, 2)
        case .detail:  (2, 2)
        case .cluster: (1, 3)
        default:       (1, 1)
        }
    }
}

/// Platzierung eines Widgets im Raster — ganzzahlige Zellkoordinaten.
struct WidgetFrame: Codable, Equatable {
    var x: Int      // Spalte (0-basiert)
    var y: Int      // Zeile (0-basiert)
    var w: Int      // Breite in Spalten
    var h: Int      // Höhe in Zeilen

    /// Überlappt dieser Rahmen einen anderen (in Zellkoordinaten)?
    func intersects(_ o: WidgetFrame) -> Bool {
        x < o.x + o.w && x + w > o.x && y < o.y + o.h && y + h > o.y
    }
}

struct WidgetPlacement: Codable, Equatable, Identifiable {
    var widget: DashboardWidget
    var frame: WidgetFrame
    var id: DashboardWidget { widget }
}

/// Eine vollständige Anordnung: ein Raster aus `columns` Spalten und die
/// Platzierung jedes sichtbaren Widgets. Nicht enthaltene Widgets sind versteckt.
struct DashboardLayout: Codable, Equatable {
    var columns: Int
    var placements: [WidgetPlacement]

    /// Anzahl belegter Zeilen — für die Höhe des Canvas.
    var rows: Int {
        max(1, placements.map { $0.frame.y + $0.frame.h }.max() ?? 1)
    }

    func placement(for w: DashboardWidget) -> WidgetPlacement? {
        placements.first { $0.widget == w }
    }

    var hiddenWidgets: [DashboardWidget] {
        DashboardWidget.allCases.filter { placement(for: $0) == nil }
    }
}

/// Fertige Layouts, die in den Einstellungen angeboten werden.
enum DashboardPreset: String, CaseIterable, Identifiable {
    case classic     // slurm-tui-Nachbau
    case twoColumn   // Tabelle | Detail
    case focusJobs   // Tabelle oben, Detail unten
    case monitoring  // Cluster-Karten groß oben

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic:    String(localized: "Klassisch")
        case .twoColumn:  String(localized: "Zwei Spalten")
        case .focusJobs:  String(localized: "Fokus Jobs")
        case .monitoring: String(localized: "Monitoring")
        }
    }

    var subtitle: String {
        switch self {
        case .classic:    String(localized: "Tabelle + Detail links, Cluster-Karten rechts (wie slurm-tui)")
        case .twoColumn:  String(localized: "Tabelle und Detail nebeneinander, volle Höhe")
        case .focusJobs:  String(localized: "Tabelle über Detail, je volle Breite")
        case .monitoring: String(localized: "GPU-/Quota-/Stunden-Karten groß, Jobs darunter")
        }
    }

    var symbol: String {
        switch self {
        case .classic:    "rectangle.split.2x2"
        case .twoColumn:  "rectangle.split.2x1"
        case .focusJobs:  "rectangle.split.1x2"
        case .monitoring: "chart.bar.xaxis"
        }
    }

    var layout: DashboardLayout {
        switch self {
        case .classic:
            DashboardLayout(columns: 6, placements: [
                .init(widget: .jobs,    frame: .init(x: 0, y: 0, w: 4, h: 3)),
                .init(widget: .detail,  frame: .init(x: 0, y: 3, w: 4, h: 3)),
                // Kombinierte Spalte: GPU-Belegung huggt ihre Höhe,
                // Quotas + Stunden teilen sich den Rest (s. JobsView).
                .init(widget: .cluster, frame: .init(x: 4, y: 0, w: 2, h: 6)),
            ])
        case .twoColumn:
            DashboardLayout(columns: 6, placements: [
                .init(widget: .jobs,   frame: .init(x: 0, y: 0, w: 3, h: 6)),
                .init(widget: .detail, frame: .init(x: 3, y: 0, w: 3, h: 6)),
            ])
        case .focusJobs:
            DashboardLayout(columns: 6, placements: [
                .init(widget: .jobs,   frame: .init(x: 0, y: 0, w: 6, h: 3)),
                .init(widget: .detail, frame: .init(x: 0, y: 3, w: 6, h: 3)),
            ])
        case .monitoring:
            DashboardLayout(columns: 6, placements: [
                .init(widget: .gpuAllocation, frame: .init(x: 0, y: 0, w: 2, h: 3)),
                .init(widget: .diskQuotas,    frame: .init(x: 2, y: 0, w: 2, h: 3)),
                .init(widget: .gpuHours,      frame: .init(x: 4, y: 0, w: 2, h: 3)),
                .init(widget: .jobs,          frame: .init(x: 0, y: 3, w: 4, h: 3)),
                .init(widget: .detail,        frame: .init(x: 4, y: 3, w: 2, h: 3)),
            ])
        }
    }
}
