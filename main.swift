import Foundation
import CoreGraphics
import Network
import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Constants

private let kServiceType = "_kvmswitch._tcp"
private let kRecordSize = 32
// Stamp injected events so the local tap can recognize and ignore them
// (prevents an inject -> tap -> forward feedback loop in symmetric mode).
private let kInjectedMagic: Int64 = 0x4B564D31 // "KVM1"

private func log(_ msg: String) {
  let ts = ISO8601DateFormatter().string(from: Date())
  FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
}

private func mainAsync(_ work: @escaping () -> Void) {
  if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
}

private func primaryIPv4() -> String {
  var result: String?
  var ifaddr: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&ifaddr) == 0 else { return "?" }
  defer { freeifaddrs(ifaddr) }
  var ptr = ifaddr
  while let cur = ptr {
    let iface = cur.pointee
    ptr = iface.ifa_next
    guard let sa = iface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
    let name = String(cString: iface.ifa_name)
    guard name == "en0" || name == "en1" else { continue }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
    result = String(cString: host)
  }
  return result ?? "?"
}

private func selfHostName() -> String {
  if let n = (Host.current().localizedName) { return n }
  return ProcessInfo.processInfo.hostName
}

private enum EdgeDir: String, Codable, CaseIterable {
  case right, left, top, bottom
  var display: String {
    switch self {
    case .right: return "справа"
    case .left: return "слева"
    case .top: return "сверху"
    case .bottom: return "снизу"
    }
  }
}

private let kEdgeThreshold = 120.0 // accumulated px of "push" into the edge before switching

/// Union of all active displays in global top-left coordinates (matches CGEvent.location).
private func displaysUnion() -> CGRect {
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  var count: UInt32 = 0
  CGGetActiveDisplayList(16, &ids, &count)
  var rect = CGRect.null
  for i in 0 ..< Int(count) { rect = rect.union(CGDisplayBounds(ids[i])) }
  return rect.isNull ? CGDisplayBounds(CGMainDisplayID()) : rect
}

private func endpointLabel(_ ep: NWEndpoint) -> String {
  switch ep {
  case .hostPort(let host, let port):
    var h = "\(host)"
    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
    return "\(h):\(port)"
  case .service(let name, _, _, _):
    return name
  default:
    return "\(ep)"
  }
}

// MARK: - Wire protocol
// Fixed 32-byte record, big-endian, length-prefixed (UInt32).
//   cgType:UInt32 | flags:UInt64 | keyCode:UInt16 | button:UInt8 | clickState:UInt8 | dx:Float64 | dy:Float64

private struct InputEvent {
  var cgType: UInt32 = 0
  var flags: UInt64 = 0
  var keyCode: UInt16 = 0
  var button: UInt8 = 0
  var clickState: UInt8 = 0
  var dx: Double = 0
  var dy: Double = 0

  func encoded() -> Data {
    var out = Data(capacity: 4 + kRecordSize)
    appendBE(&out, UInt32(kRecordSize))
    appendBE(&out, cgType)
    appendBE(&out, flags)
    appendBE(&out, keyCode)
    out.append(button)
    out.append(clickState)
    appendBE(&out, dx.bitPattern)
    appendBE(&out, dy.bitPattern)
    return out
  }

  static func decode(_ body: Data) -> InputEvent {
    var ev = InputEvent()
    var idx = body.startIndex
    ev.cgType = readBE(body, &idx, UInt32.self)
    ev.flags = readBE(body, &idx, UInt64.self)
    ev.keyCode = readBE(body, &idx, UInt16.self)
    ev.button = body[idx]; idx += 1
    ev.clickState = body[idx]; idx += 1
    ev.dx = Double(bitPattern: readBE(body, &idx, UInt64.self))
    ev.dy = Double(bitPattern: readBE(body, &idx, UInt64.self))
    return ev
  }
}

// Control records reuse the same 32-byte frame with a sentinel cgType.
private let kCtrlType: UInt32 = 0xFFFF_FFFF
private let kCtrlReturn: UInt8 = 1 // receiver -> controller: "give input back"

