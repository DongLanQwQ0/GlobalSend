import Flutter
import UIKit
import Intents
import UniformTypeIdentifiers
import ImageIO
import Photos
import Darwin

final class FileSharing: NSObject, UIDropInteractionDelegate, UIDragInteractionDelegate {
  static let shared = FileSharing()
  private let work = DispatchQueue(label: "dev.globalsend.share-inbox")
  private var channel: FlutterMethodChannel?
  private var inboxWatch: DispatchSourceFileSystemObject?
  private var observedImportEnds = Set<String>()
  private var windowLayout: [String: Double] = [:]
  private var recentlyOpened: [String: Date] = [:]
  private weak var dragView: UIView?
  private var dropRegions: [String: Any] = [:]
  private var dragSources: [String: Any] = [:]
  private var pressedSource = ""
  private var pressedGeneration = 0
  private var pressedControl = false
  private var pressedImage: UIImage?
  private var dragVisuals: [ObjectIdentifier: NativeDragVisual] = [:]
  private var dragClipboardRevision: String?
  private var dragMediaAssetId: String?
  private lazy var dropInteraction = UIDropInteraction(delegate: self)
  private lazy var dragInteraction: UIDragInteraction = {
    let value = UIDragInteraction(delegate: self); value.isEnabled = true; return value
  }()
  func install(_ messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let bridge = FlutterMethodChannel(name: "dev.globalsend/share", binaryMessenger: messenger)
    channel = bridge
    observeInbox()
    bridge.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "setDropRegions" || call.method == "setDragSources" {
        let args = call.arguments as? [String: Any] ?? [:]
        if call.method == "setDropRegions" { self.dropRegions = args }
        else { self.dragSources = args }
        self.attachToForegroundScene()
        result(nil)
      } else if call.method == "windowLayout" {
        result(self.windowLayout)
      } else if call.method == "prepareDragSource" {
        let args = call.arguments as? [String: Any] ?? [:]
        self.pressedSource = args["sourceId"] as? String ?? ""
        self.pressedGeneration = args["generation"] as? Int ?? 0
        self.pressedControl = args["blocked"] as? Bool == true
        self.pressedImage = nil
        result(nil)
      } else if call.method == "setDragPreview" {
        let args = call.arguments as? [String: Any] ?? [:]
        if args["sourceId"] as? String == self.pressedSource,
           args["generation"] as? Int == self.pressedGeneration {
          self.pressedImage = NativeDragVisual.image(args)
        }
        result(nil)
      } else if call.method == "clipboardSuggestion" {
        let clipboard=UIPasteboard.general
        let kind=clipboard.hasImages ? "image" : clipboard.hasURLs ? "url" : clipboard.hasStrings ? "text" : clipboard.numberOfItems>0 ? "files" : "empty"
        result(["available":true,"revision":String(clipboard.changeCount),"kind":kind])
      } else if call.method == "importClipboard" {
        let items=UIPasteboard.general.itemProviders.map { UIDragItem(itemProvider:$0) }
        if items.isEmpty { result(nil) }
        else { self.importItems(items, result: result) }
      } else if call.method == "share" {
        let args = call.arguments as? [String: Any] ?? [:]
        self.share(paths: args["paths"] as? [String] ?? [], text: args["text"] as? String, result: result)
      } else if call.method == "recordShareTarget" {
        do {
          let args = call.arguments as? [String: Any] ?? [:]
          let target = try JSONDecoder().decode(SharedSendTarget.self, from: JSONSerialization.data(withJSONObject: args))
          self.donate(target) { error in
            DispatchQueue.main.async {
              if let error = error { result(FlutterError(code: "SHARE_SUGGESTION", message: error.localizedDescription, details: nil)) }
              else { result(nil) }
            }
          }
        } catch { result(FlutterError(code: "SHARE_SUGGESTION", message: "设备信息无效", details: nil)) }
      } else if call.method == "pending" || call.method == "ack" {
        self.work.async {
          do {
            let store = try SharedInboxStore()
            if call.method == "ack" {
              let args = call.arguments as? [String: Any] ?? [:]
              try store.ack(args["batchId"] as? String ?? "")
              DispatchQueue.main.async { result(nil) }
            } else {
              let pending = try store.pending()
              self.observeImportEnds(pending, store: store)
              let values = try pending.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
              DispatchQueue.main.async { result(values) }
            }
          } catch { DispatchQueue.main.async { result(FlutterError(code: "SHARE_INBOX", message: error.localizedDescription, details: nil)) } }
        }
      } else { result(FlutterMethodNotImplemented) }
    }
    return bridge
  }
  private func observeInbox() {
    guard inboxWatch == nil, let store = try? SharedInboxStore() else { return }
    let descriptor = open(store.root.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
    watch.setEventHandler { [weak self] in self?.channel?.invokeMethod("pendingChanged", arguments: nil) }
    watch.setCancelHandler { close(descriptor) }
    inboxWatch = watch; watch.resume()
  }
  /// Called on `work`. A blocking OS lock wait runs off the UI/manifest queue:
  /// finish unlocks it, and process termination releases it even without a
  /// directory write. Thus early handoff cannot leave a dead importer spinning.
  private func observeImportEnds(_ pending: [SharedPayload], store: SharedInboxStore) {
    observedImportEnds.formIntersection(Set(pending.filter { $0.importing == true }.map { $0.batchId }))
    for batch in pending where batch.importing == true {
      guard observedImportEnds.insert(batch.batchId).inserted else { continue }
      let folder = store.root.appendingPathComponent(batch.batchId, isDirectory: true)
      DispatchQueue.global(qos: .utility).async {
        do { try SharedImportLease.waitForRelease(folder: folder) }
        catch { DispatchQueue.main.async { self.importFailed(error, result: nil) }; return }
        self.work.async {
          self.observedImportEnds.remove(batch.batchId)
          DispatchQueue.main.async { self.channel?.invokeMethod("pendingChanged", arguments: nil) }
        }
      }
    }
  }
  func updateWindowLayout(_ view: UIView) {
    var leading: CGFloat = 0, trailing: CGFloat = 0, controlsBottom: CGFloat = 0
    if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .pad {
      // UIKit's public corner-adapting guides account for the actual scene's
      // window controls and change during resize/rotation. Never guess from
      // screen width or add a permanent tablet-only title offset.
      let normal = view.layoutGuide(for: .margins()).layoutFrame
      let horizontal = view.layoutGuide(for: .margins(cornerAdaptation: .horizontal)).layoutFrame
      let vertical = view.layoutGuide(for: .margins(cornerAdaptation: .vertical)).layoutFrame
      leading = max(0, horizontal.minX - normal.minX)
      trailing = max(0, normal.maxX - horizontal.maxX)
      controlsBottom = max(view.safeAreaInsets.top, vertical.minY)
    }
    let value = ["leading": Double(leading), "trailing": Double(trailing),
      "controlsBottom": Double(controlsBottom), "width": Double(view.bounds.width), "height": Double(view.bounds.height)]
    guard value != windowLayout else { return }
    windowLayout = value
    channel?.invokeMethod("windowLayoutChanged", arguments: value)
  }
  func attachToForegroundScene() {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
          let view = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.view else { return }
    guard dragView !== view else { return }
    dragView?.removeInteraction(dropInteraction); dragView?.removeInteraction(dragInteraction)
    dragView = view
    view.addInteraction(dropInteraction); view.addInteraction(dragInteraction)
  }
  private func rect(_ value: [String: Any], in view: UIView, surface: [String: Any]) -> CGRect {
    let width = (surface["surfaceWidth"] as? NSNumber)?.doubleValue ?? 0
    let height = (surface["surfaceHeight"] as? NSNumber)?.doubleValue ?? 0
    guard width > 0, height > 0 else { return .null }
    let x = (value["left"] as? NSNumber)?.doubleValue ?? 0, y = (value["top"] as? NSNumber)?.doubleValue ?? 0
    let right = (value["right"] as? NSNumber)?.doubleValue ?? x, bottom = (value["bottom"] as? NSNumber)?.doubleValue ?? y
    let sx = view.bounds.width / CGFloat(width), sy = view.bounds.height / CGFloat(height)
    return CGRect(x: CGFloat(x) * sx, y: CGFloat(y) * sy, width: CGFloat(right - x) * sx, height: CGFloat(bottom - y) * sy)
  }
  /// nil rejects the location, an empty ID stages, a device ID sends that batch.
  private func destination(_ session: UIDropSession) -> String? {
    guard dropRegions["enabled"] as? Bool == true, let view = dragView else { return nil }
    let point = session.location(in: view)
    for device in dropRegions["devices"] as? [[String: Any]] ?? [] {
      if rect(device, in: view, surface: dropRegions).contains(point) { return device["deviceId"] as? String }
    }
    return rect(dropRegions, in: view, surface: dropRegions).contains(point) ? "" : nil
  }
  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    session.items.contains { item in
      let provider = item.itemProvider
      return SharedItemLoader.canLoad(provider)
    }
  }
  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
    let target = destination(session)
    let allowed = target != nil
    channel?.invokeMethod("nativeDrag", arguments: ["active": allowed, "local": session.localDragSession != nil,
      "sessionActive": session.localDragSession != nil, "importing": false, "targetDeviceId": target ?? ""])
    return UIDropProposal(operation: allowed ? .copy : .cancel)
  }
  func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { endHover(session) }
  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { endHover(session, ended: true) }
  private func endHover(_ session: UIDropSession, ended: Bool = false) {
    channel?.invokeMethod("nativeDrag", arguments: ["active": false, "local": session.localDragSession != nil,
      "sessionActive": session.localDragSession != nil && !ended, "importing": false])
  }
  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    guard let device = destination(session) else { return }
    endHover(session)
    importItems(session.items, device: device)
  }
  private func importItems(_ items: [UIDragItem], device: String = "", result: FlutterResult? = nil) {
    let id = UUID().uuidString, server = dropRegions["serverKey"] as? String ?? ""
    do {
      let store = try SharedInboxStore()
      let target = device.isEmpty ? nil : SharedSendTarget(serverKey: server, deviceId: device)
      let batch = try SharedImportBatch(store: store, id: id, total: items.count, target: target)
      let group = DispatchGroup()
      channel?.invokeMethod("pendingChanged", arguments: nil)
      // Start provider loads in performDrop; copy their temporary URLs before
      // each completion returns. The same loader handles the share extension.
      for (index, item) in items.enumerated() {
        if let local = item.localObject as? [String: String] {
          group.enter()
          work.async {
            do { try batch.record(index, path: local["path"], text: local["text"], error: nil, temporary: false) }
            catch { DispatchQueue.main.async { self.importFailed(error, result: nil) } }
            group.leave()
          }
          continue
        }
        group.enter()
        SharedItemLoader.load(item.itemProvider, store: store, folder: batch.folder) { path, text, error in
          do { try batch.record(index, path: path, text: text, error: error) }
          catch { DispatchQueue.main.async { self.importFailed(error, result: nil) } }
          group.leave()
        }
      }
      group.notify(queue: work) {
        do {
          _ = try batch.finish()
          DispatchQueue.main.async { self.channel?.invokeMethod("pendingChanged", arguments: nil); result?(nil) }
        } catch { DispatchQueue.main.async { self.importFailed(error, result: result) } }
      }
    } catch { importFailed(error, result: result) }
  }
  private func importFailed(_ error: Error, result: FlutterResult?) {
    if let result=result { result(FlutterError(code:"CLIPBOARD_IMPORT",message:error.localizedDescription,details:nil)) }
    else { channel?.invokeMethod("importError", arguments: error.localizedDescription) }
  }
  func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
    guard let view = dragView else { return [] }
    let point = session.location(in: view)
    guard let source = (dragSources["sources"] as? [[String: Any]] ?? []).reversed().first(where: { rect($0, in: view, surface: dragSources).contains(point) }) else { return [] }
    let sourceID = source["sourceId"] as? String ?? ""
    if sourceID == pressedSource && pressedControl { return [] }
    var items: [UIDragItem]
    dragClipboardRevision = source["clipboardRevision"] as? String
    dragMediaAssetId = source["mediaAssetId"] as? String
    if dragClipboardRevision != nil {
      // Resolve the real providers at the native gesture, not a suggestion's
      // placeholder label, and leave the unconfirmed sending queue untouched.
      items = UIPasteboard.general.itemProviders.map { UIDragItem(itemProvider: $0) }
    } else if let assetId = dragMediaAssetId {
      // Hand UIKit a lazy file provider, not a converted UIImage or a placeholder.
      // Photos delivers the original bytes only when the drop target requests them.
      items = mediaProvider(assetId).map { [UIDragItem(itemProvider: $0)] } ?? []
    } else {
      items = (source["paths"] as? [String] ?? []).compactMap { path -> UIDragItem? in
        guard let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        provider.suggestedName = URL(fileURLWithPath: path).lastPathComponent
        let item = UIDragItem(itemProvider: provider)
        item.localObject = ["path": path]
        return item
      }
      items += (source["texts"] as? [String] ?? []).map { text in
        let item = UIDragItem(itemProvider: NSItemProvider(object: text as NSString))
        item.localObject = ["text": text]
        return item
      }
    }
    let scaleX = view.bounds.width / CGFloat((dragSources["surfaceWidth"] as? NSNumber)?.doubleValue ?? 1)
    let scaleY = view.bounds.height / CGFloat((dragSources["surfaceHeight"] as? NSNumber)?.doubleValue ?? 1)
    let area = CGRect(x: CGFloat((source["previewLeft"] as? NSNumber)?.doubleValue ?? 0) * scaleX,
                      y: CGFloat((source["previewTop"] as? NSNumber)?.doubleValue ?? 0) * scaleY,
                      width: CGFloat((source["previewWidth"] as? NSNumber)?.doubleValue ?? 0) * scaleX,
                      height: CGFloat((source["previewHeight"] as? NSNumber)?.doubleValue ?? 0) * scaleY)
    let image = sourceID == pressedSource ? pressedImage : nil
    for item in items {
      let visual = NativeDragVisual(image: image ?? NativeDragVisual.fallback(source, size: area.size), area: area)
      dragVisuals[ObjectIdentifier(item)] = visual
      item.previewProvider = {
        // The session and the initial lift share the exact card pixels. A
        // snapshot of Flutter's root UIView is neither the card nor its texture.
        UIDragPreview(view: visual.view(), parameters: visual.parameters())
      }
    }
    return items
  }
  func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
    targetedPreview(item)
  }
  func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem, withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? {
    targetedPreview(item)
  }
  private func targetedPreview(_ item: UIDragItem) -> UITargetedDragPreview? {
    guard let container = dragView, let visual = dragVisuals[ObjectIdentifier(item)] else { return nil }
    return UITargetedDragPreview(view: visual.view(), parameters: visual.parameters(),
      target: UIDragPreviewTarget(container: container, center: CGPoint(x: visual.area.midX, y: visual.area.midY)))
  }
  func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool { false }
  func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
    channel?.invokeMethod("nativeDrag", arguments: ["active": false, "local": true, "sessionActive": true, "importing": false])
  }
  func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
    var event: [String: Any] = ["active": false, "local": true, "sessionActive": false, "importing": false]
    if let revision = dragClipboardRevision {
      event["clipboardRevision"] = revision
      event["operation"] = operation == .copy || operation == .move ? "copy" : "cancel"
    }
    if let assetId = dragMediaAssetId {
      event["mediaAssetId"] = assetId
      event["operation"] = operation == .copy || operation == .move ? "copy" : "cancel"
    }
    channel?.invokeMethod("nativeDrag", arguments: event)
    dragVisuals.removeAll()
    pressedImage = nil
    dragClipboardRevision = nil
    dragMediaAssetId = nil
  }
  private func mediaProvider(_ assetId: String) -> NSItemProvider? {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return nil }
    let resources = PHAssetResource.assetResources(for: asset)
    let preferred: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
    guard let resource = resources.first(where: { $0.type == preferred }) ?? resources.first(where: { $0.type == .photo || $0.type == .video }) else { return nil }
    let provider = NSItemProvider()
    var name = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
    let existingSuffix = (name as NSString).pathExtension
    if let type = UTType(resource.uniformTypeIdentifier), let ext = type.preferredFilenameExtension {
      let namedType = UTType(filenameExtension: existingSuffix)
      let matches = namedType.map { $0.conforms(to: type) || type.conforms(to: $0) } ?? false
      if !matches {
        name = (existingSuffix.isEmpty ? name : (name as NSString).deletingPathExtension) + "." + ext
      }
    }
    provider.suggestedName = name
    let fileName = name
    let exports = NativeMediaDragExports()
    provider.registerFileRepresentation(forTypeIdentifier: resource.uniformTypeIdentifier, fileOptions: [], visibility: .all) { completion in
      // Consumers may load one provider repeatedly or concurrently. Photos
      // requires a new destination for each write; never overwrite an earlier
      // load's file while that consumer is still reading it.
      let export = exports.make(name: fileName)
      let progress = Progress(totalUnitCount: 1)
      do {
        try FileManager.default.createDirectory(at: export.directory, withIntermediateDirectories: true)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        PHAssetResourceManager.default().writeData(for: resource, toFile: export.file, options: options) { error in
          progress.completedUnitCount = 1
          completion(error == nil ? export.file : nil, false, error)
        }
      } catch { completion(nil, false, error) }
      return progress
    }
    return provider
  }
  private func donate(_ target: SharedSendTarget, completed: @escaping (Error?) -> Void) {
    let name = target.name?.isEmpty == false ? target.name! : "设备"
    let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
        content: nil, speakableGroupName: INSpeakableString(spokenPhrase: name),
        conversationIdentifier: target.conversationIdentifier, serviceName: nil, sender: nil, attachments: nil)
    let symbol: String
    switch target.platform {
    case "windows": symbol = "desktopcomputer"
    case "android": symbol = "iphone"
    case "web": symbol = "globe"
    default: symbol = "ipad"
    }
    let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360)).image { _ in
      UIColor.secondarySystemBackground.setFill()
      UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 360, height: 360)).fill()
      UIImage(systemName: symbol)?.withTintColor(.label, renderingMode: .alwaysOriginal)
          .draw(in: CGRect(x: 84, y: 84, width: 192, height: 192))
    }
    if let data = image.pngData() { intent.setImage(INImage(imageData: data), forParameterNamed: \.speakableGroupName) }
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.identifier = target.conversationIdentifier
    interaction.direction = .outgoing
    interaction.donate(completion: completed)
  }
  @discardableResult func handleURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "globalsend" else { return false }
    work.async {
      do {
        if let request = try ShareLaunchRequest.parse(url) {
          try SharedInboxStore().apply(request)
          DispatchQueue.main.async { self.channel?.invokeMethod("pendingChanged", arguments: nil) }
        }
      } catch {
        DispatchQueue.main.async { self.channel?.invokeMethod("importError", arguments: "分享调用参数无效") }
      }
    }
    return true
  }
  func importURLs(_ urls: [URL]) {
    let files = urls.filter { $0.isFileURL }
    guard !files.isEmpty else { return }
    work.async {
      let now = Date()
      self.recentlyOpened = self.recentlyOpened.filter { now.timeIntervalSince($0.value) < 2 }
      let unique = files.filter { self.recentlyOpened[$0.absoluteString] == nil }
      guard !unique.isEmpty else { return }
      unique.forEach { self.recentlyOpened[$0.absoluteString] = now }
      do {
        let store = try SharedInboxStore(), id = UUID().uuidString
        let folder = try store.folder(id)
        var payload = SharedPayload(batchId: id, paths: [], texts: [], temporaryPaths: [])
        for file in unique {
          do { payload.paths.append(try store.copy(file, to: folder)) }
          catch { payload.error = error.localizedDescription }
        }
        payload.temporaryPaths = payload.paths
        try store.commit(payload)
        DispatchQueue.main.async { self.channel?.invokeMethod("pendingChanged", arguments: nil) }
      } catch {
        DispatchQueue.main.async { self.channel?.invokeMethod("importError", arguments: error.localizedDescription) }
      }
    }
  }
  private func presenter() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    var view = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = view?.presentedViewController { view = presented }
    return view
  }
  private func share(paths: [String], text: String?, result: @escaping FlutterResult) {
    var items: [Any] = paths.map { URL(fileURLWithPath: $0) }
    if let text = text, !text.isEmpty { items.append(text) }
    guard !items.isEmpty else { result(nil); return }
    guard let host = presenter() else { result(FlutterError(code: "SHARE_UNAVAILABLE", message: "请回到应用进行分享", details: nil)); return }
    let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = host.view
      popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.maxY - 44, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    host.present(sheet, animated: true) { result(nil) }
  }
}

