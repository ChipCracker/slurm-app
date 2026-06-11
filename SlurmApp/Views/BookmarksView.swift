import SwiftUI

struct BookmarksView: View {
    @EnvironmentObject var bookmarks: BookmarksStore

    var body: some View {
        NavigationStack {
            ZStack {
                SlurmyPaneBackground().ignoresSafeArea()
                if bookmarks.bookmarks.isEmpty {
                    SlurmyEmptyState(
                        title: "Keine Lesezeichen",
                        message: "Markiere Jobs mit dem Lesezeichen – Slurmy hebt sie hier für dich auf.",
                        mascotWidth: 220
                    )
                } else {
                    List {
                        ForEach(bookmarks.bookmarks) { b in
                            Button {
                                guard let jid = b.jobId else { return }
                                // Jump to the job: switch to the Jobs section and
                                // ask it to focus this id.
                                NotificationCenter.default.post(name: .switchSection, object: MainSection.jobs)
                                NotificationCenter.default.post(name: .openJob, object: jid)
                            } label: {
                                HStack {
                                    Image(systemName: b.jobId != nil ? "briefcase" : "doc.text")
                                        .foregroundColor(Theme.accent)
                                    VStack(alignment: .leading) {
                                        Text(b.label).foregroundColor(Theme.textPrimary)
                                        if let jid = b.jobId {
                                            Text("Job \(jid)").font(.caption.monospaced()).foregroundColor(Theme.textSecondary)
                                        } else if let path = b.scriptPath {
                                            Text(path).font(.caption.monospaced()).foregroundColor(Theme.textSecondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if b.jobId != nil {
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundColor(Theme.textSecondary.opacity(0.6))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(b.jobId == nil)
                            .listRowBackground(Theme.surface)
                        }
                        .onDelete { idx in
                            // Map offsets to ids BEFORE removing — removing by
                            // index while the array mutates would delete the
                            // wrong rows.
                            let ids = idx.map { bookmarks.bookmarks[$0].id }
                            ids.forEach { bookmarks.remove($0) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Lesezeichen")
            // Kein opaker Nav-Bar-Hintergrund — System-Bar = Liquid Glass.
        }
    }
}
