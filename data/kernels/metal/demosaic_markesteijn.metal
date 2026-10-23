// Metal port of data/kernels/demosaic_markesteijn.cl
// ported-from-md5: c754dcf442fced36bfb4c1fa290e472e
// ported kernels: markesteijn_initial_copy, markesteijn_green_minmax, markesteijn_interpolate_green, markesteijn_solitary_green, markesteijn_recalculate_green, markesteijn_red_and_blue, markesteijn_interpolate_twoxtwo, markesteijn_convert_yuv, markesteijn_differentiate, markesteijn_homo_threshold, markesteijn_homo_set, markesteijn_homo_sum, markesteijn_homo_max, markesteijn_homo_max_corr, markesteijn_homo_quench, markesteijn_accu, markesteijn_final
/*
    This file is part of darktable,
    copyright (c) 2016 Ulrich Pegelow.

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
#define HOMOGENITY_EPS 1e-10f
#define SOLITARY_EPS 1e-12f

// directions along the both axes and both diagonals
constant const char2 dir[4] = { char2(1, 0), char2(0, 1), char2(1, 1), char2(-1, 1) };

// all possible offsets of a neighboring pixel in x/y directions
constant const char2 nboff[4] = { char2(1, 0), char2(0, 1), char2(-1, 0), char2(0, -1) };

int
hexidx1(const char2 hex, const int stride)
{
  return mad24(hex.y, stride, hex.x);
}

int
hexidx4(const char2 hex, const int stride)
{
  return mul24(mad24(hex.y, stride, hex.x), 4);
}

// copy image from image object to buffer.
kernel void markesteijn_initial_copy(texture2d<float, access::read> in [[texture(0)]],
  device float *rgb [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  device const uchar *xtrans_flat [[buffer(4)]],
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

  device float *pix = rgb + 4 * mad24(y, width, x);

  const int f = FCxtrans(y, x, xtrans);

  const float p = fmax(0.0f, Areadsingle(in, x, y));

  for(int c = 0; c < 3; c++)
    pix[c] = (c == f) ? p : 0.0f;
}


// find minimum and maximum allowed green values of red/blue pixel pairs
kernel void markesteijn_green_minmax(device float *rgb [[buffer(0)]],
  device float *gminmax [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  constant char2 &sgreen_arg [[buffer(5)]],
  device const uchar *xtrans_flat [[buffer(6)]],
  device const char2 *allhex_flat [[buffer(7)]],
  threadgroup float *buffer [[threadgroup(8)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const char2 sgreen = sgreen_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;
  device const char2 (*const allhex)[3][8] = (device const char2 (*)[3][8])allhex_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);

  // individual control variable in this work group and the work group size
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);

  // stride and maximum capacity of local buffer
  // cells of 1*float per pixel with a surrounding border of 3 cells
  const int stride = xlsz + 2*3;
  const int maxbuf = mul24(stride, ylsz + 2*3);

  // coordinates of top left pixel of buffer
  // this is 3 pixel left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 3;
  const int yul = mul24(ygid, ylsz) - 3;

  // total size of rgb (in units of 1*float)
  const int rgb_max = mul24(width, height);

  // we locally buffer rgb_0[1] (i.e. green) to speed-up reading
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    const int inidx = mad24(yy, width, xx);
    buffer[bufidx] = (inidx >= 0 && inidx < rgb_max) ? (rgb + 4 * inidx)[1] : 0.0f;
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // center the local buffer around current x,y-Pixel
  threadgroup float *buff = buffer +  mad24(ylid + 3, stride, xlid + 3);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // the color of this pixel
  const int f = FCxtrans(y, x, xtrans);

  // we only work on non-green pixels
  if(f == GREEN) return;

  // get min/max of *this* pixel
  float gmin = FLT_MAX;
  float gmax = FLT_MIN;
  device const char2 *const hex = allhex[y % 3][x % 3];
  for(int c = 0; c < 6; c++)
  {
    const float val = buff[hexidx1(hex[c], stride)];
    if(gmin > val) gmin = val;
    if(gmax < val) gmax = val;
  }

  // find the *one* neighboring non-green pixel in four directions
  threadgroup float *buff2nd = buff;                    // initialized here only to prevent compiler warning
  device const char2 *hex2nd = hex;               // initialized here only to prevent compiler warning
  for (int n = 0; n < 4; n++)
  {
    if(FCxtrans(y + nboff[n].y, x + nboff[n].x, xtrans) == 1) continue; // this is a green pixel
    buff2nd = buff + mad24(nboff[n].y, stride, nboff[n].x);
    hex2nd = allhex[(y + nboff[n].y) % 3][(x + nboff[n].x) % 3];
  }

  // we have found the second pixel: now include it into min/max calculation
  for(int c = 0; c < 6; c++)
  {
    const float val = buff2nd[hexidx1(hex2nd[c], stride)];
    if(gmin > val) gmin = val;
    if(gmax < val) gmax = val;
  }

  const int glidx = mad24(y, width, x);
  vstore2(float2(gmin, gmax), glidx, gminmax);
}


// Interpolate green horizontally, vertically, and along both diagonals
kernel void markesteijn_interpolate_green(device float *rgb_0 [[buffer(0)]],
  device float *rgb_1 [[buffer(1)]],
  device float *rgb_2 [[buffer(2)]],
  device float *rgb_3 [[buffer(3)]],
  device float *gminmax [[buffer(4)]],
  constant int &width_arg [[buffer(5)]],
  constant int &height_arg [[buffer(6)]],
  constant int &border_arg [[buffer(7)]],
  constant char2 &sgreen_arg [[buffer(8)]],
  device const uchar *xtrans_flat [[buffer(9)]],
  device const char2 *allhex_flat [[buffer(10)]],
  threadgroup float *buffer [[threadgroup(11)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const char2 sgreen = sgreen_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;
  device const char2 (*const allhex)[3][8] = (device const char2 (*)[3][8])allhex_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);

  // individual control variable in this work group and the work group size
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);

  // stride and maximum capacity of local buffer
  // cells of 4*float per pixel with a surrounding border of 6 cells
  const int stride = xlsz + 2*6;
  const int maxbuf = mul24(stride, ylsz + 2*6);

  // coordinates of top left pixel of buffer
  // this is 6 pixel left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 6;
  const int yul = mul24(ygid, ylsz) - 6;

  // total size of rgb_0 (in units of 4*float)
  const int rgb_0_max = mul24(width, height);

  // we locally buffer rgb_0 to speed-up reading
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    const int inidx = mad24(yy, width, xx);
    const float4 pixel = (inidx >= 0 && inidx < rgb_0_max) ? vload4(inidx, rgb_0) : float4(0.0f);
    vstore4(pixel, bufidx, buffer);
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // center the local buffer around current x,y-Pixel
  threadgroup float *buff = buffer + 4 * mad24(ylid + 6, stride, xlid + 6);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // the color of this pixel
  const int f = FCxtrans(y, x, xtrans);

  // we only work on non-green pixels
  if(f == GREEN) return;


  // receive min/max of this pixel
  const float gmin = (gminmax + 2 * mad24(y, width, x))[0];
  const float gmax = (gminmax + 2 * mad24(y, width, x))[1];

  device const char2 *const hex = allhex[y % 3][x % 3];

  float color[8];

  color[0] = 0.6796875f * ((buff + hexidx4(hex[1], stride))[1] + (buff + hexidx4(hex[0], stride))[1])
             - 0.1796875f * ((buff + 2 * hexidx4(hex[1], stride))[1] + (buff + 2 * hexidx4(hex[0], stride))[1]);

  color[1] = 0.87109375f * (buff + hexidx4(hex[3], stride))[1]
             + 0.13f * (buff + hexidx4(hex[2], stride))[1]
             + 0.359375f * ((buff)[f] - (buff - hexidx4(hex[2], stride))[f]);

  for(int c = 0; c < 2; c++)
  {
    color[2 + c] = 0.640625f * (buff + hexidx4(hex[4 + c], stride))[1]
                   + 0.359375f * (buff - 2 * hexidx4(hex[4 + c], stride))[1]
                   + 0.12890625f * (2.0f * (buff)[f]
                                    - (buff + 3 * hexidx4(hex[4 + c], stride))[f]
                                    - (buff - 3 * hexidx4(hex[4 + c], stride))[f]);
  }

  device float *rgb[4] = { rgb_0, rgb_1, rgb_2, rgb_3 };
  const int glidx = 4 * mad24(y, width, x);

  for(int c = 0; c < 4; c++)
  {
    // note: the original C99 code makes use of the fact that (boolean)TRUE translates to (int)1.
    //       in OpenCL (boolean)TRUE is represented by (int)-1, though.
    const int d = (!((y - sgreen.y) % 3)) ? 1 : 0;
    (rgb[c ^ d] + glidx)[1] = clamp(color[c], gmin, gmax);
  }
}



// interpolate red and blue values for solitary green pixels
kernel void markesteijn_solitary_green(device float *rgb [[buffer(0)]],
  device float *aux [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  constant int &d_arg [[buffer(5)]],
  constant char2 &dir_arg [[buffer(6)]],
  constant int &hcomp_arg [[buffer(7)]],
  constant char2 &sgreen_arg [[buffer(8)]],
  device const uchar *xtrans_flat [[buffer(9)]],
  threadgroup float *buffer [[threadgroup(10)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const int d = d_arg;
  const char2 dir = dir_arg;
  const int hcomp = hcomp_arg;
  const char2 sgreen = sgreen_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);

  // individual control variable in this work group and the work group size
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);

  // stride and maximum capacity of local buffer
  // cells of 4*float per pixel with a surrounding border of 2 cells
  const int stride = xlsz + 2*2;
  const int maxbuf = mul24(stride, ylsz + 2*2);

  // coordinates of top left pixel of buffer
  // this is 2 pixel left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 2;
  const int yul = mul24(ygid, ylsz) - 2;

  // total size of rgb (in units of 4*float)
  const int rgb_max = mul24(width, height);

  // we locally buffer rgb to speed-up reading
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    const int inidx = mad24(yy, width, xx);
    const float4 pixel = (inidx >= 0 && inidx < rgb_max) ? vload4(inidx, rgb) : float4(0.0f);
    vstore4(pixel, bufidx, buffer);
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // center the local buffer around current x,y-Pixel
  threadgroup float *buff = buffer +  4 * mad24(ylid + 2, stride, xlid + 2);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // we only work on solitary green pixels
  if((x - sgreen.x) % 3 != 0 || (y - sgreen.y) % 3 != 0) return;

  // the color of the pixel right to this one
  int h = FCxtrans(y, x + 1, xtrans);

  // the complement according to this run
  h ^= hcomp;

  // center aux and rgb around current pixel
  const int glidx = 4 * mad24(y, width, x);
  aux += glidx;
  rgb += glidx;

  float color[4] = { 0.0f };
  float ocolor[4] = { 0.0f };

  if(d > 0)
    for(int c = 0; c < 4; c++) ocolor[c] = color[c] = aux[c];

  float diff = 0.0f;

  const int i = 4 * mad24(dir.y, stride, dir.x);

  for(int c = 0; c < 2; c++, h ^= 2)
  {
    const int off = i << c;
    const float g = 2.0f * buff[1] - (buff + off)[1] - (buff - off)[1];
    color[h] = g + (buff + off)[h] + (buff - off)[h];
    diff += (d > 1) ? fsquare((buff + off)[1] - (buff - off)[1] - (buff + off)[h] + (buff - off)[h])
                      + fsquare(g)
                    : 0.0f;
  }

  color[3] = diff;

  if((d > 1) && (d & 1))
    for(int c = 0; c < 2; c++) color[c * 2] = (ocolor[3] + SOLITARY_EPS < diff) ? ocolor[c * 2] : color[c * 2];

  if((d < 2) || (d & 1))
    for(int c = 0; c < 2; c++) rgb[c * 2] = color[c * 2] / 2.0f;

  for(int c = 0; c < 4; c++)
    aux[c] = color[c];
}


// recalculate green from interpolated values of closer pixels.
kernel void markesteijn_recalculate_green(device float *rgb_0 [[buffer(0)]],
  device float *rgb_1 [[buffer(1)]],
  device float *rgb_2 [[buffer(2)]],
  device float *rgb_3 [[buffer(3)]],
  device float *gminmax [[buffer(4)]],
  constant int &width_arg [[buffer(5)]],
  constant int &height_arg [[buffer(6)]],
  constant int &border_arg [[buffer(7)]],
  constant char2 &sgreen_arg [[buffer(8)]],
  device const uchar *xtrans_flat [[buffer(9)]],
  device const char2 *allhex_flat [[buffer(10)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const char2 sgreen = sgreen_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;
  device const char2 (*const allhex)[3][8] = (device const char2 (*)[3][8])allhex_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  device float *rgb[4] = { rgb_0, rgb_1, rgb_2, rgb_3 };

  // the color of this pixel
  const int f = FCxtrans(y, x, xtrans);

  // we only work on non-green pixels
  if(f == GREEN) return;

  // receive min/max of this pixel
  const float gmin = (gminmax + 2 * mad24(y, width, x))[0];
  const float gmax = (gminmax + 2 * mad24(y, width, x))[1];

  device const char2 *const hex = allhex[y % 3][x % 3];

  const int glidx = 4 * mad24(y, width, x);

  for(int d = 3; d < 6; d++)
  {
    const int id = (d - 2) ^ (!((y - sgreen.y) % 3) ? 1 : 0);
    device float *rfx = rgb[id] + glidx;
    const float val = (rfx - 2 * hexidx4(hex[d], width))[1]
                       + 2.0f * (rfx + hexidx4(hex[d], width))[1]
                       - (rfx - 2 * hexidx4(hex[d], width))[f]
                       - 2.0f * (rfx + hexidx4(hex[d], width))[f]
                       + 3.0f * (rfx)[f];

    rfx[1] = clamp(val / 3.0f, gmin, gmax);
  }
}


// interpolate red for blue pixels and vice versa
kernel void markesteijn_red_and_blue(device float *rgb [[buffer(0)]],
  constant int &width_arg [[buffer(1)]],
  constant int &height_arg [[buffer(2)]],
  constant int &border_arg [[buffer(3)]],
  constant int &d_arg [[buffer(4)]],
  constant char2 &sgreen_arg [[buffer(5)]],
  device const uchar *xtrans_flat [[buffer(6)]],
  threadgroup float *buffer [[threadgroup(7)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const int d = d_arg;
  const char2 sgreen = sgreen_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);

  // individual control variable in this work group and the work group size
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);

  // stride and maximum capacity of local buffer
  // cells of 4*float per pixel with a surrounding border of 3 cells
  const int stride = xlsz + 2*3;
  const int maxbuf = mul24(stride, ylsz + 2*3);

  // coordinates of top left pixel of buffer
  // this is 3 pixels left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 3;
  const int yul = mul24(ygid, ylsz) - 3;

  // total size of rgb (in units of 4*float)
  const int rgb_max = mul24(width, height);

  // we locally buffer rgb to speed-up reading
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    const int inidx = mad24(yy, width, xx);
    const float4 pixel = (inidx >= 0 && inidx < rgb_max) ? vload4(inidx, rgb) : float4(0.0f);
    vstore4(pixel, bufidx, buffer);
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // center the local buffer around current x,y-Pixel
  threadgroup float *buff = buffer +  4 * mad24(ylid + 3, stride, xlid + 3);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // the "other" color relative to this pixel's one
  const int f = 2 -  FCxtrans(y, x, xtrans);

  // we don't work on green pixels
  if(f == GREEN) return;

  // center rgb around current pixel
  rgb += 4 * mad24(y, width, x);

  // in which direction to sample for the second pixel of this pair (horizontally or vertically)
  const int horiz = (y - sgreen.y) % 3 == 0 ? 1 : 0;
  const int c = horiz ? 4 : 4 * stride;
  const int h = horiz ? 12 * stride : 12;
  const int off = d > 1 || ((d == 0) && (c == 4)) || ((d == 1) && (c != 4)) ||
                  fabs((buff)[1] - (buff + c)[1]) + fabs((buff)[1] - (buff - c)[1]) <
                  2.0f * (fabs((buff)[1] - (buff + h)[1]) + fabs((buff)[1] - (buff - h)[1])) ? c : h;

  rgb[f] = ((buff + off)[f] + (buff - off)[f] + 2.0f * buff[1] - (buff + off)[1] - (buff - off)[1]) / 2.0f;
}


// interpolate red and blue for 2x2 blocks of green
kernel void markesteijn_interpolate_twoxtwo(device float *rgb [[buffer(0)]],
  constant int &width_arg [[buffer(1)]],
  constant int &height_arg [[buffer(2)]],
  constant int &border_arg [[buffer(3)]],
  constant int &d_arg [[buffer(4)]],
  constant char2 &sgreen_arg [[buffer(5)]],
  device const uchar *xtrans_flat [[buffer(6)]],
  device const char2 *allhex_flat [[buffer(7)]],
  threadgroup float *buffer [[threadgroup(8)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const int d = d_arg;
  const char2 sgreen = sgreen_arg;
  device const uchar (*const xtrans)[6] = (device const uchar (*)[6])xtrans_flat;
  device const char2 (*const allhex)[3][8] = (device const char2 (*)[3][8])allhex_flat;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);

  // individual control variable in this work group and the work group size
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);

  // stride and maximum capacity of local buffer
  // cells of 4*float per pixel with a surrounding border of 2 cells
  const int stride = xlsz + 2*2;
  const int maxbuf = mul24(stride, ylsz + 2*2);

  // coordinates of top left pixel of buffer
  // this is 2 pixel left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 2;
  const int yul = mul24(ygid, ylsz) - 2;

  // total size of rgb (in units of 4*float)
  const int rgb_max = mul24(width, height);

  // we locally buffer rgb to speed-up reading
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    const int inidx = mad24(yy, width, xx);
    const float4 pixel = (inidx >= 0 && inidx < rgb_max) ? vload4(inidx, rgb) : float4(0.0f);
    vstore4(pixel, bufidx, buffer);
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // center the local buffer around current x,y-Pixel
  threadgroup float *buff = buffer +  4 * mad24(ylid + 2, stride, xlid + 2);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // we only work on pixels within an 2x2 block of green.
  // for all other pixels which are in the same row or column
  // as the solitary green pixel we skip
  if((y - sgreen.y) % 3 == 0 || (x - sgreen.x) % 3 == 0) return;

  // center rgb around current pixel
  rgb += 4 * mad24(y, width, x);

  // get hexagon of surrounding pixels
  device const char2 *const hex = allhex[y % 3][x % 3];

  const int idx = hexidx4(hex[d], stride);
  const int idx1 = hexidx4(hex[d + 1], stride);

  float m[5];
  if(idx + idx1)
  {
    m[0] = 3.0f;
    m[1] = -2.0f;
    m[2] = -1.0f;
    m[3] = 2.0f;
    m[4] = 1.0f / 3.0f;
  }
  else
  {
    m[0] = 2.0f;
    m[1] = -1.0f;
    m[2] = -1.0f;
    m[3] = 1.0f;
    m[4] = 1.0f / 2.0f;
  }

  const float g = m[0] * buff[1] + m[1] * (buff + idx)[1] + m[2] * (buff + idx1)[1];

  for(int c = 0; c < 4; c += 2)
    rgb[c] = (g + m[3] * (buff + idx)[c] + (buff + idx1)[c]) * m[4];
}


// Convert to perceptual YPbPr colorspace
kernel void markesteijn_convert_yuv(device float *rgb [[buffer(0)]],
  device float *yuv [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // center input and output around current pixel
  const int idx = 4 * mad24(y, width, x);
  rgb += idx;
  yuv += idx;

  const float Y = 0.2627f * rgb[0] + 0.6780f * rgb[1] + 0.0593f * rgb[2];

  yuv[0] = Y;
  yuv[1] = (rgb[2] - Y) * 0.56433f;
  yuv[2] = (rgb[0] - Y) * 0.67815f;
}


// differentiate in all directions
kernel void markesteijn_differentiate(device float *yuv [[buffer(0)]],
  device float *drv [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  constant int &d_arg [[buffer(5)]],
  threadgroup float *buffer [[threadgroup(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const int d = d_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);

  // individual control variable in this work group and the work group size
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);

  // stride and maximum capacity of local buffer
  // cells of 4*float per pixel with a surrounding border of 1 cell
  const int stride = xlsz + 2*1;
  const int maxbuf = mul24(stride, ylsz + 2*1);

  // coordinates of top left pixel of buffer
  // this is 1 pixel left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 1;
  const int yul = mul24(ygid, ylsz) - 1;

  // total size of yuv (in units of 4*float)
  const int yuv_max = mul24(width, height);

  // we locally buffer yuv to speed-up reading
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    const int inidx = mad24(yy, width, xx);
    const float4 pixel = (inidx >= 0 && inidx < yuv_max) ? vload4(inidx, yuv) : float4(0.0f);
    vstore4(pixel, bufidx, buffer);
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // center the local buffer around current x,y-Pixel
  threadgroup float *buff = buffer +  4 * mad24(ylid + 1, stride, xlid + 1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // center drv around current pixel
  drv += mad24(y, width, x);

  const char2 p = dir[d & 3];
  const int off = 4 * mad24(p.y, stride, p.x);

  drv[0] = fsquare(2.0f * (buff)[0] - (buff + off)[0] - (buff - off)[0])
           + fsquare(2.0f * (buff)[1] - (buff + off)[1] - (buff - off)[1])
           + fsquare(2.0f * (buff)[2] - (buff + off)[2] - (buff - off)[2]);
}


// Get threshold for homogeneity maps
kernel void markesteijn_homo_threshold(device float *drv [[buffer(0)]],
  device float *thresh [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  constant int &d_arg [[buffer(5)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const int d = d_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // note: although *thresh points to a buffer of size width*height*4*sizeof(float) we only need one
  // float per cell, so we actually use only a quarter of the buffer

  const int glidx = mad24(y, width, x);

  const float deriv = drv[glidx];

  float tr = (d == 0) ? FLT_MAX : thresh[glidx];

  tr = (tr > deriv) ? deriv : tr;

  thresh[glidx] = tr;
}

// set homogeneity maps
kernel void markesteijn_homo_set(device float *drv [[buffer(0)]],
  device float *thresh [[buffer(1)]],
  device uchar *homo [[buffer(2)]],
  constant int &width_arg [[buffer(3)]],
  constant int &height_arg [[buffer(4)]],
  constant int &border_arg [[buffer(5)]],
  threadgroup float *buffer [[threadgroup(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);

  // individual control variable in this work group and the work group size
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);

  // stride and maximum capacity of local buffer
  // cells of 1*float per pixel with a surrounding border of 1 cell
  const int stride = xlsz + 2*1;
  const int maxbuf = mul24(stride, ylsz + 2*1);

  // coordinates of top left pixel of buffer
  // this is 1 pixel left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 1;
  const int yul = mul24(ygid, ylsz) - 1;

  // total size of drv (in units of 1*float)
  const int drv_max = mul24(width, height);

  // we locally buffer drv to speed-up reading
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    const int inidx = mad24(yy, width, xx);
    buffer[bufidx] = (inidx >= 0 && inidx < drv_max) ? drv[inidx] : 0.0f;
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // center the local buffer around current x,y-Pixel
  threadgroup float *buff = buffer +  mad24(ylid + 1, stride, xlid + 1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  const int glidx = mad24(y, width, x);

  const float tr = fmax(8.0f * thresh[glidx], HOMOGENITY_EPS);

  uchar accu = 0;
  for(int v = -1; v <= 1; v++)
    for(int h = -1; h <= 1; h++)
    {
      const int idx = mad24(v, stride, h);
      accu += (buff[idx] <= tr) ? 1 : 0;
    }

  homo[glidx] = accu;
}


// set homogeneity maps
kernel void markesteijn_homo_sum(device uchar *homo [[buffer(0)]],
  device uchar *homosum [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  threadgroup uchar *buffer [[threadgroup(5)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);
  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);

  // individual control variable in this work group and the work group size
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);

  // stride and maximum capacity of local buffer
  // cells of 1*uchar per pixel with a surrounding border of 2 cells
  const int stride = xlsz + 2*2;
  const int maxbuf = mul24(stride, ylsz + 2*2);

  // coordinates of top left pixel of buffer
  // this is 2 pixel left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 2;
  const int yul = mul24(ygid, ylsz) - 2;

  // total size of homo (in units of 1*uchar)
  const int homo_max = mul24(width, height);

  // we locally buffer homo to speed-up reading
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    const int inidx = mad24(yy, width, xx);
    buffer[bufidx] = (inidx >= 0 && inidx < homo_max) ? homo[inidx] : 0;
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  // center the local buffer around current x,y-Pixel
  threadgroup uchar *buff = buffer +  mad24(ylid + 2, stride, xlid + 2);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  const int glidx = mad24(y, width, x);

  uchar accu = 0;
  for(int v = -2; v <= 2; v++)
    for(int h = -2; h <= 2; h++)
    {
      const int idx = mad24(v, stride, h);
      accu += buff[idx];
    }

  homosum[glidx] = accu;
}


// get maximum value for homosum
kernel void markesteijn_homo_max(device uchar *homosum [[buffer(0)]],
  device uchar *maxval [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  constant int &d_arg [[buffer(5)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;
  const int d = d_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // note: although *maxval points to a buffer of size width*height*4*sizeof(float) we only need one
  // uchar per cell, so we actually only use a fraction of the buffer

  const int glidx = mad24(y, width, x);

  const uchar hm = homosum[glidx];

  uchar hmax = (d == 0) ? 0 : maxval[glidx];

  hmax = (hmax < hm) ? hm : hmax;

  maxval[glidx] = hmax;
}


// adjust maximum value for homosum
kernel void markesteijn_homo_max_corr(device uchar *maxval [[buffer(0)]],
  constant int &width_arg [[buffer(1)]],
  constant int &height_arg [[buffer(2)]],
  constant int &border_arg [[buffer(3)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  // note: although *maxval points to a buffer of size width*height*4*sizeof(float) we only need one
  // uchar per cell, so we actually only use a fraction of the buffer

  const int glidx = mad24(y, width, x);

  uchar hmax = maxval[glidx];

  hmax -= hmax >> 3;

  maxval[glidx] = hmax;
}

// for Markesteijn-3: only use one of two directions if one is better than the other
kernel void markesteijn_homo_quench(device uchar *homosum1 [[buffer(0)]],
  device uchar *homosum2 [[buffer(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  const int glidx = mad24(y, width, x);

  uchar hmi1, hmi2, hmo1, hmo2;

  hmi1 = hmo1 = homosum1[glidx];
  hmi2 = hmo2 = homosum2[glidx];

  hmo1 = (hmi1 < hmi2) ? 0 : hmo1;
  hmo2 = (hmi1 > hmi2) ? 0 : hmo2;

  homosum1[glidx] = hmo1;
  homosum2[glidx] = hmo2;
}

// accumulate contributions of all directions into output image
kernel void markesteijn_accu(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  device float *rgb [[buffer(2)]],
  device uchar *homosum [[buffer(3)]],
  device uchar *maxval [[buffer(4)]],
  constant int &width_arg [[buffer(5)]],
  constant int &height_arg [[buffer(6)]],
  constant int &border_arg [[buffer(7)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  const int glidx = mad24(y, width, x);

  float4 pixel = Areadpixel(in, x, y);
  float4 add = vload4(glidx, rgb);
  add.w = 1.0f;

  pixel += (homosum[glidx] >= maxval[glidx]) ? add : float4(0.0f);

  write_imagef(out, int2(x, y), pixel);
}


// process the final image
kernel void markesteijn_final(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &border_arg [[buffer(4)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int border = border_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  // take sufficient border into account
  if(x < border || x >= width-border || y < border || y >= height-border) return;

  float4 pixel = Areadpixel(in, x, y);

  pixel = (pixel.w > 0.0f) ? pixel/pixel.w : float4(0.0f);
  pixel.w = 0.0f;

  write_imagef(out, int2(x, y), fmax(float4(0.0f), pixel));
}

