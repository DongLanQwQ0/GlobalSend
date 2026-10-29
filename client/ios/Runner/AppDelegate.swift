import Flutter
import UIKit
import CryptoKit
import Security
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeChannels: [FlutterMethodChannel] = []
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let sharing = FileSharing.shared.install(messenger)
    engineBridge.applicationRegistrar.register(BulkDragFactory(messenger: messenger), withId: "dev.globalsend/drag-handle")
    let system = FlutterMethodChannel(name: "dev.globalsend/system", binaryMessenger: messenger)
    system.setMethodCallHandler { call, result in
      switch call.method {
      case "deviceName":
        result(UIDevice.current.name)
      case "updateNotificationPermission":
        let explicit = (call.arguments as? [String: Any])?["explicit"] as? Bool ?? false
        let center = UNUserNotificationCenter.current()
        if explicit {
          center.requestAuthorization(options: [.alert, .sound, .badge]) { allowed, _ in
            DispatchQueue.main.async { result(allowed) }
          }
        } else {
          center.getNotificationSettings { settings in
            DispatchQueue.main.async { result(Self.updateNotificationsAllowed(settings.authorizationStatus)) }
          }
        }
      case "notifyUpdate":
        guard let args = call.arguments as? [String: Any], let version = args["version"] as? String else {
          result(false); return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
          guard Self.updateNotificationsAllowed(settings.authorizationStatus) else {
            DispatchQueue.main.async { result(false) }; return
          }
          let content = UNMutableNotificationContent()
          content.title = "GlobalSend 有新版本"
          content.body = "\(version) 可更新，打开应用下载 IPA"
          content.sound = .default
          center.add(UNNotificationRequest(identifier: "globalsend-update", content: content, trigger: nil)) { error in
            DispatchQueue.main.async { result(error == nil) }
          }
        }
      case "openWebUrl":
        guard let args = call.arguments as? [String: Any],
              let value = args["url"] as? String, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
          result(FlutterError(code: "INVALID_URL", message: "网址无效", details: nil))
          return
        }
        UIApplication.shared.open(url) { opened in
          result(opened ? nil : FlutterError(code: "OPEN_FAILED", message: "无法打开网址", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let vault = FlutterMethodChannel(name: "dev.globalsend/vault", binaryMessenger: messenger)
    vault.setMethodCallHandler { call, result in
      guard ["seal", "unseal"].contains(call.method),
            let input = call.arguments as? FlutterStandardTypedData else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        let key = try Self.vaultKey()
        let output: Data
        if call.method == "seal" {
          output = try AES.GCM.seal(input.data, using: key).combined!
        } else {
          output = try AES.GCM.open(AES.GCM.SealedBox(combined: input.data), using: key)
        }
        result(FlutterStandardTypedData(bytes: output))
      } catch {
        result(FlutterError(code: "VAULT_FAILED", message: "无法访问本机登录凭据", details: nil))
      }
    }
    nativeChannels = [system, vault, sharing]
  }

  override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if FileSharing.shared.handleURL(url) { return true }
    if url.isFileURL { FileSharing.shared.importURLs([url]); return true }
    return super.application(app, open: url, options: options)
  }

  private static func updateNotificationsAllowed(_ status: UNAuthorizationStatus) -> Bool {
    status == .authorized || status == .provisional || status == .ephemeral
  }

  private static func vaultKey() throws -> SymmetricKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.globalsend.vault",
      kSecAttrAccount as String: "local-key"
    ]
    var lookup = query
    lookup[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      return SymmetricKey(data: data)
    }
    guard status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    let key = SymmetricKey(size: .bits256)
    var insert = query
    insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(insert as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
    }
    return key
  }
}
