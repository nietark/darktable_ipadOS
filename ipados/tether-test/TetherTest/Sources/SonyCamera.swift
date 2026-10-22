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

// Sony "PC Remote" control over raw PTP, ported from libgphoto2's ptp2
// driver: the connect sequence from camera_init() in library.c, capture
// from camera_sony_capture(), live view from camera_capture_preview() and
// property stepping from _put_sony_value_*() in config.c. Older bodies
// such as the a7 III speak protocol 200 ("mode 2"), where exposure
// settings move one notch per command instead of being set directly.

import Foundation

struct PTPEventRecord {
  var code: UInt16
  var params: [UInt32]
  var time: Date
}

// events arrive on the main thread from ImageCaptureCore and are consumed
// on the PTP queue
final class EventInbox {
  private let lock = NSLock()
  private var events: [PTPEventRecord] = []

  func push(_ e: PTPEventRecord) {
    lock.lock()
    events.append(e)
    if events.count > 500 { events.removeFirst(events.count - 500) }
    lock.unlock()
  }

  func drain() -> [PTPEventRecord] {
    lock.lock()
    defer { lock.unlock() }
    let out = events
    events = []
    return out
  }
}

struct SavedFile {
  var url: URL
  var bytes: Int
  var seconds: TimeInterval
  var info: PTPObjectInfo?
}

struct CaptureReport {
  var ok = false
  var detail = ""
  var pressToReady: TimeInterval = 0
  var pressToFile: TimeInterval = 0
  var files: [SavedFile] = []
}

final class SonyCamera {
  let transport: PTPTransport
  let inbox: EventInbox
  private let log: (String) -> Void

  private(set) var deviceInfo: PTPDeviceInfo?
  private(set) var protocolVersion: UInt16 = 0
  private(set) var extendedCodes: [UInt16] = []
  private(set) var props: [UInt16: SonyProp] = [:]
  private(set) var handshakeDone = false
  private var handshakeTime = Date.distantPast

  init(transport: PTPTransport, inbox: EventInbox, log: @escaping (String) -> Void) {
    self.transport = transport
    self.inbox = inbox
    self.log = log
  }

  // MARK: basic

  func getDeviceInfo() -> PTPResult {
    let r = transport.transact(PTPOp.getDeviceInfo)
    if r.ok { deviceInfo = PTPDeviceInfo.parse(r.data) }
    return r
  }

  @discardableResult
  func refreshProps() -> PTPResult {
    let r = transport.transact(PTPOp.sonyGetAllExtDevicePropInfo)
    if r.ok { props = SonyPropParser.parseAll(r.data) }
    return r
  }

  func value(_ code: UInt16) -> PTPValue? { props[code]?.current }

  // 0x9207: buttons and notches
  func control(_ prop: UInt16, u16 v: UInt16) -> PTPResult {
    var d = Data()
    d.appendLE(v)
    return transport.transact(PTPOp.sonyControlDevice, [UInt32(prop)], out: d)
  }

  func control(_ prop: UInt16, u8 v: UInt8) -> PTPResult {
    return transport.transact(PTPOp.sonyControlDevice, [UInt32(prop)], out: Data([v]))
  }

  // 0x9205: settings
  func setExt(_ prop: UInt16, i8 v: Int8) -> PTPResult {
    return transport.transact(PTPOp.sonySetExtDevicePropValue, [UInt32(prop)], out: Data([UInt8(bitPattern: v)]))
  }

  // MARK: handshake

