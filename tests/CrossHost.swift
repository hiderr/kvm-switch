// Same-source transport probe. It never installs a tap or posts OS input.
private var probeTimer: DispatchSourceTimer?
private var probeActions = 0
private var probeLastPassed: Bool? = nil
private var probePosts = 0
private var probeLastAction = ""

extension Node {
  static func runCrossHostProbe() {
    guard CommandLine.arguments.count == 4,
          let port = UInt16(CommandLine.arguments[3]) else { exit(2) }
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = AppConfig()
    config.manualHost = CommandLine.arguments[1]
    config.port = port
    let name = "KVM transport probe \(UUID().uuidString)"
    let node = Node(config: config, discovery: Discovery(selfName: name), selfName: name,
                    postEvent: { _ in probePosts += 1 }, inputAvailable: { true })
    node.startListener()
    node.startOutConnection()
    node.startHealthTimer()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler {
      let actionURL = directory.appendingPathComponent("action.json")
      if let data = try? Data(contentsOf: actionURL),
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let action = object["action"] as? String {
        try? FileManager.default.removeItem(at: actionURL)
        probeActions += 1
        probeLastAction = action
        probeLastPassed = nil
        switch action {
        case "acquire": node.toggleMode()
        case "down", "up", "physical":
          let source = CGEventSource(stateID: .privateState)!
          source.userData = 0
          let type: CGEventType = action == "up" ? .keyUp : .keyDown
          let key = UInt16(object["key"] as? Int ?? 7)
          let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: type == .keyDown)!
          event.flags = []
          probeLastPassed = node.handle(type: type, event: event) != nil
        case "stop": node.stop(); exit(0)
        default: break
        }
      }
      var state: [String: Any] = [
        "pid": getpid(), "time": Date().timeIntervalSince1970,
        "mode": node.mode == .remote ? "remote" : "local",
        "healthy": node.linkHealthy, "receiving": node.receivingRemote,
        "heldKeys": node.injectedKeys.sorted(), "posts": probePosts,
        "actions": probeActions, "lastAction": probeLastAction,
      ]
      if let passed = probeLastPassed { state["passedLocally"] = passed }
      if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
        try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
      }
    }
    timer.resume()
    probeTimer = timer
  }
}

DispatchQueue.main.async { Node.runCrossHostProbe() }
dispatchMain()
