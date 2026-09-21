// Appended to the actual application source by run.py. No event tap is installed
// and every injected event is recorded instead of posted to the system.
private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
  guard condition() else { fputs("FAIL: \(description)\n", stderr); exit(1) }
  checks += 1
  print("PASS: \(description)")
}

private final class EventRecorder {
  var events: [CGEvent] = []
  func record(_ event: CGEvent) { events.append(event.copy()!) }
}

// A deliberately incomplete peer exercises failures that a healthy Node would
// immediately recover from. It never captures or injects input.
private final class SilentPeer {
  let listener = try! NWListener(using: .tcp, on: .any)
  var connection: NWConnection?
  var buffer = Data()
  var silent = false
  var acknowledgeBegin = false
  var ready = false
  var beginToken: UInt64?

  init() {
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state { self?.ready = true }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self = self else { return }
      self.connection = connection
      connection.start(queue: .main)
      self.receive(connection)
    }
    listener.start(queue: .main)
  }

  private func receive(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
      guard let self = self, self.connection === connection else { return }
      if let data = data {
        self.buffer.append(data)
        var records: [InputEvent] = []
        parseFrames(&self.buffer) { records.append($0) }
        for record in records where !self.silent && record.cgType == kCtrlType {
          if record.button == kCtrlPing { self.reply(kCtrlPong, token: record.flags) }
          if record.button == kCtrlBegin {
            self.beginToken = record.flags
            if self.acknowledgeBegin { self.reply(kCtrlBeginAck, token: record.flags) }
          }
        }
      }
      if !done && error == nil { self.receive(connection) }
    }
  }

  func reply(_ code: UInt8, token: UInt64) {
    connection?.send(content: controlRecord(code, token: token), completion: .contentProcessed { _ in })
  }
}

private func unusedPort() -> UInt16 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  precondition(fd >= 0)
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  precondition(bound == 0)
  var size = socklen_t(MemoryLayout<sockaddr_in>.size)
  let result = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
  }
  precondition(result == 0)
  return UInt16(bigEndian: address.sin_port)
}