  func handshake() -> (ok: Bool, detail: String) {
    handshakeDone = false
    if deviceInfo == nil {
      let r = getDeviceInfo()
      guard r.ok else { return (false, "GetDeviceInfo failed: \(r.summary)") }
    }
    guard let di = deviceInfo else { return (false, "could not parse DeviceInfo") }
    guard di.operations.contains(PTPOp.sonyGetExtDeviceInfo) else {
      return (false, "camera does not list 0x9202; is USB Connection set to PC Remote?")
    }

    for phase: UInt32 in [1, 2] {
      let r = transport.transact(PTPOp.sonySDIOConnect, [phase, 0, 0])
      guard r.ok else { return (false, "SDIO connect phase \(phase): \(r.summary)") }
    }

    // libgphoto2 retries up to 20 times until the camera returns a list
    var ext = PTPResult()
    for _ in 0..<20 {
      ext = transport.transact(PTPOp.sonyGetExtDeviceInfo, [UInt32(SonyProtocol.v300), 1])
      guard ext.ok else { return (false, "GetExtDeviceInfo: \(ext.summary)") }
      if !ext.data.isEmpty { break }
    }
    var r = ByteReader(ext.data)
    protocolVersion = r.u16() ?? 0
    let propCodes = r.u16Array() ?? []
    let controls = r.u16Array() ?? []
    extendedCodes = propCodes + controls

    let phase3 = transport.transact(PTPOp.sonySDIOConnect, [3, 0, 0])
    guard phase3.ok else { return (false, "SDIO connect phase 3: \(phase3.summary)") }

    // 1 = the application, not the camera dials, has priority
    let prio = setExt(PTPProp.sonyPriorityMode, i8: 1)
    if !prio.ok { log("priority mode not accepted (\(prio.summary)); continuing like libgphoto2 does") }

    let pr = refreshProps()
    handshakeDone = true
    handshakeTime = Date()
    return (true, "protocol \(protocolVersion), \(propCodes.count) props + \(controls.count) controls, "
      + "0x9209 \(pr.ok ? "\(props.count) props" : pr.summary)")
  }

  // MARK: files

  private func download(_ handle: UInt32, to dir: URL, prefix: String) -> (SavedFile?, String) {
    let start = Date()
    let oiResult = transport.transact(PTPOp.getObjectInfo, [handle])
    let oi = oiResult.ok ? PTPObjectInfo.parse(oiResult.data) : nil
    let obj = transport.transact(PTPOp.getObject, [handle], timeout: 120)
    guard obj.ok else { return (nil, "GetObject: \(obj.summary)") }

    var name = oi?.filename ?? ""
    if name.count <= 4 { name = oi?.format == 0xB101 ? "capture.arw" : "capture.jpg" }
    let stamp = Self.stamp.string(from: Date())
    let url = dir.appendingPathComponent("\(prefix)\(stamp)-\(name)")
    do {
      try obj.data.write(to: url)
    } catch {
      return (nil, "write failed: \(error.localizedDescription)")
    }
    let file = SavedFile(url: url, bytes: obj.data.count, seconds: Date().timeIntervalSince(start), info: oi)
    log(String(format: "saved %@ (%@, %.1f MB in %.2f s, %.1f MB/s)", url.lastPathComponent, oi?.formatName ?? "?",
               Double(file.bytes) / 1e6, file.seconds, Double(file.bytes) / 1e6 / max(file.seconds, 0.001)))
    return (file, "")
  }

  private var objectInMemory: Int64 { value(PTPProp.sonyObjectInMemory)?.int64 ?? 0 }

  // the camera keeps finished frames in RAM until fetched; this is also the
  // "missed file" scan after a reconnect
  func downloadPending(to dir: URL, prefix: String) -> [SavedFile] {
    var files: [SavedFile] = []
    for _ in 0..<8 {
      refreshProps()
      guard objectInMemory >= 0x8000 else { break }
      log(String(format: "ObjectInMemory 0x%llX, fetching", objectInMemory))
      let (f, err) = download(SonyHandle.capturedObject, to: dir, prefix: prefix)
      guard let file = f else { log("pending download failed: \(err)"); break }
      files.append(file)
    }
    return files
  }

  // MARK: capture

