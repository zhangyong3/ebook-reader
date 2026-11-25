import Foundation

public enum LeafError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct ReadingSettings: Codable, Equatable {
    public var fontSize: Double = 22
    public var lineHeight: Double = 1.8
    public var width: Double = 680
    public var theme = "paper"
    public var font = "serif"
    public var scrolling = false
    public init() {}
}

public struct Book: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var author: String
    public var packagePath: String
    public var importedAt: Date
    public var lastOpened: Date
    public var location: String?
    public var progression: Double
    public var settings: ReadingSettings
    public init(id: String, title: String, author: String, packagePath: String) {
        self.id = id; self.title = title; self.author = author; self.packagePath = packagePath
        importedAt = Date(); lastOpened = Date(); progression = 0; settings = ReadingSettings()
    }
}

public struct Annotation: Codable, Identifiable, Equatable {
    public var id: UUID
    public var bookID: String
    public var cfi: String
    public var href: String
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var chapter: String
    public var kind: String
    public var color: String
    public var note: String
    public var createdAt: Date
    public var placement: NotePlacement?
    public var noteAppearance: NoteAppearance?
    public init(bookID: String, cfi: String, href: String = "", quote: String, prefix: String = "", suffix: String = "", chapter: String = "", kind: String = "highlight", color: String = "yellow", note: String = "") {
        id = UUID(); self.bookID = bookID; self.cfi = cfi; self.href = href; self.quote = quote
        self.prefix = prefix; self.suffix = suffix; self.chapter = chapter; self.kind = kind
        self.color = color; self.note = note; createdAt = Date()
    }
}

public struct DictionaryRecord: Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var priority: Int?
    public init(name: String, path: String, bookmark: Data?, priority: Int = 0) {
        id = UUID(); self.name = name; self.path = path; self.bookmark = bookmark; self.priority = priority
    }
}

public struct Backup: Codable {
    public var version: Int = 1
    public var exportedAt: Date = Date()
    public var books: [Book]
    public var annotations: [Annotation]
    public init(books: [Book], annotations: [Annotation]) { self.books = books; self.annotations = annotations }
}

public struct TOCEntry: Identifiable, Decodable {
    public var id: String { href }
    public let label: String
    public let href: String
    public let depth: Int
}

public struct SearchHit: Identifiable, Decodable {
    public var id: String { cfi }
    public let cfi: String
    public let excerpt: String
}

public enum Exporter {
    public static func markdown(book: Book, annotations: [Annotation]) -> String {
        var lines = ["# \(book.title)", "", book.author, ""]
        for item in annotations.sorted(by: { $0.createdAt < $1.createdAt }) {
            lines += ["## \(item.chapter.isEmpty ? "摘录" : item.chapter)", ""]
            lines += item.quote.components(separatedBy: .newlines).map { "> \($0)" }
            if !item.note.isEmpty { lines += ["", item.note] }
            lines += ["", "位置：`\(item.cfi)`", ""]
        }
        return lines.joined(separator: "\n")
    }
}
