// Metal port of data/kernels/basic.cl
// ported-from-md5: fefbb951d7a4b7477320c8dad6374162
// ported kernels: rawprepare_1f, rawprepare_1f_unnormalized, whitebalance_1f, whitebalance_1f_xtrans, whitebalance_4f, highlights_1f_clip, highlights_initmask, highlights_dilatemask, highlights_chroma, highlights_opposed, exposure, colorin_unbound, colorout, flip, interpolation_resample, interpolation_copy
/*
    This file is part of darktable,
    Copyright (C) 2009-2026 darktable developers.

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


#include <metal_stdlib>
using namespace metal;
#include "dt_metal.h"
#include "colorspace.metal.h"
#include "color_conversion.metal.h"

#include "rgb_norms.metal.h"

// #include "diffuse.cl" (not needed by the ported kernels)

int
BL(const int row, const int col)
{
  return (((row & 1) << 1) + (col & 1));
}

kernel void rawprepare_1f(texture2d<uint, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &cx_arg [[buffer(4)]],
  constant int &cy_arg [[buffer(5)]],
  device const float *sub [[buffer(6)]],
  device const float *div [[buffer(7)]],
  device const float *rdiv [[buffer(8)]],
  constant int &rx_arg [[buffer(9)]],
  constant int &ry_arg [[buffer(10)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int cx = cx_arg;
  const int cy = cy_arg;
  const int rx = rx_arg;
  const int ry = ry_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;

  const float pix = read_imageui(in, sampleri, int2(x + cx, y + cy)).x;
  const int id = BL(ry+cy+y, rx+cx+x);
  const float n = pix - sub[id];
  const float q = n * rdiv[id];
  const float rem = fma(-q, div[id], n);
  const float oval = fma(rem, rdiv[id], q);

  write_imagef(out, int2(x, y), oval);
}

kernel void rawprepare_1f_unnormalized(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &cx_arg [[buffer(4)]],
  constant int &cy_arg [[buffer(5)]],
  device const float *sub [[buffer(6)]],
  device const float *div [[buffer(7)]],
  device const float *rdiv [[buffer(8)]],
  constant int &rx_arg [[buffer(9)]],
  constant int &ry_arg [[buffer(10)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int cx = cx_arg;
  const int cy = cy_arg;
  const int rx = rx_arg;
  const int ry = ry_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width  || y >= height) return;

  const float pix = read_imagef(in, sampleri, int2(x + cx, y + cy)).x;
  const int id = BL(ry+cy+y, rx+cx+x);
  const float n = pix - sub[id];
  const float q = n * rdiv[id];
  const float rem = fma(-q, div[id], n);
  const float oval = fma(rem, rdiv[id], q);

  write_imagef(out, int2(x, y), oval);
}

kernel void whitebalance_1f(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  device float *coeffs [[buffer(4)]],
  constant uint &filters_arg [[buffer(5)]],
  device const uchar *xtrans_flat [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const uint filters = filters_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  if(x >= width || y >= height) return;
  float pixel = readsingle(in, x, y);
  write_imagef(out, int2(x, y), pixel * coeffs[FC(y, x, filters)]);
}

kernel void whitebalance_1f_xtrans(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  device float *coeffs [[buffer(4)]],
  constant uint &filters_arg [[buffer(5)]],
  device const uchar *xtrans_flat [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  if(x >= width || y >= height) return;
  float pixel = readsingle(in, x, y);
  write_imagef(out, int2(x, y), pixel * coeffs[FCxtrans(y, x, xtrans)]);
}

kernel void whitebalance_4f(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  device float *coeffs [[buffer(4)]],
  constant uint &filters_arg [[buffer(5)]],
  device const uchar *xtrans_flat [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const uint filters = filters_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  if(x >= width || y >= height) return;
  float4 pixel = Areadpixel(in, x, y);
  write_imagef (out, int2(x, y), float4(pixel.x * coeffs[0], pixel.y * coeffs[1], pixel.z * coeffs[2], pixel.w));
}

/* kernel for the exposure plugin. should work transparently with float4 and float image2d. */
kernel void exposure(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant float &black_arg [[buffer(4)]],
  constant float &scale_arg [[buffer(5)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const float black = black_arg;
  const float scale = scale_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;
  float4 pixel = Areadpixel(in, x, y);
  pixel.xyz = ((pixel - black ) * scale).xyz;
  write_imagef (out, int2(x, y), pixel);
}

/* kernel for the highlights plugin. */


static float _calc_refavg(texture2d<float, access::read> in,
                          device const uchar (*const xtrans)[6],
                          const uint filters,
                          int row,
                          int col,
                          int maxrow,
                          int maxcol,
                          device const float *correction)
{
  float mean[3] = { 0.0f, 0.0f, 0.0f };
  float cnt[3]  = { 0.0f, 0.0f, 0.0f };

  for(int dy = max(0, row - 1); dy < min(maxrow - 1, row + 2); dy++)
  {
    for(int dx = max(0, col - 1); dx < min(maxcol - 1, col + 2); dx++)
    {
      const float val = fmax(0.0f, Areadsingle(in, dx, dy));
      const int c = fcol(dy, dx, filters, xtrans);
      mean[c] += val;
      cnt[c] += 1.0f;
    }
  }

  for(int c = 0; c < 3; c++)
    mean[c] = (cnt[c] > 0.0f) ? dt_cbrt((correction[c] * mean[c]) / cnt[c]) : 0.0f;

  float croot_refavg[3] = { 0.5f * (mean[1] + mean[2]), 0.5f * (mean[0] + mean[2]), 0.5f * (mean[0] + mean[1])};
  int color = fcol(row, col, filters, xtrans);
  return fcube(croot_refavg[color]);
}

kernel void highlights_1f_clip(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &iwidth_arg [[buffer(2)]],
  constant int &iheight_arg [[buffer(3)]],
  constant int &owidth_arg [[buffer(4)]],
  constant int &oheight_arg [[buffer(5)]],
  constant float4 &clip_arg [[buffer(6)]],
  constant int &dx_arg [[buffer(7)]],
  constant int &dy_arg [[buffer(8)]],
  constant int &filters_arg [[buffer(9)]],
  device const uchar *xtrans_flat [[buffer(10)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int iwidth = iwidth_arg;
  const int iheight = iheight_arg;
  const int owidth = owidth_arg;
  const int oheight = oheight_arg;
  const float4 clip = clip_arg;
  const int dx = dx_arg;
  const int dy = dy_arg;
  const int filters = filters_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= owidth || y >= oheight) return;

  const int irow = y + dy;
  const int icol = x + dx;
  float pixel = 0.0f;
  float clips[4] = { clip.x, clip.y, clip.z, clip.w};
  if((icol >= 0) && (irow >= 0) && (irow < iheight) && (icol < iwidth))
  {
    const int color = fcol(irow, icol, filters, xtrans);
    pixel = Areadsingle(in, icol, irow);
    pixel = fmin(clips[color], pixel);
  }
  write_imagef(out, int2(x, y), pixel);
}

kernel void highlights_initmask(texture2d<float, access::read> in [[texture(0)]],
  device char *inmask [[buffer(1)]],
  constant int &msize_arg [[buffer(2)]],
  constant int &mwidth_arg [[buffer(3)]],
  constant int &mheight_arg [[buffer(4)]],
  constant int &iwidth_arg [[buffer(5)]],
  constant int &iheight_arg [[buffer(6)]],
  constant uint &filters_arg [[buffer(7)]],
  device const uchar *xtrans_flat [[buffer(8)]],
  device const float *clips [[buffer(9)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int msize = msize_arg;
  const int mwidth = mwidth_arg;
  const int mheight = mheight_arg;
  const int iwidth = iwidth_arg;
  const int iheight = iheight_arg;
  const uint filters = filters_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int mcol = get_global_id(0);
  const int mrow = get_global_id(1);

  if(mcol >= mwidth || mrow >= mheight)
    return;

  int mdx = mad24(mrow, mwidth, mcol);
  char mbuff[3] = { 0, 0, 0 };
  int irow = 3*mrow;
  int icol = 3*mcol;

  for(int y = irow; y < irow + 3; y++)
  {
    for(int x = icol; x < icol + 3; x++)
    {
      if(y < iheight && x < iwidth)
      {
        int color = fcol(y, x, filters, xtrans);
        float val = readsingle(in, x, y);
        mbuff[color] += (val >= clips[color]) ? 1 : 0;
      }
    }
  }

  for(int c = 0; c < 3; c++)
    inmask[c*msize + mdx] = mbuff[c] ? 1 : 0;
}

static char _mask_dilated(device char *in, const int w1)
{
  if(in[0])
    return 1;

  if(in[-w1-1] | in[-w1] | in[-w1+1] | in[-1] | in[1] | in[w1-1] | in[w1] | in[w1+1])
    return 1;

  const int w2 = 2*w1;
  const int w3 = 3*w1;
  return (in[-w3-2] | in[-w3-1] | in[-w3]   | in[-w3+1] | in[-w3+2] |
          in[-w2-3] | in[-w2-2] | in[-w2-1] | in[-w2]   | in[-w2+1] | in[-w2+2] | in[-w2+3] |
          in[-w1-3] | in[-w1-2] | in[-w1+2] | in[-w1+3] |
          in[-3]    | in[-2]    | in[2]     | in[3]     |
          in[w1-3]  | in[w1-2]  | in[w1+2]  | in[w1+3]  |
          in[w2-3]  | in[w2-2]  | in[w2-1]  | in[w2]    | in[w2+1]  | in[w2+2]  | in[w2+3] |
          in[w3-2]  | in[w3-1]  | in[w3]    | in[w3+1]  | in[w3+2]) ? 1 : 0;
}

kernel void highlights_dilatemask(device char *in [[buffer(0)]],
  device char *out [[buffer(1)]],
  constant int &msize_arg [[buffer(2)]],
  constant int &mwidth_arg [[buffer(3)]],
  constant int &mheight_arg [[buffer(4)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int msize = msize_arg;
  const int mwidth = mwidth_arg;
  const int mheight = mheight_arg;

  const int col = get_global_id(0);
  const int row = get_global_id(1);

  if(col >= mwidth || row >= mheight)
    return;

  int mx = mad24(row, mwidth, col);
  bool safe = col >= 3 && row >= 3 && col < mwidth - 3 && row < mheight - 3;

  out[mx] =         safe ? _mask_dilated(in + mx, mwidth)           : in[mx];
  out[mx+msize] =   safe ? _mask_dilated(in + mx + msize, mwidth)   : in[mx + msize];
  out[mx+2*msize] = safe ? _mask_dilated(in + mx + 2*msize, mwidth) : in[mx + 2*msize];
}

kernel void highlights_chroma(texture2d<float, access::read> in [[texture(0)]],
  device char *mask [[buffer(1)]],
  device float *accu [[buffer(2)]],
  constant int &width_arg [[buffer(3)]],
  constant int &height_arg [[buffer(4)]],
  constant int &msize_arg [[buffer(5)]],
  constant int &mwidth_arg [[buffer(6)]],
  constant uint &filters_arg [[buffer(7)]],
  device const uchar *xtrans_flat [[buffer(8)]],
  device const float *clips [[buffer(9)]],
  device const float *correction [[buffer(10)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int msize = msize_arg;
  const int mwidth = mwidth_arg;
  const uint filters = filters_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int row = get_global_id(0);
  if(row >= height) return;

  float sum[4] = {0.0f, 0.0f, 0.0f, 0.0f};
  float cnt[4] = {0.0f, 0.0f, 0.0f, 0.0f};

  float clipped = 0.0f;
  for(int col = 0; col < width; col++)
  {
    const int idx = mad24(row, width, col);
    const int color = fcol(row, col, filters, xtrans);
    const float inval = Areadsingle(in, col, row);
    const int px = color * msize + mad24(row/3, mwidth, col/3);
    if(mask[px] && (inval > 0.2f*clips[color]) && (inval < clips[color]))
    {
      const float ref = _calc_refavg(in, xtrans, filters, row, col, height, width, correction);
      sum[color] += inval - ref;
      cnt[color] += 1.0f;
    }
    if(mask[px]) clipped += 1.0f;
  }

  for(int c = 0; c < 3; c++)
  {
    accu[row*8 + 2*c] = sum[c];
    accu[row*8 + 2*c +1] = cnt[c];
  }
  accu[row*8 + 6] = clipped;
}

kernel void highlights_opposed(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &owidth_arg [[buffer(2)]],
  constant int &oheight_arg [[buffer(3)]],
  constant int &iwidth_arg [[buffer(4)]],
  constant int &iheight_arg [[buffer(5)]],
  constant int &dx_arg [[buffer(6)]],
  constant int &dy_arg [[buffer(7)]],
  constant uint &filters_arg [[buffer(8)]],
  device const uchar *xtrans_flat [[buffer(9)]],
  device const float *clips [[buffer(10)]],
  device const float *chroma [[buffer(11)]],
  device const float *correction [[buffer(12)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int owidth = owidth_arg;
  const int oheight = oheight_arg;
  const int iwidth = iwidth_arg;
  const int iheight = iheight_arg;
  const int dx = dx_arg;
  const int dy = dy_arg;
  const uint filters = filters_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  if(x >= owidth || y >= oheight) return;

  int irow = y + dy;
  int icol = x + dx;
  float val = 0.0f;

  if((icol >= 0) && (icol < iwidth) && (irow >= 0) && (irow < iheight))
  {
    val = Areadsingle(in, icol, irow);
    const int color = fcol(irow, icol, filters, xtrans);
    if(val >= clips[color])
    {
      const float ref = _calc_refavg(in, xtrans, filters, irow, icol, iheight, iwidth, correction);
      val = fmax(val, ref + chroma[color]);
    }
  }
  write_imagef(out, int2(x, y), val);
}

#define SQRT3 1.7320508075688772935274463415058723669f
#define SQRT12 3.4641016151377545870548926830117447339f // 2*SQRT3



#undef SQRT3
#undef SQRT12


enum wavelets_scale_t
{
  ANY_SCALE   = 1 << 0, // any wavelets scale   : reconstruct += HF
  FIRST_SCALE = 1 << 1, // first wavelets scale : reconstruct = 0
  LAST_SCALE  = 1 << 2, // last wavelets scale  : reconstruct += residual
};




float
lerp_lookup_unbounded0(texture2d<float, access::read> lut, const float x, device const float *a)
{
  // in case the tone curve is marked as linear, return the fast
  // path to linear unbounded (does not clip x at 1)
  if(a[0] >= 0.0f)
  {
    if(x < 1.0f)
    {
      const float ft = clamp(x * (float)0xffff, 0.0f, (float)0xffff);
      const int t = ft < 0xfffe ? ft : 0xfffe;
      const float f = ft - t;
      const int2 p1 = int2((t & 0xff), (t >> 8));
      const int2 p2 = int2(((t + 1) & 0xff), ((t + 1) >> 8));
      const float l1 = read_imagef(lut, sampleri, p1).x;
      const float l2 = read_imagef(lut, sampleri, p2).x;
      return l1 * (1.0f - f) + l2 * f;
    }
    else return a[1] * dtcl_pow(x*a[0], a[2]);
  }
  else return x;
}

static float4 _lookup_hsm(const float4 hsv,
                          const int hue_div,
                          const int sat_div,
                          const int val_div,
                          device const float *hsm)
{
  const float h = (hsv.x - floor(hsv.x)) * (float)hue_div;
  const float s = clipf(hsv.y) * (float)(sat_div-1);
  const float v = clipf(hsv.z) * (float)(val_div-1);
  const int hi[2] = { min((int)h, hue_div-1), (min((int)h,   hue_div-1)+1) % hue_div };
  const int si[2] = { min((int)s, sat_div-1),  min((int)s+1, sat_div-1) };
  const int vi[2] = { min((int)v, val_div-1),  min((int)v+1, val_div-1) };
  const float hf = clipf(h - (float)hi[0]);
  const float sf = clipf(s - (float)si[0]);
  const float vf = clipf(v - (float)vi[0]);

  float4 correction = float4(0.0f);
  for(int z = 0; z < 2; z++)
    for(int y = 0; y < 2; y++)
      for(int x = 0; x < 2; x++)
      {
        // DNG stores saturation first, then hue, then value, with three floats per cell
        const int index = 3 * ((vi[z] * hue_div + hi[y]) * sat_div + si[x]);
        const float weight = (z ? vf : 1.0f - vf)
                           * (y ? hf : 1.0f - hf)
                           * (x ? sf : 1.0f - sf);
        correction.x += weight * hsm[index + 0];
        correction.y += weight * hsm[index + 1];
        correction.z += weight * hsm[index + 2];
      }
  return correction;
}

static float _srgb_to_linear(const float x)
{
  return x <= 0.04045f ? x / 12.92f : dtcl_pow((x + 0.055f) / 1.055f, 2.4f);
}
static float _linear_to_srgb(const float x)
{
  return x <= 0.0031308f ? 12.92f * x : 1.055f * dtcl_pow(x, 1.0f / 2.4f) - 0.055f;
}

/* kernel for the plugin colorin: unbound processing */
kernel void colorin_unbound(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  device float *cmat [[buffer(4)]],
  device float *lmat [[buffer(5)]],
  texture2d<float, access::read> lutr [[texture(6)]],
  texture2d<float, access::read> lutg [[texture(7)]],
  texture2d<float, access::read> lutb [[texture(8)]],
  constant int &blue_mapping_arg [[buffer(9)]],
  device const float *a_flat [[buffer(10)]],
  device const float *corr [[buffer(11)]],
  constant float &scale_arg [[buffer(12)]],
  constant int &hue_div_arg [[buffer(13)]],
  constant int &sat_div_arg [[buffer(14)]],
  constant int &val_div_arg [[buffer(15)]],
  device const float *dev_hsm [[buffer(16)]],
  constant int &encoding_arg [[buffer(17)]],
  constant int &use_hsm_arg [[buffer(18)]],
  constant int &hdr_transfer_arg [[buffer(19)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int blue_mapping = blue_mapping_arg;
  device const float (*const a)[3] = (device const float (*)[3])a_flat;
  const float scale = scale_arg;
  const int hue_div = hue_div_arg;
  const int sat_div = sat_div_arg;
  const int val_div = val_div_arg;
  const int encoding = encoding_arg;
  const int use_hsm = use_hsm_arg;
  const int hdr_transfer = hdr_transfer_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;

  const float4 corval = float4(corr[0], corr[1], corr[2], corr[3]);
  float4 pixel = corval * readpixel(in, x, y);
  const float alpha = pixel.w;

  float cam[3], XYZ[3];
  if(hdr_transfer)
  {
    cam[0] = pixel.x;
    cam[1] = pixel.y;
    cam[2] = pixel.z;
    dt_hdr_decode(cam, hdr_transfer);
  }
  else
  {
    cam[0] = lerp_lookup_unbounded0(lutr, pixel.x, a[0]);
    cam[1] = lerp_lookup_unbounded0(lutg, pixel.y, a[1]);
    cam[2] = lerp_lookup_unbounded0(lutb, pixel.z, a[2]);
  }

  if(blue_mapping)
  {
    const float YY = cam[0] + cam[1] + cam[2];
    if(YY > 0.0f)
    {
      // manual gamut mapping. these values cause trouble when converting back from Lab to sRGB:
      const float zz = cam[2] / YY;
      // lower amount and higher bound_z make the effect smaller.
      // the effect is weakened the darker input values are, saturating at bound_Y
      const float bound_z = 0.5f, bound_Y = 0.8f;
      const float amount = 0.11f;
      if (zz > bound_z)
      {
        const float t = (zz - bound_z) / (1.0f - bound_z) * fmin(1.0f, YY / bound_Y);
        cam[1] += t * amount;
        cam[2] -= t * amount;
      }
    }
  }

  // now convert camera to XYZ using the color matrix
  for(int j=0;j<3;j++)
  {
    XYZ[j] = 0.0f;
    for(int i=0;i<3;i++) XYZ[j] += cmat[3*j+i] * cam[i];
  }
  float4 xyz = float4(XYZ[0], XYZ[1], XYZ[2], 0.0f);
  pixel.xyz = XYZ_to_Lab(xyz).xyz;
  if(use_hsm)
  {
    float4 prophoto_rgb = Lab_to_prophotorgb(pixel) / float4(scale);
    float4 hsv = RGB_2_HSV(prophoto_rgb);
    // Encode valueV for table lookup if needed
    float v_encoded = hsv.z;
    if(encoding == 1) // sRGB
      v_encoded = _linear_to_srgb(clipf(v_encoded));

    // Use encoded value for table lookup (need to temporarily set hsv[2])
    float4 hsv_for_lookup = hsv;
    hsv_for_lookup.z = v_encoded;
    float4 correction = _lookup_hsm(hsv_for_lookup, hue_div, sat_div, val_div, dev_hsm);

    hsv.x += correction.x / 360.0f;
    hsv.x -= floor(hsv.x); // stay within the 360° hue circle
    hsv.y = clipf(hsv.y * correction.y);

    float v_corrected = v_encoded * correction.z;
    if(encoding == 1)  // sRGB
      v_corrected = _srgb_to_linear(v_corrected);
    hsv.z = clipf(v_corrected);
    prophoto_rgb = HSV_2_RGB(hsv) * float4(scale);
    pixel = prophotorgb_to_Lab(prophoto_rgb);
  }
  pixel.w = alpha;
  write_imagef(out, int2(x, y), pixel);
}

/* kernel for the plugin colorin: with clipping */


/* kernel for the tonecurve plugin. */



/* kernel for the colorcorrection plugin. */












#define DT_LANCZOS_EPSILON (1e-9f)

#if 0
float
interpolation_func_lanczos(float width, float t)
{
  float ta = fabs(t);

  float r = (ta > width) ? 0.0f : ((ta < DT_LANCZOS_EPSILON) ? 1.0f : width*native_sin(M_PI_F*t)*native_sin(M_PI_F*t/width)/(M_PI_F*M_PI_F*t*t));

  return r;
}
#else



#endif


/* kernel for clip&rotate: bilinear interpolation */




/* kernel for clip&rotate: bicubic interpolation */



/* kernel for clip&rotate: lanczos2 interpolation */




/* kernel for clip&rotate: lanczos3 interpolation */














// Keep in sync with defines in interpolation
#define MAX_HALF_FILTER_WIDTH 3
#define MAX_KERNEL_REQ ((2 * (MAX_HALF_FILTER_WIDTH) + 3) & (~3))



#undef MAX_KERNEL_REQ
#undef MAX_HALF_FILTER_WIDTH

/* kernels for the lens plugin: bilinear interpolation */


/* kernels for the lens plugin: bicubic interpolation */



/* kernels for the lens plugin: lanczos2 interpolation */



/* kernels for the lens plugin: lanczos3 interpolation */




/* kernel for the ashift module: bilinear interpolation */


/* kernel for the ashift module: bicubic interpolation */



/* kernel for the ashift module: lanczos2 interpolation */



/* kernels for the ashift module: lanczos3 interpolation */






#define MAXKNOTS 16

#undef MAXKNOTS


/* kernel for flip */
kernel void flip(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &owidth_arg [[buffer(4)]],
  constant int &oheight_arg [[buffer(5)]],
  constant int &orientation_arg [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int owidth = owidth_arg;
  const int oheight = oheight_arg;
  const int orientation = orientation_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;

  // ORIENTATION_FLIP_X = 2
  int ox = (orientation & 2) ? width - x - 1 : x;

  // ORIENTATION_FLIP_Y = 1
  int oy = (orientation & 1) ? height - y - 1 : y;

  // ORIENTATION_SWAP_XY = 4
  if(orientation & 4)
  {
     const int tmp = ox;
     ox = oy;
     oy = tmp;
  }

  if(ox >= 0 && oy >= 0 && ox < owidth && oy < oheight)
  {
    const float4 pixel = readpixel(in, x, y);
    write_imagef(out, int2(ox, oy), pixel);
  }
}



/* kernel for monochrome */


/* kernel for the plugin colorout, fast matrix + shaper path only */
kernel void colorout(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  device float *mat [[buffer(4)]],
  texture2d<float, access::read> lutr [[texture(5)]],
  texture2d<float, access::read> lutg [[texture(6)]],
  texture2d<float, access::read> lutb [[texture(7)]],
  device const float *a_flat [[buffer(8)]],
  constant int &hdr_transfer_arg [[buffer(9)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  device const float (*const a)[3] = (device const float (*)[3])a_flat;
  const int hdr_transfer = hdr_transfer_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;

  float4 pixel = Areadpixel(in, x, y);
  float XYZ[3], rgb[3];
  float4 xyz = Lab_to_XYZ(pixel);
  XYZ[0] = xyz.x;
  XYZ[1] = xyz.y;
  XYZ[2] = xyz.z;
  for(int i=0;i<3;i++)
  {
    rgb[i] = 0.0f;
    for(int j=0;j<3;j++) rgb[i] += mat[3*i+j]*XYZ[j];
  }
  dt_hdr_encode(rgb, hdr_transfer);
  pixel.x = lerp_lookup_unbounded0(lutr, rgb[0], a[0]);
  pixel.y = lerp_lookup_unbounded0(lutg, rgb[1], a[1]);
  pixel.z = lerp_lookup_unbounded0(lutb, rgb[2], a[2]);
  write_imagef (out, int2(x, y), pixel);
}


/* kernel for the levels plugin */


/* kernel for the colorzones plugin */
enum
{
  DT_IOP_COLORZONES_L = 0,
  DT_IOP_COLORZONES_C = 1,
  DT_IOP_COLORZONES_h = 2
};


/* kernel for the zonesystem plugin */





/* kernel to fill an image with a color (for the borders plugin). */



/* kernel for the overexposed plugin. */
typedef enum dt_clipping_preview_mode_t
{
  DT_CLIPPING_PREVIEW_GAMUT = 0,
  DT_CLIPPING_PREVIEW_ANYRGB = 1,
  DT_CLIPPING_PREVIEW_LUMINANCE = 2,
  DT_CLIPPING_PREVIEW_SATURATION = 3
} dt_clipping_preview_mode_t;

/* kernel for the rawoverexposed plugin. */


/* kernel for the lowlight plugin. */



/* kernel for the contrast lightness saturation module */


/* kernel for the unbreak input profile module - gamma version */

/* kernel for the unbreak input profile module - log version */


/* kernel for the interpolation resample helper */
kernel void interpolation_resample(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  device const int *hmeta [[buffer(4)]],
  device const int *vmeta [[buffer(5)]],
  device const int *hlength [[buffer(6)]],
  device const int *vlength [[buffer(7)]],
  device const int *hindex [[buffer(8)]],
  device const int *vindex [[buffer(9)]],
  device const float *hkernel [[buffer(10)]],
  device const float *vkernel [[buffer(11)]],
  constant int &htaps_arg [[buffer(12)]],
  constant int &vtaps_arg [[buffer(13)]],
  threadgroup float *lkernel [[threadgroup(14)]],
  threadgroup int *lindex [[threadgroup(15)]],
  threadgroup float4 *buffer [[threadgroup(16)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int htaps = htaps_arg;
  const int vtaps = vtaps_arg;

  const int x = get_global_id(0);
  const int yi = get_global_id(1);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int y = yi / vtaps;
  const int iy = yi % vtaps;

  // Initialize resampling indices
  const int xm = min(x, width - 1);
  const int ym = min(y, height - 1);
  const int hlidx = hmeta[xm*3];   // H(orizontal) L(ength) I(n)d(e)x
  const int hkidx = hmeta[xm*3+1]; // H(orizontal) K(ernel) I(n)d(e)x
  const int hiidx = hmeta[xm*3+2]; // H(orizontal) I(ndex) I(n)d(e)x
  const int vlidx = vmeta[ym*3];   // V(ertical) L(ength) I(n)d(e)x
  const int vkidx = vmeta[ym*3+1]; // V(ertical) K(ernel) I(n)d(e)x
  const int viidx = vmeta[ym*3+2]; // V(ertical) I(ndex) I(n)d(e)x

  const int hl = hlength[hlidx];   // H(orizontal) L(ength)
  const int vl = vlength[vlidx];   // V(ertical) L(ength)

  // generate local copy of horizontal index field and kernel
  for(int n = 0; n <= htaps/ylsz; n++)
  {
    int k = mad24(n, ylsz, ylid);
    if(k >= hl) continue;
    lindex[k] = hindex[hiidx+k];
    lkernel[k] = hkernel[hkidx+k];
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // horizontal convolution kernel; store intermediate result in local buffer
  if(x < width && y < height)
  {
    const int yvalid = iy < vl;

    const int yy = yvalid ? vindex[viidx+iy] : -1;

    float4 vpixel = float4(0.0f);

    for (int ix = 0; ix < hl && yvalid; ix++)
    {
      const int xx = lindex[ix];
      float4 hpixel = readpixel(in, xx, yy);
      vpixel += hpixel * lkernel[ix];
    }

    buffer[ylid] = yvalid ? vpixel * vkernel[vkidx+iy] : float4(0.0f);
  }
  else
    buffer[ylid] = float4(0.0f);

  barrier(CLK_LOCAL_MEM_FENCE);

  // recursively reduce local buffer (vertical convolution kernel)
  for(int offset = vtaps / 2; offset > 0; offset >>= 1)
  {
    if (iy < offset)
    {
      buffer[ylid] += buffer[ylid + offset];
    }
    barrier(CLK_LOCAL_MEM_FENCE);
  }

  // store final result
  if (iy == 0 && x < width && y < height)
  {
    write_ipixel(out, int2(x, y), buffer[ylid]);
  }
}

/* kernel for the interpolation copy helper */
kernel void interpolation_copy(texture2d<float, access::read> dev_in [[texture(0)]],
  texture2d<float, access::write> dev_out [[texture(1)]],
  constant int &owidth_arg [[buffer(2)]],
  constant int &oheight_arg [[buffer(3)]],
  constant int &iwidth_arg [[buffer(4)]],
  constant int &iheight_arg [[buffer(5)]],
  constant int &dx_arg [[buffer(6)]],
  constant int &dy_arg [[buffer(7)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int owidth = owidth_arg;
  const int oheight = oheight_arg;
  const int iwidth = iwidth_arg;
  const int iheight = iheight_arg;
  const int dx = dx_arg;
  const int dy = dy_arg;

  const int ocol = get_global_id(0);
  const int orow = get_global_id(1);

  if(ocol >= owidth || orow >= oheight) return;

  float4 pix = float4(0.0f);

  const int irow = orow + dy;
  const int icol = ocol + dx;

  if(irow < iheight && irow >= 0 && icol < iwidth && icol >= 0)
  {
    pix = Areadpixel(dev_in, icol, irow);
  }
  write_imagef(dev_out, int2(ocol, orow), pix);
}

