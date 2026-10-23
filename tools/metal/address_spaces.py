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
# reads clang's JSON AST dump of an emulator source on stdin and lists the
# pointer and reference declarations in the ports under SRCDIR that have no
# address space. Metal requires one on every pointer; the emulator compiles
# without, so check_ports.sh runs this. A `thread` qualifier expands to
# nothing in the emulator, so it is looked for in the source line instead.
#
#   address_spaces.py SRCDIR < ast.json

import json
import re
import sys

KINDS = ('ParmVarDecl', 'VarDecl', 'FieldDecl', 'TypedefDecl', 'CStyleCastExpr')


def main():
  srcdir = sys.argv[1].rstrip('/') + '/'
  root = json.load(sys.stdin)
  lines = {}
  cur = {'file': None, 'line': None}
  hits = set()

  def upd1(loc):
    cur['file'] = loc.get('file', cur['file'])
    cur['line'] = loc.get('line', cur['line'])
    return cur['file'], cur['line']

  # the dump leaves out file and line when they did not change since the
  # location printed before, so they are tracked in print order
  def upd(loc):
    if not loc:
      return None, None
    if 'spellingLoc' in loc:
      upd1(loc['spellingLoc'])
      return upd1(loc['expansionLoc'])
    return upd1(loc)

  def source_line(path, n):
    if path not in lines:
      with open(path) as f:
        lines[path] = f.read().split('\n')
    text = lines[path]
    return text[n - 1] if 0 < n <= len(text) else ''

  stack = [root]
  while stack:
    node = stack.pop()
    if not isinstance(node, dict):
      continue
    path, line = upd(node.get('loc'))
    rng = node.get('range', {})
    upd(rng.get('begin'))
    upd(rng.get('end'))
    qual = node.get('type', {}).get('qualType', '')
    # an unnamed parameter is one of an implicit copy or move constructor
    if (node.get('kind') in KINDS and not node.get('isImplicit')
        and (node['kind'] != 'ParmVarDecl' or 'name' in node)
        and path and path.startswith(srcdir)
        and ('*' in qual or '&' in qual)
        and not re.search(r'\b(device|constant|threadgroup)\b|address_space', qual)):
      text = source_line(path, line)
      if not re.search(r'\bthread\b', text):
        hits.add((path[len(srcdir):], line, node.get('name', node['kind']), qual))
    # children in order, so locations are seen as they were printed
    stack.extend(reversed(node.get('inner', [])))

  for path, line, name, qual in sorted(hits):
    print(f'{path}:{line}: {name} has no address space ({qual})')
  return 1 if hits else 0


if __name__ == '__main__':
  sys.exit(main())