private func eventually(_ description: String, timeout: Double = 5,
                        _ condition: @escaping () -> Bool, then continuation: @escaping () -> Void) {
  let deadline = monotonicNow() + timeout
  func poll() {
    if condition() { expect(true, description); continuation(); return }
    guard monotonicNow() < deadline else { expect(false, description); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
  }
  poll()
}

extension Node {
  private static func testNode(_ recorder: EventRecorder = EventRecorder(), inputAvailable: @escaping () -> Bool = { true }) -> Node {
    let config = AppConfig()
    config.manualHost = "127.0.0.1"
    let name = "KVM regression \(UUID().uuidString)"
    return Node(config: config, discovery: Discovery(selfName: name), selfName: name,
                postEvent: recorder.record, inputAvailable: inputAvailable)
  }

  static func runUnitTests() {
    var cursorLease = CursorLease(deadline: 101)
    expect(cursorLease.valid(at: 100) && !cursorLease.ended,
           "cursor lease remains active before deadline")
    expect(cursorLease.renew(until: 101.25, now: 100.5) && cursorLease.deadline == 101.25,
           "fresh bounded renewal advances cursor lease")
    expect(!cursorLease.valid(at: 101.25) && cursorLease.ended,
           "cursor lease expires exactly at its deadline")
    expect(!cursorLease.renew(until: 102, now: 101.5),
           "queued renewal cannot resurrect expired cursor lease")
    expect(!cursorLease.valid(at: 100),
           "expired cursor lease stays terminal even with earlier observed time")
    var releasedLease = CursorLease(deadline: 101)
    releasedLease.stop()
    releasedLease.stop()
    expect(releasedLease.ended && !releasedLease.valid(at: 100) &&
           !releasedLease.renew(until: 101, now: 100),
           "cursor STOP is idempotent and rejects stale queued renewal")
    for deadline in [Double.nan, Double.infinity, -Double.infinity] {
      var invalidLease = CursorLease(deadline: deadline)
      expect(!invalidLease.valid(at: 100) && invalidLease.ended,
             "nonfinite initial cursor deadline is rejected: \(deadline)")
    }
    for deadline in [Double.nan, Double.infinity, -Double.infinity, 99, 100, 102] {
      var invalidRenewal = CursorLease(deadline: 101)
      expect(!invalidRenewal.renew(until: deadline, now: 100) && invalidRenewal.ended,
             "invalid or stale cursor renewal terminates lease: \(deadline)")
    }
    var maximumLease = CursorLease(deadline: 101)
    expect(maximumLease.renew(until: 100 + kCursorLeaseDuration + 0.05, now: 100),
           "cursor renewal accepts exact configured maximum deadline")

    let original = InputEvent(cgType: CGEventType.keyDown.rawValue, flags: 0x123456789,
                              keyCode: 42, button: 2, clickState: 3, dx: -12.25, dy: 40.5)
    let bytes = original.encoded()
    var buffer = Data(bytes.prefix(7))
    var decoded: [InputEvent] = []
    parseFrames(&buffer) { decoded.append($0) }
    expect(decoded.isEmpty && buffer.count == 7, "partial frame stays buffered")
    buffer.append(bytes.dropFirst(7))
    buffer.append(controlRecord(kCtrlPing, token: 991))
    parseFrames(&buffer) { decoded.append($0) }
    expect(decoded.count == 2 && buffer.isEmpty, "fragmented and coalesced frames parse")
    expect(decoded[0].flags == original.flags && decoded[0].dx == original.dx &&
           decoded[0].keyCode == 42 && decoded[1].flags == 991, "wire values and heartbeat token survive framing")
    buffer = Data([0, 0, 0, 255, 1, 2, 3])
    parseFrames(&buffer) { _ in expect(false, "malformed frame never dispatched") }
    expect(buffer.isEmpty, "malformed length discards buffer")

    let node = testNode()
    let key = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    key.flags = []
    node.mode = .remote
    node.outgoingSession = 99
    node.outReady = true
    node.lastPong = monotonicNow() - kLeaseDuration - 0.1
    expect(node.handle(type: .keyDown, event: key) != nil && node.mode == .local,
           "expired peer lease passes the current physical key through")
    expect(node.outgoingSession == 0, "return to local clears previous outgoing session")
    node.mode = .remote
    node.outReady = true
    node.lastPong = monotonicNow()
    expect(node.handle(type: .keyDown, event: key) != nil && node.mode == .local,
           "missing socket passes current physical key through")
    node.mode = .remote
    node.pendingBegin = 12
    _ = node.handle(type: .tapDisabledByTimeout, event: key)
    expect(node.mode == .local && node.pendingBegin == nil, "disabled tap abandons forwarding and pending acquisition")

    let recorder = EventRecorder()
    let receiver = testNode(recorder)
    receiver.inject(InputEvent(cgType: CGEventType.keyDown.rawValue, keyCode: 4))
    receiver.inject(InputEvent(cgType: CGEventType.flagsChanged.rawValue, flags: 0x8, keyCode: 55))
    receiver.inject(InputEvent(cgType: CGEventType.leftMouseDown.rawValue, button: 0))
    expect(receiver.injectedKeys == [4, 55] && receiver.injectedButtons == [0], "receiver tracks injected keys, modifiers and buttons")
    receiver.releaseInjectedInput()
    let releases = Array(recorder.events.suffix(3))
    expect(releases.filter { $0.type == .keyUp || $0.type == .flagsChanged }.count == 2 &&
           releases.filter { $0.type == .leftMouseUp }.count == 1 &&
           releases.allSatisfy { $0.flags.isEmpty }, "release synthesizes all missing ups with cleared flags")
    let releaseCount = recorder.events.count
    receiver.releaseInjectedInput()
    expect(recorder.events.count == releaseCount, "release is idempotent")
    receiver.receivingRemote = true
    key.setIntegerValueField(.eventSourceUserData, value: kInjectedMagic)
    expect(receiver.handle(type: .keyDown, event: key) != nil && receiver.receivingRemote,
           "injected events never claim physical ownership")
    let physicalSource = CGEventSource(stateID: .privateState)!
    physicalSource.userData = 0
    let physicalKey = CGEvent(keyboardEventSource: physicalSource, virtualKey: 0, keyDown: true)!
    physicalKey.flags = []
    let physicalResult = receiver.handle(type: .keyDown, event: physicalKey)
    expect(physicalResult != nil && !receiver.receivingRemote,
           "physical input takes local ownership and passes through")

    let stale = testNode()
    stale.config.port = unusedPort()
    stale.startOutConnection()
    let old = stale.outConn!
    let oldCallback = old.stateUpdateHandler!
    let replacement = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    stale.outConn = replacement
    stale.outReady = true
    oldCallback(.cancelled)
    expect(stale.outConn === replacement && stale.outReady, "stale cancellation cannot tear down replacement socket")
    old.cancel()
    stale.pendingSends = 256
    expect(!stale.sendData(bytes, on: replacement) && stale.outConn == nil && stale.mode == .local,
           "send backpressure disconnects and restores local input")

    let incoming = testNode(recorder)
    let current = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    incoming.incomingConn = current
    incoming.receivingRemote = true
    incoming.incomingSession = 42
    incoming.lastIncomingPing = monotonicNow()
    incoming.lastHealthTick = monotonicNow()
    let before = recorder.events.count
    incoming.receive(original, from: replacement)
    expect(recorder.events.count == before && incoming.incomingConn === current,
           "replaced incoming socket cannot inject or alter current state")
    incoming.receive(InputEvent(cgType: kCtrlType, flags: 41, button: kCtrlEnd), from: current)
    expect(incoming.receivingRemote, "stale session END cannot stop new ownership")
    incoming.receive(InputEvent(cgType: kCtrlType, flags: 42, button: kCtrlEnd), from: current)
    expect(!incoming.receivingRemote, "matching session END releases ownership")
    incoming.incomingConnected = true
    incoming.localKeys = [5]
    incoming.receive(InputEvent(cgType: kCtrlType, flags: 43, button: kCtrlBegin), from: current)
    expect(!incoming.receivingRemote && incoming.localKeys == [5] && recorder.events.count == before,
           "BEGIN cannot acquire over a physically held local key or synthesize its release")
    incoming.localKeys.removeAll()
    incoming.localButtons = [0]
    incoming.receive(InputEvent(cgType: kCtrlType, flags: 44, button: kCtrlBegin), from: current)
    expect(!incoming.receivingRemote && incoming.localButtons == [0] && recorder.events.count == before,
           "BEGIN cannot acquire over a physically held local mouse button")
    incoming.localButtons.removeAll()
    incoming.receivingRemote = true
    incoming.lastHealthTick = monotonicNow() - kLeaseDuration - 0.1
    incoming.receive(original, from: current)
    expect(incoming.incomingConn == nil && !incoming.receivingRemote && recorder.events.count == before,
           "main-loop gap rejects queued input and closes old session")
    let unavailable = testNode(inputAvailable: { false })
    unavailable.incomingConn = replacement
    unavailable.receive(InputEvent(cgType: kCtrlType, flags: 123, button: kCtrlPing), from: replacement)
    expect(unavailable.incomingConn == nil && !unavailable.incomingConnected,
           "missing input permission cannot acknowledge application readiness")
    expect(recorder.events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == kInjectedMagic },
           "every emitted and released event carries anti-loop stamp")

    let keyboardRecorder = EventRecorder()
    let keyboard = testNode(keyboardRecorder)
    let keyboardSource = CGEventSource(stateID: .privateState)!
    keyboardSource.userData = 0
    let caps = CGEvent(keyboardEventSource: keyboardSource, virtualKey: 57, keyDown: true)!
    caps.type = .flagsChanged
    caps.flags = .maskAlphaShift
    _ = keyboard.handle(type: .flagsChanged, event: caps)
    expect(keyboard.localKeys.isEmpty, "Caps Lock ON is not mistaken for a physically held key")
    keyboard.inject(InputEvent(cgType: CGEventType.flagsChanged.rawValue,
                               flags: CGEventFlags.maskAlphaShift.rawValue, keyCode: 57))
    expect(keyboardRecorder.events.last?.type == .flagsChanged && !keyboard.injectedKeys.contains(57),
           "Caps Lock flags propagate without adding a held cleanup key")
    let capsCount = keyboardRecorder.events.count
    keyboard.releaseInjectedInput()
    expect(keyboardRecorder.events.count == capsCount, "disconnect does not synthesize a Caps Lock toggle")
    for (code, bit) in modifierBit where code != 57 {
      keyboard.inject(InputEvent(cgType: CGEventType.flagsChanged.rawValue, flags: bit, keyCode: code))
      expect(keyboardRecorder.events.last?.type == .flagsChanged &&
             keyboardRecorder.events.last?.getIntegerValueField(.keyboardEventKeycode) == Int64(code) &&
             keyboard.injectedKeys.contains(code), "modifier \(code) preserves flagsChanged identity and held state")
      keyboard.inject(InputEvent(cgType: CGEventType.flagsChanged.rawValue, keyCode: code))
      expect(!keyboard.injectedKeys.contains(code), "modifier \(code) releases its own side independently")
    }
    for code in (UInt16(0)...UInt16(127)).filter({ modifierBit[$0] == nil }) {
      keyboard.inject(InputEvent(cgType: CGEventType.keyDown.rawValue, keyCode: code, button: 1, dx: 40))
      let replay = keyboardRecorder.events.last!
      expect(replay.type == .keyDown && replay.getIntegerValueField(.keyboardEventKeycode) == Int64(code) &&
             replay.getIntegerValueField(.keyboardEventAutorepeat) == 1 &&
             replay.getIntegerValueField(.keyboardEventKeyboardType) == 40,
             "ordinary/navigation/function/keypad key \(code) preserves code, repeat and keyboard type")
      keyboard.inject(InputEvent(cgType: CGEventType.keyUp.rawValue, keyCode: code, dx: 40))
    }
    expect(mask & (1 << kSystemDefinedType.rawValue) != 0, "event tap includes auxiliary system-defined keys")
    for code in AuxiliaryKey.supported.sorted() {
      keyboard.inject(InputEvent(cgType: kSystemDefinedType.rawValue, keyCode: code, button: 0xA, clickState: 1))
      let auxiliary = AuxiliaryKey(event: keyboardRecorder.events.last!)
      expect(auxiliary?.code == code && auxiliary?.down == true && auxiliary?.repeated == true &&
             keyboard.injectedAuxiliaryKeys.contains(code), "auxiliary key \(code) preserves down and repeat")
      keyboard.releaseInjectedInput()
      let released = AuxiliaryKey(event: keyboardRecorder.events.last!)
      expect(released?.code == code && released?.down == false && released?.repeated == false &&
             keyboard.injectedAuxiliaryKeys.isEmpty, "auxiliary key \(code) releases on session cleanup")
    }
    let emittedBeforeInvalid = keyboardRecorder.events.count
    keyboard.inject(InputEvent(cgType: kSystemDefinedType.rawValue, keyCode: 6, button: 0xA))
    keyboard.inject(InputEvent(cgType: kSystemDefinedType.rawValue, keyCode: 0, button: 1))
    keyboard.inject(InputEvent(cgType: kSystemDefinedType.rawValue, keyCode: 0, button: 0xA, clickState: 2))
    expect(keyboardRecorder.events.count == emittedBeforeInvalid,
           "unsupported power key and malformed auxiliary states are never injected")
    expect(keyboardRecorder.events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == kInjectedMagic },
           "keyboard and auxiliary events retain anti-loop source stamp")
    let reserved = testNode()
    reserved.reservedToggleKeys = [1]
    reserved.pendingBegin = 99
    reserved.dropAndReconnect()
    reserved.config.hotkey.keyCode = 2
    let oldShortcut = CGEvent(keyboardEventSource: keyboardSource, virtualKey: 1, keyDown: true)!
    oldShortcut.flags = []
    oldShortcut.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    expect(reserved.handle(type: .keyDown, event: oldShortcut) == nil && reserved.reservedToggleKeys == [1],
           "held shortcut repeats stay reserved after connection failure and shortcut change")
    let oldShortcutUp = CGEvent(keyboardEventSource: keyboardSource, virtualKey: 1, keyDown: false)!
    oldShortcutUp.flags = []
    expect(reserved.handle(type: .keyUp, event: oldShortcutUp) == nil && reserved.reservedToggleKeys.isEmpty,
           "original shortcut up is swallowed after configuration change")
    reserved.reservedToggleKeys = [1]
    oldShortcut.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    expect(reserved.handle(type: .keyDown, event: oldShortcut) != nil && reserved.reservedToggleKeys.isEmpty,
           "fresh key press recovers reservation if its previous up was missed")
    let overlapping = testNode()
    overlapping.mode = .remote
    overlapping.outReady = true
    overlapping.lastPong = monotonicNow()
    overlapping.outConn = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let firstDown = CGEvent(keyboardEventSource: keyboardSource, virtualKey: 1, keyDown: true)!
    firstDown.flags = overlapping.config.hotkey.requiredFlags
    expect(overlapping.handle(type: .keyDown, event: firstDown) == nil &&
           overlapping.reservedToggleKeys == [1], "first physically pressed shortcut stays reserved through local return")
    overlapping.config.hotkey.keyCode = 2
    let secondDown = CGEvent(keyboardEventSource: keyboardSource, virtualKey: 2, keyDown: true)!
    secondDown.flags = overlapping.config.hotkey.requiredFlags
    expect(overlapping.handle(type: .keyDown, event: secondDown) == nil &&
           overlapping.reservedToggleKeys == [1, 2], "changed shortcut reserves second held key without losing first")
    overlapping.pendingBegin = nil
    overlapping.mode = .remote
    firstDown.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    secondDown.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    let sendsBeforeHeldRepeats = overlapping.pendingSends
    expect(overlapping.handle(type: .keyDown, event: firstDown) == nil &&
           overlapping.handle(type: .keyDown, event: secondDown) == nil &&
           overlapping.pendingSends == sendsBeforeHeldRepeats,
           "both simultaneous reserved shortcut repeat streams stay out of remote transport")
    let secondUp = CGEvent(keyboardEventSource: keyboardSource, virtualKey: 2, keyDown: false)!
    secondUp.flags = []
    expect(overlapping.handle(type: .keyUp, event: secondUp) == nil &&
           overlapping.reservedToggleKeys == [1], "releasing newest shortcut first preserves older reservation")
    expect(overlapping.handle(type: .keyDown, event: firstDown) == nil &&
           overlapping.pendingSends == sendsBeforeHeldRepeats,
           "older shortcut repeat remains swallowed after newer shortcut release")
    expect(overlapping.handle(type: .keyUp, event: oldShortcutUp) == nil &&
           overlapping.reservedToggleKeys.isEmpty && overlapping.pendingSends == sendsBeforeHeldRepeats,
           "out-of-order shortcut releases balance both reservations without forwarding orphan ups")
    overlapping.stop()
    let mouseRecorder = EventRecorder()
    let mouse = testNode(mouseRecorder)
    mouse.displayBounds = CGRect(x: -900, y: -200, width: 800, height: 600)
    mouse.cursor = CGPoint(x: -105, y: -195)
    mouse.receivingRemote = true
    mouse.inject(InputEvent(cgType: CGEventType.mouseMoved.rawValue, dx: 20, dy: -12))
    let moved = mouseRecorder.events.last!
    expect(moved.location == CGPoint(x: -101, y: -200) &&
           moved.getIntegerValueField(.mouseEventDeltaX) == 20 &&
           moved.getIntegerValueField(.mouseEventDeltaY) == -12,
           "mouse event preserves movement deltas while clamping to cached negative-origin display")
    expect(mouse.edgePush(mouse.cursor, 20, -12, .right) == 20 &&
           mouse.edgePush(mouse.cursor, 20, -12, .top) == 12,
           "edge detection uses the same cached display bounds as injected movement")
    mouse.refreshDisplayBounds()
    expect(mouse.displayBounds == displaysUnion() && mouse.displayBounds.contains(mouse.cursor),
           "display refresh replaces cached bounds and reclamps injected cursor")
    runMotionBatchTests()
  }

  private static func runMotionBatchTests() {
    func fixture() -> (Node, EventRecorder, NWConnection) {
      let recorder = EventRecorder(), node = testNode(recorder)
      let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
      node.incomingConn = connection
      node.incomingConnected = true
      node.incomingSession = 42
      node.receivingRemote = true
      node.lastIncomingPing = monotonicNow()
      node.lastHealthTick = monotonicNow()
      node.displayBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
      node.cursor = CGPoint(x: 100, y: 100)
      return (node, recorder, connection)
    }
    func move(_ dx: Double, _ dy: Double = 0, flags: UInt64 = 0) -> InputEvent {
      InputEvent(cgType: CGEventType.mouseMoved.rawValue, flags: flags, dx: dx, dy: dy)
    }
    let (burst, burstEvents, burstConnection) = fixture()
    burst.receiveBatch(Array(repeating: move(1, 2), count: 100), from: burstConnection)
    expect(burstEvents.events.count == 1 && burst.cursor == CGPoint(x: 200, y: 300) &&
           burstEvents.events[0].location == burst.cursor &&
           burstEvents.events[0].getDoubleValueField(.mouseEventDeltaX) == 100 &&
           burstEvents.events[0].getDoubleValueField(.mouseEventDeltaY) == 200,
           "100 adjacent received moves produce one post with final position and accumulated deltas")
    expect(burst.pendingMotion == nil && burst.motionBatchConnection == nil,
           "motion batching retains nothing across receive callbacks")
    burst.receiveBatch([move(1)], from: burstConnection)
    expect(burstEvents.events.count == 2 && burst.cursor.x == 201,
           "next receive callback posts promptly without a batching timer")

    let (clamped, clampedEvents, clampedConnection) = fixture()
    clamped.displayBounds = CGRect(x: -100, y: -50, width: 100, height: 100)
    clamped.cursor = CGPoint(x: -10, y: 0)
    clamped.receiveBatch([move(20), move(-20)], from: clampedConnection)
    expect(clampedEvents.events.count == 1 && clamped.cursor.x == -21 &&
           clampedEvents.events[0].getDoubleValueField(.mouseEventDeltaX) == 0,
           "batch geometry clamps each move before reversal instead of clamping a summed delta")

    let shift = CGEventFlags.maskShift.rawValue | 0x2
    let (flags, flagEvents, flagConnection) = fixture()
    flags.receiveBatch([move(1), move(1), move(1, flags: shift), move(1, flags: shift)], from: flagConnection)
    expect(flagEvents.events.count == 2 && flagEvents.events[0].flags.isEmpty &&
           flagEvents.events[1].flags.rawValue == shift &&
           flagEvents.events.allSatisfy { $0.getDoubleValueField(.mouseEventDeltaX) == 2 },
           "modifier changes split otherwise adjacent movement batches")
    let physicalSource = CGEventSource(stateID: .privateState)!
    physicalSource.userData = 0
    let physicalKey = CGEvent(keyboardEventSource: physicalSource, virtualKey: 0, keyDown: true)!
    physicalKey.flags = []
    expect(flags.handle(type: .keyDown, event: physicalKey) != nil && !flags.receivingRemote &&
           flagEvents.events.last?.type == .flagsChanged && flagEvents.events.last?.flags.isEmpty == true &&
           flags.pendingMotion == nil, "physical takeover releases modifiers after prior motion and leaves no delayed motion")

    let (ordered, orderedEvents, orderedConnection) = fixture()
    ordered.receiveBatch([
      move(1), move(2), InputEvent(cgType: CGEventType.leftMouseDown.rawValue),
      InputEvent(cgType: CGEventType.leftMouseDragged.rawValue, dx: 3),
      InputEvent(cgType: CGEventType.leftMouseDragged.rawValue, dx: 4),
      InputEvent(cgType: CGEventType.keyDown.rawValue, keyCode: 5),
      InputEvent(cgType: CGEventType.keyUp.rawValue, keyCode: 5),
      InputEvent(cgType: CGEventType.leftMouseUp.rawValue),
      move(6), InputEvent(cgType: kCtrlType, flags: 42, button: kCtrlEnd), move(7)
    ], from: orderedConnection)
    expect(orderedEvents.events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseDragged,
             .leftMouseDragged, .keyDown, .keyUp, .leftMouseUp, .mouseMoved] &&
           orderedEvents.events[0].location.x == 103 && orderedEvents.events[1].location.x == 103 &&
           ordered.cursor.x == 116 && !ordered.receivingRemote,
           "batching preserves click, individual drag, key and END ordering and rejects motion after END")

    let (barriers, barrierEvents, barrierConnection) = fixture()
    barriers.receiveBatch([move(1), InputEvent(cgType: CGEventType.keyDown.rawValue, keyCode: 4),
      move(1), InputEvent(cgType: CGEventType.scrollWheel.rawValue, dy: 2),
      move(1), InputEvent(cgType: kCtrlType, flags: 10, button: kCtrlPing), move(1)
    ], from: barrierConnection)
    expect(barrierEvents.events.map(\.type) == [.mouseMoved, .keyDown, .mouseMoved, .scrollWheel,
           .mouseMoved, .mouseMoved], "keyboard, scroll and heartbeat records are strict movement barriers")

    let (edge, edgeEvents, edgeConnection) = fixture()
    let (reference, _, referenceConnection) = fixture()
    for node in [edge, reference] {
      node.displayBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
      node.cursor = CGPoint(x: 90, y: 10)
      node.config.edgeEnabled = true
      node.config.edgeDirection = .right
      node.edgeResumeAt = 0
    }
    let trajectory = [move(10, flags: shift), move(-20, flags: shift),
                      move(80, flags: shift), move(80, flags: shift), move(-30, flags: shift)]
    for event in trajectory { reference.receive(event, from: referenceConnection) }
    edge.receiveBatch(trajectory, from: edgeConnection)
    expect(edge.cursor == reference.cursor && edge.recvPressure == reference.recvPressure &&
           edge.receivingRemote == reference.receivingRemote && !edge.receivingRemote,
           "batched edge pressure and return point match sequential input including boundary reversal")
    expect(edgeEvents.events.map(\.type) == [.mouseMoved, .flagsChanged] &&
           edgeEvents.events.last?.flags.isEmpty == true && edge.injectedKeys.isEmpty,
           "edge return flushes old motion before modifier release without reviving old flags")

    let (stale, staleEvents, staleConnection) = fixture()
    let replacement = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    stale.incomingConn = replacement
    stale.receiveBatch([move(20)], from: staleConnection)
    expect(staleEvents.events.isEmpty && stale.cursor.x == 100 && stale.pendingMotion == nil,
           "stale socket batch cannot move or queue the replacement session cursor")
    stale.lastIncomingPing = monotonicNow() - kLeaseDuration - 1
    stale.receiveBatch([move(20)], from: replacement)
    expect(staleEvents.events.isEmpty && stale.cursor.x == 100 && stale.pendingMotion == nil,
           "expired input lease cannot queue or emit batched movement")
    stale.lastIncomingPing = monotonicNow()
    stale.lastHealthTick = monotonicNow() - kLeaseDuration - 1
    stale.receiveBatch([move(20)], from: replacement)
    expect(staleEvents.events.isEmpty && stale.incomingConn == nil && stale.motionBatchConnection == nil,
           "main-loop gap closes old batch session with no delayed movement")

    let (invalid, invalidEvents, invalidConnection) = fixture()
    invalid.receiveBatch([move(1), move(.nan), move(.infinity), move(1)], from: invalidConnection)
    expect(invalidEvents.events.count == 1 && invalid.cursor.x == 102 &&
           invalidEvents.events[0].getDoubleValueField(.mouseEventDeltaX) == 2,
           "invalid movement deltas cannot poison accumulated cursor motion")
  }

  static func runNetworkTests() {
    let aRecorder = EventRecorder(), bRecorder = EventRecorder()
    let a = testNode(aRecorder), b = testNode(bRecorder)
    let aPort = unusedPort()
    var bPort = unusedPort()
    while bPort == aPort { bPort = unusedPort() }
    a.config.port = aPort
    b.config.port = bPort
    a.startListener()
    b.startListener()
    a.config.port = bPort
    b.config.port = aPort
    a.startOutConnection()
    b.startOutConnection()
    a.startHealthTimer()
    b.startHealthTimer()
    eventually("both real TCP links establish application heartbeats", { a.linkHealthy && b.linkHealthy }) {
      func continueWithHandoff() {
        let aConnection = a.outConn, bConnection = b.outConn
        let heldSource = CGEventSource(stateID: .privateState)!
        heldSource.userData = 0
        let localKeyDown = CGEvent(keyboardEventSource: heldSource, virtualKey: 12, keyDown: true)!
        localKeyDown.flags = []
        let localModifierDown = CGEvent(keyboardEventSource: heldSource, virtualKey: 55, keyDown: true)!
        localModifierDown.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        let localMouseDown = CGEvent(mouseEventSource: heldSource, mouseType: .leftMouseDown,
                                    mouseCursorPosition: .zero, mouseButton: .left)!
        localMouseDown.flags = []
        expect(a.handle(type: .keyDown, event: localKeyDown) != nil &&
               a.handle(type: .flagsChanged, event: localModifierDown) != nil &&
               a.handle(type: .leftMouseDown, event: localMouseDown) != nil,
               "pre-handoff physical key, modifier and button downs reach local apps")
        let shortcut = CGEvent(keyboardEventSource: heldSource, virtualKey: a.config.hotkey.keyCode, keyDown: true)!
        shortcut.flags = a.config.hotkey.requiredFlags
        expect(a.handle(type: .keyDown, event: shortcut) == nil, "switching shortcut down is reserved locally")
        expect(a.mode == .local && a.pendingBegin != nil, "sender waits for BEGIN acknowledgement before swallowing input")
        eventually("BEGIN/ACK establishes one direction of ownership", { a.mode == .remote && b.receivingRemote }) {
          shortcut.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
          let sendsBeforeRepeat = a.pendingSends
          expect(a.handle(type: .keyDown, event: shortcut) == nil && a.pendingSends == sendsBeforeRepeat,
                 "reserved switching shortcut repeats never reach remote keyboard")
          let shortcutUp = CGEvent(keyboardEventSource: heldSource, virtualKey: a.config.hotkey.keyCode, keyDown: false)!
          shortcutUp.flags = a.config.hotkey.requiredFlags
          expect(a.handle(type: .keyUp, event: shortcutUp) == nil && a.reservedToggleKeys.isEmpty,
                 "reserved switching shortcut up completes the swallowed pair")
          let localKeyUp = CGEvent(keyboardEventSource: heldSource, virtualKey: 12, keyDown: false)!
          localKeyUp.flags = []
          let localModifierUp = CGEvent(keyboardEventSource: heldSource, virtualKey: 55, keyDown: false)!
          localModifierUp.flags = []
          let localMouseUp = CGEvent(mouseEventSource: heldSource, mouseType: .leftMouseUp,
                                    mouseCursorPosition: .zero, mouseButton: .left)!
          localMouseUp.flags = []
          expect(a.handle(type: .keyUp, event: localKeyUp) != nil,
                 "key held before handoff receives its matching local release")
          expect(a.handle(type: .flagsChanged, event: localModifierUp) != nil,
                 "modifier held before handoff receives its matching local release")
          expect(a.handle(type: .leftMouseUp, event: localMouseUp) != nil,
                 "button held before handoff receives its matching local release")
          expect(a.localKeys.isEmpty && a.localButtons.isEmpty && a.mode == .remote,
                 "balancing local releases clears tracking without ending forwarding")
          let source = CGEventSource(stateID: .privateState)!
          source.userData = 0
          let key = CGEvent(keyboardEventSource: source, virtualKey: 7, keyDown: true)!
          key.flags = []
          key.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
          key.setIntegerValueField(.keyboardEventKeyboardType, value: 40)
          let volume = AuxiliaryKey.event(code: 0, down: true, repeated: true, source: source)!
          expect(a.handle(type: kSystemDefinedType, event: volume) == nil,
                 "supported auxiliary down is captured for the active remote session")
          expect(a.handle(type: .keyDown, event: key) == nil, "healthy acknowledged sender forwards and suppresses local key")
          eventually("actual wire input reaches recorder without OS posting", { b.injectedKeys.contains(7) }) {
            expect(bRecorder.events.contains { event in
              event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 7 &&
                event.getIntegerValueField(.keyboardEventAutorepeat) == 1 &&
                event.getIntegerValueField(.keyboardEventKeyboardType) == 40
            }, "autorepeat and keyboard type survive real TCP forwarding")
            expect(b.injectedAuxiliaryKeys == [0] && bRecorder.events.contains {
              let event = AuxiliaryKey(event: $0)
              return event?.code == 0 && event?.down == true && event?.repeated == true
            }, "media key identity, down and repeat survive real TCP forwarding")
            expect(bRecorder.events.contains { $0.type == .keyUp && $0.getIntegerValueField(.keyboardEventKeycode) == 12 } &&
                   bRecorder.events.contains { $0.type == .flagsChanged && $0.getIntegerValueField(.keyboardEventKeycode) == 55 && $0.flags.isEmpty } &&
                   bRecorder.events.contains { $0.type == .leftMouseUp },
                   "pre-handoff releases also travel over TCP to receiver")
            _ = b.handle(type: .keyDown, event: key)
            let physicalUp = CGEvent(keyboardEventSource: source, virtualKey: 7, keyDown: false)!
            physicalUp.flags = []
            _ = b.handle(type: .keyUp, event: physicalUp)
            eventually("receiver physical takeover returns sender to local", { a.mode == .local && !b.receivingRemote }) {
              expect(b.injectedKeys.isEmpty && bRecorder.events.contains { $0.type == .keyUp }, "takeover releases injected held key")
              expect(b.injectedAuxiliaryKeys.isEmpty && bRecorder.events.contains {
                let event = AuxiliaryKey(event: $0)
                return event?.code == 0 && event?.down == false
              }, "physical takeover releases remotely held media key")
              expect(a.outConn === aConnection && b.outConn === bConnection, "incoming connections do not provoke reconnect storm")
              b.toggleMode()
              eventually("same protocol acquires ownership in reverse direction", { b.mode == .remote && a.receivingRemote }) {
                // Close the peer's socket to exercise EOF separately from timeout.
                a.healthTimer?.cancel()
                a.incomingConn?.cancel()
                a.incomingConn = nil
                eventually("connection failure restores sender without physical hotkey", { b.mode == .local && !b.linkHealthy }) {
                  a.stop(); b.stop()
                  runFullKeyboardNetworkTests()
                }
              }
            }
          }
        }
      }
      a.toggleMode()
      b.toggleMode()
      eventually("simultaneous BEGIN requests settle with both inputs local", {
        a.mode == .local && b.mode == .local && a.pendingBegin == nil && b.pendingBegin == nil &&
        !a.receivingRemote && !b.receivingRemote
      }) {
        expect(a.linkHealthy && b.linkHealthy, "simultaneous acquisition preserves both healthy connections")
        continueWithHandoff()
      }
    }
  }

  static func runFullKeyboardNetworkTests() {
    let recorder = EventRecorder()
    let sender = testNode(), receiver = testNode(recorder)
    let senderPort = unusedPort()
    var receiverPort = unusedPort()
    while receiverPort == senderPort { receiverPort = unusedPort() }
    sender.config.port = senderPort; receiver.config.port = receiverPort
    sender.startListener(); receiver.startListener()
    sender.config.port = receiverPort; receiver.config.port = senderPort
    sender.startOutConnection(); receiver.startOutConnection()
    sender.startHealthTimer(); receiver.startHealthTimer()
    let source = CGEventSource(stateID: .privateState)!
    source.userData = 0
    let ordinary = (UInt16(0)...UInt16(127)).filter { modifierBit[$0] == nil }
    let modifiers = modifierBit.keys.sorted()
    let auxiliary = AuxiliaryKey.supported.sorted()

    func checkOrdinary(_ index: Int) {
      guard index < ordinary.count else { checkModifier(0); return }
      let code = ordinary[index], before = recorder.events.count
      for (down, repeated) in [(true, false), (true, true), (false, false)] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        event.setIntegerValueField(.keyboardEventKeyboardType, value: 41)
        expect(sender.handle(type: down ? .keyDown : .keyUp, event: event) == nil,
               "full wire matrix captures key \(code) \(down ? (repeated ? "repeat" : "down") : "up")")
      }
      eventually("full wire matrix delivers key \(code)", { recorder.events.count >= before + 3 }) {
        let events = Array(recorder.events[before..<(before + 3)])
        expect(events.map(\.type) == [.keyDown, .keyDown, .keyUp] &&
               events.map { $0.getIntegerValueField(.keyboardEventAutorepeat) } == [0, 1, 0] &&
               events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(code) &&
                 $0.getIntegerValueField(.keyboardEventKeyboardType) == 41 && $0.flags.isEmpty &&
                 $0.getIntegerValueField(.eventSourceUserData) == kInjectedMagic } &&
               !receiver.injectedKeys.contains(code),
               "full wire matrix preserves key \(code) identity/type/repeat/flags/keyboard-type and balances release")
        checkOrdinary(index + 1)
      }
    }

    func checkModifier(_ index: Int) {
      guard index < modifiers.count else { checkAuxiliary(0); return }
      let code = modifiers[index], bit = modifierBit[code]!, before = recorder.events.count
      let family: CGEventFlags
      switch code {
      case 59, 62: family = .maskControl
      case 56, 60: family = .maskShift
      case 55, 54: family = .maskCommand
      case 58, 61: family = .maskAlternate
      case 57: family = .maskAlphaShift
      default: family = .maskSecondaryFn
      }
      for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: down ? bit | family.rawValue : 0)
        event.setIntegerValueField(.keyboardEventKeyboardType, value: 41)
        expect(sender.handle(type: .flagsChanged, event: event) == nil,
               "full wire matrix captures modifier \(code) \(down ? "press" : "release")")
      }
      eventually("full wire matrix delivers modifier \(code)", { recorder.events.count >= before + 2 }) {
        let events = Array(recorder.events[before..<(before + 2)])
        expect(events.allSatisfy { $0.type == .flagsChanged &&
                 $0.getIntegerValueField(.keyboardEventKeycode) == Int64(code) &&
                 $0.getIntegerValueField(.keyboardEventKeyboardType) == 41 } &&
               events[0].flags.rawValue == bit | family.rawValue && events[1].flags.isEmpty &&
               !receiver.injectedKeys.contains(code),
               "full wire matrix preserves modifier \(code) side/state/type and clears held state")
        checkModifier(index + 1)
      }
    }

    func checkAuxiliary(_ index: Int) {
      guard index < auxiliary.count else {
        print("Keyboard wire matrix: 118 ordinary codes × down/repeat/up; 10 modifier codes × press/release; 24 auxiliary codes × down/repeat/up; all 128 virtual codes covered.")
        sender.stop(); receiver.stop()
        runSilentPeerTests()
        return
      }
      let code = auxiliary[index], before = recorder.events.count
      for (down, repeated) in [(true, false), (true, true), (false, false)] {
        let event = AuxiliaryKey.event(code: code, down: down, repeated: repeated, source: source)!
        expect(sender.handle(type: kSystemDefinedType, event: event) == nil,
               "full wire matrix captures auxiliary \(code) \(down ? (repeated ? "repeat" : "down") : "up")")
      }
      eventually("full wire matrix delivers auxiliary \(code)", { recorder.events.count >= before + 3 }) {
        let events = recorder.events[before..<(before + 3)].compactMap { AuxiliaryKey(event: $0) }
        expect(events.count == 3 && events.allSatisfy { $0.code == code } &&
               events.map(\.down) == [true, true, false] && events.map(\.repeated) == [false, true, false] &&
               !receiver.injectedAuxiliaryKeys.contains(code),
               "full wire matrix preserves auxiliary \(code) down/repeat/up and balances release")
        checkAuxiliary(index + 1)
      }
    }

    eventually("full keyboard matrix establishes two healthy TCP nodes", { sender.linkHealthy && receiver.linkHealthy }) {
      sender.toggleMode()
      eventually("full keyboard matrix acquires acknowledged ownership", { sender.mode == .remote && receiver.receivingRemote }) {
        checkOrdinary(0)
      }
    }
  }

  static func runSilentPeerTests() {
    let peer = SilentPeer()
    let node = testNode()
    eventually("silent-peer fixture starts loopback listener", { peer.ready && peer.listener.port != nil }) {
      node.config.port = peer.listener.port!.rawValue
      node.startOutConnection()
      node.startHealthTimer()
      eventually("fixture supplies healthy application heartbeats", { node.linkHealthy }) {
        node.toggleMode()
        eventually("unacknowledged BEGIN expires while heartbeat remains healthy",
                   { peer.beginToken != nil && node.pendingBegin == nil && node.linkHealthy }) {
          expect(node.mode == .local, "unacknowledged acquisition never suppresses input")
          peer.reply(kCtrlBeginAck, token: peer.beginToken!)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect(node.mode == .local, "late BEGIN acknowledgement cannot resurrect expired acquisition")
            let expiredToken = peer.beginToken!
            node.toggleMode()
            let freshToken = node.pendingBegin!
            peer.reply(kCtrlReturn, token: expiredToken)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect(node.pendingBegin == freshToken && node.mode == .local,
                   "RETURN from previous session cannot cancel newer pending acquisition")
            peer.acknowledgeBegin = true
            peer.reply(kCtrlBeginAck, token: freshToken)
            eventually("fixture acknowledges a fresh acquisition", { node.mode == .remote }) {
              let connection = peer.connection
              peer.silent = true
              eventually("silent open TCP peer loses application lease", { node.mode == .local && !node.linkHealthy }) {
                expect(peer.connection === connection, "timeout test kept peer socket open rather than cancelling it")
                let source = CGEventSource(stateID: .privateState)!
                source.userData = 0
                let key = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)!
                key.flags = []
                expect(node.handle(type: .keyDown, event: key) != nil, "physical key passes through after silent-peer timeout")
                node.stop()
                peer.listener.cancel()
                peer.connection?.cancel()
                print("\(checks) regression checks passed; no event taps installed or system input posted.")
                exit(0)
              }
            }
            }
          }
        }
      }
    }
  }
}

DispatchQueue.main.async {
  Node.runUnitTests()
  Node.runNetworkTests()
}
dispatchMain()
