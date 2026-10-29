import Foundation

@main
struct SharedInboxGroupTests {
  static func main() throws {
    let configured = "group.dev.globalsend.globalsend"
    let hostID = "dev.globalsend.globalsend.TESTTEAM01"
    let resigned = "group." + hostID
    let originalURL = URL(fileURLWithPath: "/fixture/original")
    let sharedURL = URL(fileURLWithPath: "/fixture/resigned")
    var attempts: [String] = []
    func resolve(_ allowed: [String: URL], host: String? = "dev.globalsend.globalsend.TESTTEAM01") -> URL? {
      attempts = []
      return SharedInboxGroup.container(configuredGroup: configured,
          hostBundleIdentifier: host, locate: { group in
            attempts.append(group)
            return allowed[group]
          })
    }
    precondition(resolve([configured: originalURL, resigned: sharedURL]) == originalURL)
    precondition(attempts == [configured], "Keep the existing queue when its group is available")
    precondition(resolve([resigned: sharedURL]) == sharedURL)
    precondition(attempts == [configured, resigned], "Recognize iloader's authorized group")
    precondition(resolve([:]) == nil, "A guessed identifier must not grant container access")
    precondition(resolve([:], host: nil) == nil && attempts == [configured])
    precondition(resolve([:], host: "dev.globalsend.globalsend") == nil && attempts == [configured])
    let app = URL(fileURLWithPath: "/Applications/GlobalSend.app", isDirectory: true)
    let ext = app.appendingPathComponent("PlugIns/ShareExtension.appex", isDirectory: true)
    precondition(SharedInboxGroup.hostBundleURL(for: app) == app)
    precondition(SharedInboxGroup.hostBundleURL(for: ext) == app,
                 "Host and extension must derive the same resigned host ID, not the extension ID")
    let id = UUID().uuidString
    let handoff = try ShareLaunchRequest.parse(ShareLaunchRequest.handoffURL(batchId: id))!
    precondition(handoff.batchId == id && handoff.target == nil && handoff.text == nil)
    var call = URLComponents(string: "globalsend://send")!
    call.queryItems = [URLQueryItem(name: "requestId", value: id.lowercased()),
      URLQueryItem(name: "serverKey", value: "center-one"), URLQueryItem(name: "deviceId", value: "unique-device-id"),
      URLQueryItem(name: "text", value: "图片 + 链接 & 正文\n第二行")]
    let request = try ShareLaunchRequest.parse(call.url!)!
    precondition(request.batchId == id && request.target?.deviceId == "unique-device-id")
    precondition(request.text == "图片 + 链接 & 正文\n第二行")
    let unrelated = try ShareLaunchRequest.parse(URL(string: "https://example.test")!)
    precondition(unrelated == nil)
    do {
      _ = try ShareLaunchRequest.parse(URL(string: "globalsend://send?text=missing-target")!)
      preconditionFailure("Incomplete directed call must not create or send a batch")
    } catch {}
    let fixture = URL(fileURLWithPath: "artifacts/tmp/ios-share-tests/" + UUID().uuidString, isDirectory: true)
    let store = try SharedInboxStore(root: fixture)
    defer { try? FileManager.default.removeItem(at: fixture) }
    try store.setDefaultTarget(request.target)
    let selected = try store.defaultTarget()
    precondition(selected?.deviceId == "unique-device-id")
    let before = try store.pending()
    precondition(before.isEmpty, "Target settings are not an incoming batch")
    try store.apply(request)
    try store.apply(request)
    let pending = try store.pending()
    precondition(pending.count == 1 && pending[0].texts == [request.text!])
    precondition(pending[0].target?.serverKey == "center-one")
    try store.ack(id)
    let after = try store.pending()
    precondition(after.isEmpty)
    let old = Data("{\"batchId\":\"old\",\"paths\":[],\"texts\":[\"legacy\"],\"temporaryPaths\":[]}".utf8)
    let legacy = try JSONDecoder().decode(SharedPayload.self, from: old)
    precondition(legacy.target == nil)
    print("PASS: wake URL, directed text API, durable target, same-ID idempotence, ack and old share schema")
    print("PASS: original group, iloader group, denied container, missing ID, duplicate candidate, host/extension agreement")
  }
}
