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

// PTP codes and wire formats. The Sony vendor codes are taken from
// libgphoto2 camlibs/ptp2/ptp.h (LGPL-2.1-or-later), which is where all
// Sony knowledge in this app comes from; Sony's own Camera Remote Command
// documents are deliberately not used.

import Foundation

enum PTPOp {
  static let getDeviceInfo: UInt16 = 0x1001
  static let getObjectInfo: UInt16 = 0x1008
  static let getObject: UInt16 = 0x1009

  // libgphoto2 ptp.h: PTP_OC_SONY_*
  static let sonySDIOConnect: UInt16 = 0x9201
  static let sonyGetExtDeviceInfo: UInt16 = 0x9202
  static let sonySetExtDevicePropValue: UInt16 = 0x9205
  static let sonyControlDevice: UInt16 = 0x9207
  static let sonyGetAllExtDevicePropInfo: UInt16 = 0x9209
}

enum PTPResponse {
  static let ok: UInt16 = 0x2001
  static let generalError: UInt16 = 0x2002
  static let sessionNotOpen: UInt16 = 0x2003
  static let operationNotSupported: UInt16 = 0x2005
  static let invalidObjectHandle: UInt16 = 0x2009
  static let accessDenied: UInt16 = 0x200F
  static let deviceBusy: UInt16 = 0x2019

  static func name(_ code: UInt16) -> String {
    switch code {
    case 0: return "no response"
    case ok: return "OK"
    case generalError: return "GeneralError"
    case sessionNotOpen: return "SessionNotOpen"
    case operationNotSupported: return "OperationNotSupported"
    case invalidObjectHandle: return "InvalidObjectHandle"
    case accessDenied: return "AccessDenied"
    case deviceBusy: return "DeviceBusy"
    default: return String(format: "0x%04X", code)
    }
  }
}

enum PTPDataType {
  static let int8: UInt16 = 0x0001
  static let uint8: UInt16 = 0x0002
  static let int16: UInt16 = 0x0003
  static let uint16: UInt16 = 0x0004
  static let int32: UInt16 = 0x0005
  static let uint32: UInt16 = 0x0006
  static let int64: UInt16 = 0x0007
  static let uint64: UInt16 = 0x0008
  static let int128: UInt16 = 0x0009
  static let uint128: UInt16 = 0x000A
  static let arrayMask: UInt16 = 0x4000
  static let string: UInt16 = 0xFFFF
}

enum PTPProp {
  // standard PTP properties the a7 III reports through the Sony blob
  static let whiteBalance: UInt16 = 0x5005
  static let fNumber: UInt16 = 0x5007
  static let focusMode: UInt16 = 0x500A
  static let exposureProgram: UInt16 = 0x500E
  static let exposureBias: UInt16 = 0x5010

  // libgphoto2 ptp.h: PTP_DPC_SONY_*
  static let sonyShutterSpeed: UInt16 = 0xD20D
  static let sonyFocusFound: UInt16 = 0xD213
  static let sonyObjectInMemory: UInt16 = 0xD215
  static let sonyBatteryLevel: UInt16 = 0xD218
  static let sonyISO: UInt16 = 0xD21E
  static let sonyStillImageStoreDestination: UInt16 = 0xD222
  static let sonyExposureCompensation: UInt16 = 0xD224
  static let sonyPriorityMode: UInt16 = 0xD25A
  static let sonyShutterHalfRelease: UInt16 = 0xD2C1
  static let sonyShutterRelease: UInt16 = 0xD2C2
}

enum PTPEvent {
  // libgphoto2 ptp.h: PTP_EC_Sony_*
  static let sonyObjectAdded: UInt16 = 0xC201
  static let sonyObjectRemoved: UInt16 = 0xC202
  static let sonyPropChanged: UInt16 = 0xC203
}

enum SonyHandle {
  // libgphoto2 library.c: the finished frame and the live view frame
  static let capturedObject: UInt32 = 0xFFFF_C001
  static let liveView: UInt32 = 0xFFFF_C002
}

enum SonyProtocol {
  // libgphoto2 ptp.c: SONY_PROTOCOL_2_00 / _3_00. The a7 III answers 200.
  static let v200: UInt16 = 0x00C8
  static let v300: UInt16 = 0x012C
}

let sonyUSBVendorID = 0x054C

// MARK: - containers

enum PTPContainer {
  static let commandType: UInt16 = 1
  static let dataType: UInt16 = 2

  static func command(_ op: UInt16, transaction: UInt32, params: [UInt32]) -> Data {
    var d = Data()
    d.appendLE(UInt32(12 + 4 * params.count))
    d.appendLE(commandType)
    d.appendLE(op)
    d.appendLE(transaction)
    for p in params { d.appendLE(p) }
    return d
  }

  static func dataContainer(_ op: UInt16, transaction: UInt32, payload: Data) -> Data {
    var d = Data()
    d.appendLE(UInt32(12 + payload.count))
    d.appendLE(dataType)
    d.appendLE(op)
    d.appendLE(transaction)
    d.append(payload)
    return d
  }

  // the response container: length, type 3, code, transaction, params
  static func parseResponse(_ data: Data) -> (code: UInt16, params: [UInt32])? {
    var r = ByteReader(data)
    guard let _ = r.u32(), let _ = r.u16(), let code = r.u16(), let _ = r.u32() else { return nil }
    var params: [UInt32] = []
    while let p = r.u32() { params.append(p) }
    return (code, params)
  }

