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
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