private func controlRecord(_ code: UInt8) -> Data {
  var ev = InputEvent(); ev.cgType = kCtrlType; ev.button = code
  return ev.encoded()
}

/// Pulls complete length-prefixed 32-byte frames out of a buffer.
private func parseFrames(_ buffer: inout Data, _ handle: (InputEvent) -> Void) {
  while buffer.count >= 4 {
    var idx = buffer.startIndex
    let len = Int(readBE(buffer, &idx, UInt32.self))
    guard len == kRecordSize else { buffer.removeAll(keepingCapacity: true); return }
    guard buffer.count >= 4 + len else { return }
    let body = buffer.subdata(in: idx ..< idx + len)
    buffer.removeSubrange(buffer.startIndex ..< idx + len)
    handle(InputEvent.decode(body))
  }
}

private func appendBE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
  var be = value.bigEndian
  withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

private func readBE<T: FixedWidthInteger>(_ data: Data, _ idx: inout Data.Index, _ type: T.Type) -> T {
  let size = MemoryLayout<T>.size
  var value: T = 0
  _ = withUnsafeMutableBytes(of: &value) { dst in
    data.copyBytes(to: dst, from: idx ..< idx + size)
  }
  idx += size
  return T(bigEndian: value)
}

// MARK: - Config (persisted, editable from the UI)

private struct HotkeySpec: Codable, Equatable {
  var keyCode: UInt16 = 1 // 'S'
  var control = true
  var option = true
  var command = true
  var shift = false

  var requiredFlags: CGEventFlags {
    var f: CGEventFlags = []
    if control { f.insert(.maskControl) }
    if option { f.insert(.maskAlternate) }
    if command { f.insert(.maskCommand) }
    if shift { f.insert(.maskShift) }
    return f
  }

  func matches(keyCode kc: UInt16, flags: CGEventFlags) -> Bool {
    guard kc == keyCode else { return false }
    let req = requiredFlags
    let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    return flags.intersection(relevant) == req
  }

  var display: String {
    var s = ""
    if control { s += "⌃" }
    if option { s += "⌥" }
    if shift { s += "⇧" }
    if command { s += "⌘" }
    s += KeyNames.name(for: keyCode)
    return s
  }
}

private final class AppConfig: ObservableObject, Codable {
  @Published var peerName: String = ""   // chosen peer (Bonjour name)
  @Published var manualHost: String = "" // optional manual IP/host fallback
  @Published var port: UInt16 = 52333
  @Published var hotkey = HotkeySpec()
  @Published var autostart = false
  @Published var edgeEnabled = false
  @Published var edgeDirection: EdgeDir = .right

  enum CodingKeys: String, CodingKey {
    case peerName, manualHost, port, hotkey, autostart, edgeEnabled, edgeDirection
  }

  init() {}

  required init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    peerName = (try? c.decode(String.self, forKey: .peerName)) ?? ""
    manualHost = (try? c.decode(String.self, forKey: .manualHost)) ?? ""
    port = (try? c.decode(UInt16.self, forKey: .port)) ?? 52333
    hotkey = (try? c.decode(HotkeySpec.self, forKey: .hotkey)) ?? HotkeySpec()
    autostart = (try? c.decode(Bool.self, forKey: .autostart)) ?? false
    edgeEnabled = (try? c.decode(Bool.self, forKey: .edgeEnabled)) ?? false
    edgeDirection = (try? c.decode(EdgeDir.self, forKey: .edgeDirection)) ?? .right
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(peerName, forKey: .peerName)
    try c.encode(manualHost, forKey: .manualHost)
    try c.encode(port, forKey: .port)
    try c.encode(hotkey, forKey: .hotkey)
    try c.encode(autostart, forKey: .autostart)
    try c.encode(edgeEnabled, forKey: .edgeEnabled)
    try c.encode(edgeDirection, forKey: .edgeDirection)
  }

  // change hooks (separate so UI edits can trigger engine restarts)
  var onLinkConfigChanged: (() -> Void)?
  var onHotkeyChanged: (() -> Void)?

  private static var fileURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("KVM Switch", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.json")
  }

  static func load() -> AppConfig {
    guard let data = try? Data(contentsOf: fileURL),
          let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
      return AppConfig()
    }
    return cfg
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) {
      try? data.write(to: AppConfig.fileURL)
    }
  }
}

