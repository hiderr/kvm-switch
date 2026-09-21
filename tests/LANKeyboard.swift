// Real LAN keyboard probe. No event taps, cursor hiding or OS event posting.
private var lanTimer: DispatchSourceTimer?
private func eventSnapshot(_ event: CGEvent) -> [String: Int64] {
  if let aux = AuxiliaryKey(event: event) {
    return ["type": 14, "key": Int64(aux.code), "down": aux.down ? 1 : 0,
            "repeat": aux.repeated ? 1 : 0, "flags": Int64(bitPattern: event.flags.rawValue)]
  }
  return ["type": Int64(event.type.rawValue), "key": event.getIntegerValueField(.keyboardEventKeycode),
          "repeat": event.getIntegerValueField(.keyboardEventAutorepeat),
          "keyboardType": event.getIntegerValueField(.keyboardEventKeyboardType),
          "flags": Int64(bitPattern: event.flags.rawValue)]
}
extension Node {
  static func runLANKeyboard() {
    guard CommandLine.arguments.count == 4 else { exit(2) }
    let role = CommandLine.arguments[1], peer = CommandLine.arguments[2]
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    let config = AppConfig(); config.manualHost = peer; config.port = 53645; config.edgeEnabled = false
    var received = [[String: Int64]]()
    let node = Node(config: config, discovery: Discovery(selfName: "LAN keyboard probe"),
      selfName: "LAN keyboard probe", postEvent: { received.append(eventSnapshot($0)) }, inputAvailable: { true })
    let source = CGEventSource(stateID: .privateState)!; source.userData = 0
    var matrix = [CGEvent]()
    for key in UInt16(0)...UInt16(127) where modifierBit[key] == nil {
      for (down, repeated) in [(true, false), (true, true), (false, false)] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        event.setIntegerValueField(.keyboardEventKeyboardType, value: 41)
        matrix.append(event)
      }
    }
    for key in modifierBit.keys.sorted() {
      let family: CGEventFlags
      switch key {
      case 59, 62: family = .maskControl
      case 56, 60: family = .maskShift
      case 55, 54: family = .maskCommand
      case 58, 61: family = .maskAlternate
      case 57: family = .maskAlphaShift
      default: family = .maskSecondaryFn
      }
      for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: down ? modifierBit[key]! | family.rawValue : 0)
        event.setIntegerValueField(.keyboardEventKeyboardType, value: 41)
        matrix.append(event)
      }
    }
    for key in AuxiliaryKey.supported.sorted() {
      for (down, repeated) in [(true, false), (true, true), (false, false)] {
        matrix.append(AuxiliaryKey.event(code: key, down: down, repeated: repeated, source: source)!)
      }
    }
    var sent = 0, started = false, finishing = false
    let startedAt = monotonicNow()
    func finish(_ success: Bool) {
      let result: [String: Any] = ["success": success, "role": role, "expected": matrix.map(eventSnapshot),
        "received": received, "sent": sent, "expectedCount": matrix.count,
        "heldKeys": node.injectedKeys.sorted(), "heldAuxiliary": node.injectedAuxiliaryKeys.sorted()]
      try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: output)
      node.stop(); exit(success ? 0 : 1)
    }
    if role == "receive" { node.startListener() } else { node.startOutConnection() }
    node.startHealthTimer()
    let timer = DispatchSource.makeTimerSource(queue: .main); lanTimer = timer
    timer.schedule(deadline: .now(), repeating: .milliseconds(5))
    timer.setEventHandler {
      if monotonicNow() - startedAt > 35 { finish(false) }
      if role == "receive" {
        if received.count >= matrix.count && !node.receivingRemote {
          finish(received == matrix.map(eventSnapshot) && node.injectedKeys.isEmpty && node.injectedAuxiliaryKeys.isEmpty)
        }
      } else {
        if !started && node.linkHealthy { started = true; node.toggleMode() }
        guard node.mode == .remote, !finishing else { return }
        if sent < matrix.count {
          let event = matrix[sent]
          guard node.handle(type: event.type, event: event) == nil else { finish(false); return }
          sent += 1
        } else {
          finishing = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            node.becomeLocal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(true) }
          }
        }
      }
    }
    timer.resume()
  }
}
DispatchQueue.main.async { Node.runLANKeyboard() }
dispatchMain()
