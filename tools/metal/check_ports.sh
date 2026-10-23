#!/bin/bash
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
# check the Metal kernel ports without a Mac
#
#   tools/metal/check_ports.sh [PORT...]
#
# compiles every port (or the named ones, e.g. basic sigmoid) with clang++
# against the emulator's imitation of metal_stdlib, once normally and once
# with address spaces as clang address spaces, and lists pointer and
# reference declarations without an address space, which Metal rejects.
# It does not replace a build with Apple's Metal compiler.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)
CXX=${CXX:-clang++}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/dt-metal-check.XXXXXX")
trap 'rm -rf "$OUT"' EXIT

python3 "$HERE/metal_kernels.py" emu "$SRC/data/kernels" "$OUT" || exit 1

ports=("$@")
if [[ ${#ports[@]} == 0 ]]; then
  for f in "$SRC"/data/kernels/metal/*.metal; do
    b=$(basename "$f"); ports+=("${b%.metal}")
  done
fi

FLAGS=(-std=c++17 -fsyntax-only -Wno-unknown-attributes
       -I "$SRC/src/common/metal" -I "$SRC/src/common/metal/emu" -I "$OUT/src"
       -I "$SRC/src/common" -I "$SRC/src/external/OpenCL")

fail=0
for p in "${ports[@]}"; do
  echo "== $p"
  "$CXX" "${FLAGS[@]}" "$OUT/emu_$p.cc" || fail=1
  "$CXX" "${FLAGS[@]}" -DDTCL_EMU_STRICT "$OUT/emu_$p.cc" || fail=1
  "$CXX" "${FLAGS[@]}" -DDTCL_EMU_STRICT -Xclang -ast-dump=json "$OUT/emu_$p.cc" 2>/dev/null \
    | python3 "$HERE/address_spaces.py" "$OUT/src" || fail=1
done

[[ $fail == 0 ]] && echo "all ports passed" || echo "some ports FAILED"
exit $fail