// MARK: - Bonjour discovery

private final class Discovery: ObservableObject {
  @Published var peers: [String] = []       // peer Bonjour names (excluding self)
  private var endpoints: [String: NWEndpoint] = [:]
  private var browser: NWBrowser?
  private let selfName: String

  init(selfName: String) { self.selfName = selfName }

  func endpoint(for name: String) -> NWEndpoint? { endpoints[name] }

  func start() {
    let params = NWParameters()
    params.includePeerToPeer = true
    let browser = NWBrowser(for: .bonjour(type: kServiceType, domain: nil), using: params)
    self.browser = browser
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self = self else { return }
      var map: [String: NWEndpoint] = [:]
      for r in results {
        if case .service(let name, _, _, _) = r.endpoint, name != self.selfName {
          map[name] = r.endpoint
        }
      }
      mainAsync {
        self.endpoints = map
        self.peers = map.keys.sorted()
      }
    }
    browser.start(queue: .main)
  }
}

// MARK: - Node (symmetric: forwards out AND receives/injects)

private enum Mode { case local, remote }

private final class Node {
  let config: AppConfig
  let discovery: Discovery
  let selfName: String

  // sender side
  private var mode: Mode = .local
  private var outConn: NWConnection?
  private var outReady = false
  private var pendingToggleUpSwallow = false
  private let netQueue = DispatchQueue(label: "kvm.net")
  private var reconnectScheduled = false

  // receiver side
  private var listener: NWListener?
  private var incomingConnected = false
  private var incomingPeer: String?
  private var incomingConn: NWConnection?
  private let injectQueue = DispatchQueue(label: "kvm.inject")
  private let injectSource: CGEventSource?
  private var cursor: CGPoint
  private var inBuffer = Data()

  // edge-of-screen switching
  private var edgePressure = 0.0   // controller side: push into the exit edge
  private var recvPressure = 0.0   // receiver side: push into the return edge
  private var outBuffer = Data()

  private var tapPort: CFMachPort?
  var onStatus: (() -> Void)?

  private static let mask: CGEventMask = {
    let types: [CGEventType] = [
      .keyDown, .keyUp, .flagsChanged,
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
      .otherMouseDown, .otherMouseUp,
      .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      .scrollWheel,
    ]
    return types.reduce(0) { $0 | (1 << $1.rawValue) }
  }()

  init(config: AppConfig, discovery: Discovery, selfName: String) {
    self.config = config
    self.discovery = discovery
    self.selfName = selfName
    let bounds = CGDisplayBounds(CGMainDisplayID())
    cursor = CGPoint(x: bounds.midX, y: bounds.midY)
    injectSource = CGEventSource(stateID: .hidSystemState)
    injectSource?.userData = kInjectedMagic
  }

  // MARK: status surface

  var iconTitle: String {
    if mode == .remote && outReady { return "🔵" }
    if outReady || incomingConnected { return "🟢" }
    return "🔴"
  }

  var menuLines: [String] {
    var lines: [String] = []
    lines.append("Этот Mac: \(selfName) (\(primaryIPv4()))")
    let target = currentTargetLabel()
    lines.append(mode == .remote ? "Ввод: → уходит на второй Mac ▶︎" : "Ввод: на этом Mac")
    lines.append(outReady ? "→ Связь со вторым: есть (\(target))" : "→ Связь со вторым: нет (\(target))")
    lines.append(incomingConnected ? "← Принимаю ввод от: \(incomingPeer ?? "?")" : "← Входящего ввода нет")
    lines.append("Порт: \(config.port)  Хоткей: \(config.hotkey.display)")
    if config.edgeEnabled {
      lines.append("Край экрана: вкл (\(config.edgeDirection.display))")
    }
    return lines
  }

  private func currentTargetLabel() -> String {
    if !config.peerName.isEmpty { return config.peerName }
    if !config.manualHost.isEmpty { return "\(config.manualHost):\(config.port)" }
    return "не выбран"
  }

  private func notify() { mainAsync { self.onStatus?() } }

