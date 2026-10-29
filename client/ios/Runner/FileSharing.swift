import Flutter
import UIKit

final class FileSharing {
  static let shared = FileSharing()
  private let work = DispatchQueue(label: "dev.globalsend.share-inbox")
  private var channel: FlutterMethodChannel?
  private var recentlyOpened: [String: Date] = [:]
  func install(_ messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let bridge = FlutterMethodChannel(name: "dev.globalsend/share", binaryMessenger: messenger)
    channel = bridge
    bridge.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "share" {
        let args = call.arguments as? [String: Any] ?? [:]
        self.share(paths: args["paths"] as? [String] ?? [], text: args["text"] as? String, result: result)
      } else if call.method == "pending" || call.method == "ack" || call.method == "setDefaultTarget" {
        self.work.async {
          do {
            let store = try SharedInboxStore()
            if call.method == "setDefaultTarget" {
              let args = call.arguments as? [String: Any] ?? [:]
              let target = try (args["target"] as? [String: Any]).map {
                try JSONDecoder().decode(SharedSendTarget.self, from: JSONSerialization.data(withJSONObject: $0))
              }
              try store.setDefaultTarget(target)
              DispatchQueue.main.async { result(nil) }
            } else if call.method == "ack" {
              let args = call.arguments as? [String: Any] ?? [:]
              try store.ack(args["batchId"] as? String ?? "")
              DispatchQueue.main.async { result(nil) }
            } else {
              let values = try store.pending().map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
              DispatchQueue.main.async { result(values) }
            }
          } catch { DispatchQueue.main.async { result(FlutterError(code: "SHARE_INBOX", message: error.localizedDescription, details: nil)) } }
        }
      } else { result(FlutterMethodNotImplemented) }
    }
    return bridge
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
  init(frame: CGRect, identifier: Int64, messenger: FlutterBinaryMessenger, arguments: [String: Any]) {
    paths = arguments["paths"] as? [String] ?? []
    texts = arguments["texts"] as? [String] ?? []
    button = UIButton(type: .system)
    channel = FlutterMethodChannel(name: "dev.globalsend/drag-handle/\(identifier)", binaryMessenger: messenger)
    super.init()
    button.frame = frame
    button.tintColor = UIColor(red: 0.09, green: 0.42, blue: 0.31, alpha: 1)
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
      else { self.paths = arguments["paths"] as? [String] ?? []; self.texts = arguments["texts"] as? [String] ?? [] }
      result(nil)
    }
  }
  func view() -> UIView { button }
  func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
    var items = paths.compactMap { path -> UIDragItem? in
      guard let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) else { return nil }
      provider.suggestedName = URL(fileURLWithPath: path).lastPathComponent
      return UIDragItem(itemProvider: provider)
    }
    items += texts.map { UIDragItem(itemProvider: NSItemProvider(object: $0 as NSString)) }
    return items
  }
  func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession) -> Bool { false }
  func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) { dragging = true }
  func dragInteraction(_ interaction: UIDragInteraction, sessionDidEnd session: UIDragSession) {
    dragging = false
    if let value = pending { paths = value["paths"] as? [String] ?? []; texts = value["texts"] as? [String] ?? []; pending = nil }
  }
  deinit { channel.setMethodCallHandler(nil) }
}