/// One native root reports real window-control layout for every Flutter route.
final class GlobalSendViewController: FlutterViewController {
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    FileSharing.shared.updateWindowLayout(view)
  }
  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    FileSharing.shared.updateWindowLayout(view)
  }
}

/// The provider and any in-flight Photos request retain this export. Its
/// temporary original is removed when the native drag/provider has finished.
private final class NativeMediaDragExports {
  private let lock = NSLock()
  private var files: [NativeMediaDragFile] = []
  func make(name: String) -> NativeMediaDragFile {
    let file = NativeMediaDragFile(name: name)
    lock.lock(); files.append(file); lock.unlock()
    return file
  }
}
private final class NativeMediaDragFile {
  let directory: URL
  let file: URL
  init(name: String) {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlobalSend/media-drag/" + UUID().uuidString, isDirectory: true)
    file = directory.appendingPathComponent(name)
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
}

/// UIKit needs a real raster view, not a snapshot of Flutter's GPU surface.
private struct NativeDragVisual {
  let image: UIImage
  let area: CGRect
  func view() -> UIView {
    let view = UIImageView(image: image)
    view.frame = CGRect(origin: .zero, size: area.size)
    view.contentMode = .scaleToFill
    view.layer.cornerRadius = 14
    view.clipsToBounds = true
    return view
  }
  func parameters() -> UIDragPreviewParameters {
    let parameters = UIDragPreviewParameters()
    parameters.backgroundColor = .clear
    parameters.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: area.size), cornerRadius: 14)
    return parameters
  }
  static func image(_ args: [String: Any]) -> UIImage? {
    guard let pixels = args["rgba"] as? FlutterStandardTypedData,
          let width = args["width"] as? Int, let height = args["height"] as? Int,
          width > 0, height > 0, pixels.data.count == width * height * 4,
          let provider = CGDataProvider(data: pixels.data as CFData),
          let raster = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
    return UIImage(cgImage: raster)
  }
  static func fallback(_ source: [String: Any], size: CGSize) -> UIImage {
    // A rapid native lift can precede Flutter's readback. Render actual text or
    // the file thumbnail rather than allowing UIKit to lift the entire page.
    let size = CGSize(width: max(1, size.width), height: max(1, size.height))
    let paths = source["paths"] as? [String] ?? []
    var thumbnail: UIImage?
    if let path = paths.first,
       let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
       let raster = CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
         kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
      thumbnail = UIImage(cgImage: raster)
    }
    return UIGraphicsImageRenderer(size: size).image { _ in
      UIColor.secondarySystemBackground.setFill()
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 14).fill()
      if let thumbnail = thumbnail {
        let ratio = max(size.width / thumbnail.size.width, size.height / thumbnail.size.height)
        thumbnail.draw(in: CGRect(x: (size.width - thumbnail.size.width * ratio) / 2,
          y: (size.height - thumbnail.size.height * ratio) / 2,
          width: thumbnail.size.width * ratio, height: thumbnail.size.height * ratio))
      } else {
        let text = (source["texts"] as? [String])?.first ?? (paths.first.map { URL(fileURLWithPath: $0).lastPathComponent }) ?? (source["label"] as? String ?? "剪贴板")
        (text as NSString).draw(in: CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 14),
          withAttributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.label])
      }
    }
  }
}

