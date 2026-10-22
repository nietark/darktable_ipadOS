// Metal port of data/kernels/colorspaces.cl
// ported-from-md5: ade4d5ef490be379b4f166527e374406
// ported kernels: colorspaces_transform_lab_to_rgb_matrix, colorspaces_transform_rgb_matrix_to_lab
/*
    This file is part of darktable,
    Copyright (C) 2019-2026 darktable developers.

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
#include "color_conversion.metal.h"
#include "colorspace.metal.h"

kernel void colorspaces_transform_lab_to_rgb_matrix(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant const dt_colorspaces_iccprofile_info_cl_t *profile_info [[buffer(4)]],
  texture2d<float, access::read> lut [[texture(5)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;

  float4 pixel = Areadpixel(in, x, y);
  pixel.xyz = Lab_to_XYZ(pixel).xyz;
  pixel = matrix_product(pixel, profile_info->matrix_out);

  if(profile_info->nonlinearlut)
    pixel = apply_trc_out(pixel, profile_info, lut);

  write_imagef(out, int2(x, y), pixel);
}

kernel void colorspaces_transform_rgb_matrix_to_lab(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant const dt_colorspaces_iccprofile_info_cl_t *profile_info [[buffer(4)]],
  texture2d<float, access::read> lut [[texture(5)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;

  const int x = get_global_id(0);
  const int y = get_global_id(1);

  if(x >= width || y >= height) return;

  float4 pixel = Areadpixel(in, x, y);

  if(profile_info->nonlinearlut)
    pixel = apply_trc_in(pixel, profile_info, lut);

  pixel = matrix_product(pixel, profile_info->matrix_in);
  pixel.xyz = XYZ_to_Lab(pixel).xyz;

  write_imagef(out, int2(x, y), pixel);
}

