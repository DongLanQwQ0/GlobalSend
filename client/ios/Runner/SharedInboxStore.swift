import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import ImageIO
import UniformTypeIdentifiers
#endif

#if canImport(UniformTypeIdentifiers) && canImport(ImageIO)
#if canImport(UIKit)
import UIKit
#endif

enum SharedItemLoader {
  static func canLoad(_ provider: NSItemProvider) -> Bool {
    provider.registeredTypeIdentifiers.contains { value in
      guard let type = UTType(value) else { return false }
      return type.conforms(to: .data) || type.conforms(to: .item)
    } || hasImageObject(provider)
  }
  static func hasImageObject(_ provider: NSItemProvider) -> Bool {
    #if canImport(UIKit)
    return provider.canLoadObject(ofClass: UIImage.self)
    #else
    return false
    #endif
  }
  static func load(_ provider: NSItemProvider, store: SharedInboxStore, folder: URL, completed: @escaping (String?, String?, Error?) -> Void) {
    SharedProviderImport(provider, store: store, folder: folder, completed: completed).start()
  }
  static func url(_ item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let text = item as? String { return URL(string: text) }
    if let data = item as? Data, let text = String(data: data, encoding: .utf8) { return URL(string: text) }
    return nil
  }
  static func imageURL(_ url: URL, name: String?) -> Bool {
    if url.scheme?.lowercased() == "data" { return url.absoluteString.lowercased().hasPrefix("data:image/") }
    return [url.pathExtension, ((name ?? "") as NSString).pathExtension].contains {
      UTType(filenameExtension: $0)?.conforms(to: .image) == true
    }
  }
  static func loadURL(_ url: URL, image: Bool, store: SharedInboxStore, folder: URL, name: String?, completed: @escaping (String?, String?, Error?) -> Void) {
    if url.isFileURL {
      do { completed(try store.copy(url, to: folder, suggestedName: name), nil, nil) }
      catch { completed(nil, nil, error) }
    } else if url.scheme?.lowercased() == "data", url.absoluteString.lowercased().hasPrefix("data:image/"),
              let comma = url.absoluteString.firstIndex(of: ",") {
      let header = String(url.absoluteString[..<comma]), body = String(url.absoluteString[url.absoluteString.index(after: comma)...])
      let mime = String(header.dropFirst(5).split(separator: ";")[0])
      let data = header.lowercased().contains(";base64") ? Data(base64Encoded: body, options: .ignoreUnknownCharacters) : percentData(body)
      guard let data = data else { completed(nil, nil, CocoaError(.fileReadCorruptFile)); return }
      do { completed(try store.writeData(data, to: folder, name: name ?? "shared-image", typeIdentifiers: [UTType(mimeType: mime)?.identifier ?? UTType.image.identifier]), nil, nil) }
      catch { completed(nil, nil, error) }
    } else if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), image || imageURL(url, name: name) {
      URLSession.shared.downloadTask(with: url) { file, response, error in
        guard let file = file, let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") == true || CGImageSourceCreateWithURL(file as CFURL, nil) != nil else {
          completed(nil, nil, error ?? CocoaError(.fileReadCorruptFile)); return
        }
        let types = response.mimeType.flatMap { UTType(mimeType: $0) }.map { [$0.identifier] } ?? []
        do { completed(try store.copy(file, to: folder, suggestedName: name ?? response.suggestedFilename, typeIdentifiers: types), nil, nil) }
        catch { completed(nil, nil, error) }
      }.resume()
    } else if url.scheme?.lowercased() == "blob" || image {
      completed(nil, nil, NSError(domain: "GlobalSend.Share", code: 2, userInfo: [NSLocalizedDescriptionKey: "浏览器未提供可读取的图片数据"]))
    } else { completed(nil, url.absoluteString, nil) }
  }
  private static func percentData(_ text: String) -> Data? {
    let bytes = Array(text.utf8)
    var data = Data(), index = 0
    while index < bytes.count {
      if bytes[index] == 37 {
        guard index + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else { return nil }
        data.append(value); index += 3
      } else { data.append(bytes[index]); index += 1 }
    }
    return data
  }
}

