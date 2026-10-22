# Metal kernels: prototype

An experimental way to run darktable's GPU code path on Apple's Metal
instead of OpenCL, aimed at an iPad port. Nothing here changes how
darktable builds or behaves unless you turn it on.

## How it fits together

darktable reaches OpenCL only through the function table that
`src/common/dlopencl.c` loads from a shared library, chosen by the
`opencl_library` preference. The Metal runtime is such a library:

- `src/common/metal/dtcl.c` exports the 43 `cl*` functions darktable uses
  and keeps the bookkeeping (objects, arguments, device queries)
- `src/common/metal/dtcl_metal.m` runs the work on the GPU through Metal
- `src/common/metal/dtcl_emu.cc` runs the same Metal sources on the CPU,
  so the ports and the runtime can be tested on Linux without a Mac
- `data/kernels/metal/*.metal` are the hand-checked ports of the OpenCL
  kernels the default edit uses; programs and kernels without a port build
  "successfully" with no kernels, so darktable falls back to the CPU for
  that module, as it does after any OpenCL failure

Each port records the md5 of the `.cl` file it was made from. When the
OpenCL source changes, the build prints a warning and the runtime refuses
the stale port (set `DT_METAL_ALLOW_STALE=1` to use it anyway). Set
`DT_METAL_DEBUG=1` for the runtime's own log.

The ports are compiled with `-fno-fast-math`, and the runtime with
`-fno-fast-math -ffp-contract=off`, to match darktable's reference
(`opencl_fast=FALSE`) results.

## Ported kernels

| program | kernels |
|---|---|
| basic.cl | rawprepare_1f, rawprepare_1f_unnormalized, whitebalance_1f, whitebalance_1f_xtrans, whitebalance_4f, highlights_1f_clip, highlights_initmask, highlights_dilatemask, highlights_chroma, highlights_opposed, exposure, colorin_unbound, colorout, flip, interpolation_resample, interpolation_copy |
| demosaic_ppg.cl | border_interpolate, ppg_demosaic_green, ppg_demosaic_redblue, clip_and_zoom_demosaic_half_size |
| demosaic_rcd.cl | rcd_populate, rcd_step_1, rcd_step_2, rcd_step_3, rcd_step_4_0 to rcd_step_4_3, rcd_write_output |
| channelmixer.cl | channelmixerrgb_CAT16 |
| sigmoid.cl | sigmoid_loglogistic_per_channel |
| colorspaces.cl | colorspaces_transform_lab_to_rgb_matrix, colorspaces_transform_rgb_matrix_to_lab |

X-Trans demosaicing (Markesteijn) is not ported; X-Trans raws run that
one module on the CPU.

## A separate dev build

Never point an everyday darktable at this. Build a separate copy, install
it to its own prefix, and run it only with its own configuration and
library:

```bash
cmake -S . -B build-metal -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=$HOME/dt-metal -DUSE_METAL=ON
cmake --build build-metal
cmake --install build-metal
```

`USE_METAL` needs macOS with Xcode's command line tools (`xcrun metal`).
The runtime lands in `build-metal/lib/darktable/libdarktable_metal.so`
(CMake's name for the module; it is a Mach-O bundle on macOS).

To try it interactively, always with throwaway directories:

```bash
mkdir -p /tmp/dt-metal
$HOME/dt-metal/bin/darktable --configdir /tmp/dt-metal/config \
    --cachedir /tmp/dt-metal/cache --library /tmp/dt-metal/library.db \
    --conf opencl=TRUE \
    --conf opencl_library=$HOME/dt-metal/lib/darktable/libdarktable_metal.so \
    --conf clplatform_darktablemetal=TRUE -d opencl
```

and open copies of raws, not the originals.

## Checking the ports without a Mac

```bash
tools/metal/check_ports.sh
```

compiles every port with clang++ against the emulator's imitation of
`metal_stdlib`, with strict vector math and with address spaces checked,
and lists pointers without an address space. It catches most of what
Apple's compiler would reject, not all of it.

For a full run on Linux, build the emulator with clang (the imitation
relies on clang's vector extension):

```bash
CC=clang CXX=clang++ cmake -S . -B build-emu -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_METAL_EMULATOR=ON
cmake --build build-emu
```

## Verification harness

```bash
tools/metal/harness.sh --cli build-metal/bin/darktable-cli \
    --cl-library build-metal/lib/darktable/libdarktable_metal.so \
    [--reference DIR] [--diffstat]
```

renders every raw in `src/tests/integration/images` (run
`git submodule update --init src/tests/integration` first) with the
default edit, once on the CPU and once through the runtime, and compares
the two with CIEDE2000. It fails when the maximum dE exceeds 2.3 or the
mean exceeds 0.77, and when the runtime did not load. It also lists
modules that fell back to the CPU, which would otherwise pass as a perfect
match. `--diffstat` adds darktable's own per-module CPU/GPU statistics,
and `--reference DIR` compares with `<name>_default.tif` renders made
elsewhere, for information.

Everything happens in a fresh temporary directory with its own configdir,
cachedir and an in-memory library, on copies of the raws. The harness
needs only bash, python3 and numpy. Pass `--cl-library
build-emu/lib/darktable/libdarktable_metal_emu.so` to run it with the
emulator.

With `--integration [TEST...]` the harness runs darktable's integration
tests instead, with their OpenCL pass going through the runtime. They need
what `src/tests/integration/run` needs, and use its configdir,
`/tmp/darktable-test`.
