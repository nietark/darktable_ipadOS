// Metal port of data/kernels/demosaic_ppg.cl
// ported-from-md5: a70a330024f50b036c252bc865151929
// ported kernels: border_interpolate, ppg_demosaic_green, ppg_demosaic_redblue, clip_and_zoom_demosaic_half_size
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
// FC return values are either 0/1/2/3 = G/M/C/Y or 0/1/2/3 = R/G1/B/G2
#define FCV(val, col) ((col == 0) ? val.x : ((col & 1) ? val.y : val.z) )





#define SWAP(a, b)                \
  {                               \
    const float tmp = (b);        \
    (b) = (a);                    \
    (a) = tmp;                    \
  }

constant int glim[5] = { 0, 1, 2, 1, 0 };

#undef SWAP

// This median filter is inspired by GPL code from socles, an OpenCL image processing library.

#define cas(a, b)				\
	do {					\
		float x = a;			\
		int c = a > b;			\
		a = c ? b : a;			\
		b = c ? x : b;			\
	} while (0)


// 3x3 median filter
// uses a sorting network to sort entirely in registers with no branches

#undef cas


/**
 * downscales and clips a mosaiced buffer (in) to the given region of interest (r_*)
 * and writes it to out in float4 format.
 * filters is the dcraw supplied int encoding the bayer pattern.
 * resamping is done via rank-1 lattices and demosaicing using half-size interpolation.
 */
