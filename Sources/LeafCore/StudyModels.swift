import Foundation
import CryptoKit

public struct NotePlacement: Codable, Equatable {
    public var offsetX: Double
    public var offsetY: Double
    public init(offsetX: Double, offsetY: Double) { self.offsetX = offsetX; self.offsetY = offsetY }
}
public struct NoteAppearance: Codable, Equatable {
    public var font = "system"
    public var color = "#292d28"
    public var size: Double = 15
    public init() {}
}
public struct HighlightStyle: Codable, Equatable {
    public var kind = "highlight"
    public var color = "yellow"
    public init() {}
}
public struct DictionarySnapshot: Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var html: String
    public init(id: UUID, name: String, html: String) { self.id=id; self.name=name; self.html=html }
}
public struct QueryHistory: Codable, Identifiable {
    public var id: String
    public var kind: String
    public var query: String
    public var updatedAt: Date
    public var dictionaries: [DictionarySnapshot]
    public var analysis: String
    public var status: String
    public var model: String?
    public init(kind: String, query: String, dictionaries: [DictionarySnapshot] = [], analysis: String = "", status: String = "completed", model: String? = nil) {
        let canonical = query.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        self.id = SHA256.hash(data: Data((kind + ":" + canonical).utf8)).map { String(format: "%02x", $0) }.joined()
        self.kind=kind; self.query=query; self.dictionaries=dictionaries; self.analysis=analysis
        self.status=status; self.model=model; updatedAt=Date()
    }
}
public struct APIConfiguration: Codable, Equatable {
    public var baseURL = "https://api.openai.com/v1"
    public var model = ""
    public init() {}
    public func endpoint() throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw LeafError.invalid("Base URL 需要有效的 HTTPS 地址，本地调试可使用 localhost HTTP。")
        }
        var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { path = "v1" }
        if !path.hasSuffix("chat/completions") { path += "/chat/completions" }
        parts.path = "/" + path
        guard let url = parts.url else { throw LeafError.invalid("Base URL 无法解析。") }
        return url
    }
}

/// SSE is framed by blank lines, not by network packets or UTF-8 byte boundaries.
public struct SSEDecoder {
    private var lines: [String] = []
    public init() {}
    public mutating func consume(_ line: String) -> String? {
        let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if clean.isEmpty {
            guard !lines.isEmpty else { return nil }
            defer { lines.removeAll(keepingCapacity: true) }; return lines.joined(separator: "\n")
        }
        if clean.hasPrefix("data:") {
            var payload = String(clean.dropFirst(5)); if payload.first == " " { payload.removeFirst() }
            lines.append(payload)
        }
        return nil
    }
    public mutating func finish() -> String? { consume("") }
}
public enum ChatChunk: Equatable {
    case text(String)
    case finish(String?)
    public static func decode(_ data: String) throws -> ChatChunk? {
        if data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return .finish(nil) }
        guard let bytes = data.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        if object["error"] != nil { throw LeafError.invalid("模型服务在流式输出过程中返回错误，请重试或检查设置。") }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return nil }
        if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty { return .text(text) }
        if let reason = choice["finish_reason"] as? String { return .finish(reason) }
        return nil
    }
}