/// Safari often advertises the page URL before its image. Try the original
/// image's file/data representations first, and continue when one is unavailable.
private final class SharedProviderImport {
  typealias Finish = (String?, String?, Error?) -> Void
  typealias Attempt = (@escaping Finish) -> Void
  private var attempts: [Attempt] = []
  private var index = 0
  private let completed: Finish
  init(_ provider: NSItemProvider, store: SharedInboxStore, folder: URL, completed: @escaping Finish) {
    self.completed = completed
    let types = provider.registeredTypeIdentifiers
    let images = types.filter { UTType($0)?.conforms(to: .image) == true }
    let hasImage = !images.isEmpty || SharedItemLoader.hasImageObject(provider)
    let hasURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    NSLog("GlobalSend import provider types: %@", types.joined(separator: ","))
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      attempts.append { finish in
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
          guard let url = SharedItemLoader.url(item), url.isFileURL else { finish(nil, nil, error ?? CocoaError(.fileReadUnknown)); return }
          do { finish(try store.copy(url, to: folder, suggestedName: provider.suggestedName, typeIdentifiers: types), nil, nil) }
          catch { finish(nil, nil, error) }
        }
      }
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier) {
      attempts.append { finish in
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.folder.identifier) { file, _, error in
          guard let file = file else { finish(nil, nil, error); return }
          do { finish(try store.copy(file, to: folder, suggestedName: provider.suggestedName), nil, nil) }
          catch { finish(nil, nil, error) }
        }
      }
    }
    let files = images + types.filter { identifier in
      guard !images.contains(identifier), let type = UTType(identifier), type.conforms(to: .data) else { return false }
      if hasURL && !hasImage && type == .data { return false }
      return !type.conforms(to: .url) && (!type.conforms(to: .text) || !hasImage && !hasURL && !(provider.suggestedName ?? "").isEmpty)
    }
    for type in files {
      attempts.append { finish in
        provider.loadFileRepresentation(forTypeIdentifier: type) { file, error in
          guard let file = file else { finish(nil, nil, error); return }
          // The provider may delete this URL as soon as the callback returns.
          do { finish(try store.copy(file, to: folder, suggestedName: provider.suggestedName, typeIdentifiers: [type] + types), nil, nil) }
          catch { finish(nil, nil, error) }
        }
      }
      attempts.append { finish in
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
          guard let data = data else { finish(nil, nil, error); return }
          do { finish(try store.writeData(data, to: folder, name: provider.suggestedName ?? "shared-file", typeIdentifiers: [type] + types), nil, nil) }
          catch { finish(nil, nil, error) }
        }
      }
      attempts.append { finish in
        provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
          if let data = item as? Data {
            do { finish(try store.writeData(data, to: folder, name: provider.suggestedName ?? "shared-file", typeIdentifiers: [type] + types), nil, nil) }
            catch { finish(nil, nil, error) }
          } else if let url = SharedItemLoader.url(item) {
            SharedItemLoader.loadURL(url, image: hasImage, store: store, folder: folder, name: provider.suggestedName, completed: finish)
          } else {
            #if canImport(UIKit)
            if let image = item as? UIImage, let data = image.pngData() {
              do { finish(try store.writeData(data, to: folder, name: provider.suggestedName ?? "shared-image.png", typeIdentifiers: [UTType.png.identifier]), nil, nil) }
              catch { finish(nil, nil, error) }
              return
            }
            #endif
            finish(nil, nil, error)
          }
        }
      }
    }
    if hasURL {
      attempts.append { finish in
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
          guard let url = SharedItemLoader.url(item) else { finish(nil, nil, error); return }
          SharedItemLoader.loadURL(url, image: hasImage, store: store, folder: folder, name: provider.suggestedName, completed: finish)
        }
      }
    }
    #if canImport(UIKit)
    if provider.canLoadObject(ofClass: UIImage.self) {
      attempts.append { finish in
        _ = provider.loadObject(ofClass: UIImage.self) { item, error in
          guard let image = item as? UIImage, let data = image.pngData() else { finish(nil, nil, error); return }
          do { finish(try store.writeData(data, to: folder, name: provider.suggestedName ?? "shared-image.png", typeIdentifiers: [UTType.png.identifier]), nil, nil) }
          catch { finish(nil, nil, error) }
        }
      }
    }
    #endif
    if !hasImage && !hasURL, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      attempts.append { finish in
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
          if let text = item as? String { finish(nil, text, nil) }
          else if let data = item as? Data, let text = String(data: data, encoding: .utf8) { finish(nil, text, nil) }
          else { finish(nil, nil, error) }
        }
      }
    }
  }
  func start() { next(nil) }
  private func next(_ lastError: Error?) {
    guard index < attempts.count else { completed(nil, nil, lastError ?? CocoaError(.fileReadUnsupportedScheme)); return }
    let attempt = attempts[index]; index += 1
    attempt { path, text, error in
      if path != nil || text != nil { self.completed(path, text, nil) }
      else { self.next(error ?? lastError) }
    }
  }
}
#endif

