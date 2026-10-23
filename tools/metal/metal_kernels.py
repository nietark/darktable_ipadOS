#!/usr/bin/env python3
#
#   This file is part of darktable,
#   Copyright (C) 2026 darktable developers.
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
"""Build-time tables for the Metal runtime in src/common/metal.

  metal_kernels.py check KERNELDIR [--strict]
      list the Metal ports whose OpenCL source changed since they were made;
      with --strict, exit 1 if there are any

  metal_kernels.py programs KERNELDIR OUT.c [--metallib-dir DIR]
      the dtcl_programs[] table: every program of programs.conf with the
      hash darktable's source is recognized by, and for each Metal port its
      kernels and their argument kinds, plus the compiled .metallib files

  metal_kernels.py emu KERNELDIR OUTDIR
      the C++ sources that let the emulator backend call the Metal kernels
"""

import hashlib
import os
import re
import sys

PORT_DIR = 'metal'
POSITION_PARAMS = ('dt_gid', 'dt_lid', 'dt_grp', 'dt_lsz', 'dt_gsz')


def fnv1a64(data):
  h = 0xcbf29ce484222325
  for b in data:
    h ^= b
    h = (h * 0x100000001b3) & 0xffffffffffffffff
  return h


def programs(kerneldir):
  with open(os.path.join(kerneldir, 'programs.conf')) as f:
    for line in f:
      line = line.split('#')[0].split()
      if len(line) == 2:
        yield line[0]


def split_top(s):
  # only used on parameter lists, where < > are template brackets
  out, depth, cur = [], 0, ''
  for ch in s:
    if ch in '([<':
      depth += 1
    elif ch in ')]>':
      depth -= 1
    if ch == ',' and depth == 0:
      out.append(cur.strip())
      cur = ''
    else:
      cur += ch
  if cur.strip():
    out.append(cur.strip())
  return out


def matching(text, i, o, c):
  depth = 0
  for j in range(i, len(text)):
    if text[j] == o:
      depth += 1
    elif text[j] == c:
      depth -= 1
      if depth == 0:
        return j
  raise ValueError('unbalanced')


def parse_port(path):
  """(ported_md5, [(kernel, argkinds, uses_barrier)])"""
  with open(path) as f:
    text = f.read()
  m = re.search(r'^// ported-from-md5: ([0-9a-f]{32})', text, re.M)
  if not m:
    raise ValueError('%s: no ported-from-md5 line' % path)
  ported_md5 = m.group(1)
  kernels = []
  for k in re.finditer(r'^kernel\s+void\s+(\w+)\s*\(', text, re.M):
    name = k.group(1)
    p_close = matching(text, k.end() - 1, '(', ')')
    b_open = text.index('{', p_close)
    body = text[b_open:matching(text, b_open, '{', '}')]
    kinds = ''
    params = split_top(text[k.end():p_close])
    for i, p in enumerate(params):
      var = re.search(r'(\w+)\s*\[\[', p)
      if var and var.group(1) in POSITION_PARAMS:
        continue
      a = re.search(r'\[\[\s*(buffer|texture|threadgroup)\((\d+)\)\s*\]\]', p)
      if not a:
        raise ValueError('%s: %s argument %d has no binding: %s' % (path, name, i, p))
      if int(a.group(2)) != i:
        # dtcl binds clSetKernelArg(k, n, ...) to Metal index n
        raise ValueError('%s: %s argument %d is bound at index %s' % (path, name, i, a.group(2)))
      if a.group(1) == 'texture':
        kinds += 'T'
      elif a.group(1) == 'threadgroup':
        kinds += 'L'
      elif '&' in p.split('[[')[0]:
        kinds += 'V'
      else:
        kinds += 'B'
    kernels.append((name, kinds, 'barrier(' in body))
  return ported_md5, kernels


def collect(kerneldir):
  out = []
  for prog in programs(kerneldir):
    with open(os.path.join(kerneldir, prog), 'rb') as f:
      data = f.read()
    base = os.path.splitext(prog)[0]
    port = os.path.join(kerneldir, PORT_DIR, base + '.metal')
    ported_md5, kernels = parse_port(port) if os.path.exists(port) else (None, [])
    out.append(dict(name=prog, base=base, hash=fnv1a64(data), md5=hashlib.md5(data).hexdigest(),
                    ported_md5=ported_md5, kernels=kernels))
  return out


def cmd_check(kerneldir, strict):
  stale = [p for p in collect(kerneldir) if p['ported_md5'] and p['ported_md5'] != p['md5']]
  for p in stale:
    print('warning: data/kernels/%s changed since its Metal port was made (ported from %s, now %s);'
          ' the Metal runtime will not use the port until it is updated'
          % (p['name'], p['ported_md5'], p['md5']))
  return 1 if stale and strict else 0


def c_bytes(data):
  lines = []
  for i in range(0, len(data), 16):
    lines.append('  ' + ''.join('%d,' % b for b in data[i:i + 16]))
  return '\n'.join(lines)


