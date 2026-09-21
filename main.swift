import Foundation
import CoreGraphics
import Network
import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices

// MARK: - Constants

private let kServiceType = "_kvmswitch._tcp"
private let kRecordSize = 32
// Stamp injected events so the local tap can recognize and ignore them
// (prevents an inject -> tap -> forward feedback loop in symmetric mode).
private let kInjectedMagic: Int64 = 0x4B564D31 // "KVM1"

private let kDebugLogURL: URL = {
  let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("KVM Switch", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.appendingPathComponent("debug.log")
}()

private let logQueue = DispatchQueue(label: "kvm.log")

private func log(_ msg: String) {
  logQueue.async { writeLog(msg) }
}

private func writeLog(_ msg: String) {
  let ts = ISO8601DateFormatter().string(from: Date())
  let line = "[\(ts)] \(msg)\n"
  FileHandle.standardError.write(line.data(using: .utf8)!)
  guard let data = line.data(using: .utf8) else { return }
  if let fh = try? FileHandle(forWritingTo: kDebugLogURL) {
    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
  } else {
    try? data.write(to: kDebugLogURL)
  }
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
// Keyboard records reuse button for autorepeat and dx for keyboard type.
// Auxiliary-key records (CG type 14 / NSEvent subtype 8) use keyCode for the
// NX key identifier, button for 0xA down / 0xB up, and clickState for repeat.

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

private let kSystemDefinedType = CGEventType(rawValue: 14)!

private struct AuxiliaryKey {
  // IOKit/hidsystem/ev_keymap.h: documented auxiliary controls, plus MENU (25).
  // Power (6) and unknown system events stay on the physically attached Mac.
  static let supported = Set((UInt16(0)...UInt16(23)).filter { $0 != 6 } + [25])
  let code: UInt16
  let down: Bool
  let repeated: Bool

  init?(event: CGEvent) {
    guard event.type == kSystemDefinedType, let native = NSEvent(cgEvent: event),
          native.type == .systemDefined, native.subtype.rawValue == 8 else { return nil }
    let data = UInt32(truncatingIfNeeded: native.data1)
    let code = UInt16(data >> 16)
    let state = UInt8(truncatingIfNeeded: data >> 8)
    guard Self.supported.contains(code), state == 0xA || state == 0xB,
          data & 0xFE == 0 else { return nil }
    self.code = code
    down = state == 0xA
    repeated = data & 1 != 0
  }

  static func event(code: UInt16, down: Bool, repeated: Bool = false,
                    flags: UInt64 = 0, source: CGEventSource?) -> CGEvent? {
    guard supported.contains(code) else { return nil }
    let data = (Int(code) << 16) | ((down ? 0xA : 0xB) << 8) | (repeated ? 1 : 0)
    guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)), timestamp: monotonicNow(),
        windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)?.cgEvent else { return nil }
    event.setSource(source)
    return event
  }
}

// Control records reuse the same 32-byte frame with a sentinel cgType.
private let kCtrlType: UInt32 = 0xFFFF_FFFF
private let kCtrlReturn: UInt8 = 1
private let kCtrlPing: UInt8 = 2
private let kCtrlPong: UInt8 = 3
private let kCtrlBegin: UInt8 = 4
private let kCtrlBeginAck: UInt8 = 5
private let kCtrlEnd: UInt8 = 6
private let kLeaseDuration = 1.5
private func monotonicNow() -> Double { ProcessInfo.processInfo.systemUptime }

private func controlRecord(_ code: UInt8, token: UInt64 = 0) -> Data {
  var ev = InputEvent(); ev.cgType = kCtrlType; ev.button = code; ev.flags = token
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
  private let pathMonitor = NWPathMonitor()
  private var sawFirstPath = false

  init(selfName: String) { self.selfName = selfName }

  func endpoint(for name: String) -> NWEndpoint? { endpoints[name] }

  func start() {
    startBrowser()
    // A DHCP lease change / Wi-Fi reconnect leaves the browser holding stale
    // records so the peer is never rediscovered at its new address. Restart it
    // on every network transition (the first callback is just the initial path).
    pathMonitor.pathUpdateHandler = { [weak self] _ in
      guard let self = self else { return }
      if self.sawFirstPath { self.restartBrowser() } else { self.sawFirstPath = true }
    }
    pathMonitor.start(queue: .main)
  }

  private func startBrowser() {
    let params = NWParameters()
    params.includePeerToPeer = false // Use the shared LAN; P2P radio activity can add latency.
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
    browser.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.restartBrowser()
      default: break
      }
    }
    browser.start(queue: .main)
  }

  private func restartBrowser() {
    let old = browser
    browser = nil
    old?.stateUpdateHandler = nil   // detach so its .cancelled doesn't re-enter here
    old?.cancel()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self = self, self.browser == nil else { return }
      self.startBrowser()
    }
  }
}

// MARK: - Cursor visibility guard

private let kCursorLeaseDuration = 1.0

// One helper owns one hide/show pair. Expiry is terminal; buffered renewals may
// never revive a lease after the main process has stopped making progress.
private struct CursorLease {
  private(set) var deadline: Double
  private(set) var ended = false

  init(deadline: Double) { self.deadline = deadline }

  mutating func valid(at now: Double) -> Bool {
    if ended || !deadline.isFinite || now >= deadline { ended = true }
    return !ended
  }

  mutating func renew(until next: Double, now: Double) -> Bool {
    guard valid(at: now), next.isFinite, next > now,
          next <= now + kCursorLeaseDuration + 0.05 else { ended = true; return false }
    deadline = next
    return true
  }

  mutating func stop() { ended = true }
}