  // MARK: lifecycle

  func start() {
    config.onLinkConfigChanged = { [weak self] in self?.applyLinkConfig() }
    startListener()
    startOutConnection()
    installTap()
    discovery.start()
    log("node ready (symmetric). hotkey=\(config.hotkey.display)")
  }

  func applyLinkConfig() {
    // port / peer changed: rebind listener and reconnect outgoing
    listener?.cancel()
    startListener()
    outConn?.cancel()
    outConn = nil
    outReady = false
    startOutConnection()
    notify()
  }

  // MARK: listener (incoming -> inject)

  private func startListener() {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let params = NWParameters(tls: nil, tcp: tcp)
    params.allowLocalEndpointReuse = true
    params.includePeerToPeer = true
    guard let port = NWEndpoint.Port(rawValue: config.port) else { return }
    do {
      let l = try NWListener(using: params, on: port)
      l.service = NWListener.Service(name: selfName, type: kServiceType)
      l.newConnectionHandler = { [weak self] conn in
        guard let self = self else { return }
        log("incoming from \(conn.endpoint)")
        conn.start(queue: self.injectQueue)
        self.inBuffer.removeAll(keepingCapacity: true)
        self.incomingConn = conn
        self.recvPressure = 0
        mainAsync {
          self.incomingConnected = true
          self.incomingPeer = endpointLabel(conn.endpoint)
          self.notify()
        }
        self.receiveLoop(conn)
      }
      l.start(queue: injectQueue)
      listener = l
    } catch {
      log("listener error on \(config.port): \(error)")
    }
  }

