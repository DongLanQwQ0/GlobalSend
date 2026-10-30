import UIKit
import UniformTypeIdentifiers
import Intents

/// Commit the batch before the LocalSend-style responder-chain handoff.
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
    let intent = extensionContext?.intent as? INSendMessageIntent
    let target = SharedSendTarget.fromConversationIdentifier(intent?.conversationIdentifier,
        name: intent?.speakableGroupName?.spokenPhrase)
    DispatchQueue.global(qos: .userInitiated).async { self.importItems(inputs, providers: providers, target: target) }
  }
  private func importItems(_ inputs: [NSExtensionItem], providers: [NSItemProvider], target: SharedSendTarget?) {
    do {
      let store = try SharedInboxStore(extensionOnly: true), id = UUID().uuidString
      let folder = try store.folder(id)
      let group = DispatchGroup(), lock = NSLock()
      var payload = SharedPayload(batchId: id, paths: [], texts: [], temporaryPaths: [])
      var outcomes: [Int: (String?, String?, Error?)] = [:]
      if providers.isEmpty { payload.texts = inputs.compactMap { $0.attributedContentText?.string } }
      for (index, provider) in providers.enumerated() {
        group.enter()
        SharedItemLoader.load(provider, store: store, folder: folder) { path, text, error in
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
      payload.target = target
      try store.commit(payload)
      DispatchQueue.main.async {
        self.finished = true
        self.label.text = payload.paths.isEmpty && payload.texts.isEmpty ? (payload.error ?? "没有可分享的内容") : "已加入待发送\n打开 GlobalSend 即可发送"
        self.done.setTitle("完成", for: .normal)
        if !payload.paths.isEmpty || !payload.texts.isEmpty { self.openHost(batchId: id) }
      }
    } catch {
      DispatchQueue.main.async { self.label.text = error.localizedDescription; self.done.setTitle("关闭", for: .normal) }
    }
  }
  private func openHost(batchId: String) {
    let url = ShareLaunchRequest.handoffURL(batchId: batchId)
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        application.open(url, options: [:]) { opened in
          if opened { self.extensionContext?.completeRequest(returningItems: nil) }
        }
        return
      }
      responder = current.next
    }
    // The durable batch remains available if this iPadOS version denies opening.
  }
  @objc private func close() {
    if finished { extensionContext?.completeRequest(returningItems: nil) }
    else {
      cancellation.lock(); cancelled = true; cancellation.unlock()
      extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
  }
}