private func enableBackgroundCursorHiding() -> Bool {
  // Quartz otherwise reports success without hiding for a background menu-bar
  // app. Mature macOS KVMs use this connection-scoped WindowServer property.
  // These private symbols are optional: refuse remote capture if unavailable.
  typealias Connection = @convention(c) () -> Int32
  typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
  let handle = dlopen(nil, RTLD_LAZY)
  defer { if let handle = handle { dlclose(handle) } }
  guard let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
        let propertySymbol = dlsym(handle, "CGSSetConnectionProperty") else { return false }
  let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
  let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
  return setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
}

private func runCursorGuard(deadline: Double) -> Never {
  var lease = CursorLease(deadline: deadline)
  guard lease.valid(at: monotonicNow()),
        deadline <= monotonicNow() + kCursorLeaseDuration + 0.05,
        enableBackgroundCursorHiding(),
        CGDisplayHideCursor(CGMainDisplayID()) == .success else { exit(2) }
  // Keep physical movement associated. This also makes background cursor hiding
  // take effect reliably when WindowServer has a pending cursor update.
  CGAssociateMouseAndMouseCursorPosition(1)
  // Never disconnect mouse motion, warp, or pin: even a stopped helper cannot
  // block mouse movement. Process exit also releases its WindowServer hide count.
  func finish(_ status: Int32) -> Never {
    CGDisplayShowCursor(CGMainDisplayID())
    exit(status)
  }
  signal(SIGPIPE, SIG_IGN)
  _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
  _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
  func acknowledge() -> Bool {
    let bytes: [UInt8] = [79, 75, 10] // OK\n
    return bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) } == bytes.count
  }
  guard acknowledge() else { finish(0) }
  var buffer = Data()
  var bytes = [UInt8](repeating: 0, count: 1024)
  while lease.valid(at: monotonicNow()) {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
    let ready = poll(&descriptor, 1, 25)
    guard lease.valid(at: monotonicNow()) else { break }
    if ready < 0 { if errno == EINTR { continue }; finish(1) }
    if ready == 0 { continue }
    let count = read(STDIN_FILENO, &bytes, bytes.count)
    if count == 0 { finish(0) }
    if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; finish(1) }
    buffer.append(contentsOf: bytes.prefix(count))
    guard buffer.count <= 4096 else { finish(1) }
    while let newline = buffer.firstIndex(of: 10) {
      let line = String(data: buffer[..<newline], encoding: .utf8) ?? ""
      buffer.removeSubrange(buffer.startIndex...newline)
      guard let next = Double(line), lease.renew(until: next, now: monotonicNow()),
            acknowledge() else { finish(0) }
    }
  }
  finish(0)
}

private final class CursorGuardClient {
  private var process: Process?
  private var writer: FileHandle?
  private var readerSource: DispatchSourceRead?
  private var lastAck = -Double.infinity
  private var leaseDeadline = -Double.infinity
  private var ackBuffer = Data()
  private var acquisition: ((Bool) -> Void)?
  var onFailure: (() -> Void)?

  var healthy: Bool {
    process?.isRunning == true && monotonicNow() < leaseDeadline &&
      monotonicNow() - lastAck < kCursorLeaseDuration
  }

  func acquire(until deadline: Double, completion: @escaping (Bool) -> Void) {
    release()
    guard deadline > monotonicNow() else { completion(false); return }
    let child = Process()
    let input = Pipe(), output = Pipe()
    child.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    child.arguments = ["--cursor-guard", String(deadline)]
    child.standardInput = input
    child.standardOutput = output
    child.standardError = FileHandle.standardError
    let handle = output.fileHandleForReading
    let fd = handle.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let writeFD = input.fileHandleForWriting.fileDescriptor
    _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
    _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
    writer = input.fileHandleForWriting
    process = child
    acquisition = completion
    leaseDeadline = deadline
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setCancelHandler { try? handle.close() }
    source.setEventHandler { [weak self, weak child] in
      guard let self = self, let child = child, self.process === child else { return }
      var bytes = [UInt8](repeating: 0, count: 1024)
      let count = read(fd, &bytes, bytes.count)
      if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
      guard count > 0, self.ackBuffer.count + count <= 4096 else { self.failed(); return }
      self.ackBuffer.append(contentsOf: bytes.prefix(count))
      while let end = self.ackBuffer.firstIndex(of: 10) {
        let line = String(data: self.ackBuffer[..<end], encoding: .utf8)
        self.ackBuffer.removeSubrange(self.ackBuffer.startIndex...end)
        guard line == "OK", monotonicNow() < self.leaseDeadline else { self.failed(); return }
        self.lastAck = monotonicNow()
        let completion = self.acquisition
        self.acquisition = nil
        completion?(true)
      }
    }
    readerSource = source
    child.terminationHandler = { [weak self, weak child] _ in
      DispatchQueue.main.async {
        guard let self = self, let child = child, self.process === child else { return }
        self.failed()
      }
    }
    source.resume()
    do { try child.run() }
    catch { log("cursor guard could not start: \(error)"); failed() }
    // Only the child's inherited descriptor should keep the input read end open.
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
  }

  func renew(until deadline: Double) -> Bool {
    guard healthy, let writer = writer else { return false }
    let data = Data("\(deadline)\n".utf8)
    let count = data.withUnsafeBytes { write(writer.fileDescriptor, $0.baseAddress, $0.count) }
    guard count == data.count else { return false }
    leaseDeadline = deadline
    return true
  }

  private func failed() {
    release()
    onFailure?()
  }

  func release() {
    let old = process
    process = nil
    lastAck = -Double.infinity
    leaseDeadline = -Double.infinity
    ackBuffer.removeAll()
    readerSource?.cancel()
    readerSource = nil
    try? writer?.close() // EOF makes a responsive helper show and exit immediately.
    writer = nil
    let completion = acquisition
    acquisition = nil
    completion?(false)
    // A stopped/hung helper cannot process EOF. Kill only the child we created;
    // WindowServer then removes that process's cursor hide count.
    if let old = old {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        if old.isRunning { kill(old.processIdentifier, SIGKILL) }
      }
    }
  }
}

