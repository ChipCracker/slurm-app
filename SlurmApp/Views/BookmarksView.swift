import SwiftUI

struct BookmarksView: View {
    @EnvironmentObject var bookmarks: BookmarksStore

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if bookmarks.bookmarks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bookmark")
                            .font(.largeTitle)
                            .foregroundColor(Theme.textSecondary)
                        Text("Keine Bookmarks")
                            .foregroundColor(Theme.textSecondary)
                    }
                } else {
                    List {
                        ForEach(bookmarks.bookmarks) { b in
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
                            }
                            .listRowBackground(Theme.surface)
                        }
                        .onDelete { idx in
                            for i in idx { bookmarks.remove(bookmarks.bookmarks[i].id) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Marken")
            .navBarBackground(Theme.background)
        }
    }
}
