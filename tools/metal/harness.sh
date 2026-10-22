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
# verification harness for the Metal kernel ports
#
# renders test raws with the default edit twice, once on the CPU and once
# through the Metal runtime (or its Linux emulator) loaded as darktable's
# OpenCL library, and compares both with CIEDE2000 against each other and
# against reference renders. Only the GPU against CPU comparison decides
# the exit status.
#
#   tools/metal/harness.sh --cli BUILD/bin/darktable-cli \
#       --cl-library BUILD/lib/darktable/libdarktable_metal.so \
#       [--images DIR] [--reference DIR] [--work DIR] [--only NAME] \
#       [--max 2.3] [--mean 0.77] [--diffstat]
#
#   tools/metal/harness.sh --cli ... --cl-library ... --integration [TEST...]
#       runs src/tests/integration/run (all tests, or the named ones) with
#       its OpenCL pass going through the runtime instead
#
# everything runs in a fresh work directory with its own configdir,
# cachedir and an in-memory library, on copies of the raws. Nothing reads
# or writes the configuration or library of an installed darktable.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)

CLI=
CL_LIBRARY=
IMAGES=$SRC/src/tests/integration/images
REFERENCE=
WORK=
ONLY=
MAX=2.3
MEAN=0.77
DIFFSTAT=no
INTEGRATION=no
TESTS=()

usage()
{
  sed -n '19,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --cli) CLI=$2; shift ;;
    --cl-library) CL_LIBRARY=$2; shift ;;
    --images) IMAGES=$2; shift ;;
    --reference) REFERENCE=$2; shift ;;
    --work) WORK=$2; shift ;;
    --only) ONLY=$2; shift ;;
    --max) MAX=$2; shift ;;
    --mean) MEAN=$2; shift ;;
    --diffstat) DIFFSTAT=yes ;;
    --integration) INTEGRATION=yes ;;
    -h|--help) usage ;;
    -*) echo "unknown option $1"; usage ;;
    *) TESTS+=("$1") ;;
  esac
  shift
done

[[ -x $CLI ]] || { echo "--cli must name a darktable-cli executable"; exit 2; }
[[ -f $CL_LIBRARY ]] || { echo "--cl-library must name the Metal runtime library"; exit 2; }
[[ -d $IMAGES ]] || { echo "no image directory $IMAGES (git submodule update --init src/tests/integration)"; exit 2; }

CL_LIBRARY=$(cd "$(dirname "$CL_LIBRARY")" && pwd)/$(basename "$CL_LIBRARY")
[[ -n $WORK ]] || WORK=$(mktemp -d "${TMPDIR:-/tmp}/dt-metal-harness.XXXXXX")
mkdir -p "$WORK/raws" "$WORK/out"
WORK=$(cd "$WORK" && pwd)

# a configdir per run, so the CPU and GPU passes cannot share a kernel
# cache or a device blacklist entry written by the other
run_cli()
{
  local name=$1 raw=$2 out=$3; shift 3
  local cfg=$WORK/config-$name
  rm -rf "$cfg"; mkdir -p "$cfg"
  rm -f "$out"
  # the same core options as src/tests/integration/run, so results line
  # up with the integration test expectations
  "$CLI" --width 2048 --height 2048 --hq true --apply-custom-presets false \
    "$raw" "$out" \
    --core --configdir "$cfg" --cachedir "$cfg/cache" --library :memory: \
    --conf host_memory_limit=8192 \
    --conf resourcelevel=reference \
    --conf worker_threads=4 -t 4 \
    --conf opencl_fast=FALSE \
    --conf plugins/lighttable/export/force_lcms2=FALSE \
    --conf plugins/lighttable/export/pixel_interpolator=lanczos3 \
    --conf plugins/lighttable/export/pixel_interpolator_warp=bicubic \
    --conf plugins/lighttable/export/iccintent=0 \
    --conf plugins/imageio/format/tiff/bpp=16 \
    --conf plugins/imageio/format/tiff/compress=0 \
    "$@"
}

