#!/usr/bin/env python3
#
#   This file is part of darktable,
#   copyright (c) 2026 darktable developers.
#
#   darktable is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   darktable is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with darktable.  If not, see <http://www.gnu.org/licenses/>.
#
# compare two sRGB TIFF exports of darktable-cli with CIEDE2000
#
#   dtdiff.py REFERENCE.tif TEST.tif [--max 2.3] [--mean 0.77] [--info]
#
# prints max, mean and 99.9th percentile dE and the share of pixels above
# the max threshold; exits 1 when either threshold is exceeded, unless
# --info is given. Only numpy is needed: the reader handles the
# uncompressed and deflate, 8/16 bit integer TIFFs darktable writes, so the
# harness runs the same on a Mac without extra Python packages.

import argparse
import struct
import sys
import zlib

import numpy as np


def _read_tiff(path):
  with open(path, 'rb') as f:
    data = f.read()
  bo = {b'II': '<', b'MM': '>'}.get(data[:2])
  if bo is None or struct.unpack(bo + 'H', data[2:4])[0] != 42:
    raise ValueError(f'{path}: not a classic TIFF')
  ifd = struct.unpack(bo + 'I', data[4:8])[0]
  n = struct.unpack(bo + 'H', data[ifd:ifd + 2])[0]
  sizes = {1: 1, 2: 1, 3: 2, 4: 4, 16: 8}
  codes = {1: 'B', 2: 'c', 3: 'H', 4: 'I', 16: 'Q'}
  tags = {}
  for i in range(n):
    e = ifd + 2 + 12 * i
    tag, typ, cnt = struct.unpack(bo + 'HHI', data[e:e + 8])
    if typ not in sizes:
      continue
    size = sizes[typ] * cnt
    off = e + 8 if size <= 4 else struct.unpack(bo + 'I', data[e + 8:e + 12])[0]
    tags[tag] = struct.unpack(bo + codes[typ] * cnt, data[off:off + size])

  width, height = tags[256][0], tags[257][0]
  bps = tags[258][0]
  spp = tags.get(277, (1,))[0]
  compression = tags.get(259, (1,))[0]
  predictor = tags.get(317, (1,))[0]
  fmt = tags.get(339, (1,))[0]
  if fmt != 1 or bps not in (8, 16) or tags.get(284, (1,))[0] != 1:
    raise ValueError(f'{path}: only chunky 8/16 bit integer TIFFs are supported')
  if compression not in (1, 8, 32946):
    raise ValueError(f'{path}: unsupported compression {compression}')

  dtype = np.dtype(bo + ('u1' if bps == 8 else 'u2'))
  rows_per_strip = tags.get(278, (height,))[0]
  out = np.empty((height, width, spp), dtype=dtype.newbyteorder('='))
  row = 0
  for off, cnt in zip(tags[273], tags[279]):
    chunk = data[off:off + cnt]
    if compression != 1:
      chunk = zlib.decompress(chunk)
    rows = min(rows_per_strip, height - row)
    strip = np.frombuffer(chunk, dtype=dtype, count=rows * width * spp)
    strip = strip.reshape(rows, width, spp)
    if predictor == 2:
      strip = np.cumsum(strip, axis=1, dtype=strip.dtype)
    out[row:row + rows] = strip
    row += rows
  return out[..., :3].astype(np.float64) / (255.0 if bps == 8 else 65535.0)


def _srgb_to_lab(rgb):
  lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
  m = np.array([[0.4124564, 0.3575761, 0.1804375],
                [0.2126729, 0.7151522, 0.0721750],
                [0.0193339, 0.1191920, 0.9503041]])
  xyz = lin @ m.T / np.array([0.95047, 1.0, 1.08883])
  f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
  return np.stack([116 * f[..., 1] - 16,
                   500 * (f[..., 0] - f[..., 1]),
                   200 * (f[..., 1] - f[..., 2])], axis=-1)


def _ciede2000(lab1, lab2):
  L1, a1, b1 = np.moveaxis(lab1, -1, 0)
  L2, a2, b2 = np.moveaxis(lab2, -1, 0)
  C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
  Cm7 = ((C1 + C2) / 2) ** 7
  G = 0.5 * (1 - np.sqrt(Cm7 / (Cm7 + 25.0 ** 7)))
  a1p, a2p = (1 + G) * a1, (1 + G) * a2
  C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
  h1p = np.degrees(np.arctan2(b1, a1p)) % 360
  h2p = np.degrees(np.arctan2(b2, a2p)) % 360
  dLp, dCp = L2 - L1, C2p - C1p
  dh = h2p - h1p
  dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
  dh = np.where(C1p * C2p == 0, 0, dh)
  dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh) / 2)
  Lpm, Cpm = (L1 + L2) / 2, (C1p + C2p) / 2
  hs = h1p + h2p
  hpm = np.where(np.abs(h1p - h2p) > 180,
                 np.where(hs < 360, (hs + 360) / 2, (hs - 360) / 2), hs / 2)
  hpm = np.where(C1p * C2p == 0, hs, hpm)
  T = (1 - 0.17 * np.cos(np.radians(hpm - 30)) + 0.24 * np.cos(np.radians(2 * hpm))
       + 0.32 * np.cos(np.radians(3 * hpm + 6)) - 0.20 * np.cos(np.radians(4 * hpm - 63)))
  dtheta = 30 * np.exp(-(((hpm - 275) / 25) ** 2))
  Cpm7 = Cpm ** 7
  Rc = 2 * np.sqrt(Cpm7 / (Cpm7 + 25.0 ** 7))
  Sl = 1 + 0.015 * (Lpm - 50) ** 2 / np.sqrt(20 + (Lpm - 50) ** 2)
  Sc = 1 + 0.045 * Cpm
  Sh = 1 + 0.015 * Cpm * T
  Rt = -np.sin(np.radians(2 * dtheta)) * Rc
  return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2
                 + Rt * (dCp / Sc) * (dHp / Sh))


def main():
  ap = argparse.ArgumentParser(description=__doc__)
  ap.add_argument('reference')
  ap.add_argument('test')
  ap.add_argument('--max', type=float, default=2.3, help='max dE allowed (default 2.3)')
  ap.add_argument('--mean', type=float, default=0.77, help='mean dE allowed (default 0.77)')
  ap.add_argument('--info', action='store_true', help='report only, always exit 0')
  args = ap.parse_args()

  ref, tst = _read_tiff(args.reference), _read_tiff(args.test)
  if ref.shape != tst.shape:
    print(f'size mismatch: {ref.shape[1]}x{ref.shape[0]} vs {tst.shape[1]}x{tst.shape[0]}')
    return 1
  de = _ciede2000(_srgb_to_lab(ref), _srgb_to_lab(tst))
  dmax, dmean = float(de.max()), float(de.mean())
  above = float((de > args.max).mean()) * 100
  ok = dmax <= args.max and dmean <= args.mean
  print(f'max dE {dmax:.4f}  mean dE {dmean:.5f}  p99.9 {float(np.percentile(de, 99.9)):.4f}'
        f'  above {args.max}: {above:.4f} %' + ('' if args.info else f'  {"OK" if ok else "FAIL"}'))
  return 0 if ok or args.info else 1


if __name__ == '__main__':
  sys.exit(main())
