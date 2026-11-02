import UIKit
import UniformTypeIdentifiers
import Intents

/// Publish a live batch and request the host immediately. Keep this extension
/// request alive until its provider-owned files are safely copied.
final class ShareViewController: UIViewController {
  private let label = UILabel()
  private let done = UIButton(type: .system)
  private let progress = UIProgressView(progressViewStyle: .default)
  private var started = false
  private var finished = false
  private var cancelled = false
  private var hostOpened = false
  private let cancellation = NSLock()
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    label.numberOfLines = 0
    label.textAlignment = .center
    label.text = "正在打开 GlobalSend…"
    label.font = .preferredFont(forTextStyle: .body)
    done.setTitle("取消", for: .normal)
    done.addTarget(self, action: #selector(close), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [label, progress, done])
    stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
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
      let store = try SharedInboxStore(extensionOnly: true)
      let texts = providers.isEmpty ? inputs.compactMap { $0.attributedContentText?.string } : []
      let batch = try SharedImportBatch(store: store, total: providers.count, target: target, texts: texts)
      // Do not wait for all copies before requesting the foreground handoff.
      // The host sees importing=true and watches actual manifest changes.
      DispatchQueue.main.async {
        self.openHost(batchId: batch.id)
        DispatchQueue.global(qos: .userInitiated).async { self.loadItems(providers, store: store, batch: batch) }
      }
    } catch {
      DispatchQueue.main.async { self.label.text = error.localizedDescription; self.done.setTitle("关闭", for: .normal) }
    }
  }
  private func loadItems(_ providers: [NSItemProvider], store: SharedInboxStore, batch: SharedImportBatch) {
    do {
      let group = DispatchGroup()
      for (index, provider) in providers.enumerated() {
        group.enter()
        SharedItemLoader.load(provider, store: store, folder: batch.folder) { path, text, error in
          do {
            let value = try batch.record(index, path: path, text: text, error: error)
            DispatchQueue.main.async {
              self.label.text = "正在导入 \(value.completedItems ?? 0)/\(value.totalItems ?? 0) 项"
              self.progress.setProgress(Float(value.completedItems ?? 0) / Float(max(1, value.totalItems ?? 0)), animated: true)
            }
          } catch { DispatchQueue.main.async { self.label.text = error.localizedDescription } }
          group.leave()
        }
      }
      group.wait()
      cancellation.lock(); let wasCancelled = cancelled; cancellation.unlock()
      if wasCancelled { batch.cancel(); return }
      let payload = try batch.finish()
      DispatchQueue.main.async {
        self.finished = true
        self.label.text = payload.error ?? (payload.paths.isEmpty && payload.texts.isEmpty ? "没有可分享的内容" : "导入完成")
        self.progress.setProgress(1, animated: true)
        self.done.setTitle("完成", for: .normal)
        if self.hostOpened { self.extensionContext?.completeRequest(returningItems: nil) }
        else if !payload.paths.isEmpty || !payload.texts.isEmpty { self.openHost(batchId: batch.id) }
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
          self.hostOpened = opened
          if opened && self.finished { self.extensionContext?.completeRequest(returningItems: nil) }
          else if !opened && self.finished { self.label.text = "导入完成，请打开 GlobalSend" }
        }
        return
      }
      responder = current.next
    }
    // Share extensions do not have an unconditional public host-launch API.
    // Keep the durable batch when the responder-chain request is unavailable.
    if finished { label.text = "导入完成，请打开 GlobalSend" }
  }
  @objc private func close() {
    if finished { extensionContext?.completeRequest(returningItems: nil) }
    else {
      cancellation.lock(); cancelled = true; cancellation.unlock()
      extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
  }
}