enum SharedImportedFileName {
  static func resolve(source: URL, suggestedName: String?, typeIdentifiers: [String] = []) -> String {
    let name = (suggestedName?.isEmpty == false ? suggestedName! : source.lastPathComponent) as NSString
    let leaf = name.lastPathComponent.isEmpty ? "shared-file" : name.lastPathComponent
    if (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return leaf }
    let originalSuffix = (leaf as NSString).pathExtension
    var suffix = source.pathExtension
    #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
    // Photos often supplies public.file-url first, with a suffixless name.
    // Inspect the image container, without decoding pixels or transcoding it.
    if let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
       let identifier = CGImageSourceGetType(image),
       let type = UTType(identifier as String), let actual = type.preferredFilenameExtension {
      if UTType(filenameExtension: originalSuffix) == type { return leaf }
      let placeholder = ["pic", "image", "img", "bin", "tmp", "dat"].contains(originalSuffix.lowercased())
      let imageSuffix = UTType(filenameExtension: originalSuffix)?.conforms(to: .image) == true
      let stem = placeholder || imageSuffix ? (leaf as NSString).deletingPathExtension : leaf
      return stem + "." + actual
    }
    if suffix.isEmpty {
      suffix = typeIdentifiers.compactMap { UTType($0)?.preferredFilenameExtension }.first ?? ""
    }
    if suffix.isEmpty {
      suffix = (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredFilenameExtension ?? ""
    }
    #endif
    if !originalSuffix.isEmpty { return leaf }
    return suffix.isEmpty ? leaf : leaf + "." + suffix
  }
}

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
  var importing: Bool? = nil
  var completedItems: Int? = nil
  var totalItems: Int? = nil
}

/// A real process-owned lock distinguishes a suspended importer (still active)
/// from a terminated one. It does not guess completion from a timeout.
final class SharedImportLease {
  private var descriptor: Int32
  init(folder: URL) throws {
    let opened = open(folder.appendingPathComponent("import.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard opened >= 0, flock(opened, LOCK_EX | LOCK_NB) == 0 else {
      if opened >= 0 { close(opened) }
      throw CocoaError(.fileLocking)
    }
    descriptor = opened
  }
  func release() {
    if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
  }
  deinit { release() }
  static func waitForRelease(folder: URL) throws {
    let descriptor = open(folder.appendingPathComponent("import.lock").path, O_RDWR)
    if descriptor < 0 {
      if errno == ENOENT { return }
      throw CocoaError(.fileReadUnknown)
    }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno != EINTR { throw CocoaError(.fileLocking) }
    }
    flock(descriptor, LOCK_UN)
  }
  static func active(folder: URL) -> Bool {
    let descriptor = open(folder.appendingPathComponent("import.lock").path, O_RDWR)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
      flock(descriptor, LOCK_UN); return false
    }
    return true
  }
}

