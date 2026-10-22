/*
    This file is part of darktable,
    Copyright (C) 2026 darktable developers.

    darktable is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    darktable is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with darktable.  If not, see <http://www.gnu.org/licenses/>.
*/

// OpenCL C compatibility layer for the Metal ports in this directory, and
// the Metal version of data/kernels/common.h.
//
// Every ported kernel takes the five uint3 parameters dt_gid, dt_lid,
// dt_grp, dt_lsz and dt_gsz, so the OpenCL work-item functions below can
// stay macros and the kernel bodies keep their OpenCL wording.
//
// The math functions are the plain metal:: ones. They are only as precise
// as darktable's reference OpenCL setting when the library is compiled with
// fast math off (-fno-fast-math), which src/common/metal/CMakeLists.txt does.

#pragma once

#include <metal_stdlib>
using namespace metal;

#define get_global_id(i) ((int)dt_gid[i])
#define get_local_id(i) ((int)dt_lid[i])
#define get_group_id(i) ((int)dt_grp[i])
#define get_local_size(i) ((int)dt_lsz[i])
#define get_global_size(i) ((int)dt_gsz[i])
#define get_num_groups(i) ((int)(dt_gsz[i] / dt_lsz[i]))

#define CLK_LOCAL_MEM_FENCE mem_flags::mem_threadgroup
#define CLK_GLOBAL_MEM_FENCE mem_flags::mem_device
#define barrier(flags) threadgroup_barrier(flags)

#define mad24(a, b, c) ((a) * (b) + (c))
#define mul24(a, b) ((a) * (b))
#define native_recip(x) (1.0f / (x))
// the native_ functions trade precision for speed; Metal gets the precise ones
#define native_sin(x) sin(x)
#define native_cos(x) cos(x)
#define native_exp(x) exp(x)
#define native_log(x) log(x)
#define native_sqrt(x) sqrt(x)
#define native_powr(x, y) powr(x, y)
#define native_divide(x, y) ((x) / (y))
#define convert_float4(v) float4(v)
#define convert_int2(v) int2(v)
#define convert_float2(v) float2(v)
#define as_uint(v) as_type<uint>(v)
#define as_int(v) as_type<int>(v)
#define as_float(v) as_type<float>(v)

// metal has no cbrt, log1p, expm1 or hypot that is guaranteed to be precise
static inline float dt_cbrt(const float x)
{
  if(x == 0.0f || !isfinite(x)) return x;
  const float ax = fabs(x);
  float y = pow(ax, 1.0f / 3.0f);
  // one Newton step brings pow's result to within an ulp of cbrtf()
  y = y - (y * y * y - ax) / (3.0f * y * y);
  return copysign(y, x);
}

static inline float4 dt_cbrt(const float4 x)
{
  return float4(dt_cbrt(x.x), dt_cbrt(x.y), dt_cbrt(x.z), dt_cbrt(x.w));
}

static inline float dt_log1p(const float x)
{
  // Goldberg's trick: exact for small x, where log(1 + x) loses the low bits
  const float u = 1.0f + x;
  return (u == 1.0f) ? x : log(u) * x / (u - 1.0f);
}

static inline float dt_expm1(const float x)
{
  const float u = exp(x);
  if(u == 1.0f) return x;
  const float um1 = u - 1.0f;
  return (um1 == -1.0f) ? -1.0f : um1 * x / log(u);
}

static inline float dt_hypot(const float x, const float y)
{
  const float ax = fabs(x), ay = fabs(y);
  const float m = fmax(ax, ay);
  if(m == 0.0f || !isfinite(m)) return m;
  const float rx = ax / m, ry = ay / m;
  return m * sqrt(rx * rx + ry * ry);
}

// OpenCL samplers; the reads below implement them on access::read textures
enum dt_cl_sampler_t
{
  sampleri, // unnormalized, clamp to edge, nearest
  samplerf, // unnormalized, clamp to edge, linear
  samplerc, // unnormalized, clamp to border, nearest
  samplerA  // unnormalized, no addressing, nearest
};