if [[ $INTEGRATION == yes ]]; then
  # the integration tests take the CLI from DARKTABLE_CLI and run it with
  # the --core options last, so a wrapper can append the runtime's own.
  # They use their own configdir, /tmp/darktable-test
  wrapper=$WORK/darktable-cli
  {
    echo '#!/bin/bash'
    printf 'exec %q "$@" --conf %q' "$CLI" "opencl_library=$CL_LIBRARY"
    echo ' --conf clplatform_darktablemetal=TRUE --conf clplatform_darktablemetalemulator=TRUE'
  } > "$wrapper"
  chmod +x "$wrapper"
  cd "$SRC/src/tests/integration" || exit 2
  DARKTABLE_CLI=$wrapper ./run ${TESTS[@]+"${TESTS[@]}"}
  exit $?
fi

GPU_OPTIONS=(--conf opencl=TRUE
             --conf "opencl_library=$CL_LIBRARY"
             --conf clplatform_darktablemetal=TRUE
             --conf clplatform_darktablemetalemulator=TRUE
             --conf opencl_scheduling_profile=default)

export OMP_THREAD_LIMIT=4

fail=0

for img in "$IMAGES"/*; do
  [[ -f $img ]] || continue
  base=$(basename "$img")
  stem=${base%.*}
  [[ -n $ONLY && $stem != "$ONLY" ]] && continue

  echo "== $base"
  cp "$img" "$WORK/raws/$base"
  raw=$WORK/raws/$base
  cpu=$WORK/out/${stem}_cpu.tif
  gpu=$WORK/out/${stem}_gpu.tif

  run_cli cpu "$raw" "$cpu" --disable-opencl > "$WORK/out/${stem}_cpu.log" 2>&1
  [[ -f $cpu ]] || { echo "   CPU render failed, see $WORK/out/${stem}_cpu.log"; fail=1; continue; }

  extra=()
  # --dump-diff-pipe with a name no module has: without it, the diffstat
  # code passes a NULL list to dt_str_commasubstring() and crashes
  [[ $DIFFSTAT == yes ]] && extra=(--opencl-diffstat --dump-diff-pipe none)
  run_cli gpu "$raw" "$gpu" "${GPU_OPTIONS[@]}" -d opencl -d pipe ${extra[@]+"${extra[@]}"} \
    > "$WORK/out/${stem}_gpu.log" 2>&1
  [[ -f $gpu ]] || { echo "   GPU render failed, see $WORK/out/${stem}_gpu.log"; fail=1; continue; }

  # darktable falls back to the CPU per module when a kernel is missing or
  # fails, which would otherwise pass as a perfect match
  if ! grep -q "opencl library '$CL_LIBRARY'" "$WORK/out/${stem}_gpu.log"; then
    echo "   the Metal runtime was not loaded, see $WORK/out/${stem}_gpu.log"
    fail=1
    continue
  fi
  fallback=$(grep "couldn't run module on GPU" "$WORK/out/${stem}_gpu.log" \
               | sed 's/.*\] *\([a-z0-9_]*\).*/\1/' | sort -u | tr '\n' ' ')
  [[ -n $fallback ]] && echo "   CPU fallback: $fallback"

  printf '   gpu vs cpu       '
  python3 "$HERE/dtdiff.py" "$cpu" "$gpu" --max "$MAX" --mean "$MEAN" || fail=1
  if [[ -n $REFERENCE && -f $REFERENCE/${stem}_default.tif ]]; then
    # for information only: a reference made by another build or with other
    # export settings differs from both renders by the same amount
    printf '   cpu vs reference '
    python3 "$HERE/dtdiff.py" "$REFERENCE/${stem}_default.tif" "$cpu" --max "$MAX" --info
    printf '   gpu vs reference '
    python3 "$HERE/dtdiff.py" "$REFERENCE/${stem}_default.tif" "$gpu" --max "$MAX" --info
  fi
  if [[ $DIFFSTAT == yes ]]; then
    grep "OpenCL diff stats" "$WORK/out/${stem}_gpu.log" | sed 's/^/   /'
  fi
done

echo
echo "renders and logs are in $WORK/out"
[[ $fail == 0 ]] && echo "all checks passed" || echo "some checks FAILED"
exit $fail
