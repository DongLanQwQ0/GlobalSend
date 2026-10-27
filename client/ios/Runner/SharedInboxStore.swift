import Foundation

struct SharedPayload: Codable {
  let batchId: String
  var paths: [String]
  var texts: [String]
  var temporaryPaths: [String]
  var error: String?
}

/// Compiled into both targets. The extension commits a manifest only after its
/// provider-owned temporary files have been copied into this stable container.
final class SharedInboxStore {
  let root: URL
  init(extensionOnly: Bool = false) throws {
    let manager = FileManager.default
    let group = Bundle.main.object(forInfoDictionaryKey: "GLOBALSEND_APP_GROUP_ID") as? String ?? "group.dev.globalsend.globalsend"
    if let container = manager.containerURL(forSecurityApplicationGroupIdentifier: group) {
      root = container.appendingPathComponent("ShareInbox", isDirectory: true)
    } else if !extensionOnly {
      root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ShareInbox", isDirectory: true)
    } else {
      throw NSError(domain: "GlobalSend.Share", code: 1, userInfo: [NSLocalizedDescriptionKey: "分享扩展尚未取得 App Group 授权，请用一致的组权限重新签名。"])
    }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func folder(_ batchId: String) throws -> URL {
    let location = root.appendingPathComponent(batchId, isDirectory: true)
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    return location
  }
  func copy(_ source: URL, to folder: URL, suggestedName: String? = nil) throws -> String {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let name = (suggestedName?.isEmpty == false ? suggestedName! : source.lastPathComponent) as NSString
    let leaf = name.lastPathComponent.isEmpty ? "shared-file" : name.lastPathComponent
    let item = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
    let target = item.appendingPathComponent(leaf)
    var coordinationError: NSError?
    var copyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
      do { try FileManager.default.copyItem(at: readable, to: target) }
      catch { copyError = error }
    }
    if let error = coordinationError { throw error }
    if let error = copyError { throw error }
    return target.path
  }
  func writeData(_ data: Data, to folder: URL, name: String) throws -> String {
    let item = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
    let target = item.appendingPathComponent((name as NSString).lastPathComponent)
    try data.write(to: target, options: .atomic)
    return target.path
  }
  func commit(_ payload: SharedPayload) throws {
    try JSONEncoder().encode(payload).write(to: root.appendingPathComponent(payload.batchId + ".json"), options: .atomic)
  }
  func pending() throws -> [SharedPayload] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
      .filter { $0.pathExtension == "json" }
      .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) }
      .map { try JSONDecoder().decode(SharedPayload.self, from: Data(contentsOf: $0)) }
  }
  func ack(_ id: String) throws {
    guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
    let manifest = root.appendingPathComponent(id + ".json")
    if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
    // Bytes now belong to the staged source/history, not to the inbox manifest.
  }
}
