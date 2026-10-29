import Foundation

enum SharedInboxGroup {
  static func hostBundleURL(for bundleURL: URL) -> URL {
    bundleURL.pathExtension == "appex"
      ? bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      : bundleURL
  }

  static func container(configuredGroup: String, hostBundleIdentifier: String?,
                        locate: (String) -> URL?) -> URL? {
    // iloader signs the host and all extensions into group.<resigned host ID>.
    // Its rewritten entitlement does not update our custom Info.plist key.
    // Keep existing installations on their configured group when available.
    if let container = locate(configuredGroup) { return container }
    if let host = hostBundleIdentifier {
      let resignedGroup = "group." + host
      if resignedGroup != configuredGroup { return locate(resignedGroup) }
    }
    return nil
  }
}

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
    let host = Bundle(url: SharedInboxGroup.hostBundleURL(for: Bundle.main.bundleURL))
    if let container = SharedInboxGroup.container(configuredGroup: group,
        hostBundleIdentifier: host?.bundleIdentifier,
        locate: { manager.containerURL(forSecurityApplicationGroupIdentifier: $0) }) {
      root = container.appendingPathComponent("ShareInbox", isDirectory: true)
    } else if !extensionOnly {
      root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ShareInbox", isDirectory: true)
    } else {
      throw NSError(domain: "GlobalSend.Share", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开分享空间，请用同一账号一起签名主应用和分享扩展，并保留扩展。"])
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
