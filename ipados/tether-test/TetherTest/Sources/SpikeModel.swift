/*
    This file is part of the darktable iPadOS tethering test app.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// The one-day spike: eight steps, each answering one question, run in
// order. Everything ImageCaptureCore reports arrives on the main thread;
// every PTP transaction runs on the transport's serial queue.

import Foundation
import ImageCaptureCore
import UIKit

enum StepStatus: String {
  case notRun = "not run"
  case running = "running"
  case pass = "pass"
  case fail = "fail"
  case partial = "partial"
}

struct StepResult: Identifiable {
  let id: Int
  let title: String
  let question: String
  let ifFails: String
  var status: StepStatus = .notRun
  var detail = ""
  var timing = ""
  var finishedAt: Date?
}

final class SpikeModel: ObservableObject {
  @Published var steps: [StepResult] = [
    StepResult(id: 1, title: "Find the camera",
               question: "Does ICDeviceBrowser see the a7 III in PC Remote mode?",
               ifFails: "set USB Connection to Mass Storage, then MTP, and note what appears"),
    StepResult(id: 2, title: "Authorization",
               question: "Are contents and control authorization granted?",
               ifFails: "\"not determined\" is the known iOS 26.1 beta bug: note the build"),
    StepResult(id: 3, title: "Raw PTP",
               question: "Does GetDeviceInfo (0x1001) come back through requestSendPTPCommand?",
               ifFails: "error -21249 means fallback 1 (receive only)"),
    StepResult(id: 4, title: "Sony handshake",
               question: "Does the SDIO connect (0x9201, 0x9202) succeed?",
               ifFails: "check the camera menu settings in the README"),
    StepResult(id: 5, title: "Shutter and download",
               question: "Half press, full press, release; how long until the file is on the iPad?",
               ifFails: "try manual focus, check a card is in the camera"),
    StepResult(id: 6, title: "Live view",
               question: "How many live view frames per second over 100 frames?",
               ifFails: "note it; shutter and download still matter more"),
    StepResult(id: 7, title: "Settings",
               question: "Can ISO and shutter speed be changed from the iPad and read back?",
               ifFails: "set the mode dial to M and ISO off auto, then retry"),
    StepResult(id: 8, title: "One-hour heartbeat",
               question: "Does the link survive an hour and two cable pulls, with missed files recovered?",
               ifFails: "note when and how it failed"),
  ]

  @Published var log: [String] = []
  @Published var deviceLine = "no camera yet"
  @Published var authLine = ""
  @Published var browsing = false
  @Published var sessionOpen = false
  @Published var busy = false
  @Published var liveImage: UIImage?
  @Published var liveRunning = false
  @Published var liveFPS = ""
  @Published var lastCaptureImage: UIImage?
  @Published var lastCaptureName = ""
  @Published var readouts: [(String, String)] = []
  @Published var heartbeatRunning = false
  @Published var heartbeatLine = ""
  @Published var receiveOnlyDownload = false
  @Published var verbose = false {
    didSet { transport?.verbose = verbose }
  }
  @Published var wrapOutData = false {
    didSet { transport?.wrapOutData = wrapOutData }
  }

  private let browser = ICDeviceBrowser()
  private let events = TTDeviceEvents()
  private let inbox = EventInbox()
  private(set) var camera: ICCameraDevice?
  private var transport: PTPTransport?
  private var sony: SonyCamera?
  private var pendingOpen: ((Error?) -> Void)?

  // heartbeat and reconnect bookkeeping for step 8
  private var heartbeatTimer: Timer?
  private var heartbeatInFlight = false
  private var heartbeatStart = Date()
  private var beats = 0
  private var beatFailures = 0
  private var consecutiveFailures = 0
  private var beatLatencies: [TimeInterval] = []
  private var cableOutAt: Date?
  private var reconnects: [TimeInterval] = []
  private var reconnectFailures = 0
  private var missedRecovered = 0

  let documents: URL
  let capturesDir: URL
  let logURL: URL
  private let logQueue = DispatchQueue(label: "tethertest.log")
  private var logHandle: FileHandle?

  static let osBuild = ProcessInfo.processInfo.operatingSystemVersionString

  static let hardwareModel: String = {
    var u = utsname()
    uname(&u)
    return withUnsafeBytes(of: &u.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
  }()

  init() {
    let fm = FileManager.default
    documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    capturesDir = documents.appendingPathComponent("captures", isDirectory: true)
    let logsDir = documents.appendingPathComponent("logs", isDirectory: true)
    try? fm.createDirectory(at: capturesDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    logURL = logsDir.appendingPathComponent("tethertest-\(f.string(from: Date())).log")
    fm.createFile(atPath: logURL.path, contents: nil)
    logHandle = try? FileHandle(forWritingTo: logURL)

    wireEvents()
    browser.delegate = events
    say("TetherTest started on \(UIDevice.current.model) \(Self.hardwareModel), iPadOS \(Self.osBuild)")
    say("authorization before asking: contents=\(TTContentsAuthorizationStatus(browser)) control=\(TTControlAuthorizationStatus(browser))")
  }

  // MARK: logging

  private static let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  // safe from any thread
  func say(_ message: String) {
    let line = "\(Self.clock.string(from: Date())) \(message)"
    logQueue.async { [weak self] in
      if let data = (line + "\n").data(using: .utf8) { self?.logHandle?.write(data) }
    }
    DispatchQueue.main.async {
      self.log.append(line)
      if self.log.count > 1500 { self.log.removeFirst(self.log.count - 1500) }
    }
  }

  private func setStep(_ id: Int, _ status: StepStatus, _ detail: String, timing: String = "") {
    DispatchQueue.main.async {
      guard let i = self.steps.firstIndex(where: { $0.id == id }) else { return }
      self.steps[i].status = status
      self.steps[i].detail = detail
      if !timing.isEmpty || status != .running { self.steps[i].timing = timing }
      if status != .running { self.steps[i].finishedAt = Date() }
    }
    if status != .running { say("step \(id): \(status.rawValue.uppercased()) \(detail) \(timing)") }
  }

  // runs on the PTP queue with the busy flag set; refuses while busy
  private func ptpWork(_ name: String, _ body: @escaping (SonyCamera) -> Void) {
    guard let sony = sony, let transport = transport else {
      say("\(name): no camera session; run steps 1 to 3 first")
      return
    }
    guard !busy else {
      say("\(name): busy, wait for the running step to finish")
      return
    }
    busy = true
    transport.queue.async {
      body(sony)
      DispatchQueue.main.async {
        self.busy = false
        self.updateReadouts()
      }
    }
  }

  // MARK: ImageCaptureCore events

  private func wireEvents() {
    events.note = { [weak self] msg in self?.say(msg) }

    events.deviceAdded = { [weak self] device in
      guard let self = self else { return }
      let vid = TTVendorID(device), pid = TTProductID(device)
      self.say("device added: \(TTDescribeDevice(device))")
      guard let cam = device as? ICCameraDevice else {
        self.say("not a camera device, ignoring")
        return
      }
      if self.camera != nil && self.camera !== cam {
        self.say("already using a camera, ignoring this one")
        return
      }
      self.attach(cam)
      var mode = ""
      // libgphoto2 library.c device table
      if pid == 0x0C34 { mode = " (product 0x0C34: a7 III in PC Remote)" }
      if pid == 0x0C03 { mode = " (product 0x0C03: a7 III in MTP mode, switch to PC Remote)" }
      if vid == sonyUSBVendorID {
        self.setStep(1, .pass, "\(device.name ?? "camera"), vendor 0x054C, product \(String(format: "0x%04lX", pid))\(mode)")
      } else {
        self.setStep(1, .partial, "found \(device.name ?? "camera") but vendor is \(String(format: "0x%04lX", vid)), not Sony")
      }
      if let out = self.cableOutAt, self.heartbeatRunning {
        self.recover(after: out)
      }
    }

    events.deviceRemoved = { [weak self] device in
      guard let self = self else { return }
      self.say("device removed: \(device.name ?? "?")")
      if device === self.camera {
        self.detach()
        if self.heartbeatRunning {
          self.cableOutAt = Date()
          self.say("step 8: cable out at \(Self.clock.string(from: Date())), waiting for the camera to come back")
        }
      }
    }

    events.sessionOpened = { [weak self] device, error in
      guard let self = self else { return }
      self.say("session opened: \(error.map { "error \($0)" } ?? "ok")")
      self.sessionOpen = error == nil
      let cb = self.pendingOpen
      self.pendingOpen = nil
      cb?(error)
    }

    events.sessionClosed = { [weak self] _, error in
      self?.say("session closed\(error.map { ": \($0)" } ?? "")")
      self?.sessionOpen = false
    }

    events.deviceReady = { [weak self] device in
      self?.say("device ready: \(device.name ?? "?")")
    }

    events.catalogComplete = { [weak self] cam in
      let files: [ICCameraItem]? = cam.mediaFiles
      self?.say("content catalog complete: \(files?.count ?? 0) media file(s) visible to ImageCaptureCore")
    }

    events.itemsAdded = { [weak self] _, items in
      guard let self = self else { return }
      for item in items {
        self.say("camera item added: \(item.name ?? "?") (\(type(of: item)))")
        if self.receiveOnlyDownload, let file = item as? ICCameraFile {
          let start = Date()
          TTDownloadFile(file, self.capturesDir) { name, error in
            if let e = error {
              self.say("receive-only download failed: \(e)")
            } else {
              self.say(String(format: "receive-only download: %@ in %.2f s", name ?? "?", Date().timeIntervalSince(start)))
            }
          }
        }
      }
    }

    events.ptpEvent = { [weak self] _, data in
      guard let self = self else { return }
      var r = ByteReader(data)
      guard let _ = r.u32(), let _ = r.u16(), let code = r.u16(), let _ = r.u32() else {
        self.say("ptp event (unparsed): \(data.hexPrefix())")
        return
      }
      var params: [UInt32] = []
      while let p = r.u32() { params.append(p) }
      self.inbox.push(PTPEventRecord(code: code, params: params, time: Date()))
      if self.verbose || code != PTPEvent.sonyPropChanged {
        self.say(String(format: "ptp event 0x%04X ", code) + params.map { String(format: "0x%X", $0) }.joined(separator: ","))
      }
    }
  }

  private func attach(_ cam: ICCameraDevice) {
    camera = cam
    cam.delegate = events
    let t = PTPTransport(camera: cam) { [weak self] msg in self?.say(msg) }
    t.verbose = verbose
    t.wrapOutData = wrapOutData
    transport = t
    sony = SonyCamera(transport: t, inbox: inbox) { [weak self] msg in self?.say(msg) }
    deviceLine = TTDescribeDevice(cam)
  }

  private func detach() {
    camera = nil
    transport = nil
    sony = nil
    sessionOpen = false
    liveRunning = false
    deviceLine = "camera gone"
  }

  private func openSession(timeout: TimeInterval = 15, _ done: @escaping (Error?) -> Void) {
    guard let cam = camera else {
      done(NSError(domain: "TetherTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"]))
      return
    }
    if cam.hasOpenSession {
      sessionOpen = true
      done(nil)
      return
    }
    pendingOpen = done
    say("requesting session")
    cam.requestOpenSession()
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
      guard let self = self, let cb = self.pendingOpen else { return }
      self.pendingOpen = nil
      cb(NSError(domain: "TetherTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "no session within \(Int(timeout)) s"]))
    }
  }

  // MARK: steps

  func run(_ id: Int) {
    switch id {
    case 1: step1()
    case 2: step2()
    case 3: step3()
    case 4: step4()
    case 5: step5()
    case 6: step6()
    case 7: step7()
    case 8: heartbeatRunning ? stopHeartbeat() : startHeartbeat()
    default: break
    }
  }

  private func step1() {
    setStep(1, .running, "browsing; plug in the camera")
    if !browsing {
      browser.start()
      browsing = true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
      guard let self = self, self.camera == nil,
            self.steps[0].status == .running else { return }
      self.setStep(1, .fail, "nothing found in 15 s; run step 2, then try again, then try other USB modes")
    }
  }

  private func step2() {
    setStep(2, .running, "asking")
    TTRequestAuthorization(browser) { [weak self] contents, control in
      guard let self = self else { return }
      self.authLine = "contents: \(contents)   control: \(control)"
      let ok = contents.hasSuffix("Authorized") && control.hasSuffix("Authorized")
      self.setStep(2, ok ? .pass : .fail, "contents=\(contents) control=\(control) on iPadOS \(Self.osBuild)")
      if ok && !self.browsing {
        self.browser.start()
        self.browsing = true
      }
    }
  }

  private func step3() {
    guard camera != nil else {
      setStep(3, .fail, "no camera; step 1 first")
      return
    }
    setStep(3, .running, "opening session")
    openSession { [weak self] error in
      guard let self = self else { return }
      if let e = error {
        self.setStep(3, .fail, "session did not open: \(e.localizedDescription)")
        return
      }
      self.ptpWork("step 3") { sony in
        let r = sony.getDeviceInfo()
        if r.notAuthorized {
          self.setStep(3, .fail, "error -21249, not authorized to send PTP commands: switch to fallback 1")
          return
        }
        guard r.ok, let di = sony.deviceInfo else {
          self.setStep(3, .fail, "GetDeviceInfo: \(r.summary)")
          return
        }
        let sonyOps = di.operations.filter { $0 >= 0x9200 && $0 < 0x9300 }
          .map { String(format: "%04X", $0) }.joined(separator: " ")
        self.setStep(3, .pass,
                     "\(di.manufacturer) \(di.model) firmware \(di.deviceVersion), vendor ext 0x\(String(di.vendorExtensionID, radix: 16)), "
                       + "\(di.operations.count) ops, Sony ops: \(sonyOps.isEmpty ? "none" : sonyOps)",
                     timing: String(format: "%.0f ms", r.elapsed * 1000))
      }
    }
  }

  private func step4() {
    setStep(4, .running, "handshaking")
    ptpWork("step 4") { sony in
      let start = Date()
      let (ok, detail) = sony.handshake()
      self.setStep(4, ok ? .pass : .fail, detail, timing: String(format: "%.2f s", Date().timeIntervalSince(start)))
    }
  }

  private func step5() {
    setStep(5, .running, "capturing")
    let dir = capturesDir
    ptpWork("step 5") { sony in
      let report = sony.capture(to: dir)
      self.setStep(5, report.ok ? .pass : .fail, report.detail,
                   timing: report.ok ? String(format: "%.2f s press to file", report.pressToFile) : "")
      if let f = report.files.last {
        let image = UIImage(contentsOfFile: f.url.path)
        DispatchQueue.main.async {
          self.lastCaptureName = report.files.map { $0.url.lastPathComponent }.joined(separator: ", ")
          self.lastCaptureImage = image
        }
      }
    }
  }

  private func step6() {
    setStep(6, .running, "fetching 100 frames")
    ptpWork("step 6") { sony in
      var frames = 0, bytes = 0, failures = 0
      var lastError = ""
      let start = Date()
      while frames < 100 && failures < 10 {
        let (jpeg, detail) = sony.liveViewFrame()
        guard let j = jpeg else {
          failures += 1
          lastError = detail
          continue
        }
        frames += 1
        bytes += j.count
        let img = UIImage(data: j)
        DispatchQueue.main.async { self.liveImage = img }
      }
      let secs = Date().timeIntervalSince(start)
      let fps = Double(frames) / max(secs, 0.001)
      DispatchQueue.main.async { self.liveFPS = String(format: "%.1f fps", fps) }
      let detail = String(format: "%d frames, %d failures, %.1f fps, avg %.0f KB/frame", frames, failures, fps,
                          Double(bytes) / Double(max(frames, 1)) / 1024) + (lastError.isEmpty ? "" : "; last error: \(lastError)")
      self.setStep(6, frames == 100 ? .pass : .fail, detail, timing: String(format: "%.1f fps", fps))
    }
  }

  private func step7() {
    setStep(7, .running, "stepping ISO and shutter speed")
    ptpWork("step 7") { sony in
      var notes: [String] = []
      var ok = true
      for (prop, name) in [(PTPProp.sonyISO, "ISO"), (PTPProp.sonyShutterSpeed, "shutter")] {
        let up = sony.step(prop, by: 1)
        let down = sony.step(prop, by: -1)
        let fmt: (PTPValue?) -> String = { v in
          prop == PTPProp.sonyISO ? SonyFormat.iso(v?.uint32) : SonyFormat.shutter(v?.uint32)
        }
        let changed = up.after != up.before
        let restored = down.after == up.before
        ok = ok && changed && restored
        notes.append("\(name) \(fmt(up.before)) -> \(fmt(up.after)) -> \(fmt(down.after))"
          + (up.detail.isEmpty ? "" : " (\(up.detail))"))
      }
      self.setStep(7, ok ? .pass : .fail, notes.joined(separator: "; "))
    }
  }

  // MARK: manual controls

  func captureNow() { step5() }

  func nudge(_ prop: UInt16, _ delta: Int) {
    ptpWork("nudge") { sony in
      let r = sony.step(prop, by: delta)
      if !r.detail.isEmpty { self.say("nudge: \(r.detail)") }
    }
  }

  func toggleLiveView() {
    if liveRunning {
      liveRunning = false
      return
    }
    guard let sony = sony, let transport = transport, !busy else {
      say("live view: no session, or busy")
      return
    }
    liveRunning = true
    busy = true
    transport.queue.async {
      var frames = 0
      var windowStart = Date()
      while true {
        var keepGoing = false
        DispatchQueue.main.sync { keepGoing = self.liveRunning }
        if !keepGoing { break }
        let (jpeg, detail) = sony.liveViewFrame()
        guard let j = jpeg else {
          self.say("live view stopped: \(detail)")
          break
        }
        frames += 1
        let img = UIImage(data: j)
        let elapsed = Date().timeIntervalSince(windowStart)
        var fps: String?
        if elapsed >= 2 {
          fps = String(format: "%.1f fps", Double(frames) / elapsed)
          frames = 0
          windowStart = Date()
        }
        DispatchQueue.main.async {
          self.liveImage = img
          if let f = fps { self.liveFPS = f }
        }
      }
      DispatchQueue.main.async {
        self.liveRunning = false
        self.busy = false
      }
    }
  }

  func updateReadouts() {
    guard let s = sony else {
      readouts = []
      return
    }
    // props are only written on the PTP queue; read a snapshot there
    s.transport.queue.async {
      let p = s.props
      func raw(_ code: UInt16) -> String {
        guard let prop = p[code] else { return "-" }
        return SonyFormat.value(prop.current)
      }
      var focus = "-"
      if let f = p[PTPProp.focusMode]?.current.int64 { focus = f == 1 ? "manual" : "auto (\(f))" }
      let comp = p[PTPProp.sonyExposureCompensation] ?? p[PTPProp.exposureBias]
      var rows: [(String, String)] = []
      rows.append(("ISO", SonyFormat.iso(p[PTPProp.sonyISO]?.current.uint32)))
      rows.append(("Shutter", SonyFormat.shutter(p[PTPProp.sonyShutterSpeed]?.current.uint32)))
      rows.append(("Aperture", SonyFormat.fNumber(p[PTPProp.fNumber]?.current.int64)))
      rows.append(("Exp. comp.", SonyFormat.ev(comp?.current.int64)))
      rows.append(("Focus mode", focus))
      rows.append(("Battery", raw(PTPProp.sonyBatteryLevel)))
      rows.append(("Objects in RAM", raw(PTPProp.sonyObjectInMemory)))
      rows.append(("Protocol", s.protocolVersion == 0 ? "-" : "\(s.protocolVersion)"))
      rows.append(("Properties", "\(p.count)"))
      DispatchQueue.main.async { self.readouts = rows }
    }
  }

  func dumpProps() {
    ptpWork("dump") { sony in
      sony.refreshProps()
      for (code, prop) in sony.props.sorted(by: { $0.key < $1.key }) {
        self.say(String(format: "prop 0x%04X type 0x%04X getset %d enabled %d = ", code, prop.dataType, prop.getSet, prop.isEnabled)
          + SonyFormat.value(prop.current) + (prop.enumValues.isEmpty ? "" : " (\(prop.enumValues.count) choices)"))
      }
    }
  }

  // MARK: step 8

  private func startHeartbeat() {
    guard sony?.handshakeDone == true else {
      say("step 8: run steps 3 and 4 first")
      return
    }
    heartbeatRunning = true
    heartbeatStart = Date()
    beats = 0
    beatFailures = 0
    consecutiveFailures = 0
    beatLatencies = []
    reconnects = []
    reconnectFailures = 0
    missedRecovered = 0
    setStep(8, .running, "heartbeat every 3 s; pull the cable twice during the hour")
    heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.beat() }
  }

  private func stopHeartbeat() {
    heartbeatTimer?.invalidate()
    heartbeatTimer = nil
    heartbeatRunning = false
    let minutes = Date().timeIntervalSince(heartbeatStart) / 60
    let ok = minutes >= 60 && reconnects.count >= 2 && reconnectFailures == 0
    let enough = minutes >= 60 && reconnects.count >= 2
    setStep(8, ok ? .pass : (enough ? .fail : .partial), heartbeatSummary())
  }

  private func heartbeatSummary() -> String {
    let minutes = Date().timeIntervalSince(heartbeatStart) / 60
    let avgBeat = beatLatencies.isEmpty ? 0 : beatLatencies.reduce(0, +) / Double(beatLatencies.count)
    let maxBeat = beatLatencies.max() ?? 0
    let avgReconnect = reconnects.isEmpty ? 0 : reconnects.reduce(0, +) / Double(reconnects.count)
    return String(format: "%.0f min, %d beats, %d failed (avg %.0f ms, max %.0f ms); %d reconnects (avg %.1f s), %d failed; %d missed file(s) recovered",
                  minutes, beats, beatFailures, avgBeat * 1000, maxBeat * 1000, reconnects.count, avgReconnect,
                  reconnectFailures, missedRecovered)
  }

  private func beat() {
    guard !heartbeatInFlight, let sony = sony, let transport = transport else {
      heartbeatLine = (cableOutAt != nil ? "cable out; " : "") + heartbeatSummary()
      return
    }
    heartbeatInFlight = true
    transport.queue.async {
      let r = sony.refreshProps()
      DispatchQueue.main.async {
        self.heartbeatInFlight = false
        self.beats += 1
        if r.ok {
          self.consecutiveFailures = 0
          self.beatLatencies.append(r.elapsed)
        } else {
          self.beatFailures += 1
          self.consecutiveFailures += 1
          if self.consecutiveFailures == 3 { self.say("step 8: three heartbeats in a row failed, link looks dead") }
        }
        self.heartbeatLine = self.heartbeatSummary()
        if !self.busy { self.updateReadouts() }
      }
    }
  }

  // camera came back after a cable pull: session, handshake, missed files
  private func recover(after out: Date) {
    let back = Date()
    say(String(format: "step 8: camera back after %.1f s out; recovering", back.timeIntervalSince(out)))
    openSession { [weak self] error in
      guard let self = self else { return }
      if let e = error {
        self.reconnectFailures += 1
        self.say("step 8: reconnect failed, session: \(e.localizedDescription)")
        return
      }
      self.recoverOnQueue(back: back)
    }
  }

  // waits for a step that was running when the cable came out to time out
  private func recoverOnQueue(back: Date, attempt: Int = 0) {
    if busy {
      if attempt < 60 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
          self?.recoverOnQueue(back: back, attempt: attempt + 1)
        }
      } else {
        reconnectFailures += 1
        say("step 8: reconnect gave up, PTP queue still busy after 60 s")
      }
      return
    }
    let dir = capturesDir
    ptpWork("reconnect") { sony in
      let info = sony.getDeviceInfo()
      var ok = false
      var detail = "GetDeviceInfo: \(info.summary)"
      if info.ok { (ok, detail) = sony.handshake() }
      let missed = ok ? sony.downloadPending(to: dir, prefix: "missed-") : []
      let took = Date().timeIntervalSince(back)
      DispatchQueue.main.async {
        self.cableOutAt = nil
        if ok {
          self.reconnects.append(took)
          self.missedRecovered += missed.count
        } else {
          self.reconnectFailures += 1
        }
        self.say(String(format: "step 8: reconnect %@ in %.1f s, %d missed file(s); %@", ok ? "ok" : "FAILED", took, missed.count, detail))
        self.heartbeatLine = self.heartbeatSummary()
      }
    }
  }

  // MARK: export

  func writeResults() -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    var md = "# a7 III tethering spike\n\n"
    md += "- date: \(f.string(from: Date()))\n"
    md += "- iPad: \(Self.hardwareModel), iPadOS \(Self.osBuild)\n"
    if let di = sony?.deviceInfo { md += "- camera: \(di.manufacturer) \(di.model), firmware \(di.deviceVersion)\n" }
    md += "- camera as seen by ImageCaptureCore: \(deviceLine)\n"
    md += "- authorization: \(authLine)\n"
    md += "- out-data wrapped in container: \(wrapOutData ? "yes" : "no")\n\n"
    md += "| step | question | result | timing | detail |\n|---|---|---|---|---|\n"
    for s in steps {
      let detail = s.detail.replacingOccurrences(of: "|", with: "/")
      md += "| \(s.id). \(s.title) | \(s.question) | \(s.status.rawValue) | \(s.timing) | \(detail) |\n"
    }
    md += "\nFull log: \(logURL.lastPathComponent) (in the logs folder)\n"
    let url = documents.appendingPathComponent("spike-results.md")
    try? md.write(to: url, atomically: true, encoding: .utf8)
    say("results written to \(url.lastPathComponent)")
    return url
  }
}