kernel void clip_and_zoom_demosaic_half_size(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant int &rin_wd_arg [[buffer(4)]],
  constant int &rin_ht_arg [[buffer(5)]],
  constant float &r_scale_arg [[buffer(6)]],
  constant uint &filters_arg [[buffer(7)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const int rin_wd = rin_wd_arg;
  const int rin_ht = rin_ht_arg;
  const float r_scale = r_scale_arg;
  const uint filters = filters_arg;

  // global id is pixel in output image (float4)
  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;

  float4 color = float4(0.0f, 0.0f, 0.0f, 0.0f);
  float weight = 0.0f;

  // adjust to pixel region and don't sample more than scale/2 nbs!
  // pixel footprint on input buffer, radius:
  const float px_footprint = 1.0f/r_scale;
  // how many 2x2 blocks can be sampled inside that area
  const int samples = round(px_footprint/2.0f);

  int trggbx = 0, trggby = 0;
  if(FC(trggby, trggbx+1, filters) != 1) trggbx++;
  if(FC(trggby, trggbx,   filters) != 0)
  {
    trggbx = (trggbx + 1)&1;
    trggby++;
  }
  const int2 rggb = int2(trggbx, trggby);


  // upper left corner:
  const float2 f = float2(x * px_footprint, y * px_footprint);
  int2 p = int2((int)f.x & ~1, (int)f.y & ~1);
  const float2 d = float2((f.x - p.x)/2.0f, (f.y - p.y)/2.0f);

  // now move p to point to an rggb block:
  p += rggb;

  for(int j=0;j<=samples+1;j++) for(int i=0;i<=samples+1;i++)
  {
    const int xx = p.x + 2*i;
    const int yy = p.y + 2*j;

    if(xx + 1 >= rin_wd || yy + 1 >= rin_ht) continue;

    const float xfilter = (i == 0) ? 1.0f - d.x : ((i == samples+1) ? d.x : 1.0f);
    const float yfilter = (j == 0) ? 1.0f - d.y : ((j == samples+1) ? d.y : 1.0f);

    // get four mosaic pattern uint16:
    const float p1 = fmax(0.0f, readsingle(in, xx,   yy  ));
    const float p2 = fmax(0.0f, readsingle(in, xx+1, yy  ));
    const float p3 = fmax(0.0f, readsingle(in, xx,   yy+1));
    const float p4 = fmax(0.0f, readsingle(in, xx+1, yy+1));
    color += yfilter*xfilter*float4(p1, (p2+p3)*0.5f, p4, 0.0f);
    weight += yfilter*xfilter;
  }
  color = (weight > 0.0f) ? color/weight : float4(0.0f);
  write_ipixel(out, int2(x, y), color);
}


/**
 * fill greens pass of pattern pixel grouping.
 * in (float) or (float4).x -> out (float4)
 */
kernel void ppg_demosaic_green(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant uint &filters_arg [[buffer(4)]],
  threadgroup float *buffer [[threadgroup(5)]],
  constant int &border_arg [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const uint filters = filters_arg;
  const int border = border_arg;

  const int col = get_global_id(0);
  const int row = get_global_id(1);
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

  // populate local memory buffer
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    buffer[bufidx] = readsingle(in, xx, yy);
  }

  // center buffer around current x,y-Pixel
  buffer += mad24(ylid + 3, stride, xlid + 3);

  barrier(CLK_LOCAL_MEM_FENCE);

  if(col >= width - 3 || col < 3 || row >= height - 3 || row < 3) return;
  if(col >= border && col < width - border && row >= border && row < height - border) return;

  // process all non-green pixels
  const int c = FC(row, col, filters);
  float4 color = 0.0f; // output color

  const float pc = buffer[0];

  if     (c == RED) color.x = pc;
  else if(c == GREEN) color.y = pc;
  else if(c == BLUE) color.z = pc;
  else            color.y = pc; // green2

  // fill green layer for red and blue pixels:
  if(c == RED || c == BLUE)
  {
    // look up horizontal and vertical neighbours, sharpened weight:
    const float pym  = buffer[-1 * stride];
    const float pym2 = buffer[-2 * stride];
    const float pym3 = buffer[-3 * stride];
    const float pyM  = buffer[ 1 * stride];
    const float pyM2 = buffer[ 2 * stride];
    const float pyM3 = buffer[ 3 * stride];
    const float pxm  = buffer[-1];
    const float pxm2 = buffer[-2];
    const float pxm3 = buffer[-3];
    const float pxM  = buffer[ 1];
    const float pxM2 = buffer[ 2];
    const float pxM3 = buffer[ 3];
    const float guessx = (pxm + pc + pxM) * 2.0f - pxM2 - pxm2;
    const float diffx  = (fabs(pxm2 - pc) +
                          fabs(pxM2 - pc) +
                          fabs(pxm  - pxM)) * 3.0f +
                         (fabs(pxM3 - pxM) + fabs(pxm3 - pxm)) * 2.0f;
    const float guessy = (pym + pc + pyM) * 2.0f - pyM2 - pym2;
    const float diffy  = (fabs(pym2 - pc) +
                          fabs(pyM2 - pc) +
                          fabs(pym  - pyM)) * 3.0f +
                         (fabs(pyM3 - pyM) + fabs(pym3 - pym)) * 2.0f;
    if(diffx > diffy)
    {
      // use guessy
      const float m = fmin(pym, pyM);
      const float M = fmax(pym, pyM);
      color.y = fmax(fmin(guessy*0.25f, M), m);
    }
    else
    {
      const float m = fmin(pxm, pxM);
      const float M = fmax(pxm, pxM);
      color.y = fmax(fmin(guessx*0.25f, M), m);
    }
  }
  write_imagef(out, int2(col, row), fmax(float4(0.0f), color));
}


/**
 * fills the reds and blues in the gaps (done after ppg_demosaic_green).
 * in (float4) -> out (float4)
 */
kernel void ppg_demosaic_redblue(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant uint &filters_arg [[buffer(4)]],
  threadgroup float4 *buffer [[threadgroup(5)]],
  constant int &border_arg [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const uint filters = filters_arg;
  const int border = border_arg;

  // image in contains full green and sparse r b
  const int col = get_global_id(0);
  const int row = get_global_id(1);
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
  // cells of float4 per pixel with a surrounding border of 1 cell
  const int stride = xlsz + 2;
  const int maxbuf = mul24(stride, ylsz + 2);

  // coordinates of top left pixel of buffer
  // this is 1 pixel left and above of the work group origin
  const int xul = mul24(xgid, xlsz) - 1;
  const int yul = mul24(ygid, ylsz) - 1;

  // populate local memory buffer
  for(int n = 0; n <= maxbuf/lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = xul + bufidx % stride;
    const int yy = yul + bufidx / stride;
    buffer[bufidx] = readpixel(in, xx, yy);
  }

  // center buffer around current x,y-Pixel
  buffer += mad24(ylid + 1, stride, xlid + 1);

  barrier(CLK_LOCAL_MEM_FENCE);

  if(col >= width || row >= height) return;
  if(col >= border && col < width - border && row >= border && row < height - border) return;

  const int c = FC(row, col, filters);
  float4 color = buffer[0];
  if(row > 0 && col > 0 && col < width - 1 && row < height - 1)
  {
    if(c == GREEN || c == 3)
    { // calculate red and blue for green pixels:
      // need 4-nbhood:
      const float4 nt = buffer[-stride];
      const float4 nb = buffer[ stride];
      const float4 nl = buffer[-1];
      const float4 nr = buffer[ 1];
      if(FC(row, col+1, filters) == RED) // red nb in same row
      {
        color.z = (nt.z + nb.z + 2.0f*color.y - nt.y - nb.y)*0.5f;
        color.x = (nl.x + nr.x + 2.0f*color.y - nl.y - nr.y)*0.5f;
      }
      else
      { // blue nb
        color.x = (nt.x + nb.x + 2.0f*color.y - nt.y - nb.y)*0.5f;
        color.z = (nl.z + nr.z + 2.0f*color.y - nl.y - nr.y)*0.5f;
      }
    }
    else
    {
      // get 4-star-nbhood:
      const float4 ntl = buffer[-stride - 1];
      const float4 ntr = buffer[-stride + 1];
      const float4 nbl = buffer[ stride - 1];
      const float4 nbr = buffer[ stride + 1];

      if(c == RED)
      { // red pixel, fill blue:
        const float diff1  = fabs(ntl.z - nbr.z) + fabs(ntl.y - color.y) + fabs(nbr.y - color.y);
        const float guess1 = ntl.z + nbr.z + 2.0f*color.y - ntl.y - nbr.y;
        const float diff2  = fabs(ntr.z - nbl.z) + fabs(ntr.y - color.y) + fabs(nbl.y - color.y);
        const float guess2 = ntr.z + nbl.z + 2.0f*color.y - ntr.y - nbl.y;
        if     (diff1 > diff2) color.z = guess2 * 0.5f;
        else if(diff1 < diff2) color.z = guess1 * 0.5f;
        else color.z = (guess1 + guess2)*0.25f;
      }
      else // c == 2, blue pixel, fill red:
      {
        const float diff1  = fabs(ntl.x - nbr.x) + fabs(ntl.y - color.y) + fabs(nbr.y - color.y);
        const float guess1 = ntl.x + nbr.x + 2.0f*color.y - ntl.y - nbr.y;
        const float diff2  = fabs(ntr.x - nbl.x) + fabs(ntr.y - color.y) + fabs(nbl.y - color.y);
        const float guess2 = ntr.x + nbl.x + 2.0f*color.y - ntr.y - nbl.y;
        if     (diff1 > diff2) color.x = guess2 * 0.5f;
        else if(diff1 < diff2) color.x = guess1 * 0.5f;
        else color.x = (guess1 + guess2)*0.25f;
      }
    }
  }
  write_imagef(out, int2(col, row), fmax(float4(0.0f), color));
}

/**
 * Demosaic image border for the three outermost photosites
 */
kernel void border_interpolate(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant uint &filters_arg [[buffer(4)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const uint filters = filters_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;
  if(x >= 3 && x < width-3 && y >= 3 && y < height-3) return;

  float4 o;
  float sum[4] = { 0.0f };
  int count[4] = { 0 };

  for(int j=y-1; j<=y+1; j++) for (int i=x-1; i<=x+1; i++)
  {
    if(j>=0 && i>=0 && j<height && i<width)
    {
      const int f = FC(j,i,filters);
      sum[f] += readsingle(in, i, j);
      count[f]++;
    }
  }

  const float i = fmax(0.0f, readsingle(in, x, y));
  o.x = count[0] > 0 ? sum[0]/count[0] : i;
  o.y = count[1]+count[3] > 0 ? (sum[1]+sum[3])/(count[1]+count[3]) : i;
  o.z = count[2] > 0 ? sum[2]/count[2] : i;

  const int f = FC(y,x,filters);

  if     (f == 0) o.x = i;
  else if(f == 1) o.y = i;
  else if(f == 2) o.z = i;
  else            o.y = i;

  write_imagef(out, int2(x, y), fmax(float4(0.0f), o));
}
