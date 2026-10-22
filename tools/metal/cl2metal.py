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
"""Mechanical first pass of an OpenCL C to Metal Shading Language port.

Converts one .cl program (or an OpenCL header) into MSL and keeps only the
kernels named with --kernel. The output is a starting point that is then
reviewed and edited by hand; it is not regenerated at build time.

Kernel arguments keep their OpenCL position as their Metal binding index:
argument n becomes [[buffer(n)]], [[texture(n)]] or [[threadgroup(n)]], so
the runtime can bind clSetKernelArg(kernel, n, ...) without a lookup table.
Scalar arguments become `constant T &` buffers and are copied into a local
of the original name, because some kernels assign to their parameters.
"""

import argparse
import hashlib
import os
import re
import sys

VEC = r'(?:float|int|uint|uchar|char|short|ushort)(?:2|3|4|8|16)'

HEADER_MAP = {
  'common.h': None,  # dt_metal.h, included first by every port
  'colorspace.h': 'colorspace.metal.h',
  'color_conversion.h': 'color_conversion.metal.h',
  'rgb_norms.h': 'rgb_norms.metal.h',
  'hdr-transfer.h': None,  # included by dt_metal.h
}

# functions missing from, or not guaranteed by, the Metal standard library;
# dt_metal.h has precise implementations under these names
RENAMES = {
  'cbrt': 'dt_cbrt',
  'log1p': 'dt_log1p',
  'expm1': 'dt_expm1',
  'hypot': 'dt_hypot',
}


def find_matching(text, start, open_ch='(', close_ch=')'):
  depth = 0
  for i in range(start, len(text)):
    if text[i] == open_ch:
      depth += 1
    elif text[i] == close_ch:
      depth -= 1
      if depth == 0:
        return i
  raise ValueError('unbalanced %s at %d' % (open_ch, start))


def split_top(s, sep=','):
  out, depth, cur = [], 0, ''
  for ch in s:
    if ch in '([':
      depth += 1
    elif ch in ')]':
      depth -= 1
    if ch == sep and depth == 0:
      out.append(cur)
      cur = ''
    else:
      cur += ch
  if cur.strip():
    out.append(cur)
  return [o.strip() for o in out]


KERNEL_RE = re.compile(r'(?:__kernel|kernel)\s+void\s+(\w+)\s*\(')


def find_kernels(text):
  """yield (name, start, params_open, params_close, body_open, body_close)"""
  pos = 0
  while True:
    m = KERNEL_RE.search(text, pos)
    if not m:
      return
    # skip matches inside comments or identifiers
    line_start = text.rfind('\n', 0, m.start()) + 1
    if '//' in text[line_start:m.start()]:
      pos = m.end()
      continue
    p_open = m.end() - 1
    p_close = find_matching(text, p_open)
    b_open = text.index('{', p_close)
    b_close = find_matching(text, b_open, '{', '}')
    yield m.group(1), m.start(), p_open, p_close, b_open, b_close
    pos = b_close + 1


COMMENT_RE = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)


def body_subst(text):
  # leave comments as they are
  out, pos = '', 0
  for m in COMMENT_RE.finditer(text):
    out += _code_subst(text[pos:m.start()]) + m.group(0)
    pos = m.end()
  return out + _code_subst(text[pos:])


def _code_subst(text):
  # address spaces and image qualifiers
  text = re.sub(r'\b__global\b|\bglobal\b', 'device', text)
  text = re.sub(r'\b__local\b|\blocal\b', 'threadgroup', text)
  text = re.sub(r'\b__constant\b', 'constant', text)
  text = re.sub(r'\b(?:__)?read_only\s+image2d_t\b', 'texture2d<float, access::read>', text)
  text = re.sub(r'\b(?:__)?write_only\s+image2d_t\b', 'texture2d<float, access::write>', text)
  text = re.sub(r'\bunsigned\s+char\b', 'uchar', text)
  text = re.sub(r'\bunsigned\s+int\b', 'uint', text)
  text = re.sub(r'#pragma\s+OPENCL.*', '', text)
  # vector literals (float4)(a, b, c, d) and (const float4)(...)
  text = re.sub(r'\((?:const\s+)?(' + VEC + r')\)[ \t]*\(', r'\1(', text)
  # scalar splats (float4)x
  text = re.sub(r'\((?:const\s+)?(' + VEC + r')\)[ \t]*(-?[\w.]+)', r'\1(\2)', text)
  for old, new in RENAMES.items():
    text = re.sub(r'\b' + old + r'\s*\(', new + '(', text)
  return text