final class BulkDragFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger; super.init() }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView { BulkDragView(frame: frame, identifier: viewId, messenger: messenger, arguments: args as? [String: Any] ?? [:]) }
}
final class BulkDragView: NSObject, FlutterPlatformView, UIDragInteractionDelegate {
  private let button: UIButton
  private var paths: [String]
  private var texts: [String]
  private let channel: FlutterMethodChannel
  private var dragging = false
  private var pending: [String: Any]?
  private var visuals: [ObjectIdentifier: NativeDragVisual] = [:]
  init(frame: CGRect, identifier: Int64, messenger: FlutterBinaryMessenger, arguments: [String: Any]) {
    paths = arguments["paths"] as? [String] ?? []
    texts = arguments["texts"] as? [String] ?? []
    button = UIButton(type: .system)
    channel = FlutterMethodChannel(name: "dev.globalsend/drag-handle/\(identifier)", binaryMessenger: messenger)
    super.init()
    button.frame = frame
    apply(arguments)
    button.setImage(UIImage(systemName: "square.on.square"), for: .normal)
    button.accessibilityLabel = "全部拖拽"
    button.backgroundColor = .clear
    let interaction = UIDragInteraction(delegate: self)
    interaction.isEnabled = true
    button.addInteraction(interaction)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      let arguments = call.arguments as? [String: Any] ?? [:]
      if self.dragging { self.pending = arguments }
      else { self.apply(arguments) }
      result(nil)
    }
  }
  private func apply(_ arguments: [String: Any]) {
    paths = arguments["paths"] as? [String] ?? []
    texts = arguments["texts"] as? [String] ?? []
    if let color = (arguments["foreground"] as? NSNumber)?.uint32Value {
      button.tintColor = UIColor(red: CGFloat((color >> 16) & 255) / 255,
        green: CGFloat((color >> 8) & 255) / 255, blue: CGFloat(color & 255) / 255,
        alpha: CGFloat((color >> 24) & 255) / 255)
    } else { button.tintColor = .label }
  }
  func view() -> UIView { button }
  func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
    var items = paths.compactMap { path -> UIDragItem? in
      guard let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) else { return nil }
      provider.suggestedName = URL(fileURLWithPath: path).lastPathComponent
      let item = UIDragItem(itemProvider: provider)
      item.localObject = ["path": path]
      return item
    }
    items += texts.map { text in
      let item = UIDragItem(itemProvider: NSItemProvider(object: text as NSString))
      item.localObject = ["text": text]
      return item
    }
    for item in items {
      let local = item.localObject as? [String: String] ?? [:]
      let source: [String: Any] = local["path"].map { ["paths": [$0]] } ?? ["texts": [local["text"] ?? ""]]
      let size = CGSize(width: 184, height: 140)
      let visual = NativeDragVisual(image: NativeDragVisual.fallback(source, size: size),
        area: CGRect(origin: .zero, size: size))
      visuals[ObjectIdentifier(item)] = visual
      item.previewProvider = { UIDragPreview(view: visual.view(), parameters: visual.parameters()) }
    }
    return items
  }
  func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? { preview(item) }
  func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem, withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? { preview(item) }
  private func preview(_ item: UIDragItem) -> UITargetedDragPreview? {
    guard let visual = visuals[ObjectIdentifier(item)] else { return nil }
    return UITargetedDragPreview(view: visual.view(), parameters: visual.parameters(),
      target: UIDragPreviewTarget(container: button, center: CGPoint(x: button.bounds.midX, y: button.bounds.midY)))
  }
  func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool { false }
  func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) { dragging = true }
  func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
    dragging = false
    visuals.removeAll()
    if let value = pending { apply(value); pending = nil }
  }
  deinit { channel.setMethodCallHandler(nil) }
}