  private func receiveLoop(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }
      if let data = data, !data.isEmpty {
        self.inBuffer.append(data)
        self.drain()
      }
      if error != nil || isComplete {
        if self.incomingConn === conn { self.incomingConn = nil }
        mainAsync {
          self.incomingConnected = false
          self.incomingPeer = nil
          self.notify()
        }
        conn.cancel(); return
      }
      self.receiveLoop(conn)
    }
  }

  private func drain() {
    parseFrames(&inBuffer) { ev in
      if ev.cgType == kCtrlType { return } // receiver ignores inbound control
      self.inject(ev)
    }
  }

  private func inject(_ ev: InputEvent) {
    guard let type = CGEventType(rawValue: ev.cgType) else { return }
    let flags = CGEventFlags(rawValue: ev.flags)
    switch type {
    case .keyDown, .keyUp:
      guard let e = CGEvent(keyboardEventSource: injectSource, virtualKey: ev.keyCode, keyDown: type == .keyDown) else { return }
      e.flags = flags
      e.post(tap: .cghidEventTap)
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      moveCursor(dx: ev.dx, dy: ev.dy)
      checkReturnEdge(dx: ev.dx, dy: ev.dy)
      let b = CGMouseButton(rawValue: UInt32(ev.button)) ?? .left
      guard let e = CGEvent(mouseEventSource: injectSource, mouseType: type, mouseCursorPosition: cursor, mouseButton: b) else { return }
      e.flags = flags
      e.post(tap: .cghidEventTap)
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
      let b = CGMouseButton(rawValue: UInt32(ev.button)) ?? .left
      guard let e = CGEvent(mouseEventSource: injectSource, mouseType: type, mouseCursorPosition: cursor, mouseButton: b) else { return }
      e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, ev.clickState)))
      e.flags = flags
      e.post(tap: .cghidEventTap)
    case .scrollWheel:
      guard let e = CGEvent(scrollWheelEvent2Source: injectSource, units: .pixel, wheelCount: 2,
                            wheel1: Int32(ev.dy), wheel2: Int32(ev.dx), wheel3: 0) else { return }
      e.flags = flags
      e.post(tap: .cghidEventTap)
    default:
      break
    }
  }

  private func moveCursor(dx: Double, dy: Double) {
    let b = displaysUnion()
    cursor.x = min(max(b.minX, cursor.x + dx), b.maxX - 1)
    cursor.y = min(max(b.minY, cursor.y + dy), b.maxY - 1)
  }

  /// Returns push amount into the edge in `dir`, or -1 if the point is not at that edge.
  private func edgePush(_ loc: CGPoint, _ dx: Double, _ dy: Double, _ dir: EdgeDir) -> Double {
    let u = displaysUnion()
    switch dir {
    case .right:  return loc.x >= u.maxX - 2 ? max(0, dx) : -1
    case .left:   return loc.x <= u.minX + 2 ? max(0, -dx) : -1
    case .top:    return loc.y <= u.minY + 2 ? max(0, -dy) : -1
    case .bottom: return loc.y >= u.maxY - 2 ? max(0, dy) : -1
    }
  }

  /// Receiver side: while being driven, pushing toward the peer's edge returns control.
  private func checkReturnEdge(dx: Double, dy: Double) {
    guard config.edgeEnabled, let conn = incomingConn else { return }
    let push = edgePush(cursor, dx, dy, config.edgeDirection)
    if push < 0 { recvPressure = 0; return }
    recvPressure += push
    if recvPressure >= kEdgeThreshold {
      recvPressure = 0
      conn.send(content: controlRecord(kCtrlReturn), completion: .contentProcessed { _ in })
      log("edge: returning control to controller")
    }
  }

  // MARK: outgoing (tap -> forward)

  private func resolveTarget() -> NWEndpoint? {
    if !config.peerName.isEmpty, let ep = discovery.endpoint(for: config.peerName) { return ep }
    if !config.manualHost.isEmpty, let port = NWEndpoint.Port(rawValue: config.port) {
      return .hostPort(host: NWEndpoint.Host(config.manualHost), port: port)
    }
    return nil
  }

  private func startOutConnection() {
    guard let target = resolveTarget() else {
      // retry later (peer may not be discovered yet)
      netQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startOutConnection() }
      return
    }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 2
    tcp.connectionTimeout = 5
    let params = NWParameters(tls: nil, tcp: tcp)
    params.includePeerToPeer = true

    let conn = NWConnection(to: target, using: params)
    outConn = conn
    conn.stateUpdateHandler = { [weak self] state in
      guard let self = self else { return }
      switch state {
      case .ready:
        self.outReady = true
        self.outBuffer.removeAll(keepingCapacity: true)
        self.edgePressure = 0
        self.receiveControl(conn)
        self.notify(); log("out link up -> \(endpointLabel(target))")
      case .failed, .cancelled:
        self.dropAndReconnect()
      default:
        break
      }
    }
    conn.start(queue: netQueue)
  }

  private func dropAndReconnect() {
    outReady = false
    outConn?.cancel(); outConn = nil
    if mode == .remote {
      mode = .local
      NSSound.beep()
      log("SAFETY: out link lost while remote -> local")
    }
    notify()
    guard !reconnectScheduled else { return }
    reconnectScheduled = true
    netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.reconnectScheduled = false
      self?.startOutConnection()
    }
  }

  private func send(_ ev: InputEvent) {
    guard outReady, let conn = outConn else { return }
    conn.send(content: ev.encoded(), completion: .contentProcessed { _ in })
  }

  // controller listens on the outgoing link for control records (e.g. RETURN)
  private func receiveControl(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }
      if let data = data, !data.isEmpty {
        self.outBuffer.append(data)
        parseFrames(&self.outBuffer) { ev in
          if ev.cgType == kCtrlType, ev.button == kCtrlReturn {
            mainAsync { if self.mode == .remote { self.toggleMode() } }
          }
        }
      }
      if error != nil || isComplete { return }
      self.receiveControl(conn)
    }
  }

  // MARK: event tap

  private func installTap() {
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: Node.mask,
      callback: { _, type, event, refcon in
        let node = Unmanaged<Node>.fromOpaque(refcon!).takeUnretainedValue()
        return node.handle(type: type, event: event)
      },
      userInfo: refcon
    ) else {
      log("FATAL: cannot create event tap. Grant Accessibility + Input Monitoring in System Settings.")
      // keep app alive so the menu-bar icon and Settings still work
      return
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    tapPort = tap
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
      return nil
    }
    // ignore our own injected events (anti-loop in symmetric mode)
    if event.getIntegerValueField(.eventSourceUserData) == kInjectedMagic {
      return Unmanaged.passUnretained(event)
    }

    let flags = event.flags
    if type == .keyDown {
      let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
      let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
      if !isRepeat, config.hotkey.matches(keyCode: kc, flags: flags) {
        toggleMode(); pendingToggleUpSwallow = true; return nil
      }
    }
    if type == .keyUp, pendingToggleUpSwallow {
      let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
      if kc == config.hotkey.keyCode { pendingToggleUpSwallow = false; return nil }
    }

    if mode == .local, config.edgeEnabled, Node.moveTypes.contains(type) {
      let dx = event.getDoubleValueField(.mouseEventDeltaX)
      let dy = event.getDoubleValueField(.mouseEventDeltaY)
      let push = edgePush(event.location, dx, dy, config.edgeDirection)
      if push < 0 {
        edgePressure = 0
      } else {
        edgePressure += push
        if edgePressure >= kEdgeThreshold, outReady {
          edgePressure = 0
          toggleMode() // -> remote
        }
      }
    }

    switch mode {
    case .local:
      return Unmanaged.passUnretained(event)
    case .remote:
      forward(type: type, event: event, flags: flags)
      return nil
    }
  }

  private static let moveTypes: Set<CGEventType> = [
    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
  ]

  private func forward(type: CGEventType, event: CGEvent, flags: CGEventFlags) {
    if type == .flagsChanged { return }
    var ev = InputEvent()
    ev.cgType = type.rawValue
    ev.flags = flags.rawValue
    switch type {
    case .keyDown, .keyUp:
      ev.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      ev.dx = event.getDoubleValueField(.mouseEventDeltaX)
      ev.dy = event.getDoubleValueField(.mouseEventDeltaY)
      ev.button = UInt8(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber))
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
      ev.button = UInt8(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber))
      ev.clickState = UInt8(truncatingIfNeeded: event.getIntegerValueField(.mouseEventClickState))
    case .scrollWheel:
      ev.dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
      ev.dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
    default:
      return
    }
    send(ev)
  }

  func toggleMode() {
    switch mode {
    case .local:
      guard outReady else { NSSound.beep(); log("toggle ignored: out link not ready"); return }
      mode = .remote; log("mode=remote (input -> peer)")
    case .remote:
      mode = .local; log("mode=local")
    }
    NSSound.beep(); notify()
  }
}