// MARK: - Node (symmetric: forwards out AND receives/injects)

private enum Mode { case local, remote }

private final class Node {
  let config: AppConfig
  let discovery: Discovery
  let selfName: String

  // sender side
  private var mode: Mode = .local { didSet { updateInputActivity() } }
  private var outConn: NWConnection?
  private var outReady = false
  private var reservedToggleKeys: Set<UInt16> = []
  // All Node state, network callbacks and event taps are confined to main.
  private let netQueue = DispatchQueue.main
  private var reconnectScheduled = false
  private var stopped = false
  private var healthTimer: DispatchSourceTimer?
  private var lastPong = -Double.infinity
  private var connectedAt = 0.0
  private var pendingPings: [UInt64: Double] = [:]
  private var nextToken: UInt64 = 0
  private var pendingBegin: UInt64?
  private var pendingSends = 0
  private var edgeResumeAt = 0.0
  private var receivingRemote = false { didSet { updateInputActivity() } }
  private var lastIncomingPing = -Double.infinity
  private var localKeys: Set<UInt16> = []
  private var localAuxiliaryKeys: Set<UInt16> = []
  private var localButtons: Set<UInt32> = []
  private var injectedKeys: Set<UInt16> = []
  private var injectedAuxiliaryKeys: Set<UInt16> = []
  private var injectedButtons: Set<UInt32> = []
  private var pendingBeginAt = 0.0
  private var incomingSession: UInt64 = 0
  private var outgoingSession: UInt64 = 0
  private var lastHealthTick = monotonicNow()
  private let postEvent: (CGEvent) -> Void
  private let inputAvailable: (() -> Bool)?
  private let cursorGuard: CursorGuardClient?

  // receiver side
  private var listener: NWListener?
  private var incomingConnected = false
  private var incomingPeer: String?
  private var incomingConn: NWConnection?
  private let injectQueue = DispatchQueue.main
  private let injectSource: CGEventSource?
  private var cursor: CGPoint
  private var displayBounds = displaysUnion()
  private var inputActivity: NSObjectProtocol?
  private var inBuffer = Data()
  // Motion is deferred only while processing one already-received TCP batch.
  // Geometry and edge pressure still advance for every original input record.
  private var motionBatchConnection: NWConnection?
  private var pendingMotion: CGEvent?

  // edge-of-screen switching
  private var edgePressure = 0.0   // controller side: push into the exit edge
  private var recvPressure = 0.0   // receiver side: push into the return edge
  private var outBuffer = Data()

  private var tapPort: CFMachPort?
  private var tapInstalled = false
  var onStatus: (() -> Void)?

  private static let mask: CGEventMask = {
    let types: [CGEventType] = [
      .keyDown, .keyUp, .flagsChanged,
      kSystemDefinedType,
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
      .otherMouseDown, .otherMouseUp,
      .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      .scrollWheel,
    ]
    return types.reduce(0) { $0 | (1 << $1.rawValue) }
  }()

  init(config: AppConfig, discovery: Discovery, selfName: String,
       postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
       inputAvailable: (() -> Bool)? = nil) {
    self.postEvent = postEvent
    self.inputAvailable = inputAvailable
    self.cursorGuard = inputAvailable == nil ? CursorGuardClient() : nil
    self.config = config
    self.discovery = discovery
    self.selfName = selfName
    let bounds = CGDisplayBounds(CGMainDisplayID())
    cursor = CGPoint(x: bounds.midX, y: bounds.midY)
    // Keep synthetic modifier/button state separate from physical HID state.
    injectSource = CGEventSource(stateID: .privateState)
    injectSource?.userData = kInjectedMagic
    cursorGuard?.onFailure = { [weak self] in
      guard let self = self else { return }
      log("SAFETY: cursor guard stopped; restoring local input")
      self.becomeLocal()
    }
  }

