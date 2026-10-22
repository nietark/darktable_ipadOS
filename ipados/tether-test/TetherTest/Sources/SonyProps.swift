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

// Parser for the property blob Sony bodies return from 0x9209
// (GetAllExtDevicePropInfo). Layout follows libgphoto2's
// ptp_unpack_Sony_DPD() in camlibs/ptp2/ptp-pack.c and
// _ptp_sony_getalldevicepropdesc() in camlibs/ptp2/ptp.c.

import Foundation

enum PTPValue: Equatable {
  case int(Int64)
  case uint(UInt64)
  case string(String)
  case array([Int64])
  case unsupported

  var int64: Int64? {
    switch self {
    case .int(let v): return v
    case .uint(let v): return Int64(truncatingIfNeeded: v)
    default: return nil
    }
  }

  var uint32: UInt32? { int64.map { UInt32(truncatingIfNeeded: $0) } }
}

struct SonyProp {
  var code: UInt16
  var dataType: UInt16
  var getSet: UInt8
  var isEnabled: UInt8
  var current: PTPValue
  var formFlag: UInt8 = 0
  var enumValues: [PTPValue] = []
}

enum SonyPropParser {
  static func readValue(_ r: inout ByteReader, _ type: UInt16) -> PTPValue? {
    switch type {
    case PTPDataType.int8: return r.u8().map { .int(Int64(Int8(bitPattern: $0))) }
    case PTPDataType.uint8: return r.u8().map { .uint(UInt64($0)) }
    case PTPDataType.int16: return r.u16().map { .int(Int64(Int16(bitPattern: $0))) }
    case PTPDataType.uint16: return r.u16().map { .uint(UInt64($0)) }
    case PTPDataType.int32: return r.u32().map { .int(Int64(Int32(bitPattern: $0))) }
    case PTPDataType.uint32: return r.u32().map { .uint(UInt64($0)) }
    case PTPDataType.int64: return r.u64().map { .int(Int64(bitPattern: $0)) }
    case PTPDataType.uint64: return r.u64().map { .uint($0) }
    case PTPDataType.int128, PTPDataType.uint128: return r.skip(16) ? .unsupported : nil
    case PTPDataType.string: return r.string().map { .string($0) }
    default:
      guard type & PTPDataType.arrayMask != 0, let n = r.u32() else { return nil }
      let element = type & ~PTPDataType.arrayMask
      var out: [Int64] = []
      for _ in 0..<n {
        guard let v = readValue(&r, element) else { return nil }
        out.append(v.int64 ?? 0)
      }
      return .array(out)
    }
  }

  static func parseAll(_ data: Data) -> [UInt16: SonyProp] {
    var out: [UInt16: SonyProp] = [:]
    // 32-bit entry count, then 32 bits of zero
    var r = ByteReader(data, offset: 8)
    while r.remaining >= 6 {
      guard let code = r.u16(), let type = r.u16(), let getSet = r.u8(), let enabled = r.u8() else { break }
      guard let _ = readValue(&r, type) else { break } // factory default
      if type == PTPDataType.string && r.remaining == 0 { break }
      guard let current = readValue(&r, type) else { break }
      var prop = SonyProp(code: code, dataType: type, getSet: getSet, isEnabled: enabled, current: current)
      if let flag = r.u8() {
        prop.formFlag = flag
        if flag == 1 { // range: min, max, step
          for _ in 0..<3 { _ = readValue(&r, type) }
        } else if flag == 2, let n = r.u16() {
          for _ in 0..<n {
            guard let v = readValue(&r, type) else { break }
            prop.enumValues.append(v)
          }
        }
      }
      // 2024 and later bodies append a second enum list; a value below
      // 0x200 cannot be the next property code (0x5xxx or 0xDxxx)
      if let next = r.peekU16(), next < 0x200, prop.formFlag == 2, let n = r.u16() {
        prop.enumValues = []
        for _ in 0..<n {
          guard let v = readValue(&r, type) else { break }
          prop.enumValues.append(v)
        }
      }
      out[code] = prop
    }
    return out
  }
}

// MARK: - display

enum SonyFormat {
  static func iso(_ v: UInt32?) -> String {
    guard let v = v else { return "-" }
    // libgphoto2 config.c: SONY_ISO_MASK, all ones means auto
    let base = v & 0x00FF_FFFF
    return base == 0x00FF_FFFF ? "ISO auto" : "ISO \(base)"
  }

  static func shutter(_ v: UInt32?) -> String {
    guard let v = v else { return "-" }
    if v == 0 { return "bulb" }
    var n = Int(v >> 16), d = Int(v & 0xFFFF)
    if d == 10 && n % 10 == 0 { n /= 10; d = 1 }
    if d == 0 { return String(format: "0x%08X", v) }
    return d == 1 ? "\(n)\"" : "\(n)/\(d)"
  }

  static func fNumber(_ v: Int64?) -> String {
    guard let v = v else { return "-" }
    return String(format: "f/%.1f", Double(v) / 100)
  }

  static func ev(_ v: Int64?) -> String {
    guard let v = v else { return "-" }
    return String(format: "%+.1f EV", Double(v) / 1000)
  }

  static func value(_ v: PTPValue) -> String {
    switch v {
    case .int(let i): return "\(i)"
    case .uint(let u): return String(format: "%llu (0x%llX)", u, u)
    case .string(let s): return "\"\(s)\""
    case .array(let a): return "[\(a.prefix(8).map(String.init).joined(separator: ","))\(a.count > 8 ? ",..." : "")]"
    case .unsupported: return "?"
    }
  }
}
