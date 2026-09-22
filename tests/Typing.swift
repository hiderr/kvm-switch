// Same-source LAN regression for typing near the return edge. Never installs an
// event tap, hides the cursor, or posts keyboard/mouse events to the OS.
private var typingTimer: DispatchSourceTimer?
extension Node {
  static func runTypingProbe() {
    guard CommandLine.arguments.count == 4 else { exit(2) }
    let role = CommandLine.arguments[1], peer = CommandLine.arguments[2]
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    let config = AppConfig()
    config.manualHost = peer; config.port = 53646
    config.edgeEnabled = true; config.edgeDirection = .right
    var received: [CGEvent] = []
    let node = Node(config: config, discovery: Discovery(selfName: "Typing regression"),
      selfName: "Typing regression", postEvent: { received.append($0.copy()!) }, inputAvailable: { true })
    let source = CGEventSource(stateID: .privateState)!
    source.userData = 0
    var matrix: [CGEvent] = []
    let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
    func key(_ code: UInt16, _ down: Bool, _ flags: CGEventFlags = [], modifier: Bool = false) {
      let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
      if modifier { event.type = .flagsChanged }
      event.flags = flags
      event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
      event.setIntegerValueField(.keyboardEventKeyboardType, value: 40)
      matrix.append(event)
    }
    func move(_ dx: Double) {
      let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                          mouseCursorPosition: CGPoint(x: 999, y: 100), mouseButton: .left)!
      event.flags = []
      event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
      event.setDoubleValueField(.mouseEventDeltaX, value: dx)
      matrix.append(event)
    }
    for _ in 0..<20 {
      move(-1); move(80) // partial push that must not survive typing
      key(55, true, command, modifier: true)
      key(9, true, command); key(9, false, command)
      key(55, false, modifier: true)
      key(36, true); key(36, false)
      move(50) // would return control if the earlier 80 px were still counted
    }
    let expectedKeys = matrix.filter { Node.keyboardTypes.contains($0.type) }
    var sent = 0, acquired = false, configured = false, finishing = false
    var sendAfter = Double.infinity
    let startedAt = monotonicNow()
    func finish(_ success: Bool, _ reason: String) {
      let keys = received.filter { Node.keyboardTypes.contains($0.type) }
      let result: [String: Any] = ["success": success, "reason": reason, "role": role,
        "cycles": 20, "sent": sent, "keyboardEvents": keys.count,
        "expectedKeyboardEvents": expectedKeys.count, "receiving": node.receivingRemote,
        "mode": node.mode == .remote ? "remote" : "local", "edgePressure": node.recvPressure.amount,
        "heldKeys": node.injectedKeys.sorted(), "cursorX": node.cursor.x, "cursorY": node.cursor.y]
      try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: output)
      node.stop(); exit(success ? 0 : 1)
    }
    if role == "receive" { node.startListener() } else { node.startOutConnection() }
    node.startHealthTimer()
    let timer = DispatchSource.makeTimerSource(queue: .main); typingTimer = timer
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
    timer.setEventHandler {
      if monotonicNow() - startedAt > 25 { finish(false, "timeout"); return }
      if role == "receive" {
        if node.receivingRemote && !configured {
          configured = true
          node.displayBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
          node.cursor = CGPoint(x: 999, y: 100)
          node.edgeResumeAt = 0
        }
        if configured && !node.receivingRemote {
          let keys = received.filter { Node.keyboardTypes.contains($0.type) }
          let equal = keys.count == expectedKeys.count && zip(keys, expectedKeys).allSatisfy {
            $0.type == $1.type && $0.flags == $1.flags &&
            $0.getIntegerValueField(.keyboardEventKeycode) == $1.getIntegerValueField(.keyboardEventKeycode)
          }
          finish(equal && node.injectedKeys.isEmpty && node.cursor == CGPoint(x: 999, y: 100),
                 equal ? "all Enter/paste events arrived in order; sender ended session" : "session ended before typing completed")
        }
      } else {
        if !acquired && node.linkHealthy { acquired = true; node.toggleMode() }
        guard node.mode == .remote, !finishing else { return }
        if sendAfter == .infinity { sendAfter = monotonicNow() + 0.7 }
        guard monotonicNow() >= sendAfter else { return }
        if sent < matrix.count {
          let event = matrix[sent]
          guard node.handle(type: event.type, event: event) == nil else {
            finish(false, "input unexpectedly passed locally"); return
          }
          sent += 1
        } else {
          finishing = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard node.mode == .remote else { finish(false, "unexpected return after typing"); return }
            node.becomeLocal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish(true, "remote ownership survived all typing cycles") }
          }
        }
      }
    }
    timer.resume()
  }
}
DispatchQueue.main.async { Node.runTypingProbe() }
dispatchMain()
