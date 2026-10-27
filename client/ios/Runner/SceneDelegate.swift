import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    FileSharing.shared.importURLs(connectionOptions.urlContexts.map { $0.url })
  }
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let files = URLContexts.filter { $0.url.isFileURL }
    FileSharing.shared.importURLs(files.map { $0.url })
    let other = Set(URLContexts.filter { !$0.url.isFileURL })
    if !other.isEmpty { super.scene(scene, openURLContexts: other) }
  }
}
