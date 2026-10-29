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

struct SharedSendTarget: Codable {
  let serverKey: String
  let deviceId: String
  var name: String?
  var platform: String?
  var conversationIdentifier: String {
    "globalsend-device:" + String(data: try! JSONEncoder().encode([serverKey, deviceId]), encoding: .utf8)!
  }
  static func fromConversationIdentifier(_ value: String?, name: String?) -> SharedSendTarget? {
    let prefix = "globalsend-device:"
    guard let value = value, value.hasPrefix(prefix),
          let data = String(value.dropFirst(prefix.count)).data(using: .utf8),
          let ids = try? JSONDecoder().decode([String].self, from: data), ids.count == 2,
          !ids[0].isEmpty, !ids[1].isEmpty else { return nil }
    return SharedSendTarget(serverKey: ids[0], deviceId: ids[1], name: name)
  }
}

struct ShareLaunchRequest {
  let batchId: String
  let target: SharedSendTarget?
  let text: String?
  static func parse(_ url: URL) throws -> ShareLaunchRequest? {
    guard url.scheme?.lowercased() == "globalsend" else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    func query(_ key: String) -> String? { components?.queryItems?.first { $0.name == key }?.value }
    let sending = url.host == "send"
    guard sending || url.host == "share",
          let id = query(sending ? "requestId" : "batchId"), let uuid = UUID(uuidString: id) else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    var target: SharedSendTarget?
    if let deviceId = query("deviceId"), !deviceId.isEmpty,
       let serverKey = query("serverKey"), !serverKey.isEmpty {
      target = SharedSendTarget(serverKey: serverKey, deviceId: deviceId, name: query("deviceName"))
    }
    let text = sending ? query("text") : nil
    if sending && (target == nil || text?.isEmpty != false) { throw CocoaError(.fileReadCorruptFile) }
    return ShareLaunchRequest(batchId: uuid.uuidString, target: target, text: text)
  }
  static func handoffURL(batchId: String) -> URL {
    var url = URLComponents()
    url.scheme = "globalsend"; url.host = "share"
    url.queryItems = [URLQueryItem(name: "batchId", value: batchId)]
    return url.url!
  }
}

struct SharedPayload: Codable {
  let batchId: String
  var paths: [String]
  var texts: [String]
  var temporaryPaths: [String]
  var error: String?
  var target: SharedSendTarget?
}

/// Compiled into both targets. The extension commits a manifest only after its
/// provider-owned temporary files have been copied into this stable container.
final class SharedInboxStore {
  let root: URL
  init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
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
  func apply(_ request: ShareLaunchRequest) throws {
    let manifest = root.appendingPathComponent(request.batchId + ".json")
    if FileManager.default.fileExists(atPath: manifest.path) {
      if let target = request.target {
        var payload = try JSONDecoder().decode(SharedPayload.self, from: Data(contentsOf: manifest))
        payload.target = target
        try commit(payload)
      }
    } else if let text = request.text {
      try commit(SharedPayload(batchId: request.batchId, paths: [], texts: [text], temporaryPaths: [], target: request.target))
    }
  }
  func pending() throws -> [SharedPayload] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
      .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
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
