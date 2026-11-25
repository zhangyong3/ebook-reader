import Foundation
import CryptoKit
import Darwin

/// Local credentials are separate from the library database and exported note backups.
public struct LocalAPIKeyStore {
    public let fileURL: URL
    public init(root: URL) { fileURL=root.appendingPathComponent("api-keys.json") }
    private func account(_ base: String) -> String {
        let canonical=base.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        return SHA256.hash(data:Data(canonical.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func load() throws -> [String:String] {
        guard FileManager.default.fileExists(atPath:fileURL.path) else { return [:] }
        do { return try JSONDecoder().decode([String:String].self,from:Data(contentsOf:fileURL)) }
        catch { throw LeafError.invalid("无法读取本地 API Key 文件，请检查应用数据目录中的 api-keys.json。") }
    }
    public func read(baseURL: String) throws -> String? { try load()[account(baseURL)] }
    /// Empty input clears the credential for this service; other services retain their keys.
    public func save(_ key: String, baseURL: String) throws {
        var values=try load()
        let trimmed=key.trimmingCharacters(in:.whitespacesAndNewlines)
        values[account(baseURL)]=trimmed.isEmpty ? nil : trimmed
        let data=try JSONEncoder().encode(values), manager=FileManager.default
        try manager.createDirectory(at:fileURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let temporary=fileURL.deletingLastPathComponent().appendingPathComponent(".api-keys-"+UUID().uuidString)
        defer { try? manager.removeItem(at:temporary) }
        guard manager.createFile(atPath:temporary.path,contents:data,attributes:[.posixPermissions:0o600]) else {
            throw LeafError.invalid("无法保存本地 API Key 文件。")
        }
        guard rename(temporary.path,fileURL.path)==0 else { throw LeafError.invalid("无法更新本地 API Key 文件。") }
    }
}