// MARK: - Autostart (LaunchAgent; works with ad-hoc signature)

private enum Autostart {
  static let label = "com.star-village.kvm-switch"

  private static var plistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(label).plist")
  }

  static func isEnabled() -> Bool {
    FileManager.default.fileExists(atPath: plistURL.path)
  }

  static func set(_ enabled: Bool) {
    if enabled {
      let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
      let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [exe],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": "/tmp/kvm-switch.log",
        "StandardErrorPath": "/tmp/kvm-switch.log",
      ]
      let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try? data?.write(to: plistURL)
      runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    } else {
      runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
      try? FileManager.default.removeItem(at: plistURL)
    }
  }

  private static func runLaunchctl(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
  }
}

// MARK: - Key names (for hotkey display)

private enum KeyNames {
  static func name(for code: UInt16) -> String {
    let map: [UInt16: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
      11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
      31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
      45: "N", 46: "M", 49: "Space", 36: "Return", 48: "Tab", 53: "Esc",
      123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    return map[code] ?? "key\(code)"
  }
}

// MARK: - Settings window (SwiftUI)

private struct SettingsView: View {
  @ObservedObject var config: AppConfig
  @ObservedObject var discovery: Discovery
  let selfName: String
  @State private var recording = false
  @State private var hotkeyMonitor: Any?