static inline float4 _dt_texel(texture2d<float, access::read> img, int x, int y)
{
  const int w = (int)img.get_width();
  const int h = (int)img.get_height();
  // metal leaves out-of-range reads undefined; OpenCL clamps to the edge
  return img.read(uint2(clamp(x, 0, w - 1), clamp(y, 0, h - 1)));
}

static inline float4 read_imagef(texture2d<float, access::read> img, const dt_cl_sampler_t s, const int2 p)
{
  if(s == samplerc
     && (p.x < 0 || p.y < 0 || p.x >= (int)img.get_width() || p.y >= (int)img.get_height()))
    return float4(0.0f);
  return _dt_texel(img, p.x, p.y);
}

static inline float4 read_imagef(texture2d<float, access::read> img, const dt_cl_sampler_t s, const float2 p)
{
  if(s != samplerf)
    return read_imagef(img, s, int2(floor(p)));

  // OpenCL 1.2 section 8.2: unnormalized linear filtering
  const float2 t = p - 0.5f;
  const float2 f = floor(t);
  const float2 a = t - f;
  const int x0 = (int)f.x, y0 = (int)f.y;
  return (1.0f - a.x) * (1.0f - a.y) * _dt_texel(img, x0, y0)
       + a.x * (1.0f - a.y) * _dt_texel(img, x0 + 1, y0)
       + (1.0f - a.x) * a.y * _dt_texel(img, x0, y0 + 1)
       + a.x * a.y * _dt_texel(img, x0 + 1, y0 + 1);
}

static inline uint4 read_imageui(texture2d<uint, access::read> img, const dt_cl_sampler_t s, const int2 p)
{
  const int w = (int)img.get_width();
  const int h = (int)img.get_height();
  if(s == samplerc && (p.x < 0 || p.y < 0 || p.x >= w || p.y >= h))
    return uint4(0);
  return img.read(uint2(clamp(p.x, 0, w - 1), clamp(p.y, 0, h - 1)));
}

static inline void write_imagef(texture2d<float, access::write> img, const int2 p, const float4 v)
{
  img.write(v, uint2(p));
}

static inline void write_imagef(texture2d<float, access::write> img, const int2 p, const float v)
{
  img.write(float4(v), uint2(p));
}

#define get_image_width(img) ((int)(img).get_width())
#define get_image_height(img) ((int)(img).get_height())

// what follows is data/kernels/common.h, minus the atomics, which none of
// the ported kernels use

#define NORM_MIN 1.52587890625e-05f // norm can't be < to 2^(-16)

#ifndef M_PI_F
#define M_PI_F 3.14159265358979323846f
#endif

#ifndef M_LN2f
#define M_LN2f 0.69314718055994530942f
#endif

#ifndef M_PI_2f
#define M_PI_2f 1.57079632679489661923f
#endif

#ifndef M_PI_4f
#define M_PI_4f 0.78539816339744830962f
#endif

#ifndef M_SQRT2_F
#define M_SQRT2_F 1.41421356237309504880f
#endif

#define DT_2PI_F 6.28318530717958647693f

#define LUT_ELEM 512 // gamut LUT number of elements:

#define RED 0
#define GREEN 1
#define BLUE 2
#define ALPHA 3

#define dtcl_sin(A) sin(A)
#define dtcl_cos(A) cos(A)
#define dtcl_sqrt(A) sqrt(A)
#define dtcl_pow(A,B) pow(A,B)
#define dtcl_exp(A) exp(A)
#define dtcl_log(A) log(A)
#define dtcl_log2(A) log2(A)
#define dtcl_exp2(A) exp2(A)
#define dtcl_exp10(A) exp10(A)
#define dtcl_log10(A) log10(A)

static inline float dt_fast_hypot(const float x, const float y)
{
  return dt_hypot(x, y);
}

// Kahan summation algorithm
#define Kahan_sum(m, c, add)        \
  {                                 \
    const float t1 = (add) - (c);   \
    const float t2 = (m) + t1;      \
    c = (t2 - m) - t1;              \
    m = t2;                         \
  }

static inline float scharr_gradient(device float *in, const int k, const int w)
{
  const float gx = 47.0f / 255.0f * (in[k-w-1] - in[k-w+1] + in[k+w-1] - in[k+w+1])
                + 162.0f / 255.0f * (in[k-1]   - in[k+1]);
  const float gy = 47.0f / 255.0f * (in[k-w-1] - in[k+w-1] + in[k-w+1] - in[k+w+1])
                + 162.0f / 255.0f * (in[k-w]   - in[k+w]);
  return dt_fast_hypot(gx, gy);
}

