import Foundation

@main
struct SharedInboxGroupTests {
  static func main() {
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
    print("PASS: original group, iloader group, denied container, missing ID, duplicate candidate, host/extension agreement")
  }
}