def cmd_programs(kerneldir, out_path, metallib_dir=None):
  progs = collect(kerneldir)
  o = ['// generated by tools/metal/metal_kernels.py, do not edit', '',
       '#include "dtcl.h"', '']
  for p in progs:
    if not p['kernels']:
      continue
    o.append('static const dtcl_kernel_info_t _kernels_%s[] = {' % p['base'])
    for name, kinds, barrier in p['kernels']:
      o.append('  { "%s", "%s", %d },' % (name, kinds, 1 if barrier else 0))
    o.append('};')
    if metallib_dir:
      with open(os.path.join(metallib_dir, p['base'] + '.metallib'), 'rb') as f:
        o.append('static const unsigned char _metallib_%s[] = {\n%s\n};' % (p['base'], c_bytes(f.read())))
    o.append('')
  o.append('const dtcl_program_info_t dtcl_programs[] = {')
  for p in progs:
    if p['kernels']:
      lib = ('_metallib_%s, sizeof(_metallib_%s)' % (p['base'], p['base'])) if metallib_dir else 'NULL, 0'
      o.append('  { "%s", 0x%016xull, "%s", "%s", _kernels_%s, %d, %s },'
               % (p['name'], p['hash'], p['md5'], p['ported_md5'], p['base'], len(p['kernels']), lib))
    else:
      o.append('  { "%s", 0x%016xull, "%s", NULL, NULL, 0, NULL, 0 },' % (p['name'], p['hash'], p['md5']))
  o.append('};')
  o.append('const int dtcl_num_programs = %d;' % len(progs))
  with open(out_path, 'w') as f:
    f.write('\n'.join(o) + '\n')
  return 0


FLOAT_RE = re.compile(r'(?<![\w.])((?:\d+\.\d*|\.\d+)(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+)(?![\w.])')
CTOR_RE = re.compile(r'\b((?:float|u?int|u?char|u?short)[234])\(')


def cmd_emu(kerneldir, outdir):
  # clang's vector types have no constructor syntax: float4(a, b) becomes
  # make_float4(a, b), see src/common/metal/emu/metal_stdlib
  srcdir = os.path.join(outdir, 'src')
  os.makedirs(srcdir, exist_ok=True)
  portdir = os.path.join(kerneldir, PORT_DIR)
  for name in os.listdir(portdir):
    if name.endswith('.metal') or name.endswith('.h'):
      with open(os.path.join(portdir, name)) as f:
        text = CTOR_RE.sub(r'make_\1(', f.read())
      # the shim defines threadgroup away, which must not reach the attribute
      text = text.replace('[[threadgroup(', '[[dtcl_threadgroup(')
      # unsuffixed floating constants are float in Metal and double in C++
      text = FLOAT_RE.sub(r'\1f', text)
      dst = os.path.join(srcdir, name)
      if not os.path.exists(dst) or open(dst).read() != text:
        with open(dst, 'w') as f:
          f.write(text)

  progs = [p for p in collect(kerneldir) if p['kernels']]
  for p in progs:
    o = ['// generated by tools/metal/metal_kernels.py, do not edit', '',
         '#include "dtcl_emu.h"', '',
         '// every port in its own namespace, as every port is its own Metal library',
         'namespace dtcl_emu_%s {' % p['base'],
         'DTCL_EMU_USING',
         '#include "%s.metal"' % p['base'],
         '}', '',
         'extern const dtcl_emu_kernel_t dtcl_emu_kernels_%s[] = {' % p['base']]
    for name, _, _ in p['kernels']:
      o.append('  { "%s", dtcl_emu_invoker(dtcl_emu_%s::%s) },' % (name, p['base'], name))
    o.append('  { nullptr, nullptr }')
    o.append('};')
    with open(os.path.join(outdir, 'emu_%s.cc' % p['base']), 'w') as f:
      f.write('\n'.join(o) + '\n')

  o = ['// generated by tools/metal/metal_kernels.py, do not edit', '',
       '#include "dtcl_emu.h"', '']
  for p in progs:
    o.append('extern const dtcl_emu_kernel_t dtcl_emu_kernels_%s[];' % p['base'])
  o.append('')
  o.append('const dtcl_emu_program_t dtcl_emu_programs[] = {')
  for p in progs:
    o.append('  { "%s", dtcl_emu_kernels_%s },' % (p['name'], p['base']))
  o.append('  { nullptr, nullptr }')
  o.append('};')
  with open(os.path.join(outdir, 'emu_registry.cc'), 'w') as f:
    f.write('\n'.join(o) + '\n')
  return 0


def main(argv):
  if len(argv) >= 3 and argv[1] == 'check':
    return cmd_check(argv[2], '--strict' in argv)
  if len(argv) >= 4 and argv[1] == 'programs':
    libdir = argv[argv.index('--metallib-dir') + 1] if '--metallib-dir' in argv else None
    return cmd_programs(argv[2], argv[3], libdir)
  if len(argv) == 4 and argv[1] == 'emu':
    return cmd_emu(argv[2], argv[3])
  print(__doc__)
  return 2


if __name__ == '__main__':
  sys.exit(main(sys.argv))