  // ImageCaptureCore is expected to hand back the bare data phase, but strip
  // a USB data container header if one is there
  static func stripDataHeader(_ data: Data) -> (Data, Bool) {
    guard data.count >= 12 else { return (data, false) }
    var r = ByteReader(data)
    if let len = r.u32(), let type = r.u16(), Int(len) == data.count, type == dataType {
      return (data.subdata(in: data.startIndex + 12 ..< data.endIndex), true)
    }
    return (data, false)
  }
}

// MARK: - little-endian helpers

extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
    var le = v.littleEndian
    Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
  }

  func hexPrefix(_ n: Int = 32) -> String {
    let bytes = prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
    return count > n ? bytes + " ... (\(count) bytes)" : bytes
  }
}

struct ByteReader {
  private let bytes: [UInt8]
  private(set) var offset = 0

  init(_ data: Data, offset: Int = 0) {
    bytes = [UInt8](data)
    self.offset = offset
  }

  var remaining: Int { bytes.count - offset }

  mutating func skip(_ n: Int) -> Bool {
    guard n <= remaining else { return false }
    offset += n
    return true
  }

  private mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
    let size = MemoryLayout<T>.size
    guard size <= remaining else { return nil }
    var v: T = 0
    for i in 0..<size { v |= T(bytes[offset + i]) << (8 * i) }
    offset += size
    return v
  }

  mutating func u8() -> UInt8? { read(UInt8.self) }
  mutating func u16() -> UInt16? { read(UInt16.self) }
  mutating func u32() -> UInt32? { read(UInt32.self) }
  mutating func u64() -> UInt64? { read(UInt64.self) }

  func peekU16() -> UInt16? {
    var copy = self
    return copy.u16()
  }

  // PTP string: u8 character count including the terminator, then UCS-2
  mutating func string() -> String? {
    guard let n = u8() else { return nil }
    if n == 0 { return "" }
    var units: [UInt16] = []
    for _ in 0..<n {
      guard let c = u16() else { return nil }
      units.append(c)
    }
    if units.last == 0 { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
  }

  mutating func u16Array() -> [UInt16]? {
    guard let n = u32(), Int(n) * 2 <= remaining else { return nil }
    var out: [UInt16] = []
    out.reserveCapacity(Int(n))
    for _ in 0..<n { out.append(u16()!) }
    return out
  }
}

// MARK: - datasets

struct PTPDeviceInfo {
  var standardVersion: UInt16 = 0
  var vendorExtensionID: UInt32 = 0
  var vendorExtensionVersion: UInt16 = 0
  var vendorExtensionDesc = ""
  var operations: [UInt16] = []
  var events: [UInt16] = []
  var properties: [UInt16] = []
  var manufacturer = ""
  var model = ""
  var deviceVersion = ""
  var serial = ""

  static func parse(_ data: Data) -> PTPDeviceInfo? {
    var r = ByteReader(data)
    var di = PTPDeviceInfo()
    guard let sv = r.u16(), let ve = r.u32(), let vv = r.u16(), let vd = r.string(),
          let _ = r.u16(), // functional mode
          let ops = r.u16Array(), let evs = r.u16Array(), let props = r.u16Array(),
          let _ = r.u16Array(), let _ = r.u16Array(), // capture and image formats
          let man = r.string(), let model = r.string()
    else { return nil }
    di.standardVersion = sv
    di.vendorExtensionID = ve
    di.vendorExtensionVersion = vv
    di.vendorExtensionDesc = vd
    di.operations = ops
    di.events = evs
    di.properties = props
    di.manufacturer = man
    di.model = model
    di.deviceVersion = r.string() ?? ""
    di.serial = r.string() ?? ""
    return di
  }

  // libgphoto2 library.c treats MTP-flavored "Sony Corporation" as Sony too
  var isSony: Bool { vendorExtensionID == 0x11 || manufacturer.hasPrefix("Sony") }
}

struct PTPObjectInfo {
  var storageID: UInt32 = 0
  var format: UInt16 = 0
  var compressedSize: UInt32 = 0
  var width: UInt32 = 0
  var height: UInt32 = 0
  var filename = ""

  static func parse(_ data: Data) -> PTPObjectInfo? {
    var r = ByteReader(data)
    var oi = PTPObjectInfo()
    guard let sid = r.u32(), let fmt = r.u16(), r.skip(2), let size = r.u32() else { return nil }
    oi.storageID = sid
    oi.format = fmt
    oi.compressedSize = size
    // thumb format, thumb size, thumb width, thumb height
    guard r.skip(2 + 4 + 4 + 4), let w = r.u32(), let h = r.u32() else { return oi }
    oi.width = w
    oi.height = h
    // bit depth, parent, association type, association desc, sequence number
    guard r.skip(4 + 4 + 2 + 4 + 4) else { return oi }
    oi.filename = r.string() ?? ""
    return oi
  }

  var formatName: String {
    switch format {
    case 0x3801: return "JPEG"
    case 0xB101: return "Sony ARW"
    default: return String(format: "0x%04X", format)
    }
  }
}