  func capture(to dir: URL) -> CaptureReport {
    var report = CaptureReport()
    guard handshakeDone else { report.detail = "run the handshake first"; return report }

    // libgphoto2 waits 3 s after connecting on the a7 III and similar bodies,
    // polling properties, or the first capture does nothing
    while Date().timeIntervalSince(handshakeTime) < 3 {
      refreshProps()
      Thread.sleep(forTimeInterval: 0.2)
    }

    let stale = downloadPending(to: dir, prefix: "pending-")
    if !stale.isEmpty { log("fetched \(stale.count) frame(s) that were waiting before this capture") }
    _ = inbox.drain()

    let press = Date()
    var r = control(PTPProp.sonyShutterHalfRelease, u16: 2)
    guard r.ok else { report.detail = "half press: \(r.summary)"; return report }
    r = control(PTPProp.sonyShutterRelease, u16: 2)
    guard r.ok else { report.detail = "full press: \(r.summary)"; return report }

    var objectAnnounced = false
    let manualFocus = value(PTPProp.focusMode)?.int64 == 1
    if !manualFocus {
      // hold the button until focus is found, at most 1 s
      while Date().timeIntervalSince(press) < 1 {
        let evs = inbox.drain()
        if evs.contains(where: { $0.code == PTPEvent.sonyObjectAdded }) { objectAnnounced = true; break }
        if evs.contains(where: { $0.code == PTPEvent.sonyPropChanged && $0.params.first == UInt32(PTPProp.sonyFocusFound) }) { break }
        refreshProps()
        let ff = value(PTPProp.sonyFocusFound)?.int64 ?? 0
        if ff == 2 || ff == 3 { break }
      }
    }

    _ = control(PTPProp.sonyShutterRelease, u16: 1)
    _ = control(PTPProp.sonyShutterHalfRelease, u16: 1)

    // 30 s longest exposure plus 5 s to write, as in libgphoto2
    var ready = objectAnnounced
    while !ready && Date().timeIntervalSince(press) < 35 {
      if inbox.drain().contains(where: { $0.code == PTPEvent.sonyObjectAdded }) { ready = true; break }
      refreshProps()
      if objectInMemory >= 0x8000 { ready = true; break }
      Thread.sleep(forTimeInterval: 0.05)
    }
    report.pressToReady = Date().timeIntervalSince(press)
    guard ready else {
      report.detail = "no frame within 35 s (no focus? card full?)"
      return report
    }

    // RAW+JPEG leaves two objects; fetch until the camera reports none.
    // Never touch 0xFFFFC001 when nothing is there: libgphoto2 notes that
    // crashes the camera firmware.
    for i in 0..<4 {
      if i > 0 {
        refreshProps()
        if objectInMemory < 0x8000 { break }
      }
      let (f, err) = download(SonyHandle.capturedObject, to: dir, prefix: "")
      guard let file = f else { report.detail = err; break }
      report.files.append(file)
    }
    report.pressToFile = Date().timeIntervalSince(press)
    report.ok = !report.files.isEmpty
    if report.ok {
      let mb = Double(report.files.reduce(0) { $0 + $1.bytes }) / 1e6
      report.detail = String(format: "%d file(s), %.1f MB; press to ready %.2f s, press to file on iPad %.2f s",
                             report.files.count, mb, report.pressToReady, report.pressToFile)
    }
    return report
  }

  // MARK: live view

  func liveViewFrame() -> (jpeg: Data?, detail: String) {
    var obj = PTPResult()
    var got = false
    for _ in 0..<50 {
      let info = transport.transact(PTPOp.getObjectInfo, [SonyHandle.liveView], timeout: 2)
      if info.code == PTPResponse.invalidObjectHandle {
        Thread.sleep(forTimeInterval: 0.05)
        continue
      }
      obj = transport.transact(PTPOp.getObject, [SonyHandle.liveView], timeout: 3)
      if obj.ok { got = true; break }
      // AccessDenied means we asked too soon after the last frame
      guard obj.code == PTPResponse.accessDenied else { return (nil, obj.summary) }
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard got else { return (nil, "no live view frame after 50 tries") }

    // a header comes first; its first 4 bytes are usually the JPEG offset
    let bytes = [UInt8](obj.data)
    var start = -1
    if bytes.count > 4 {
      let off = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
      if off + 1 < bytes.count && bytes[off] == 0xFF && bytes[off + 1] == 0xD8 { start = off }
    }
    if start < 0, bytes.count > 1 {
      for i in 0..<(bytes.count - 1) where bytes[i] == 0xFF && bytes[i + 1] == 0xD8 {
        start = i
        break
      }
    }
    guard start >= 0 else { return (nil, "frame has no JPEG start marker (\(bytes.count) bytes)") }
    return (Data(bytes[start...]), "")
  }

  // MARK: settings

  // one notch up (+1) or down (-1). For shutter speed +1 means faster.
  func step(_ prop: UInt16, by delta: Int) -> (before: PTPValue?, after: PTPValue?, detail: String) {
    refreshProps()
    let before = value(prop)
    let r = control(prop, u8: delta > 0 ? 0x01 : 0xFF)
    guard r.ok else { return (before, before, "step: \(r.summary)") }
    // the camera takes a moment to apply it (0.7 s on the SLT-A58 per libgphoto2)
    let start = Date()
    while Date().timeIntervalSince(start) < 3 {
      Thread.sleep(forTimeInterval: 0.2)
      refreshProps()
      if value(prop) != before { break }
    }
    let after = value(prop)
    return (before, after, after == before ? "value did not change within 3 s" : "")
  }

  private static let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HHmmss"
    return f
  }()
}