static inline float fp32_div(const float a, const float b)
{
  // the Newton-Raphson refinement of common.h, kept so results match OpenCL
  float y = native_recip(b);
  float e = fma(-b, y, 1.0f);
  y = fma(y, e, y);
  float q = a * y;
  float r = fma(-b, q, a);
  return fma(r, y, q);
}

static inline int
FC(const int row, const int col, const uint filters)
{
  return filters >> ((((row) << 1 & 14) + ((col) & 1)) << 1) & 3;
}

static inline int
FCxtrans(const int row, const int col, device const uchar (*const xtrans)[6])
{
  // There used to be a few cases in xtrans demosaicers in which row or col was negative.
  // The +600 ensures a non-negative array index as in CPU code
  return xtrans[(row + 600) % 6][(col + 600) % 6];
}

static inline int
fcol(const int row, const int col, const uint filters, device const uchar (*const xtrans)[6])
{
  return (filters == 9) ? xtrans[(row + 600) % 6][(col + 600) % 6]
                        : filters >> ((((row) << 1 & 14) + ((col) & 1)) << 1) & 3;
}

static inline float fast_mexp2f(const float x)
{
  const float i1 = (float)0x3f800000u; // 2^0
  const float i2 = (float)0x3f000000u; // 2^-1
  const float k0 = i1 + x * (i2 - i1);
  const uint k = (k0 >= (float)0x800000u) ? (uint)k0 : 0u;
  return as_type<float>(k);
}

/* we use this exp approximation to maintain full identity with cpu path */
static inline float
dt_fast_expf(const float x)
{
  // meant for the range [-100.0f, 0.0f]. largest error ~ -0.06 at 0.0f.
  // will get _a_lot_ worse for x > 0.0f (9000 at 10.0f)..
  const int i1 = 0x3f800000u;
  // e^x, the comment would be 2^x
  const int i2 = 0x402DF854u;//0x40000000u;
  const int k0 = i1 + x * (i2 - i1);
  return as_type<float>(k0 > 0 ? k0 : 0);
}

static inline float fsquare(const float a)
{
  return (a * a);
}

static inline float fcube(const float a)
{
  return (a * a * a);
}

static inline float clipf(const float a)
{
  return clamp(a, 0.0f, 1.0f);
}

static inline float4 clip4(const float4 a)
{
  return clamp(a, float4(0.0f), float4(1.0f));
}

static inline float fmax3(const float4 o)
{
  return fmax(fmax(o.x, o.y), o.z);
}

static inline int clip_mirror(int i, const int max)
{
  if(i < 0)
    i = -i;
  else if(i > max)
    i = max - (i - max);
  return i;
}

static inline float readsingle(texture2d<float, access::read> in, int col, int row)
{
  return read_imagef(in, sampleri, int2(col, row)).x;
}

static inline float Areadsingle(texture2d<float, access::read> in, int col, int row)
{
  return read_imagef(in, samplerA, int2(col, row)).x;
}

static inline float4 readpixel(texture2d<float, access::read> in, int col, int row)
{
  return read_imagef(in, sampleri, int2(col, row));
}

static inline float4 Areadpixel(texture2d<float, access::read> in, int col, int row)
{
  return read_imagef(in, samplerA, int2(col, row));
}

static inline float4 Creadpixel(texture2d<float, access::read> in, int col, int row)
{
  return read_imagef(in, samplerc, int2(col, row));
}

static inline float readalpha(texture2d<float, access::read> in, int col, int row)
{
  return clipf(read_imagef(in, sampleri, int2(col, row)).w);
}

static inline void write_ipixel(texture2d<float, access::write> out, const int2 pos, const float4 pixel)
{
  write_imagef(out, pos, pixel);
}

// src/common/hdr-transfer.h picks its OpenCL spelling of the math functions
// from this macro
#define __OPENCL_C_VERSION__ 120
#include "hdr-transfer.h"
#undef __OPENCL_C_VERSION__

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