def convert_signature(name, params, body):
  args = split_top(params)
  sig, prelude = [], []
  for i, a in enumerate(args):
    a = ' '.join(a.split())
    # "const global T *p" is the same as "global const T *p"
    a = re.sub(r'^const\s+((?:__)?(?:global|constant|local))\s+', r'\1 const ', a)
    m = re.match(r'(?:__)?(read_only|write_only)\s+image2d_t\s+(\w+)$', a)
    if m:
      kind, var = m.groups()
      if kind == 'write_only':
        sig.append('texture2d<float, access::write> %s [[texture(%d)]]' % (var, i))
      else:
        elem = 'uint' if re.search(r'read_imageui\s*\(\s*' + var + r'\b', body) else 'float'
        sig.append('texture2d<%s, access::read> %s [[texture(%d)]]' % (elem, var, i))
      continue
    # pointer to array: global const float (*const a)[3]
    m = re.match(r'(?:__)?(global|constant)\s+(.*?)\(\s*\*\s*(?:const\s+)?(\w+)\s*\)\s*\[(\d+)\]$', a)
    if m:
      space, base, var, n = m.groups()
      space = 'device' if space == 'global' else 'constant'
      base = body_subst(base).strip()
      sig.append('%s %s *%s_flat [[buffer(%d)]]' % (space, base, var, i))
      prelude.append('  %s %s (*const %s)[%s] = (%s %s (*)[%s])%s_flat;'
                     % (space, base, var, n, space, base, n, var))
      continue
    m = re.match(r'(?:__)?(global|constant|local)\s+(.*?)\s*\*\s*(?:const\s+)?(?:restrict\s+)?(\w+)$', a)
    if m:
      space, base, var = m.groups()
      base = body_subst(base).strip()
      if space == 'local':
        sig.append('threadgroup %s *%s [[threadgroup(%d)]]' % (base, var, i))
      else:
        sig.append('%s %s *%s [[buffer(%d)]]' % ('device' if space == 'global' else 'constant', base, var, i))
      continue
    m = re.match(r'(?:const\s+)?([\w ]+?)\s+(\w+)$', a)
    if m:
      typ, var = m.groups()
      typ = body_subst(typ).strip()
      sig.append('constant %s &%s_arg [[buffer(%d)]]' % (typ, var, i))
      prelude.append('  const %s %s = %s_arg;' % (typ, var, var)
                     if a.startswith('const') else
                     '  %s %s = %s_arg;' % (typ, var, var))
      continue
    raise ValueError('kernel %s: cannot convert argument "%s"' % (name, a))
  sig += ['uint3 dt_gid [[thread_position_in_grid]]',
          'uint3 dt_lid [[thread_position_in_threadgroup]]',
          'uint3 dt_grp [[threadgroup_position_in_grid]]',
          'uint3 dt_lsz [[threads_per_threadgroup]]',
          'uint3 dt_gsz [[threads_per_grid]]']
  return sig, prelude


FUNC_RE = re.compile(r'^(?:static\s+|inline\s+|const\s+)*[A-Za-z_][\w<>, :]*?[\s*]+(\w+)\s*\(', re.M)


