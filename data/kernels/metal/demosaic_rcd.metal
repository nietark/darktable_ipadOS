// Metal port of data/kernels/demosaic_rcd.cl
// ported-from-md5: c621a9c3e5f86f2f5a5aaf8bf3f008f6
// ported kernels: rcd_populate, rcd_step_1, rcd_step_2, rcd_step_3, rcd_step_4_0, rcd_step_4_1, rcd_step_4_2, rcd_step_4_3, rcd_write_output
/*
    This file is part of darktable,
    Copyright (C) 2020-2026 darktable developers.

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
/** Correct index into "half-width" cl_mem buffers if the buffer has an odd width
    is not a simple idx-full / 2!
*/

static inline int _half_idx(const int row, const int col, const int w)
{
  return mad24(row, (w + 1) / 2, col / 2);
}

// Populate cfa and rgb data by normalized input
kernel void rcd_populate(texture2d<float, access::read> in [[texture(0)]],
  device float *cfa [[buffer(1)]],
  device float *rgb0 [[buffer(2)]],
  device float *rgb1 [[buffer(3)]],
  device float *rgb2 [[buffer(4)]],
  constant int &w_arg [[buffer(5)]],
  constant int &height_arg [[buffer(6)]],
  constant uint &filters_arg [[buffer(7)]],
  constant float &scale_arg [[buffer(8)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;
  const uint filters = filters_arg;
  const float scale = scale_arg;

  const int col = get_global_id(0);
  const int row = get_global_id(1);
  if(col >= w || row >= height) return;
  const float val = scale * fmax(0.0f, Areadsingle(in, col, row));
  const int c0 = FC(row, 0, filters);
  const int c1 = FC(row, 1, filters);
  device float *p0 = (c0 == GREEN) ? rgb1 : (c0 == BLUE) ? rgb2 : rgb0;
  device float *p1 = (c1 == GREEN) ? rgb1 : (c1 == BLUE) ? rgb2 : rgb0;
  const int idx = mad24(row, w, col);
  cfa[idx] = p0[idx] = p1[idx] = val;
}

// Write back-normalized data in rgb channels to output
kernel void rcd_write_output(texture2d<float, access::write> out [[texture(0)]],
  device float *rgb0 [[buffer(1)]],
  device float *rgb1 [[buffer(2)]],
  device float *rgb2 [[buffer(3)]],
  constant int &w_arg [[buffer(4)]],
  constant int &height_arg [[buffer(5)]],
  constant float &scale_arg [[buffer(6)]],
  constant int &border_arg [[buffer(7)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;
  const float scale = scale_arg;
  const int border = border_arg;

  const int col = get_global_id(0);
  const int row = get_global_id(1);
  if(!(col >= border && col < w - border && row >= border && row < height - border)) return;
  const int idx = mad24(row, w, col);

  write_imagef(out, int2(col, row), fmax(float4(0.0f), float4(scale * rgb0[idx], scale * rgb1[idx], scale * rgb2[idx], 0.0f)));
}

#define eps 1e-5f              // Tolerance to avoid dividing by zero
#define epssq 1e-10f

static inline float rcd_vdiff_local(threadgroup const float *buf, const int stride)
{
  return fsquare(buf[-3 * stride] - buf[-stride] - buf[stride] + buf[3 * stride] - 3.0f *(buf[-2 * stride] + buf[2 * stride]) + 6.0f * buf[0]);
}

static inline float rcd_hdiff_local(threadgroup const float *buf)
{
  return fsquare(buf[-3] - buf[-1] - buf[1] + buf[3] - 3.0f *(buf[-2] + buf[2]) + 6.0f * buf[0]);
}

// Step 1.1 + 1.2: preload one CFA tile and derive the directional discrimination locally
// so we avoid materializing two full-frame high-pass buffers in global memory.
// helpers and rcd_step_1 from ansel code @aurelienpierre
kernel void rcd_step_1(device float *cfa [[buffer(0)]],
  device float *VH_dir [[buffer(1)]],
  constant int &w_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  threadgroup float *buffer [[threadgroup(4)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;

  const int xlsz = get_local_size(0);
  const int ylsz = get_local_size(1);
  const int xlid = get_local_id(0);
  const int ylid = get_local_id(1);
  const int xgid = get_group_id(0);
  const int ygid = get_group_id(1);
  const int l = mad24(ylid, xlsz, xlid);
  const int lsz = mul24(xlsz, ylsz);
  const int stride = xlsz + 8;
  const int maxbuf = mul24(stride, ylsz + 8);
  const int xul = mul24(xgid, xlsz) - 2;
  const int yul = mul24(ygid, ylsz) - 2;

  for(int n = 0; n <= maxbuf / lsz; n++)
  {
    const int bufidx = mad24(n, lsz, l);
    if(bufidx >= maxbuf) continue;
    const int xx = clamp(xul + bufidx % stride, 0, w - 1);
    const int yy = clamp(yul + bufidx / stride, 0, height - 1);
    buffer[bufidx] = cfa[mad24(yy, w, xx)];
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  const int col = 2 + get_global_id(0);
  const int row = 2 + get_global_id(1);
  if((row > height - 3) || (col > w - 3)) return;
  const int idx = mad24(row, w, col);
  threadgroup const float *buf = buffer + mad24(ylid + 4, stride, xlid + 4);

  const float V_Stat = fmax(epssq, rcd_vdiff_local(buf - stride, stride)
                                  + rcd_vdiff_local(buf, stride)
                                  + rcd_vdiff_local(buf + stride, stride));
  const float H_Stat = fmax(epssq, rcd_hdiff_local(buf - 1)
                                  + rcd_hdiff_local(buf)
                                  + rcd_hdiff_local(buf + 1));
  VH_dir[idx] = (row < 4 || row > height - 5 || col < 4 || col > w - 5)
                ? 0.0f : fp32_div(V_Stat, V_Stat + H_Stat);
}

// Step 2: Low pass filter incorporating green, red and blue local samples from the raw data
kernel void rcd_step_2(device float *lpf [[buffer(0)]],
  device float *cfa [[buffer(1)]],
  constant int &w_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant uint &filters_arg [[buffer(4)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;
  const uint filters = filters_arg;

  const int row = 2 + get_global_id(1);
  const int col = 2 + (FC(row, 0, filters) & 1) + 2 *get_global_id(0);
  if((col > w - 3) || (row > height - 3)) return;
  const int idx = mad24(row, w, col);

  lpf[_half_idx(row, col, w)] = cfa[idx]
     + 0.5f * (cfa[idx - w    ] + cfa[idx + w    ] + cfa[idx     - 1] + cfa[idx     + 1])
    + 0.25f * (cfa[idx - w - 1] + cfa[idx - w + 1] + cfa[idx + w - 1] + cfa[idx + w + 1]);
}

// Step 3: Populate the green channel at blue and red CFA positions
kernel void rcd_step_3(device float *lpf [[buffer(0)]],
  device float *cfa [[buffer(1)]],
  device float *rgb1 [[buffer(2)]],
  device float *VH_Dir [[buffer(3)]],
  constant int &w_arg [[buffer(4)]],
  constant int &height_arg [[buffer(5)]],
  constant uint &filters_arg [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;
  const uint filters = filters_arg;

  const int row = 4 + get_global_id(1);
  const int col = 4 + (FC(row, 0, filters) & 1) + 2 * get_global_id(0);
  if((col > w - 5) || (row > height - 5)) return;
  const int idx = mad24(row, w, col);
  const int lidx = _half_idx(row, col, w);
  const int hw2 = 2 * ((w + 1) / 2); // two rows in the half-width buffer
  const int w2 = 2 * w;
  const int w3 = 3 * w;
  const int w4 = 4 * w;

  // Refined vertical and horizontal local discrimination
  const float VH_Central_Value   = VH_Dir[idx];
  const float VH_Neighbourhood_Value = 0.25f * (VH_Dir[idx - w - 1] + VH_Dir[idx - w + 1] + VH_Dir[idx + w - 1] + VH_Dir[idx + w + 1]);
  const float VH_Disc = (fabs( 0.5f - VH_Central_Value ) < fabs(0.5f - VH_Neighbourhood_Value)) ? VH_Neighbourhood_Value : VH_Central_Value;

  const float cfai = cfa[idx];
  // Cardinal gradients
  const float N_Grad = eps + fabs(cfa[idx - w] - cfa[idx + w]) + fabs(cfai - cfa[idx - w2]) + fabs(cfa[idx - w] - cfa[idx - w3]) + fabs(cfa[idx - w2] - cfa[idx - w4]);
  const float S_Grad = eps + fabs(cfa[idx + w] - cfa[idx - w]) + fabs(cfai - cfa[idx + w2]) + fabs(cfa[idx + w] - cfa[idx + w3]) + fabs(cfa[idx + w2] - cfa[idx + w4]);
  const float W_Grad = eps + fabs(cfa[idx - 1] - cfa[idx + 1]) + fabs(cfai - cfa[idx -  2]) + fabs(cfa[idx - 1] - cfa[idx -  3]) + fabs(cfa[idx -  2] - cfa[idx -  4]);
  const float E_Grad = eps + fabs(cfa[idx + 1] - cfa[idx - 1]) + fabs(cfai - cfa[idx +  2]) + fabs(cfa[idx + 1] - cfa[idx +  3]) + fabs(cfa[idx +  2] - cfa[idx +  4]);

  const float lfpi = lpf[lidx];
  // Cardinal pixel estimations
  const float N_Est = fp32_div(cfa[idx - w] * (lfpi + lfpi), eps + lfpi + lpf[lidx - hw2]);
  const float S_Est = fp32_div(cfa[idx + w] * (lfpi + lfpi), eps + lfpi + lpf[lidx + hw2]);
  const float W_Est = fp32_div(cfa[idx - 1] * (lfpi + lfpi), eps + lfpi + lpf[lidx - 1]);
  const float E_Est = fp32_div(cfa[idx + 1] * (lfpi + lfpi), eps + lfpi + lpf[lidx + 1]);

  // Vertical and horizontal estimations
  const float V_Est = fp32_div(S_Grad * N_Est + N_Grad * S_Est, N_Grad + S_Grad);
  const float H_Est = fp32_div(W_Grad * E_Est + E_Grad * W_Est, E_Grad + W_Grad);

  // G@B and G@R interpolation
  rgb1[idx] = mix(V_Est, H_Est, clipf(VH_Disc));
}

// Step 4.0: Calculate the square of the P/Q diagonals color difference high pass filter
kernel void rcd_step_4_0(device float *cfa [[buffer(0)]],
  device float *p_diff [[buffer(1)]],
  device float *q_diff [[buffer(2)]],
  constant int &w_arg [[buffer(3)]],
  constant int &height_arg [[buffer(4)]],
  constant uint &filters_arg [[buffer(5)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;
  const uint filters = filters_arg;

  const int row = 3 + get_global_id(1);
  const int col = 3 + 2 * get_global_id(0);
  if((col > w - 4) || (row > height - 4)) return;
  const int idx = mad24(row, w, col);
  const int idx2 = _half_idx(row, col, w);
  const int w2 = 2 * w;
  const int w3 = 3 * w;

  p_diff[idx2] = fsquare((cfa[idx - w3 - 3] - cfa[idx - w - 1] - cfa[idx + w + 1] + cfa[idx + w3 + 3]) - 3.0f * (cfa[idx - w2 - 2] + cfa[idx + w2 + 2]) + 6.0f * cfa[idx]);
  q_diff[idx2] = fsquare((cfa[idx - w3 + 3] - cfa[idx - w + 1] - cfa[idx + w - 1] + cfa[idx + w3 - 3]) - 3.0f * (cfa[idx - w2 + 2] + cfa[idx + w2 - 2]) + 6.0f * cfa[idx]);
}

// Step 4.1: Calculate P/Q diagonals local discrimination strength
kernel void rcd_step_4_1(device float *PQ_dir [[buffer(0)]],
  device float *p_diff [[buffer(1)]],
  device float *q_diff [[buffer(2)]],
  constant int &w_arg [[buffer(3)]],
  constant int &height_arg [[buffer(4)]],
  constant uint &filters_arg [[buffer(5)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;
  const uint filters = filters_arg;

  const int row = 2 + get_global_id(1);
  const int col = 2 + (FC(row, 0, filters) & 1) + 2 *get_global_id(0);
  if(row < 4 || (col > w - 5) || (row > height - 5)) return;
  const int idx2 = _half_idx(row, col, w);
  const int idx3 = _half_idx(row - 1, col - 1, w);
  const int idx4 = _half_idx(row + 1, col - 1, w);

  const float P_Stat = fmax(epssq, p_diff[idx3]     + p_diff[idx2] + p_diff[idx4 + 1]);
  const float Q_Stat = fmax(epssq, q_diff[idx3 + 1] + q_diff[idx2] + q_diff[idx4]);
  PQ_dir[idx2] = fp32_div(P_Stat, P_Stat + Q_Stat);
}

// Step 4.2: Populate the red and blue channels at blue and red CFA positions
kernel void rcd_step_4_2(device float *PQ_dir [[buffer(0)]],
  device float *rgb0 [[buffer(1)]],
  device float *rgb1 [[buffer(2)]],
  device float *rgb2 [[buffer(3)]],
  constant int &w_arg [[buffer(4)]],
  constant int &height_arg [[buffer(5)]],
  constant uint &filters_arg [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;
  const uint filters = filters_arg;

  const int row = 4 + get_global_id(1);
  const int col = 4 + (FC(row, 0, filters) & 1) + 2 * get_global_id(0);
  if((col > w - 5) || (row > height - 5)) return;

  const int color = 2 - FC(row, col, filters);

  device float *rgbc = rgb0;
  if(color == GREEN) rgbc = rgb1;
  else if(color == BLUE) rgbc = rgb2;

  const int idx = mad24(row, w, col);
  const int pqidx = _half_idx(row, col, w);
  const int pqidx2 = _half_idx(row - 1, col - 1, w);
  const int pqidx3 = _half_idx(row + 1, col - 1, w);
  const int w2 = 2 * w;
  const int w3 = 3 * w;

  const float PQ_Central_Value   = PQ_dir[pqidx];
  const float PQ_Neighbourhood_Value = 0.25f * (PQ_dir[pqidx2] + PQ_dir[pqidx2 + 1] + PQ_dir[pqidx3] + PQ_dir[pqidx3 + 1]);
  const float PQ_Disc = (fabs(0.5f - PQ_Central_Value) < fabs(0.5f - PQ_Neighbourhood_Value)) ? PQ_Neighbourhood_Value : PQ_Central_Value;

  const float NW_Grad = eps + fabs(rgbc[idx - w - 1] - rgbc[idx + w + 1]) + fabs(rgbc[idx - w - 1] - rgbc[idx - w3 - 3]) + fabs(rgb1[idx] - rgb1[idx - w2 - 2]);
  const float NE_Grad = eps + fabs(rgbc[idx - w + 1] - rgbc[idx + w - 1]) + fabs(rgbc[idx - w + 1] - rgbc[idx - w3 + 3]) + fabs(rgb1[idx] - rgb1[idx - w2 + 2]);
  const float SW_Grad = eps + fabs(rgbc[idx - w + 1] - rgbc[idx + w - 1]) + fabs(rgbc[idx + w - 1] - rgbc[idx + w3 - 3]) + fabs(rgb1[idx] - rgb1[idx + w2 - 2]);
  const float SE_Grad = eps + fabs(rgbc[idx - w - 1] - rgbc[idx + w + 1]) + fabs(rgbc[idx + w + 1] - rgbc[idx + w3 + 3]) + fabs(rgb1[idx] - rgb1[idx + w2 + 2]);

  const float NW_Est = rgbc[idx - w - 1] - rgb1[idx - w - 1];
  const float NE_Est = rgbc[idx - w + 1] - rgb1[idx - w + 1];
  const float SW_Est = rgbc[idx + w - 1] - rgb1[idx + w - 1];
  const float SE_Est = rgbc[idx + w + 1] - rgb1[idx + w + 1];

  const float P_Est = fp32_div(NW_Grad * SE_Est + SE_Grad * NW_Est, NW_Grad + SE_Grad);
  const float Q_Est = fp32_div(NE_Grad * SW_Est + SW_Grad * NE_Est, NE_Grad + SW_Grad);

  rgbc[idx]= rgb1[idx] + mix(P_Est, Q_Est, clipf(PQ_Disc));
}

// Step 4.3: Populate the red and blue channels at green CFA positions
kernel void rcd_step_4_3(device float *VH_dir [[buffer(0)]],
  device float *rgb0 [[buffer(1)]],
  device float *rgb1 [[buffer(2)]],
  device float *rgb2 [[buffer(3)]],
  constant int &w_arg [[buffer(4)]],
  constant int &height_arg [[buffer(5)]],
  constant uint &filters_arg [[buffer(6)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int w = w_arg;
  const int height = height_arg;
  const uint filters = filters_arg;

  const int row = 4 + get_global_id(1);
  const int col = 4 + (FC(row, 1, filters) & 1) + 2 * get_global_id(0);
  if((col > w - 5) || (row > height - 5)) return;

  const int idx = mad24(row, w, col);
  const int w2 = 2 * w;
  const int w3 = 3 * w;

  // Refined vertical and horizontal local discrimination
  const float VH_Central_Value   = VH_dir[idx];
  const float VH_Neighbourhood_Value = 0.25f * (VH_dir[idx - w - 1] + VH_dir[idx - w + 1] + VH_dir[idx + w - 1] + VH_dir[idx + w + 1]);
  const float VH_Disc = (fabs(0.5f - VH_Central_Value) < fabs(0.5f - VH_Neighbourhood_Value)) ? VH_Neighbourhood_Value : VH_Central_Value;

  const float rgbi1 = rgb1[idx];
  const float N1 = eps + fabs(rgbi1 - rgb1[idx - w2]);
  const float S1 = eps + fabs(rgbi1 - rgb1[idx + w2]);
  const float W1 = eps + fabs(rgbi1 - rgb1[idx -  2]);
  const float E1 = eps + fabs(rgbi1 - rgb1[idx +  2]);

  const float rgb1mw1 = rgb1[idx - w];
  const float rgb1pw1 = rgb1[idx + w];
  const float rgb1m1 =  rgb1[idx - 1];
  const float rgb1p1 =  rgb1[idx + 1];


  for(int c = 0; c <= 2; c += 2)
  {
    device float *rgbc = (c == RED) ? rgb0 : rgb2;

    const float SNabs = fabs(rgbc[idx - w] - rgbc[idx + w]);
    const float EWabs = fabs(rgbc[idx - 1] - rgbc[idx + 1]);

    // Cardinal gradients
    const float N_Grad = N1 + SNabs + fabs(rgbc[idx - w] - rgbc[idx - w3]);
    const float S_Grad = S1 + SNabs + fabs(rgbc[idx + w] - rgbc[idx + w3]);
    const float W_Grad = W1 + EWabs + fabs(rgbc[idx - 1] - rgbc[idx -  3]);
    const float E_Grad = E1 + EWabs + fabs(rgbc[idx + 1] - rgbc[idx +  3]);

    // Cardinal colour differences
    const float N_Est = rgbc[idx - w] - rgb1mw1;
    const float S_Est = rgbc[idx + w] - rgb1pw1;
    const float W_Est = rgbc[idx - 1] - rgb1m1;
    const float E_Est = rgbc[idx + 1] - rgb1p1;

    // Vertical and horizontal estimations
    const float V_Est = fp32_div(N_Grad * S_Est + S_Grad * N_Est, N_Grad + S_Grad);
    const float H_Est = fp32_div(E_Grad * W_Est + W_Grad * E_Est, E_Grad + W_Grad);

    // R@G and B@G interpolation
    rgbc[idx] = rgb1[idx] + mix(V_Est, H_Est, clipf(VH_Disc));
  }
}

#undef eps
#undef epssq

