import Foundation
import Combine

struct WordContext: Decodable {
    let text: String
    let forms: [String]?
    let first_seen: String?
    let last_seen: String?
}

struct BookExample: Decodable {
    let text: String
    let translation: String?
}

struct BookWord: Decodable, Identifiable {
    let lemma: String
    let phonetic: String?
    let translation: String?
    let forms: [String]?
    let contexts: [WordContext]?
    let example: BookExample?
    let first_seen: String?
    let last_seen: String?
    var id: String { lemma }
}

struct Passage: Identifiable {
    let text: String
    var words: [String: [String]]
    var added: String
    var id: String { text }
}

enum BookOrder: String, CaseIterable, Identifiable {
    case newest, oldest, ascending, descending
    var id: Self { self }
    var title: String {
        switch self {
        case .newest: return "收录时间 · 新到旧"
        case .oldest: return "收录时间 · 旧到新"
        case .ascending: return "字母 · A 到 Z"
        case .descending: return "字母 · Z 到 A"
        }
    }

    func precedes(_ a: String, _ b: String, addedA: String, addedB: String) -> Bool {
        if addedA != addedB {
            if self == .newest { return addedA > addedB }
            if self == .oldest { return addedA < addedB }
        }
        let order = a.localizedStandardCompare(b)
        if order == .orderedSame { return self == .descending ? a > b : a < b }
        return self == .descending ? order == .orderedDescending : order == .orderedAscending
    }
}

struct BookIndex {
    var words: [BookWord] = []
    var passages: [Passage] = []
    var byWord: [String: BookWord] = [:]
    var wordText: [String: String] = [:]
    var passageText: [String: String] = [:]

    static func searchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    init(words input: [BookWord] = []) {
        words = input
        var groups: [String: Passage] = [:]
        for word in words {
            byWord[word.lemma] = word
            let core = ([word.lemma, word.translation ?? ""] + (word.forms ?? [])).joined(separator: "\n")
            let contexts = word.contexts ?? []
            let related = contexts.map(\.text) + [word.example?.text ?? ""]
            wordText[word.id] = Self.searchText(([core] + related).joined(separator: "\n"))
            for context in contexts {
                let added = context.first_seen ?? context.last_seen ?? word.first_seen ?? word.last_seen ?? ""
                var group = groups[context.text] ?? Passage(text: context.text, words: [:], added: added)
                group.words[word.lemma] = context.forms ?? [word.lemma]
                group.added = min(group.added, added)
                groups[context.text] = group
            }
        }
        passages = Array(groups.values)
        for p in passages {
            let related = p.words.keys.sorted().flatMap { lemma in
                [lemma, byWord[lemma]?.translation ?? ""] + (p.words[lemma] ?? [])
            }
            passageText[p.id] = Self.searchText(([p.text] + related).joined(separator: "\n"))
        }
    }

    func wordIDs(matching query: String, order: BookOrder) -> [String] {
        let q = Self.searchText(query)
        return words.filter { q.isEmpty || wordText[$0.id]?.contains(q) == true }.sorted {
            order.precedes($0.id, $1.id, addedA: $0.first_seen ?? $0.last_seen ?? "", addedB: $1.first_seen ?? $1.last_seen ?? "")
        }.map(\.id)
    }

    func passages(matching query: String, order: BookOrder) -> [Passage] {
        let q = Self.searchText(query)
        return passages.filter { q.isEmpty || passageText[$0.id]?.contains(q) == true }.sorted {
            order.precedes($0.text, $1.text, addedA: $0.added, addedB: $1.added)
        }
    }

}

struct BookLocation {
    static let project = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OptionD", isDirectory: true)
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["IELTS_LOOKUP_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.project
    }
    var reading: URL { root.appendingPathComponent("Reading", isDirectory: true) }
    var json: URL { reading.appendingPathComponent("查词自动收录.json") }
    var wordDocument: URL { reading.appendingPathComponent("查词自动收录.docx") }
}

// This process observes the atomic export in its directory. It never takes the lookup writer's lock.
final class BookFeed {
    private struct Export: Decodable { let entries: [BookWord] }
    private let queue = DispatchQueue(label: "reading.book.snapshot", qos: .utility)
    private let location: BookLocation
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stamp: String?
    private let publish: (Result<BookIndex, Error>) -> Void

    init(_ location: BookLocation, publish: @escaping (Result<BookIndex, Error>) -> Void) {
        self.location = location
        self.publish = publish
    }

    func start() {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: location.reading, withIntermediateDirectories: true)
            let fd = open(location.reading.path, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: queue)
                source.setEventHandler { [weak self] in self?.schedule() }
                source.setCancelHandler { close(fd) }
                watcher = source
                source.resume()
            }
            read()
        }
    }

    func refresh() { queue.async { self.read() } }

    private func schedule() {
        // Coalesce the several sibling files updated by one export, without postponing reads indefinitely.
        guard pending == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.pending = nil; self?.read() }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.14, execute: item)
    }

    private func read() {
        do {
            let url = location.json
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let next = "\(attrs[.systemFileNumber] ?? "")-\(attrs[.size] ?? "")-\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            guard stamp != next else { return }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Export.self, from: data)
            let index = BookIndex(words: decoded.entries)
            stamp = next
            publish(.success(index))
        } catch let e as NSError {
            if e.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code),
               !FileManager.default.fileExists(atPath: location.reading.appendingPathComponent(".查词数据/records.sqlite").path) {
                stamp = nil
                publish(.success(BookIndex()))
            } else {
                stamp = nil
                publish(.failure(e))
            }
        }
    }

    deinit { watcher?.cancel() }
}

final class BookStore: ObservableObject {
    @Published var index = BookIndex()
    @Published var loaded = false
    @Published var problem: String?
    @Published var revision = 0
    let location: BookLocation
    private var feed: BookFeed?

    init(location: BookLocation = BookLocation()) {
        self.location = location
        feed = BookFeed(location) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let updated):
                    self.index = updated
                    self.loaded = true
                    self.problem = nil
                    self.revision += 1
                case .failure(let error):
                    self.loaded = true
                    self.problem = error.localizedDescription
                }
            }
        }
        feed?.start()
    }

    func refresh() { feed?.refresh() }
}
