# Slurmy — Design & Brand Guide

> **Slurmy** ist neugierig, freundlich und bringt Daten zum Leuchten.
> Er macht komplexe Cluster & Systeme **sichtbar, verständlich und lebendig.**

Slurmy ist eine native App (iPhone · iPad · Mac) zum Überwachen und Steuern von
**Slurm-HPC-Clustern**: Jobs ansehen, GPU-Auslastung live verfolgen, Logs lesen,
Jobs einreichen/abbrechen. Zielgruppe: ML-/Research-Leute, die täglich mit
GPU-Clustern arbeiten. Tonalität: **technisch kompetent, aber freundlich und
verspielt** — ein seriöses Tool mit Charakter.

---

## Maskottchen — Slurmy, die leuchtende Cluster Raupe

Eine **freundliche, segmentierte Raupe**. Die Körpersegmente stehen für die
**Nodes eines Clusters** — jedes trägt einen leuchtenden Cyan-„Node". Slurmy
„kriecht durch den Cluster" und behält die Jobs im Blick.

**Charakterattribute:** Neugierig · Freundlich · Intelligent · Zuverlässig · Leuchtend

**Slogans:**
- „Clusters, simplified. Beautifully."
- „Data comes alive."

**Stil:** flache Vektor-Illustration, **kräftige dunkle Outline** (`#12173D`),
weiche runde Formen, sanfte Verläufe in den Flächen, leuchtende Cyan-Highlights
mit weichem Glow, kein harter Schatten, transparenter Hintergrund.

---

## Logo

- **Wortmarke:** „Slurmy" + Subline „die leuchtende Cluster Raupe".
- **Varianten:** Maskottchen-only (App-Icon), horizontal (Maskottchen links +
  Wortmarke rechts), gestapelt (Maskottchen oben + Wortmarke darunter).
- Mindestabstand = Höhe eines Raupen-Segments rundum. Nicht verzerren, nicht
  umfärben, Outline nie entfernen.

---

## Farbpalette

| Token | Hex | Rolle |
|-------|-----|-------|
| Indigo Deep   | `#211F54` | Basis / dunkler Hintergrund, Verlaufsstart |
| Blue Mid      | `#26459E` | Verlauf, Flächen |
| Blue Bright   | `#2973EB` | Primär-Akzent (hell), Verlaufsende |
| Blue Light    | `#578FFA` | Körper-Verlauf oben, helle Akzente |
| Indigo        | `#262973` | Körper-Verlauf unten, Tiefen |
| Navy (Outline)| `#12173D` | Konturen, dunkelster Text auf Hell |
| Cyan Node     | `#9EE0FF` | Leuchtende Nodes, Highlights, Cheeks |
| Cyan Glow     | `#D1F5FF` | Glow-Spitzen, hellste Highlights |

**Verlauf (Standard):** diagonal/vertikal `#578FFA → #262973` (hell oben → tief
unten). Leuchtende Elemente bekommen einen weichen Cyan-Glow (`#9EE0FF` → transparent).

### Mapping auf die App-Themes (`Theme.swift`)
Die App ist Dark-first, unterstützt aber Hell/Dunkel/Automatisch. Die Akzentfarbe
ist als „Farbthema" wählbar; **Blau** ist der Marken-Default und entspricht der
Palette oben. Statusfarben (running/pending/failed) sind bewusst von der
Markenpalette entkoppelt und bleiben über alle Themes konstant.

---

## Typografie

**Inter** (gesamte UI & Marketing).
- Headlines: Inter Bold / SemiBold
- Body: Inter Regular / Medium
- Technische Werte (Job-IDs, Pfade, Logs, GPU-Zahlen): **monospaced**
  (System-Monospace bzw. „Inter"-Tabularziffern), damit Spalten ausrichten.

---

## Motiv: das Node-Grid

Durchgängiges Leitmotiv: **abgerundete Quadrate (Compute-Nodes)**, einige davon
leuchten cyan (= laufende Jobs). Es zieht sich durch App-Icon, Maskottchen
(Segment-Nodes), Ladeanimation und UI-Akzente. Eckenradius ~22 % („Squircle").

---

## Formensprache

- Abgerundete Rechtecke, Squircle-Ecken (~22 %).
- Karten: weicher Hintergrund + 1px Border, Radius 14.
- Glas-Modals: `.ultraThinMaterial` + getönter Verlauf.
- Fokus-/Cursor-Hinweis: schlanke Akzent-Leiste an der Kante (kein harter Rahmen).

---

## Stimme & Texte

Freundlich, klar, ohne Fachjargon-Überladung. Deutsch in der UI. Fehlertexte
zeigen die **echte** Ursache (z. B. die libssh2/Slurm-Meldung), nicht generische
Floskeln. Leere Zustände sprechen mit Slurmy in der ersten Person-Geste
(„Keine Jobs — alles ruhig im Cluster.").

---

## Asset-Inventar

**`branding/` (Quellen, versioniert):**
- `Icon.png` — offizielles App-Icon (Squircle-Master, 1254²)
- `slurmy.png` — Maskottchen, transparent (1536×1024)
- `Moodboard.png`, `Moodboard2.png` — Brand-Übersicht
- `Brandings.png`, `Brandings_hell.png` — Merchandise-Mockups (dunkel/hell)
- `Visitenkarten.png`, `CW_Visitenkarte.png`, `PS_Visitenkarte.png` — Visitenkarten
- `slurmy_loading.gif` — abstrahierte Lade-Animation (Node-Welle)

**In der App (`SlurmApp/Resources/Assets.xcassets/`):**
- `AppIcon.appiconset` — aus `Icon.png` re-mastert: iOS full-bleed (Indigo-Ecken)
  + macOS Squircle mit transparentem Rand.
- `AppIconPreview.imageset` — Icon-Vorschau (Settings-Header).
- `SlurmyMascot.imageset` — Maskottchen (`slurmy.png`) für Empty-States & Branding.
- `LaunchBackground.colorset` — adaptiver Startbildschirm-Hintergrund.

**In-App-Komponenten:**
- `SlurmyLoadingView` — abstrahierte Raupen-/Node-Wellen-Animation als Spinner-Ersatz.
- `SlurmyEmptyState` — Maskottchen + Hinweistext für leere/getrennte Zustände.

---

## Regenerieren der App-Icons aus `Icon.png`

Die App-Icon-PNGs werden aus `branding/Icon.png` abgeleitet (Inhalt automatisch
freigestellt, weißer Rand entfernt). Bei einem neuen `Icon.png` die Master neu
rendern (iOS full-bleed + macOS Squircle) und die mac-Größen via `sips` skalieren.