def find_functions(text):
  """yield (name, start, end) of top-level non-kernel function definitions"""
  depth, i, n = 0, 0, len(text)
  pos = 0
  while True:
    m = FUNC_RE.search(text, pos)
    if not m:
      return
    if m.group(1) in ('if', 'for', 'while', 'switch', 'return') or text[:m.start()].count('{') != text[:m.start()].count('}'):
      pos = m.end()
      continue
    p_close = find_matching(text, m.end() - 1)
    rest = text[p_close + 1:].lstrip()
    if not rest.startswith('{'):
      pos = p_close + 1
      continue
    b_open = text.index('{', p_close)
    b_close = find_matching(text, b_open, '{', '}')
    yield m.group(1), m.start(), b_close + 1
    pos = b_close + 1


def prune_helpers(text):
  """drop helper functions that no kept kernel reaches"""
  funcs = {name: (s, e) for name, s, e in find_functions(text)
           if not re.match(r'\s*kernel\s+void', text[s:e])}
  roots = [text[s:e] for name, s, e in find_functions(text) if name not in funcs]
  ident = re.compile(r'\b(\w+)\s*\(')
  live, todo = set(), roots
  while todo:
    src = todo.pop()
    for callee in ident.findall(src):
      if callee in funcs and callee not in live:
        live.add(callee)
        s, e = funcs[callee]
        todo.append(text[s:e])
  # macros can call helpers too; a macro nobody uses keeps its helpers
  # alive, which costs nothing but a little dead code
  todo = re.findall(r'#define(?:\\[ \t]*\n|[^\n])*', text)
  while todo:
    src = todo.pop()
    for callee in ident.findall(src):
      if callee in funcs and callee not in live:
        live.add(callee)
        s, e = funcs[callee]
        todo.append(text[s:e])
  dead = sorted((funcs[n] for n in funcs if n not in live), reverse=True)
  for s, e in dead:
    text = text[:s] + text[e:]
  return text


def convert(text, keep, is_header):
  out, pos, found = '', 0, []
  for name, k_start, p_open, p_close, b_open, b_close in list(find_kernels(text)):
    out += text[pos:k_start]
    pos = b_close + 1
    if name not in keep:
      # drop the kernel and the blank line that separated it from the next one
      while text[pos:pos + 1] == '\n' and out.endswith('\n\n'):
        pos += 1
      continue
    found.append(name)
    body = text[b_open + 1:b_close]
    sig, prelude = convert_signature(name, text[p_open + 1:p_close], body)
    out += 'kernel void %s(%s)\n{\n%s%s}' % (
      name, ',\n  '.join(sig), '\n'.join(prelude) + ('\n' if prelude else ''), body_subst(body))
  out += text[pos:]
  if not is_header:
    out = prune_helpers(out)
  missing = set(keep) - set(found)
  if missing:
    raise ValueError('kernels not found: %s' % ', '.join(sorted(missing)))

  # everything outside kernel bodies (helpers, headers) gets the same treatment;
  # kernel bodies were converted above and survive a second pass unchanged
  out = body_subst(out)

  def inc(m):
    name = m.group(1)
    if name in HEADER_MAP:
      return '#include "%s"' % HEADER_MAP[name] if HEADER_MAP[name] else ''
    return '// #include "%s" (not needed by the ported kernels)' % name
  out = re.sub(r'#include\s+"([^"]+)"', inc, out)
  if not is_header:
    out = re.sub(r'(\*/\s*\n)', r'\1\n#include <metal_stdlib>\nusing namespace metal;\n#include "dt_metal.h"\n', out, count=1)
  return out


def main():
  ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
  ap.add_argument('input')
  ap.add_argument('output')
  ap.add_argument('--kernel', action='append', default=[])
  args = ap.parse_args()

  with open(args.input, 'rb') as f:
    raw = f.read()
  md5 = hashlib.md5(raw).hexdigest()
  is_header = args.input.endswith('.h')
  text = convert(raw.decode('utf-8'), args.kernel, is_header)

  src = os.path.basename(args.input)
  stamp = ('// Metal port of data/kernels/%s\n'
           '// ported-from-md5: %s\n' % (src, md5))
  if args.kernel:
    stamp += '// ported kernels: %s\n' % ', '.join(args.kernel)
  with open(args.output, 'w') as f:
    f.write(stamp + text)


if __name__ == '__main__':
  sys.exit(main())