/// The app may open before provider loads finish. Only complete manifests can
/// enter the sending queue; every finished item is durable and recoverable.
final class SharedImportBatch {
  let id: String
  let folder: URL
  let total: Int
  private let store: SharedInboxStore
  private let lease: SharedImportLease
  private let lock = NSLock()
  private let target: SharedSendTarget?
  private let initialTexts: [String]
  private var outcomes: [Int: (String?, String?, Error?, Bool)] = [:]
  init(store: SharedInboxStore, id: String = UUID().uuidString, total: Int, target: SharedSendTarget? = nil, texts: [String] = []) throws {
    self.store = store; self.id = id; self.total = total; self.target = target; initialTexts = texts
    folder = try store.folder(id)
    lease = try SharedImportLease(folder: folder)
    try store.commit(snapshot(importing: true))
  }
  @discardableResult func record(_ index: Int, path: String?, text: String?, error: Error?, temporary: Bool = true) throws -> SharedPayload {
    lock.lock(); defer { lock.unlock() }
    outcomes[index] = (path, text, error, temporary)
    let payload = snapshot(importing: true)
    try store.commit(payload)
    return payload
  }
  func finish() throws -> SharedPayload {
    lock.lock(); defer { lock.unlock() }
    let payload = snapshot(importing: false)
    try store.commit(payload)
    lease.release()
    return payload
  }
  func cancel() {
    try? store.ack(id)
    try? FileManager.default.removeItem(at: folder)
    lease.release()
  }
  private func snapshot(importing: Bool) -> SharedPayload {
    var payload = SharedPayload(batchId: id, paths: [], texts: initialTexts, temporaryPaths: [], target: target,
      importing: importing, completedItems: outcomes.count, totalItems: total)
    for index in outcomes.keys.sorted() {
      guard let (path, text, error, temporary) = outcomes[index] else { continue }
      if let path = path { payload.paths.append(path); if temporary { payload.temporaryPaths.append(path) } }
      if let text = text, !payload.texts.contains(text) { payload.texts.append(text) }
      if let error = error { payload.error = error.localizedDescription }
    }
    return payload
  }
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
  func copy(_ source: URL, to folder: URL, suggestedName: String? = nil, typeIdentifiers: [String] = []) throws -> String {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let leaf = SharedImportedFileName.resolve(source: source, suggestedName: suggestedName, typeIdentifiers: typeIdentifiers)
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
  func writeData(_ data: Data, to folder: URL, name: String, typeIdentifiers: [String] = []) throws -> String {
    let item = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
    let leaf = (name as NSString).lastPathComponent
    let target = item.appendingPathComponent(leaf.isEmpty ? "shared-file" : leaf)
    try data.write(to: target, options: .atomic)
    let resolved = SharedImportedFileName.resolve(source: target, suggestedName: name, typeIdentifiers: typeIdentifiers)
    let final = item.appendingPathComponent(resolved)
    if final != target { try FileManager.default.moveItem(at: target, to: final) }
    return final.path
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
      .map { file in
        var payload = try JSONDecoder().decode(SharedPayload.self, from: Data(contentsOf: file))
        if payload.importing == true && !SharedImportLease.active(folder: root.appendingPathComponent(payload.batchId)) {
          payload.importing = false
          payload.error = "分享导入已中断，已完成内容仍保留；请从来源重新分享未完成内容。"
          try commit(payload)
        }
        return payload
      }
  }
  func ack(_ id: String) throws {
    guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
    let manifest = root.appendingPathComponent(id + ".json")
    if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
    // Bytes now belong to the staged source/history, not to the inbox manifest.
  }
}
