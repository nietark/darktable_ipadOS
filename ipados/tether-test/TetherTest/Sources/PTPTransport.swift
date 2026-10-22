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

import Foundation
import ImageCaptureCore

struct PTPResult {
  var code: UInt16 = 0
  var params: [UInt32] = []
  var data = Data()
  var error: Error?
  var timedOut = false
  var elapsed: TimeInterval = 0

  var ok: Bool { error == nil && !timedOut && code == PTPResponse.ok }

  var summary: String {
    if timedOut { return "timeout after \(String(format: "%.1f", elapsed)) s" }
    if let e = error as NSError? { return "error \(e.domain) \(e.code): \(e.localizedDescription)" }
    return "\(PTPResponse.name(code)), \(data.count) bytes, \(String(format: "%.0f", elapsed * 1000)) ms"
  }

  // ImageCaptureCore's "not authorized to send PTP command" (iOS 13 era reports)
  var notAuthorized: Bool { (error as NSError?)?.code == -21249 }
}

// One PTP transaction at a time, as the protocol requires. Every call
// blocks the caller until the camera answers or the timeout fires, so it
// must only be used from PTPTransport.queue, never from the main thread.
final class PTPTransport {
  let camera: ICCameraDevice
  let queue = DispatchQueue(label: "tethertest.ptp")
  private var transaction: UInt32 = 1
  private let log: (String) -> Void

  // the data phase we send is passed bare; flip this if the camera rejects
  // every 0x9205/0x9207 and the log shows it expects a container header
  var wrapOutData = false
  var verbose = false
  private var loggedFirstReply = false

  init(camera: ICCameraDevice, log: @escaping (String) -> Void) {
    self.camera = camera
    self.log = log
  }

  func transact(_ op: UInt16, _ params: [UInt32] = [], out: Data? = nil, timeout: TimeInterval = 5) -> PTPResult {
    dispatchPrecondition(condition: .onQueue(queue))

    let tid = transaction
    transaction &+= 1
    let command = PTPContainer.command(op, transaction: tid, params: params)
    var outData = out
    if let o = out, wrapOutData {
      outData = PTPContainer.dataContainer(op, transaction: tid, payload: o)
    }

    // the completion can arrive after we gave up waiting; the box makes sure
    // a late reply is dropped instead of touching a result already returned
    final class Box {
      let lock = NSLock()
      var done = false
      var result = PTPResult()
    }
    let box = Box()
    let sem = DispatchSemaphore(value: 0)
    let start = Date()

    TTSendPTPCommand(camera, command, outData) { inData, response, error in
      box.lock.lock()
      defer { box.lock.unlock() }
      guard !box.done else { return }
      box.done = true
      var r = PTPResult()
      r.error = error
      if let resp = response, let parsed = PTPContainer.parseResponse(resp) {
        r.code = parsed.code
        r.params = parsed.params
      }
      if let d = inData {
        let (payload, stripped) = PTPContainer.stripDataHeader(d)
        r.data = payload
        if stripped && !self.loggedFirstReply {
          self.log("note: ImageCaptureCore returned the data phase with a container header; stripped it")
        }
      }
      if !self.loggedFirstReply {
        self.loggedFirstReply = true
        self.log("first raw reply: data=[\(inData?.hexPrefix(24) ?? "nil")] response=[\(response?.hexPrefix(24) ?? "nil")]")
      }
      box.result = r
      sem.signal()
    }

    let waited = sem.wait(timeout: .now() + timeout)
    box.lock.lock()
    var result: PTPResult
    if waited == .timedOut && !box.done {
      box.done = true
      result = PTPResult()
      result.timedOut = true
    } else {
      result = box.result
    }
    box.lock.unlock()
    result.elapsed = Date().timeIntervalSince(start)

    if verbose || !result.ok {
      let p = params.map { String(format: "0x%X", $0) }.joined(separator: ",")
      log(String(format: "ptp 0x%04X(%@) -> ", op, p) + result.summary)
    }
    return result
  }
}
