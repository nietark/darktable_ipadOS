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

// stand-ins for the GTK types that core structs hold, for a build without GTK
// (DT_NO_GUI). Those structs keep their widgets next to state that processing
// reads, so they have to compile there; nothing in such a build touches the
// widgets or the colors. Also the screen scaling and overlay color of the
// GUI, which canvas drawing and hit tests use

#ifdef DT_NO_GUI

#include <cairo.h>
#include <glib.h>

typedef struct _GtkWidget GtkWidget;

// GdkRGBA's layout
typedef struct _GdkRGBA
{
  gdouble red;
  gdouble green;
  gdouble blue;
  gdouble alpha;
} GdkRGBA;

// a build without a screen draws at one pixel per pixel
#define DT_PIXEL_APPLY_DPI(value) (value)

// gui/draw.h's overlay color, in white or black for want of the preference
static inline void dt_draw_set_color_overlay(cairo_t *cr,
                                             const gboolean bright,
                                             const double alpha)
{
  const double v = bright ? 1.0 : 0.0;
  cairo_set_source_rgba(cr, v, v, v, alpha);
}

#endif // DT_NO_GUI

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
