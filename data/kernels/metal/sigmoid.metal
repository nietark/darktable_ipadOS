// Metal port of data/kernels/sigmoid.cl
// ported-from-md5: f2249e43110800baaae3f08170882f2a
// ported kernels: sigmoid_loglogistic_per_channel
/*
    This file is part of darktable,
    copyright (c) 2023-2026 darktable developers.

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


typedef struct dt_iop_sigmoid_value_order_t
{
  size_t min;
  size_t mid;
  size_t max;
} dt_iop_sigmoid_value_order_t;

static void _pixel_channel_order(thread const float *pix_in, thread dt_iop_sigmoid_value_order_t *pixel_value_order)
{
  if (pix_in[0] >= pix_in[1])
  {
    if (pix_in[1] > pix_in[2])
    {  // Case 1: r >= g >  b
      pixel_value_order->max = 0;
      pixel_value_order->mid = 1;
      pixel_value_order->min = 2;
    }
    else if (pix_in[2] > pix_in[0])
    {  // Case 2: b >  r >= g
      pixel_value_order->max = 2;
      pixel_value_order->mid = 0;
      pixel_value_order->min = 1;
    }
    else if (pix_in[2] > pix_in[1])
    {  // Case 3: r >= b >  g
      pixel_value_order->max = 0;
      pixel_value_order->mid = 2;
      pixel_value_order->min = 1;
    }
    else
    {  // Case 4: r == g == b
      // No change of the middle value, just assign something.
      pixel_value_order->max = 0;
      pixel_value_order->mid = 1;
      pixel_value_order->min = 2;
    }
  }
  else
  {
    if (pix_in[0] >= pix_in[2])
    {  // Case 5: g >  r >= b
      pixel_value_order->max = 1;
      pixel_value_order->mid = 0;
      pixel_value_order->min = 2;
    }
    else if (pix_in[2] > pix_in[1])
    {  // Case 6: b >  g >  r
      pixel_value_order->max = 2;
      pixel_value_order->mid = 1;
      pixel_value_order->min = 0;
    }
    else
    {  // Case 7: g >= b >  r
      pixel_value_order->max = 1;
      pixel_value_order->mid = 2;
      pixel_value_order->min = 0;
    }
  }
}

static inline float4 _desaturate_negative_values(const float4 i)
{
  const float pixel_average = fmax((i.x + i.y + i.z) / 3.0f, 0.0f);
  const float min_value = fmin(fmin(i.x, i.y), i.z);
  const float saturation_factor = min_value < 0.0f ? -pixel_average / (min_value - pixel_average) : 1.0f;

  return pixel_average + saturation_factor * (i - pixel_average);
}



static inline float4 _generalized_loglogistic_sigmoid_vector(const float4 i,
                                                             const float magnitude,
                                                             const float paper_exp,
                                                             const float film_fog,
                                                             const float film_power,
                                                             const float paper_power)
{
  //clamped_value
  float4 io = fmax(i, float4(0.0f));

  // The following equation can be derived as a model for film + paper but it has a pole at 0
  // magnitude * powf(1.0 + paper_exp * powf(film_fog + i, -film_power), -paper_power);
  // Rewritten on a stable around zero form:

  //film_response
  io = pow(film_fog + io, float4(film_power));
  //paper_response
  io = magnitude * pow(io / (paper_exp + io), float4(paper_power));

  // Safety check for very large floats that cause numerical errors
  // OpenCL picks per channel here; a vector condition in ?: is not portable Metal
  return select(io, float4(magnitude), isnan(io));
}

// Linear interpolation of hue that also preserve sum of channels
// Assumes hue_preservation strictly in range [0, 1]
static inline void _preserve_hue_and_energy(thread float *pix_io,
                                            thread const float *per_channel,
                                            const dt_iop_sigmoid_value_order_t order,
                                            const float hue_preservation)
{
  // Naive Hue correction of the middle channel
  const float chroma = pix_io[order.max] - pix_io[order.min];
  const float midscale = chroma != 0.f ? (pix_io[order.mid] - pix_io[order.min]) / chroma : 0.f;
  const float full_hue_correction =
    per_channel[order.min] + (per_channel[order.max] - per_channel[order.min]) * midscale;
  const float naive_hue_mid =
    (1.0f - hue_preservation) * per_channel[order.mid] + hue_preservation * full_hue_correction;

  const float per_channel_energy = per_channel[0] + per_channel[1] + per_channel[2];
  const float naive_hue_energy = per_channel[order.min] + naive_hue_mid + per_channel[order.max];
  const float pix_in_min_plus_mid = pix_io[order.min] + pix_io[order.mid];
  const float blend_factor = pix_in_min_plus_mid != 0.f ? 2.0f * pix_io[order.min] / pix_in_min_plus_mid : 0.f;
  const float energy_target = blend_factor * per_channel_energy + (1.0f - blend_factor) * naive_hue_energy;

  // Preserve hue constrained to maintain the same energy as the per channel result
  if (naive_hue_mid <= per_channel[order.mid])
  {
    const float corrected_mid =
      ((1.0f - hue_preservation) * per_channel[order.mid] + hue_preservation *
      (midscale * per_channel[order.max] + (1.0f - midscale) * (energy_target - per_channel[order.max]))) /
      (1.0f + hue_preservation * (1.0f - midscale));
    pix_io[order.min] = energy_target - per_channel[order.max] - corrected_mid;
    pix_io[order.mid] = corrected_mid;
    pix_io[order.max] = per_channel[order.max];
  }
  else
  {
    const float corrected_mid =
      ((1.0f - hue_preservation) * per_channel[order.mid] +
      hue_preservation * (per_channel[order.min] * (1.0f - midscale) +
      midscale * (energy_target - per_channel[order.min]))) / (1.0f + hue_preservation * midscale);
    pix_io[order.min] = per_channel[order.min];
    pix_io[order.mid] = corrected_mid;
    pix_io[order.max] = energy_target - per_channel[order.min] - corrected_mid;
  }
}

kernel void sigmoid_loglogistic_per_channel(texture2d<float, access::read> in [[texture(0)]],
  texture2d<float, access::write> out [[texture(1)]],
  constant int &width_arg [[buffer(2)]],
  constant int &height_arg [[buffer(3)]],
  constant float &white_target_arg [[buffer(4)]],
  constant float &paper_exp_arg [[buffer(5)]],
  constant float &film_fog_arg [[buffer(6)]],
  constant float &contrast_power_arg [[buffer(7)]],
  constant float &skew_power_arg [[buffer(8)]],
  constant float &hue_preservation_arg [[buffer(9)]],
  constant const float *pipe_to_base [[buffer(10)]],
  constant const float *base_to_rendering [[buffer(11)]],
  constant const float *rendering_to_pipe [[buffer(12)]],
  uint3 dt_gid [[thread_position_in_grid]],
  uint3 dt_lid [[thread_position_in_threadgroup]],
  uint3 dt_grp [[threadgroup_position_in_grid]],
  uint3 dt_lsz [[threads_per_threadgroup]],
  uint3 dt_gsz [[threads_per_grid]])
{
  const int width = width_arg;
  const int height = height_arg;
  const float white_target = white_target_arg;
  const float paper_exp = paper_exp_arg;
  const float film_fog = film_fog_arg;
  const float contrast_power = contrast_power_arg;
  const float skew_power = skew_power_arg;
  const float hue_preservation = hue_preservation_arg;

  const uint x = get_global_id(0);
  const uint y = get_global_id(1);

  if(x >= width || y >= height) return;

  float4 i = Areadpixel(in, x, y);
  float alpha = i.w;

  i = matrix_product_float4(i, pipe_to_base);

  // Force negative values to zero
  i = _desaturate_negative_values(i);

  // Convert to rendering primaries
  i = matrix_product_float4(i, base_to_rendering);
  float pix_array[3] = {i.x, i.y, i.z};

  i = _generalized_loglogistic_sigmoid_vector(i, white_target, paper_exp, film_fog, contrast_power, skew_power);
  float per_channel[3] = {i.x, i.y, i.z};

  // Hue correction by scaling the middle value relative to the max and min values.
  dt_iop_sigmoid_value_order_t pixel_value_order;
  _pixel_channel_order(pix_array, &pixel_value_order);
  _preserve_hue_and_energy(pix_array, per_channel, pixel_value_order, hue_preservation);

  i.xyz = float3(pix_array[0], pix_array[1], pix_array[2]);
  i = matrix_product_float4(i, rendering_to_pipe);

  // Copy over the alpha channel
  i.w = alpha;

  write_imagef(out, int2(x, y), i);
}

