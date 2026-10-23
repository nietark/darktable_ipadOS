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

#pragma once

// darktable.lib: the hooks through which processing reaches the utility
// modules (color picker samples, scopes), apart from libs/lib.h so that the
// pixelpipe builds without GTK

#include <glib.h>

#include "common/darktable.h"
#include "common/image.h"
#include "common/iop_profile.h"

struct dt_lib_module_t;
struct dt_colorpicker_sample_t;
struct dt_iop_color_picker_t;

/** struct responsible for all library related shared routines and plugins. */
typedef struct dt_lib_t
{
  GList *plugins;
  struct dt_lib_module_t *gui_module;

  /** Proxy functions for communication with views */
  struct
  {
    /** Colorpicker plugin hooks */
    struct
    {
      struct dt_lib_module_t *module;
      struct dt_colorpicker_sample_t *primary_sample;
      struct dt_iop_color_picker_t *picker_proxy;
      GSList *live_samples;
      struct dt_colorpicker_sample_t *selected_sample;
      gboolean display_samples;
      gboolean restrict_histogram;
      int statistic;
      void (*update_panel)(struct dt_lib_module_t *self);
      void (*update_samples)(struct dt_lib_module_t *self);
      void (*set_sample_box_area)(struct dt_lib_module_t *self,
                                  const dt_boundingbox_t size);
      void (*set_sample_point)(struct dt_lib_module_t *self,
                               const float pos[2]);
      void (*setup_sample)(struct dt_lib_module_t *self,
                           const gboolean denoise,
                           const gboolean pick_output);
    } colorpicker;

    /** Histogram processing hooks */
    struct
    {
      struct dt_lib_module_t *module;
      void (*process)(struct dt_lib_module_t *self, const float *const input,
                      int width, int height,
                      const dt_iop_order_iccprofile_info_t *const profile_info_from,
                      const dt_iop_order_iccprofile_info_t *const profile_info_to);
      void (*get_harmony)(struct dt_lib_module_t *self, dt_color_harmony_guide_t *guide);
      void (*set_harmony)(struct dt_lib_module_t *self, const dt_color_harmony_guide_t *guide);
      void (*set_scope)(struct dt_lib_module_t *self, int scope);
      void (*set_type)(struct dt_lib_module_t *self, int type);
      void (*get_sector_angles)(struct dt_lib_module_t *self,
                                const dt_color_harmony_type_t type,
                                const int rotation,
                                float *angles,
                                int *n);
      void (*set_harmony_callback)(struct dt_lib_module_t *self,
                                   void (*cb)(const dt_color_harmony_guide_t *, void *),
                                   void *user_data);
      gboolean is_linear;
    } histogram;

    struct
    {
      struct dt_lib_module_t *module;
    } navigation;

    struct
    {
      gboolean enabled;
    } snapshots;
  } proxy;
} dt_lib_t;

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
