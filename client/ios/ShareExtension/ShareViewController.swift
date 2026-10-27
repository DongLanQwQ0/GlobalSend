import UIKit
import UniformTypeIdentifiers

/// A standard share extension. It queues content, never privately launches the app.
final class ShareViewController: UIViewController {
  private let label = UILabel()
  private let done = UIButton(type: .system)
  private var started = false
  private var finished = false
  private var cancelled = false
  private let cancellation = NSLock()
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    label.numberOfLines = 0
    label.textAlignment = .center
    label.text = "正在加入待发送…"
    label.font = .preferredFont(forTextStyle: .body)
    done.setTitle("取消", for: .normal)
    done.addTarget(self, action: #selector(close), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [label, done])
    stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }; started = true
    let inputs = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let providers = inputs.flatMap { $0.attachments ?? [] }
    DispatchQueue.global(qos: .userInitiated).async { self.importItems(inputs, providers: providers) }
  }
  private func importItems(_ inputs: [NSExtensionItem], providers: [NSItemProvider]) {
    do {
      let store = try SharedInboxStore(extensionOnly: true), id = UUID().uuidString
      let folder = try store.folder(id)
      let group = DispatchGroup(), lock = NSLock()
      var payload = SharedPayload(batchId: id, paths: [], texts: [], temporaryPaths: [])
      var outcomes: [Int: (String?, String?, Error?)] = [:]
      if providers.isEmpty { payload.texts = inputs.compactMap { $0.attributedContentText?.string } }
      for (index, provider) in providers.enumerated() {
        group.enter()
        Self.load(provider, store: store, folder: folder) { path, text, error in
          lock.lock()
          outcomes[index] = (path, text, error)
          lock.unlock(); group.leave()
        }
      }
      group.wait()
      cancellation.lock(); let wasCancelled = cancelled; cancellation.unlock()
      if wasCancelled { try? FileManager.default.removeItem(at: folder); return }
      for index in providers.indices {
        guard let (path, text, error) = outcomes[index] else { continue }
        if let path = path { payload.paths.append(path) }
        if let text = text, !payload.texts.contains(text) { payload.texts.append(text) }
        if let error = error { payload.error = error.localizedDescription }
      }
      payload.temporaryPaths = payload.paths
      try store.commit(payload)
      DispatchQueue.main.async {
        self.finished = true
        self.label.text = payload.paths.isEmpty && payload.texts.isEmpty ? (payload.error ?? "没有可分享的内容") : "已加入待发送\n打开 GlobalSend 即可发送"
        self.done.setTitle("完成", for: .normal)
      }
    } catch {
      DispatchQueue.main.async { self.label.text = error.localizedDescription; self.done.setTitle("关闭", for: .normal) }
    }
  }
  private static func load(_ provider: NSItemProvider, store: SharedInboxStore, folder: URL, completed: @escaping (String?, String?, Error?) -> Void) {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
        guard let url = item as? URL else { completed(nil, nil, error ?? CocoaError(.fileReadUnknown)); return }
        do { completed(try store.copy(url, to: folder), nil, nil) } catch { completed(nil, nil, error) }
      }
      return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
        if let url = item as? URL { completed(nil, url.absoluteString, nil) }
        else if let text = item as? String { completed(nil, text, nil) }
        else { completed(nil, nil, error ?? CocoaError(.fileReadUnknown)) }
      }
      return
    }
    let fileType = provider.registeredTypeIdentifiers.first { identifier in
      guard let type = UTType(identifier) else { return false }
      let namedFile = !(provider.suggestedName ?? "").isEmpty
      return type.conforms(to: .data) && (!type.conforms(to: .plainText) || namedFile)
    }
    if let type = fileType {
      provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
        guard let url = url else { completed(nil, nil, error ?? CocoaError(.fileReadUnknown)); return }
        // The provider deletes this URL when this callback returns.
        let ext = UTType(type)?.preferredFilenameExtension ?? url.pathExtension
        var name = provider.suggestedName ?? url.lastPathComponent
        if (name as NSString).pathExtension.isEmpty && !ext.isEmpty { name += "." + ext }
        do { completed(try store.copy(url, to: folder, suggestedName: name), nil, nil) } catch { completed(nil, nil, error) }
      }
      return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
        if let text = item as? String { completed(nil, text, nil) }
        else if let data = item as? Data, let text = String(data: data, encoding: .utf8) { completed(nil, text, nil) }
        else { completed(nil, nil, error ?? CocoaError(.fileReadUnknown)) }
      }
      return
    }
    if provider.canLoadObject(ofClass: UIImage.self) {
      _ = provider.loadObject(ofClass: UIImage.self) { item, error in
        guard let image = item as? UIImage, let data = image.pngData() else { completed(nil, nil, error ?? CocoaError(.fileReadUnknown)); return }
        do { completed(try store.writeData(data, to: folder, name: "shared-image.png"), nil, nil) } catch { completed(nil, nil, error) }
      }
      return
    }
    completed(nil, nil, CocoaError(.fileReadUnsupportedScheme))
  }
  @objc private func close() {
    if finished { extensionContext?.completeRequest(returningItems: nil) }
    else {
      cancellation.lock(); cancelled = true; cancellation.unlock()
      extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
  }
}
