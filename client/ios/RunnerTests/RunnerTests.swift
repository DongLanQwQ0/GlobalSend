import Flutter
import UIKit
import XCTest
import UniformTypeIdentifiers
@testable import Runner

class RunnerTests: XCTestCase {

  private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGNUCOhhYGBgYgADAAuOAQCntjSiAAAAAElFTkSuQmCC")!

  func testImageDragOffersOriginalFileAndUIKitObjectWithoutReplacingFileRoute() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlobalSend/provider-tests/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("source.png")
    try png.write(to: file)
    let provider = try XCTUnwrap(NativeDragProviders.file(file))
    XCTAssertEqual(provider.suggestedName, "source.png")
    XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
    XCTAssertTrue(provider.canLoadObject(ofClass: UIImage.self))
    let bytes = expectation(description: "original file representation")
    provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
      XCTAssertNil(error)
      XCTAssertEqual(url.flatMap { try? Data(contentsOf: $0) }, self.png)
      bytes.fulfill()
    }
    let object = expectation(description: "UIKit image representation")
    provider.loadObject(ofClass: UIImage.self) { value, error in
      XCTAssertNil(error); XCTAssertNotNil(value as? UIImage); object.fulfill()
    }
    wait(for: [bytes, object], timeout: 5)
  }

  func testSafariImageWinsOverPageURLAndKeepsExactPNGBytes() throws {
    let store = try SharedInboxStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("GlobalSend/provider-tests/" + UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let folder = try store.folder(UUID().uuidString)
    let provider = NSItemProvider(object: URL(string: "https://example.invalid/page")! as NSURL)
    provider.suggestedName = "web-image"
    provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { callback in
      callback(nil, false, CocoaError(.fileReadUnknown)); return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
      callback(self.png, nil); return nil
    }
    XCTAssertTrue(SharedItemLoader.canLoad(provider))
    let loaded = expectation(description: "image file, not page URL")
    SharedItemLoader.load(provider, store: store, folder: folder) { path, text, error in
      XCTAssertNil(error); XCTAssertNil(text)
      XCTAssertEqual(path.map { URL(fileURLWithPath: $0).lastPathComponent }, "web-image.png")
      XCTAssertEqual(path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }, self.png)
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 5)
  }

  func testPlainWebLinkRemainsText() throws {
    let store = try SharedInboxStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("GlobalSend/provider-tests/" + UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let provider = NSItemProvider(object: URL(string: "https://example.invalid/page")! as NSURL)
    provider.suggestedName = "网页标题"
    provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { callback in
      callback(Data("https://example.invalid/page".utf8), nil); return nil
    }
    let loaded = expectation(description: "plain link")
    SharedItemLoader.load(provider, store: store, folder: try store.folder(UUID().uuidString)) { path, text, error in
      XCTAssertNil(error); XCTAssertNil(path)
      XCTAssertEqual(text, "https://example.invalid/page")
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 5)
  }

  func testImageDataURLPreservesBytesAndCorrectsPlaceholderSuffix() throws {
    let store = try SharedInboxStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("GlobalSend/provider-tests/" + UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let image = URL(string: "data:image/png;base64," + png.base64EncodedString())!
    let loaded = expectation(description: "image data URL")
    SharedItemLoader.loadURL(image, image: true, store: store, folder: try store.folder(UUID().uuidString), name: "image.pic") { path, text, error in
      XCTAssertNil(error); XCTAssertNil(text)
      XCTAssertEqual(path.map { URL(fileURLWithPath: $0).lastPathComponent }, "image.png")
      XCTAssertEqual(path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }, self.png)
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 5)
  }

}
