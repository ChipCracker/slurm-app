# Konfigurierbares Dashboard — Konzept

Ziel: Auf dem **Jobs-Screen** soll sich jedes Panel (Tabelle, Job-Detail,
GPU-Belegung, Speicher-Quota, GPU-Stunden) frei **verschieben und in der Größe
ändern** lassen, damit sich jede:r das Layout so hinlegt, wie es zur eigenen
Arbeit passt. Dazu kommen **fertige Layouts** (Presets) in den Einstellungen.

Abgeleitet vom TUI-Vorbild [slurm-tui](https://github.com/ChipCracker/slurm-tui),
dessen Split-Pane-Aufteilung (GPU/Resource links, Partition oben rechts, Jobs +
Logs unten rechts) das "Klassisch"-Preset nachbildet.

## Interaktionsmodell: Grid-Snap

Widgets rasten in ein **Spaltenraster** ein (Standard: 6 Spalten). Verschieben
per Drag, Größe per Eck-Griff — beides rastet in ganze Zellen ein. Das ist
robust über alle Bildschirmgrößen, leicht persistierbar und macht die fertigen
Layouts exakt reproduzierbar.

```
┌─────────┬─────────┬─────────┐
│ Jobs    │ Jobs    │ GPU     │   6 Spalten
│ (4×3)   │         │ Alloc   │   Zeilenhöhe fix, Canvas scrollt vertikal
│         │         ├─────────┤
│         │         │ Quotas  │   Drag    → verschieben (snap)
├─────────┴─────────┼─────────┤   Eck-Griff → Größe (snap, ≥ minSpan)
│ Detail (4×3)      │ Hours   │   Auge    → Widget aus-/einblenden
└───────────────────┴─────────┘
```

## Architektur

Drei kleine, wiederverwendbare Bausteine unter `SlurmApp/Views/Dashboard/`:

| Datei | Inhalt |
|-------|--------|
| `DashboardModel.swift` | `DashboardWidget` (welche Panels), `WidgetFrame` (x/y/w/h in Zellen), `WidgetPlacement`, `DashboardLayout`, die `DashboardPreset`-Presets. Reine Wert-Typen, `Codable`. |
| `DashboardStore.swift` | `@MainActor ObservableObject`. Hält das aktive `DashboardLayout`, persistiert als JSON in `UserDefaults` (`jobsDashboardLayout`/`jobsDashboardPreset`). Mutationen: `move`, `resize`, `toggle`, `apply(preset)`, `reset`. |
| `DashboardGridView.swift` | Generischer Grid-Container. Rechnet Zellgeometrie aus der verfügbaren Breite, positioniert jedes Widget, und liefert im **Edit-Modus** Drag-/Resize-Gesten mit Einrasten, Clamping und Overlap-Schutz. Inhalt jedes Widgets wird per `content: (DashboardWidget) -> View` injiziert — die Engine kennt die Slurm-Views nicht. |

### Layout-Modus statt Umbau

Der Jobs-Screen behält seinen bewährten 3-Pane-`HSplitView` **als Default**
(`jobsLayoutMode = .split`) — null Regression für die Tastatur-Navigation,
Mehrfachauswahl und Modal-Logik. Zusätzlich gibt es `.dashboard`: derselbe
Inhalt (Tabelle, Detail, Cluster-Karten) wird über die Grid-Engine platziert.
Umschalten per Toolbar-Toggle oder durch Auswahl eines Presets in den Settings.

- **Edit-Modus aus** (Default): Widgets sind voll interaktiv — Tabelle scrollt,
  Zeilen sind wählbar, Tastatur-Fokus (`table`/`detail`) funktioniert wie gehabt.
- **Edit-Modus an**: Inhalt wird inaktiv geschaltet, jedes Widget zeigt
  Kopfleiste (Titel + Sichtbarkeits-Toggle) und Eck-Griff; Gesten verschieben /
  skalieren. So kollidieren Drag-Gesten nie mit Tabellen-Scroll/-Auswahl.

### Einrasten & Kollision

- Verschieben: neue Zelle = `round(Pixeloffset / (Zellgröße + Abstand))`,
  geclamped in `[0, columns − w]` bzw. `y ≥ 0`.
- Größe: analog, Mindestgröße `widget.minSpan`, max. bis Rasterrand.
- Overlap: Drops, die ein anderes Widget überdecken würden, werden **verworfen**
  (Snap-Back, animiert) — so bleibt das Raster sauber und Presets bleiben gültig.

## Fertige Layouts (Presets)

In `DashboardPreset`, anwählbar unter **Einstellungen › Dashboard**:

| Preset | Idee |
|--------|------|
| **Klassisch** | slurm-tui-Nachbau: große Job-Tabelle links oben, Detail links unten, Cluster-Karten (GPU/Quota/Stunden) rechts gestapelt. |
| **Zwei Spalten** | Tabelle links, Detail rechts, je volle Höhe. Cluster-Karten ausgeblendet — maximaler Platz für Jobs + Detail. |
| **Fokus Jobs** | Tabelle oben über volle Breite, Detail darunter über volle Breite. Für reines Job-Monitoring. |
| **Monitoring** | Cluster-Karten (GPU-Belegung, Quota, GPU-Stunden) oben groß, Tabelle + Detail darunter. Für Auslastungs-Blick. |

Eigene Anpassungen setzen den Preset-Namen auf „Eigenes" und werden persistiert;
„Zurücksetzen" stellt **Klassisch** wieder her.

## Plattformen

- **macOS / iPad (regular width)**: volle Grid-Engine inkl. Edit-Modus.
- **iPhone (compact width)**: behält die touch-optimierte Einspalten-Liste — ein
  frei platzierbares Grid ist auf einem Telefon-Hochformat kaum sinnvoll. Presets
  und Edit-Modus sind dort ausgeblendet.

## Offene Punkte / mögliche Erweiterungen

- Inspector-Pfeil-Cursor (`j/k` über Partitionen) ist ein Split-Modus-Feature;
  im Dashboard sind die Cluster-Karten per Klick/Tap bedienbar.
- Pro-Gerät getrennte Layouts (macOS- vs. iPad-Persistenz) wären ein nächster
  Schritt; aktuell teilen sie sich den `UserDefaults`-Schlüssel.
- Optional: freies (überlappendes) Positionieren als Power-User-Schalter.
