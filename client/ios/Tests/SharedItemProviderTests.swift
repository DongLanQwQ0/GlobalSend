import Foundation
import UniformTypeIdentifiers

/// Runs against real Foundation NSItemProvider on the macOS runner, without a
/// simulator, UIKit replacement, signed app, network request or mock provider.
@main
struct SharedItemProviderTests {
  struct Result {
    let path: String?
    let text: String?
    let error: Error?
  }
  final class ResultBox {
    private let lock = NSLock()
    private var result: Result?
    private var callbacks = 0
    func finish(_ path: String?, _ text: String?, _ error: Error?) {
      lock.lock(); defer { lock.unlock() }
      callbacks += 1
      precondition(result == nil, "Provider import must finish exactly once")
      result = Result(path: path, text: text, error: error)
    }
    func read() -> Result? {
      lock.lock(); defer { lock.unlock() }; return result
    }
    func callbackCount() -> Int { lock.lock(); defer { lock.unlock() }; return callbacks }
  }
  final class Counter {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return count }
  }
  static func trace(_ message: String) {
    // Keep real callback evidence visible even if a later precondition aborts.
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
  static func load(_ provider: NSItemProvider, store: SharedInboxStore) throws -> Result {
    let box = ResultBox()
    SharedItemLoader.load(provider, store: store, folder: try store.folder(UUID().uuidString), completed: box.finish)
    let deadline = Date(timeIntervalSinceNow: 5)
    // Provider callbacks can use the main queue. Pump the real run loop rather
    // than blocking that queue with a semaphore while waiting for completion.
    while box.read() == nil && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard let result = box.read() else { fatalError("NSItemProvider import did not complete") }
    trace("CALLBACK: types=\(provider.registeredTypeIdentifiers.joined(separator: ",")) count=\(box.callbackCount()) file=\(result.path != nil) text=\(result.text != nil) error=\(result.error != nil)")
    return result
  }
  static func image(_ result: Result, bytes: Data, name: String) throws {
    precondition(result.error == nil && result.text == nil, "An image must not become its page URL or alt text")
    guard let path = result.path else { fatalError("Provider did not produce an image file") }
    precondition(URL(fileURLWithPath: path).lastPathComponent == name)
    let imported = try Data(contentsOf: URL(fileURLWithPath: path))
    precondition(imported == bytes, "Import must retain original image bytes")
  }
  static func main() throws {
    let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("artifacts/tmp/ios-provider-tests/" + UUID().uuidString, isDirectory: true)
    let store = try SharedInboxStore(root: fixture)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGNUCOhhYGBgYgADAAuOAQCntjSiAAAAAElFTkSuQmCC")!

    let webpage = NSItemProvider(object: URL(string: "https://example.invalid/page")! as NSURL)
    webpage.suggestedName = "web-image"
    webpage.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
      completed(png, nil); return nil
    }
    precondition(SharedItemLoader.canLoad(webpage))
    try image(load(webpage, store: store), bytes: png, name: "web-image.png")
    trace("PASS: real provider image bytes win over the simultaneously advertised webpage URL")

    let fallback = NSItemProvider()
    fallback.suggestedName = "fallback.pic"
    let fileRequests = Counter(), dataRequests = Counter()
    fallback.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completed in
      fileRequests.increment()
      completed(nil, false, CocoaError(.fileReadUnknown)); return nil
    }
    fallback.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
      dataRequests.increment()
      completed(png, nil); return nil
    }
    try image(load(fallback, store: store), bytes: png, name: "fallback.png")
    trace("HANDLERS same UTI: png-file=\(fileRequests.read()) png-data=\(dataRequests.read())")
    // Foundation can choose Data and synthesize a file for the same UTI. The
    // successful PNG import does not require invoking its failed file handler.
    precondition(dataRequests.read() > 0, "The only successful PNG representation must have been loaded")
    trace("PASS: same-UTI representation selection preserves image bytes and suffix")

    let typedFallback = NSItemProvider()
    typedFallback.suggestedName = "typed-fallback.pic"
    let failedJPEG = Counter(), recoveredPNG = Counter()
    typedFallback.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completed in
      failedJPEG.increment()
      trace("HANDLER: jpeg-file failed request=\(failedJPEG.read())")
      completed(nil, false, CocoaError(.fileReadUnknown)); return nil
    }
    typedFallback.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
      recoveredPNG.increment()
      trace("HANDLER: png-data succeeded request=\(recoveredPNG.read())")
      completed(png, nil); return nil
    }
    trace("CASE: failed JPEG file then PNG Data; advertised=\(typedFallback.registeredTypeIdentifiers.joined(separator: ","))")
    try image(load(typedFallback, store: store), bytes: png, name: "typed-fallback.png")
    trace("HANDLERS different UTIs: jpeg-file=\(failedJPEG.read()) png-data=\(recoveredPNG.read())")
    precondition(failedJPEG.read() > 0 && recoveredPNG.read() > 0,
      "The real failed file representation and successful Data alternative must both execute")
    trace("PASS: actual file failure falls back to another original Data representation without losing bytes")

    let original = fixture.appendingPathComponent("original.png")
    try png.write(to: original)
    let file = NSItemProvider(contentsOf: original)!
    file.suggestedName = "from-file"
    try image(load(file, store: store), bytes: png, name: "from-file.png")
    precondition(FileManager.default.fileExists(atPath: original.path), "Do not move the user's original")
    trace("PASS: real file-backed provider preserves bytes and leaves its original in place")

    let link = NSItemProvider(object: URL(string: "https://example.invalid/page")! as NSURL)
    link.suggestedName = "A named webpage"
    link.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completed in
      completed(Data("https://example.invalid/page".utf8), nil); return nil
    }
    let linked = try load(link, store: store)
    precondition(linked.path == nil && linked.error == nil && linked.text == "https://example.invalid/page")
    trace("PASS: a named ordinary webpage with a text alternative remains a link")

    for encoded in ["data:image/png;base64," + png.base64EncodedString(),
                    "data:image/png," + png.map { String(format: "%%%02X", $0) }.joined()] {
      let provider = NSItemProvider(object: URL(string: encoded)! as NSURL)
      provider.suggestedName = "data-image.pic"
      try image(load(provider, store: store), bytes: png, name: "data-image.png")
    }
    trace("PASS: real URL providers carrying base64 and percent-encoded data:image retain image bytes")

    let blob = NSItemProvider(object: URL(string: "blob:https://example.invalid/private-browser-object")! as NSURL)
    let unsupported = try load(blob, store: store)
    precondition(unsupported.path == nil && unsupported.text == nil && unsupported.error != nil)
    trace("PASS: a browser-private blob URL is not silently queued as text")
  }
}