  // Scope App Nap/timer precision assertions to an actual handoff. Idle system
  // sleep remains permitted, and test nodes never change process activity state.
  private func updateInputActivity() {
    guard inputAvailable == nil else { return }
    if !stopped && (mode == .remote || receivingRemote) {
      if inputActivity == nil {
        inputActivity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
          reason: "Forwarding keyboard and mouse input")
      }
    } else if let activity = inputActivity {
      ProcessInfo.processInfo.endActivity(activity)
      inputActivity = nil
    }
  }

  func refreshDisplayBounds() {
    displayBounds = displaysUnion()
    moveCursor(dx: 0, dy: 0)
  }

  deinit {
    if let activity = inputActivity { ProcessInfo.processInfo.endActivity(activity) }
  }

  // MARK: status surface

  var iconTitle: String {
    if mode == .remote && linkHealthy { return "🔵" }
    if linkHealthy || incomingConnected { return "🟢" }
    return "🔴"
  }

  var menuLines: [String] {
    var lines: [String] = []
    lines.append("Этот Mac: \(selfName) (\(primaryIPv4()))")
    let target = currentTargetLabel()
    lines.append(mode == .remote ? "Ввод: → уходит на второй Mac ▶︎" : "Ввод: на этом Mac")
    lines.append(linkHealthy ? "→ Связь со вторым: есть (\(target))" : "→ Связь со вторым: нет (\(target))")
    lines.append(incomingConnected ? "← Принимаю ввод от: \(incomingPeer ?? "?")" : "← Входящего ввода нет")
    lines.append("Порт: \(config.port)  Хоткей: \(config.hotkey.display)")
    if config.edgeEnabled {
      lines.append("Край экрана: вкл (\(config.edgeDirection.display))")
    }
    let capture = tapInstalled ? "✓" : "✗ нет Input Monitoring"
    let inject = AXIsProcessTrusted() ? "✓" : "✗ нет Accessibility"
    lines.append("Права: перехват \(capture), инъекция \(inject)")
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
    stopped = false
    config.onLinkConfigChanged = { [weak self] in self?.applyLinkConfig() }
    startListener()
    startOutConnection()
    installTap()
    discovery.start()
    startHealthTimer()
    log("node ready (symmetric). hotkey=\(config.hotkey.display) capture=\(tapInstalled) accessibility=\(AXIsProcessTrusted())")
  }

  func applyLinkConfig() {
    becomeLocal()
    closeIncoming()
    // Detach old callbacks before replacing connections.
    listener?.newConnectionHandler = nil
    listener?.cancel()
    startListener()
    let old = outConn
    outConn = nil
    old?.cancel()
    outReady = false
    pendingSends = 0
    lastPong = -Double.infinity
    pendingPings.removeAll()
    startOutConnection()
    notify()
  }

  // MARK: listener (incoming -> inject)

  private func startListener() {
    guard !stopped else { return }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let params = NWParameters(tls: nil, tcp: tcp)
    params.allowLocalEndpointReuse = true
    params.includePeerToPeer = false // Use the shared LAN; P2P radio activity can add latency.
    params.serviceClass = .interactiveVideo
    guard let port = NWEndpoint.Port(rawValue: config.port) else { return }
    do {
      let l = try NWListener(using: params, on: port)
      l.service = NWListener.Service(name: selfName, type: kServiceType)
      l.newConnectionHandler = { [weak self, weak l] conn in
        guard let self = self, self.listener === l else { conn.cancel(); return }
        self.closeIncoming()
        log("incoming from \(conn.endpoint)")
        self.incomingConn = conn
        self.incomingPeer = endpointLabel(conn.endpoint)
        self.lastIncomingPing = monotonicNow()
        conn.start(queue: self.injectQueue)
        self.receiveLoop(conn)
      }
      l.stateUpdateHandler = { [weak self, weak l] state in
        guard let self = self, let l = l, self.listener === l else { return }
        if case .failed(let error) = state {
          log("listener failed: \(error); retrying")
          self.listener = nil
          l.newConnectionHandler = nil
          l.cancel()
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.listener == nil, !self.stopped else { return }
            self.startListener()
          }
        }
      }
      l.start(queue: injectQueue)
      listener = l
    } catch {
      log("listener error on \(config.port): \(error)")
    }
  }

  private func closeIncoming() {
    let old = incomingConn
    incomingConn = nil
    old?.cancel()
    receivingRemote = false
    releaseInjectedInput()
    inBuffer.removeAll(keepingCapacity: true)
    incomingConnected = false
    incomingPeer = nil
    recvPressure = 0
    notify()
  }

  private func receiveLoop(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
      guard let self = self, self.incomingConn === conn else { return }
      if let data = data, !data.isEmpty {
        self.inBuffer.append(data)
        var records: [InputEvent] = []
        parseFrames(&self.inBuffer) { records.append($0) }
        self.receiveBatch(records, from: conn)
      }
      if error != nil || isComplete { self.closeIncoming(); return }
      self.receiveLoop(conn)
    }
  }

  private func receiveBatch(_ records: [InputEvent], from conn: NWConnection) {
    guard incomingConn === conn else { return }
    motionBatchConnection = conn
    defer {
      flushPendingMotion()
      motionBatchConnection = nil
    }
    for event in records {
      guard incomingConn === conn else { pendingMotion = nil; break }
      // Never move a queued pointer event across a key, button, drag, scroll,
      // modifier change, or control record, including END and heartbeat.
      if event.cgType != CGEventType.mouseMoved.rawValue ||
         (pendingMotion != nil && pendingMotion!.flags.rawValue != event.flags) {
        flushPendingMotion()
      }
      receive(event, from: conn)
    }
  }

  private func flushPendingMotion() {
    guard let event = pendingMotion else { return }
    pendingMotion = nil
    guard let conn = motionBatchConnection, incomingConn === conn,
          monotonicNow() - lastIncomingPing < kLeaseDuration,
          monotonicNow() - lastHealthTick < kLeaseDuration else { return }
    postEvent(event)
  }

  private func reply(_ code: UInt8, token: UInt64 = 0, on conn: NWConnection) {
    conn.send(content: controlRecord(code, token: token), completion: .contentProcessed { [weak self] error in
      guard let self = self, self.incomingConn === conn else { return }
      if error != nil { self.closeIncoming() }
    })
  }

  private var inputReady: Bool {
    guard injectSource != nil else { return false }
    if let inputAvailable = inputAvailable { return inputAvailable() }
    guard AXIsProcessTrusted(), let tap = tapPort else { return false }
    return CGEvent.tapIsEnabled(tap: tap)
  }

  private func receive(_ ev: InputEvent, from conn: NWConnection) {
    guard incomingConn === conn else { return }
    guard monotonicNow() - lastHealthTick < kLeaseDuration else {
      closeIncoming()
      becomeLocal()
      return
    }
    if ev.cgType == kCtrlType {
      switch ev.button {
      case kCtrlPing:
        lastIncomingPing = monotonicNow()
        // Reply on the input queue: a hung input loop cannot renew the lease.
        guard inputReady else { closeIncoming(); return }
        incomingConnected = true
        reply(kCtrlPong, token: ev.flags, on: conn)
      case kCtrlBegin:
        guard inputReady, incomingConnected, monotonicNow() - lastIncomingPing < kLeaseDuration else { return }
        // Do not inject releases over keys/buttons physically held on this Mac.
        // The requester stays local and can retry after this local gesture ends.
        guard localKeys.isEmpty, localButtons.isEmpty, localAuxiliaryKeys.isEmpty else {
          reply(kCtrlReturn, token: ev.flags, on: conn)
          log("remote acquisition declined: local keys or buttons are held")
          return
        }
        becomeLocal()
        releaseInjectedInput()
        cursor = CGEvent(source: nil)?.location ?? cursor
        recvPressure = 0
        receivingRemote = true
        log("receiving remote input session")
        incomingSession = ev.flags
        edgeResumeAt = monotonicNow() + 0.5
        reply(kCtrlBeginAck, token: ev.flags, on: conn)
      case kCtrlEnd:
        guard ev.flags == incomingSession else { return }
        receivingRemote = false
        releaseInjectedInput()
      default: break
      }
      notify()
      return
    }
    guard receivingRemote, monotonicNow() - lastIncomingPing < kLeaseDuration,
          ev.dx.isFinite, ev.dy.isFinite,
          abs(ev.dx) <= 100_000, abs(ev.dy) <= 100_000 else { return }
    inject(ev)
  }

  private func emit(_ event: CGEvent) {
    // Stamp each event even if CGEventSource allocation failed.
    event.setIntegerValueField(.eventSourceUserData, value: kInjectedMagic)
    if event.type == .mouseMoved, motionBatchConnection != nil {
      if let previous = pendingMotion {
        let dx = previous.getDoubleValueField(.mouseEventDeltaX) + event.getDoubleValueField(.mouseEventDeltaX)
        let dy = previous.getDoubleValueField(.mouseEventDeltaY) + event.getDoubleValueField(.mouseEventDeltaY)
        if previous.flags == event.flags && dx.isFinite && dy.isFinite &&
           abs(dx) <= Double(Int32.max) && abs(dy) <= Double(Int32.max) {
          event.setDoubleValueField(.mouseEventDeltaX, value: dx)
          event.setDoubleValueField(.mouseEventDeltaY, value: dy)
        } else { flushPendingMotion() }
      }
      pendingMotion = event
      return
    }
    flushPendingMotion()
    postEvent(event)
  }

  private func releaseInjectedInput() {
    // Old motion flags must never follow releases and reintroduce a modifier.
    flushPendingMotion()
    for key in injectedKeys {
      let event = CGEvent(keyboardEventSource: injectSource, virtualKey: key, keyDown: false)
      if Node.modifierBit[key] != nil { event?.type = .flagsChanged }
      event?.flags = []
      if let event = event { emit(event) }
    }
    for button in injectedButtons {
      let type: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
      let event = CGEvent(mouseEventSource: injectSource, mouseType: type,
                          mouseCursorPosition: cursor, mouseButton: CGMouseButton(rawValue: button) ?? .left)
      event?.flags = []
      if let event = event { emit(event) }
    }
    for key in injectedAuxiliaryKeys {
      if let event = AuxiliaryKey.event(code: key, down: false, source: injectSource) { emit(event) }
    }
    injectedKeys.removeAll()
    injectedButtons.removeAll()
    injectedAuxiliaryKeys.removeAll()
  }

  // keycode -> the raw modifier-flag bit reflecting THIS physical key's state.
  // Device-dependent left/right bits (NX_DEVICE*KEYMASK) let each side be tracked
  // independently, so right Command is replayed as right Command, not a generic one.
  private static let modifierBit: [UInt16: UInt64] = [
    59: 0x1,       // left control
    62: 0x2000,    // right control
    56: 0x2,       // left shift
    60: 0x4,       // right shift
    55: 0x8,       // left command
    54: 0x10,      // right command
    58: 0x20,      // left option
    61: 0x40,      // right option
    57: 0x10000,   // caps lock (maskAlphaShift)
    63: 0x800000,  // fn (maskSecondaryFn)
  ]

  private func inject(_ ev: InputEvent) {
    guard let injectSource = injectSource else { return }
    guard let type = CGEventType(rawValue: ev.cgType) else { return }
    let flags = CGEventFlags(rawValue: ev.flags)
    // A modifier can already be held when the session starts, so its initial
    // flagsChanged may have stayed on the source Mac. Track it for cleanup too.
    for (key, bit) in Node.modifierBit where key != 57 && ev.flags & bit != 0 {
      injectedKeys.insert(key)
    }
    switch type {
    case .keyDown, .keyUp:
      guard ev.button <= 1, ev.dx.isFinite, ev.dx >= 0, ev.dx <= 100_000,
            ev.dx.rounded(.towardZero) == ev.dx else { return }
      guard let e = CGEvent(keyboardEventSource: injectSource, virtualKey: ev.keyCode, keyDown: type == .keyDown) else { return }
      if type == .keyDown { injectedKeys.insert(ev.keyCode) } else { injectedKeys.remove(ev.keyCode) }
      e.setIntegerValueField(.keyboardEventAutorepeat, value: Int64(ev.button))
      e.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(ev.dx))
      e.flags = flags
      emit(e)
    case .flagsChanged:
      guard ev.dx.isFinite, ev.dx >= 0, ev.dx <= 100_000,
            ev.dx.rounded(.towardZero) == ev.dx else { return }
      guard let bit = Node.modifierBit[ev.keyCode] else { return }
      let isDown = (ev.flags & bit) != 0
      // Caps Lock is a latched state, not a held key to release on disconnect.
      if ev.keyCode != 57 {
        if isDown { injectedKeys.insert(ev.keyCode) } else { injectedKeys.remove(ev.keyCode) }
      }
      guard let e = CGEvent(keyboardEventSource: injectSource, virtualKey: ev.keyCode, keyDown: isDown) else { return }
      e.type = .flagsChanged
      e.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(ev.dx))
      e.flags = flags
      emit(e)
    case kSystemDefinedType:
      guard ev.button == 0xA || ev.button == 0xB, ev.clickState <= 1,
            let event = AuxiliaryKey.event(code: ev.keyCode, down: ev.button == 0xA,
                repeated: ev.clickState == 1, flags: ev.flags, source: injectSource) else { return }
      if ev.button == 0xA { injectedAuxiliaryKeys.insert(ev.keyCode) }
      else { injectedAuxiliaryKeys.remove(ev.keyCode) }
      emit(event)
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      moveCursor(dx: ev.dx, dy: ev.dy)
      checkReturnEdge(dx: ev.dx, dy: ev.dy)
      guard receivingRemote else { return }
      let b = CGMouseButton(rawValue: UInt32(ev.button)) ?? .left
      guard let e = CGEvent(mouseEventSource: injectSource, mouseType: type, mouseCursorPosition: cursor, mouseButton: b) else { return }
      e.setDoubleValueField(.mouseEventDeltaX, value: ev.dx)
      e.setDoubleValueField(.mouseEventDeltaY, value: ev.dy)
      e.flags = flags
      emit(e)
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
      let b = CGMouseButton(rawValue: UInt32(ev.button)) ?? .left
      guard let e = CGEvent(mouseEventSource: injectSource, mouseType: type, mouseCursorPosition: cursor, mouseButton: b) else { return }
      if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
        injectedButtons.insert(UInt32(ev.button))
      } else { injectedButtons.remove(UInt32(ev.button)) }
      e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, ev.clickState)))
      e.flags = flags
      emit(e)
    case .scrollWheel:
      guard let e = CGEvent(scrollWheelEvent2Source: injectSource, units: .pixel, wheelCount: 2,
                            wheel1: Int32(ev.dy), wheel2: Int32(ev.dx), wheel3: 0) else { return }
      e.flags = flags
      emit(e)
    default:
      break
    }
  }

  private func moveCursor(dx: Double, dy: Double) {
    let b = displayBounds
    cursor.x = min(max(b.minX, cursor.x + dx), b.maxX - 1)
    cursor.y = min(max(b.minY, cursor.y + dy), b.maxY - 1)
  }

  /// Returns push amount into the edge in `dir`, or -1 if the point is not at that edge.
  private func edgePush(_ loc: CGPoint, _ dx: Double, _ dy: Double, _ dir: EdgeDir) -> Double {
    let u = displayBounds
    switch dir {
    case .right:  return loc.x >= u.maxX - 2 ? max(0, dx) : -1
    case .left:   return loc.x <= u.minX + 2 ? max(0, -dx) : -1
    case .top:    return loc.y <= u.minY + 2 ? max(0, -dy) : -1
    case .bottom: return loc.y >= u.maxY - 2 ? max(0, dy) : -1
    }
  }

  /// Receiver side: while being driven, pushing toward the peer's edge returns control.
  private func checkReturnEdge(dx: Double, dy: Double) {
    guard config.edgeEnabled, receivingRemote, monotonicNow() >= edgeResumeAt,
          let conn = incomingConn else { return }
    let push = edgePush(cursor, dx, dy, config.edgeDirection)
    if push < 0 { recvPressure = 0; return }
    recvPressure += push
    if recvPressure >= kEdgeThreshold {
      recvPressure = 0
      receivingRemote = false
      releaseInjectedInput()
      reply(kCtrlReturn, token: incomingSession, on: conn)
      log("edge: returning control to controller")
    }
  }

  // MARK: outgoing (tap -> forward)

  private func resolveTarget() -> NWEndpoint? {
    if !config.peerName.isEmpty, let ep = discovery.endpoint(for: config.peerName) { return ep }
    if !config.manualHost.isEmpty, let port = NWEndpoint.Port(rawValue: config.port) {
      return .hostPort(host: NWEndpoint.Host(config.manualHost), port: port)
    }
    if config.peerName.isEmpty, discovery.peers.count == 1,
       let name = discovery.peers.first {
      config.peerName = name
      config.save()
      return discovery.endpoint(for: name)
    }
    return nil
  }

  private var linkHealthy: Bool {
    outReady && monotonicNow() - lastPong < kLeaseDuration
  }

  private func startHealthTimer() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self] in self?.healthTick() }
    timer.resume()
    healthTimer = timer
  }

  private func healthTick() {
    let now = monotonicNow()
    if now - lastHealthTick >= kLeaseDuration {
      // After sleep or a stalled main loop discard queued input from old sessions.
      closeIncoming()
      dropAndReconnect()
    }
    lastHealthTick = now
    if pendingBegin != nil, now - pendingBeginAt >= kLeaseDuration { becomeLocal() }
    if incomingConn != nil, now - lastIncomingPing >= kLeaseDuration { closeIncoming() }
    if outReady {
      if now - max(connectedAt, lastPong) >= kLeaseDuration {
        log("SAFETY: peer heartbeat expired; restoring local input")
        dropAndReconnect()
      } else if let conn = outConn {
        nextToken &+= 1
        pendingPings = pendingPings.filter { now - $0.value < kLeaseDuration }
        pendingPings[nextToken] = now
        sendData(controlRecord(kCtrlPing, token: nextToken), on: conn)
      }
    }
    if mode == .remote {
      let deadline = min(lastPong + kLeaseDuration, now + kCursorLeaseDuration)
      if !linkHealthy || cursorGuard?.renew(until: deadline) == false { becomeLocal() }
    }
  }

  private func startOutConnection() {
    guard !stopped, outConn == nil else { return }
    guard let target = resolveTarget() else { scheduleReconnect(); return }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 2
    tcp.connectionTimeout = 5
    let params = NWParameters(tls: nil, tcp: tcp)
    params.includePeerToPeer = false // Use the shared LAN; P2P radio activity can add latency.
    params.serviceClass = .interactiveVideo
    let conn = NWConnection(to: target, using: params)
    outConn = conn
    conn.stateUpdateHandler = { [weak self, weak conn] state in
      guard let self = self, let conn = conn, self.outConn === conn else { return }
      switch state {
      case .ready:
        self.outReady = true
        self.connectedAt = monotonicNow()
        self.lastPong = -Double.infinity
        self.pendingPings.removeAll()
        self.outBuffer.removeAll(keepingCapacity: true)
        self.edgePressure = 0
        self.receiveControl(conn)
        self.healthTick()
        self.notify()
        log("out TCP link up -> \(endpointLabel(target)); waiting for application heartbeat")
      case .failed, .cancelled, .waiting:
        self.dropAndReconnect()
      default: break
      }
    }
    conn.start(queue: netQueue)
  }

  private func scheduleReconnect() {
    guard !stopped, !reconnectScheduled else { return }
    reconnectScheduled = true
    netQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.reconnectScheduled = false
      self?.startOutConnection()
    }
  }

  private func becomeLocal() {
    let wasSending = mode == .remote || pendingBegin != nil
    let session = pendingBegin ?? outgoingSession
    mode = .local
    outgoingSession = 0
    pendingBegin = nil
    cursorGuard?.release()
    edgePressure = 0
    edgeResumeAt = monotonicNow() + 0.5
    if wasSending, let conn = outConn {
      sendData(controlRecord(kCtrlEnd, token: session), on: conn)
      log("mode=local (input restored)")
    }
    notify()
  }

  private func dropAndReconnect() {
    let old = outConn
    outConn = nil
    outReady = false
    lastPong = -Double.infinity
    pendingPings.removeAll()
    pendingSends = 0
    becomeLocal()
    old?.cancel()
    scheduleReconnect()
  }

  @discardableResult
  private func sendData(_ data: Data, on conn: NWConnection) -> Bool {
    guard outConn === conn, outReady else { return false }
    // Bound backpressure: a blocked socket must not grow an unbounded input queue.
    guard pendingSends < 256 else { dropAndReconnect(); return false }
    pendingSends += 1
    conn.send(content: data, completion: .contentProcessed { [weak self] error in
      guard let self = self, self.outConn === conn else { return }
      self.pendingSends -= 1
      if error != nil { self.dropAndReconnect() }
    })
    return true
  }

  private func send(_ ev: InputEvent) -> Bool {
    guard linkHealthy, let conn = outConn else { becomeLocal(); return false }
    return sendData(ev.encoded(), on: conn)
  }

  private func receiveControl(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
      guard let self = self, self.outConn === conn else { return }
      if let data = data, !data.isEmpty {
        self.outBuffer.append(data)
        var records: [InputEvent] = []
        parseFrames(&self.outBuffer) { records.append($0) }
        for ev in records where ev.cgType == kCtrlType {
          switch ev.button {
          case kCtrlPong:
            if let sentAt = self.pendingPings.removeValue(forKey: ev.flags),
               monotonicNow() - sentAt < kLeaseDuration {
              let wasHealthy = self.linkHealthy
              self.lastPong = sentAt
              if !wasHealthy { log("application heartbeat ready -> \(self.currentTargetLabel())") }
              self.notify()
            }
          case kCtrlBeginAck:
            if self.pendingBegin == ev.flags, self.linkHealthy,
               monotonicNow() - self.pendingBeginAt < kLeaseDuration {
              let activate: (Bool) -> Void = { [weak self] hidden in
                guard let self = self, self.pendingBegin == ev.flags else { return }
                guard hidden, self.linkHealthy,
                      monotonicNow() - self.pendingBeginAt < kLeaseDuration else {
                  self.becomeLocal(); return
                }
                self.pendingBegin = nil
                self.outgoingSession = ev.flags
                self.mode = .remote
                log("mode=remote (peer acknowledged ownership; cursor guard ready)")
                self.notify()
              }
              if let guardClient = self.cursorGuard {
                guardClient.acquire(until: min(self.lastPong + kLeaseDuration,
                                              monotonicNow() + kCursorLeaseDuration), completion: activate)
              } else { activate(true) } // transport-only tests never hide OS cursor
            }
          case kCtrlReturn:
            if ev.flags == self.pendingBegin ||
               (self.pendingBegin == nil && self.mode == .remote && ev.flags == self.outgoingSession) {
              self.becomeLocal()
            }
          default: break
          }
        }
      }
      if error != nil || isComplete { self.dropAndReconnect(); return }
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
    tapInstalled = true
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      becomeLocal()
      closeIncoming()
      log("TAP DISABLED -> restored local input before re-enabling")
      if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
      return nil
    }
    // ignore our own injected events (anti-loop in symmetric mode)
    if event.getIntegerValueField(.eventSourceUserData) == kInjectedMagic {
      return Unmanaged.passUnretained(event)
    }
    if type == kSystemDefinedType, AuxiliaryKey(event: event) == nil {
      return Unmanaged.passUnretained(event)
    }

    // Physical input on the receiving Mac takes ownership. Injected events
    // already returned above, so they cannot trigger a feedback loop.
    if receivingRemote {
      receivingRemote = false
      releaseInjectedInput()
      if let conn = incomingConn { reply(kCtrlReturn, token: incomingSession, on: conn) }
      edgeResumeAt = monotonicNow() + 0.5
    }
    if mode == .remote && (!linkHealthy || cursorGuard?.healthy == false) { becomeLocal() }
    let flags = event.flags
    // Fixed emergency return independent of the configurable shortcut.
    if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53,
       flags.contains([.maskControl, .maskAlternate, .maskCommand]) {
      becomeLocal()
      closeIncoming()
      return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
      let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
      let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
      // The reserved shortcut's down/up pair stays local to the switch. Sending
      // its repeat downs while swallowing its up would leave the peer key held.
      if reservedToggleKeys.contains(kc) {
        if isRepeat { return nil }
        // A fresh non-repeat press means an up was missed while the tap was
        // disabled; let the new press follow the current shortcut setting.
        reservedToggleKeys.remove(kc)
      }
      if !isRepeat, config.hotkey.matches(keyCode: kc, flags: flags) {
        reservedToggleKeys.insert(kc)
        toggleMode()
        return nil
      }
    }
    if type == .keyUp {
      let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
      if reservedToggleKeys.remove(kc) != nil { return nil }
    }

    if mode == .local, pendingBegin == nil, monotonicNow() >= edgeResumeAt,
       config.edgeEnabled, Node.moveTypes.contains(type) {
      let dx = event.getDoubleValueField(.mouseEventDeltaX)
      let dy = event.getDoubleValueField(.mouseEventDeltaY)
      let push = edgePush(event.location, dx, dy, config.edgeDirection)
      if push < 0 {
        edgePressure = 0
      } else {
        edgePressure += push
        if edgePressure >= kEdgeThreshold, linkHealthy {
          edgePressure = 0
          toggleMode() // -> remote
        }
      }
    }

    switch mode {
    case .local:
      recordLocal(type: type, event: event)
      return Unmanaged.passUnretained(event)
    case .remote:
      let balancesLocalDown = releasesLocalDown(type: type, event: event)
      let sent = forward(type: type, event: event, flags: flags)
      // If a down reached a local app before the handoff, its up must reach that
      // app too (notably the modifiers used to invoke the switching hotkey).
      if !sent || balancesLocalDown {
        recordLocal(type: type, event: event)
        return Unmanaged.passUnretained(event)
      }
      return nil
    }
  }

  private func releasesLocalDown(type: CGEventType, event: CGEvent) -> Bool {
    let key = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    switch type {
    case .keyUp: return localKeys.contains(key)
    case .flagsChanged:
      guard key != 57 else { return false }
      guard let bit = Node.modifierBit[key] else { return false }
      return localKeys.contains(key) && event.flags.rawValue & bit == 0
    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
      return localButtons.contains(UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber)))
    case kSystemDefinedType:
      guard let auxiliary = AuxiliaryKey(event: event) else { return false }
      return !auxiliary.down && localAuxiliaryKeys.contains(auxiliary.code)
    default: return false
    }
  }

  private func recordLocal(type: CGEventType, event: CGEvent) {
    let key = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    switch type {
    case .keyDown: localKeys.insert(key)
    case .keyUp: localKeys.remove(key)
    case .flagsChanged:
      guard key != 57 else { return }
      guard let bit = Node.modifierBit[key] else { return }
      if event.flags.rawValue & bit != 0 { localKeys.insert(key) } else { localKeys.remove(key) }
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      localButtons.insert(UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber)))
    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
      localButtons.remove(UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber)))
    case kSystemDefinedType:
      guard let auxiliary = AuxiliaryKey(event: event) else { return }
      if auxiliary.down { localAuxiliaryKeys.insert(auxiliary.code) }
      else { localAuxiliaryKeys.remove(auxiliary.code) }
    default: break
    }
  }

  private static let moveTypes: Set<CGEventType> = [
    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
  ]

  private func forward(type: CGEventType, event: CGEvent, flags: CGEventFlags) -> Bool {
    var ev = InputEvent()
    ev.cgType = type.rawValue
    ev.flags = flags.rawValue
    switch type {
    case .keyDown, .keyUp, .flagsChanged:
      // flagsChanged carries the modifier keycode; the receiver replays it as a
      // modifier key press/release so both Command sides (and all modifiers) cross.
      ev.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
      ev.button = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? 1 : 0
      ev.dx = Double(event.getIntegerValueField(.keyboardEventKeyboardType))
    case kSystemDefinedType:
      guard let auxiliary = AuxiliaryKey(event: event) else { return false }
      ev.keyCode = auxiliary.code
      ev.button = auxiliary.down ? 0xA : 0xB
      ev.clickState = auxiliary.repeated ? 1 : 0
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
      return false
    }
    return send(ev)
  }

  func stop() {
    stopped = true
    becomeLocal()
    closeIncoming()
    healthTimer?.cancel()
    healthTimer = nil
    let old = outConn
    outConn = nil
    outReady = false
    old?.cancel()
    listener?.newConnectionHandler = nil
    listener?.cancel()
    listener = nil
    if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: false) }
  }

  func toggleMode() {
    if mode == .remote || pendingBegin != nil { becomeLocal(); return }
    guard inputReady, linkHealthy, let conn = outConn else {
      NSSound.beep()
      log("toggle ignored: no healthy peer (both Macs need the updated version and permissions)")
      return
    }
    nextToken &+= 1
    pendingBegin = nextToken
    pendingBeginAt = monotonicNow()
    if !sendData(controlRecord(kCtrlBegin, token: nextToken), on: conn) { becomeLocal() }
    // Cursor hiding begins only after peer and independent helper acknowledgement.
    // No cursor pinning or mouse disassociation is used.
    notify()
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

  func applicationWillTerminate(_ notification: Notification) {
    node.stop()
  }

  func applicationDidChangeScreenParameters(_ notification: Notification) {
    node.refreshDisplayBounds()
  }

  private func refreshIcon() {
    let title = node.iconTitle
    if statusItem.button?.title != title { statusItem.button?.title = title }
  }

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

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--cursor-guard",
   let deadline = Double(CommandLine.arguments[2]) {
  runCursorGuard(deadline: deadline)
}

private let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
