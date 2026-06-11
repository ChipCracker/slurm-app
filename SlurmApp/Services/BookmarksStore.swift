import Foundation

@MainActor
final class BookmarksStore: ObservableObject {
    @Published var bookmarks: [Bookmark] = []

    private let url: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.url = docs.appendingPathComponent("bookmarks.json")
        load()
    }

    func add(_ bookmark: Bookmark) {
        bookmarks.append(bookmark)
        save()
    }

    func remove(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    private func load() {
        // No file yet on first launch is normal — don't log that. A file that
        // exists but won't decode is corruption: surface it instead of silently
        // starting empty (which would then overwrite the file on the next save
        // and lose everything).
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            bookmarks = try JSONDecoder().decode([Bookmark].self, from: data)
        } catch {
            Log.store.error("Lesezeichen konnten nicht geladen werden: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.store.error("Lesezeichen konnten nicht gespeichert werden: \(error.localizedDescription, privacy: .public)")
        }
    }
}