  var body: some View {
    Form {
      Section("Этот Mac") {
        LabeledContent("Имя", value: selfName)
        LabeledContent("Адрес", value: primaryIPv4())
      }
      Section("Второй Mac") {
        Picker("Найден в сети", selection: $config.peerName) {
          Text("— не выбран —").tag("")
          ForEach(discovery.peers, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: config.peerName) { _, _ in save() }
        TextField("Или вручную (IP/host)", text: $config.manualHost)
          .onSubmit { save() }
        TextField("Порт", value: $config.port, format: .number)
          .onSubmit { save() }
      }
      Section("Переключение") {
        HStack {
          Text("Хоткей")
          Spacer()
          Button(recording ? "Нажми комбинацию…" : config.hotkey.display) { startRecording() }
            .buttonStyle(.bordered)
        }
      }
      Section("Край экрана") {
        Toggle("Переключать наведением на край", isOn: $config.edgeEnabled)
          .onChange(of: config.edgeEnabled) { _, _ in save() }
        Picker("Второй Mac находится", selection: $config.edgeDirection) {
          ForEach(EdgeDir.allCases, id: \.self) { Text($0.display).tag($0) }
        }
        .onChange(of: config.edgeDirection) { _, _ in save() }
        .disabled(!config.edgeEnabled)
        Text("Курсор уходит на второй Mac только на крайнем ребре всех твоих экранов — между своими мониторами ходишь свободно.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Запуск") {
        Toggle("Запускать автоматически при логине", isOn: $config.autostart)
          .onChange(of: config.autostart) { _, on in
            Autostart.set(on); save()
          }
      }
    }
    .formStyle(.grouped)
    .frame(width: 380, height: 420)
    .onAppear { config.autostart = Autostart.isEnabled() }
  }

  private func save() {
    config.save()
    config.onLinkConfigChanged?()
  }

  private func startRecording() {
    recording = true
    hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
      var hk = HotkeySpec()
      hk.keyCode = ev.keyCode
      hk.control = ev.modifierFlags.contains(.control)
      hk.option = ev.modifierFlags.contains(.option)
      hk.command = ev.modifierFlags.contains(.command)
      hk.shift = ev.modifierFlags.contains(.shift)
      config.hotkey = hk
      recording = false
      if let m = hotkeyMonitor { NSEvent.removeMonitor(m); hotkeyMonitor = nil }
      save()
      return nil
    }
  }
}

// MARK: - App delegate / menu bar

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let config = AppConfig.load()
  private let selfName = selfHostName()
  private lazy var discovery = Discovery(selfName: selfName)
  private lazy var node = Node(config: config, discovery: discovery, selfName: selfName)
  private var statusItem: NSStatusItem!
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu(); menu.delegate = self
    statusItem.menu = menu

    node.onStatus = { [weak self] in self?.refreshIcon() }
    node.start()
    refreshIcon()
  }

  private func refreshIcon() { statusItem.button?.title = node.iconTitle }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let title = menu.addItem(withTitle: "KVM Switch", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(.separator())
    for line in node.menuLines {
      menu.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false
    }
    menu.addItem(.separator())

    // peer picker submenu
    let peerItem = NSMenuItem(title: "Второй Mac", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    if discovery.peers.isEmpty {
      sub.addItem(withTitle: "поиск в сети…", action: nil, keyEquivalent: "").isEnabled = false
    }
    for name in discovery.peers {
      let it = NSMenuItem(title: name, action: #selector(pickPeer(_:)), keyEquivalent: "")
      it.target = self
      it.state = (name == config.peerName) ? .on : .off
      sub.addItem(it)
    }
    peerItem.submenu = sub
    menu.addItem(peerItem)

    let toggle = NSMenuItem(title: "Переключить ввод (\(config.hotkey.display))", action: #selector(onToggle), keyEquivalent: "")
    toggle.target = self
    menu.addItem(toggle)

    let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)
  }

  @objc private func pickPeer(_ sender: NSMenuItem) {
    config.peerName = sender.title
    config.save()
    config.onLinkConfigChanged?()
    refreshIcon()
  }

  @objc private func onToggle() { node.toggleMode() }

  @objc private func openSettings() {
    if settingsWindow == nil {
      let view = SettingsView(config: config, discovery: discovery, selfName: selfName)
      let host = NSHostingController(rootView: view)
      let win = NSWindow(contentViewController: host)
      win.title = "KVM Switch — Настройки"
      win.styleMask = [.titled, .closable]
      win.isReleasedWhenClosed = false
      settingsWindow = win
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.center()
    settingsWindow?.makeKeyAndOrderFront(nil)
  }
}

// MARK: - Entry point

private let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
