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

// the helpers of common/utility.h and utility_svg.h that need librsvg, kept
// apart so that the rest of the core builds without librsvg and GTK

#include "common/darktable.h"
#include "common/file_location.h"
#include "common/utility.h"
#include "common/utility_svg.h"
#include "gui/gtk.h"

#include <librsvg/rsvg.h>
// ugh, ugly hack. why do people break stuff all the time?
#ifndef RSVG_CAIRO_H
#include <librsvg/rsvg-cairo.h>
#endif

static cairo_surface_t *_util_get_svg_img(gchar *logo,
                                          const float size)
{
  GError *error = NULL;
  cairo_surface_t *surface = NULL;
  char datadir[PATH_MAX] = { 0 };

  dt_loc_get_datadir(datadir, sizeof(datadir));
  char *dtlogo = g_build_filename(datadir, "pixmaps", logo, NULL);
  RsvgHandle *svg = rsvg_handle_new_from_file(dtlogo, &error);
  if(svg)
  {
    RsvgDimensionData dimension;
    dimension = dt_get_svg_dimension(svg);

    const float ppd = darktable.gui ? darktable.gui->ppd : 1.0;

    const float svg_size = MAX(dimension.width, dimension.height);
    const float factor = size > 0.0 ? size / svg_size : -1.0 * size;
    const float final_width = dimension.width * factor * ppd,
                final_height = dimension.height * factor * ppd;
    const int stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, final_width);

    guint8 *image_buffer = calloc(stride * final_height, sizeof(guint8));
    if(!image_buffer)
    {
      dt_print(DT_DEBUG_ALWAYS,
               "warning: unable to allocate rasterization buffer for SVG '%s'", dtlogo);
      g_free(logo);
      g_free(dtlogo);
      g_object_unref(svg);
      return NULL;
    }
    if(darktable.gui)
      surface = dt_cairo_image_surface_create_for_data(image_buffer,
                                                       CAIRO_FORMAT_ARGB32, final_width,
                                                       final_height, stride);
    else // during startup we don't know ppd yet and darktable.gui isn't initialized yet.
      surface = cairo_image_surface_create_for_data(image_buffer,
                                                    CAIRO_FORMAT_ARGB32,
                                                    final_width,
                                                    final_height, stride);
    if(cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS)
    {
      dt_print(DT_DEBUG_ALWAYS,
               "warning: can't load darktable logo from SVG file `%s'",
               dtlogo);
      cairo_surface_destroy(surface);
      free(image_buffer);
      image_buffer = NULL;
      surface = NULL;
    }
    else
    {
      cairo_t *cr = cairo_create(surface);
      cairo_scale(cr, factor, factor);
      dt_render_svg(svg, cr, dimension.width, dimension.height, 0, 0);
      cairo_destroy(cr);
      cairo_surface_flush(surface);
    }
    g_object_unref(svg);
  }
  else
  {
    dt_print(DT_DEBUG_ALWAYS,
             "warning: can't load darktable logo from SVG file `%s'\n%s",
             dtlogo, error->message);
    g_error_free(error);
  }

  g_free(logo);
  g_free(dtlogo);

  return surface;
}

cairo_surface_t *dt_util_get_logo(const float size)
{
  char *logo;
  const dt_logo_season_t season = dt_util_get_logo_season();
  if(season != DT_LOGO_SEASON_NONE)
    logo = g_strdup_printf("idbutton-%d.svg", (int)season);
  else
    logo = g_strdup("idbutton.svg");

  return _util_get_svg_img(logo, size);
}

cairo_surface_t *dt_util_get_logo_text(const float size)
{
  return _util_get_svg_img(g_strdup("dt_text.svg"), size);
}

RsvgDimensionData dt_get_svg_dimension(RsvgHandle *svg)
{
  RsvgDimensionData dimension;
  // rsvg_handle_get_dimensions has been deprecated in librsvg 2.52
  #if LIBRSVG_CHECK_VERSION(2,52,0)
    double width;
    double height;
    if(rsvg_handle_get_intrinsic_size_in_pixels(svg, &width, &height)) //only works if SVG document has size specified
    {
      dimension.width = lround(width);
      dimension.height = lround(height);
    }
    else
    {
#define VIEWPORT_SIZE 32767 //use maximum cairo surface size to have enough precision when size is converted to int
      const RsvgRectangle viewport = {
        .x = 0,
        .y = 0,
        .width = VIEWPORT_SIZE,
        .height = VIEWPORT_SIZE,
      };
#undef VIEWPORT_SIZE
      RsvgRectangle rectangle;
      rsvg_handle_get_geometry_for_layer(svg, NULL, &viewport, NULL, &rectangle, NULL);
      dimension.width = lround(rectangle.width);
      dimension.height = lround(rectangle.height);
    }
  #else
    rsvg_handle_get_dimensions(svg, &dimension);
  #endif
  return dimension;
}

void dt_render_svg(RsvgHandle *svg,
                   cairo_t *cr,
                   const double width,
                   const double height,
                   const double offset_x,
                   const double offset_y)
{
  // rsvg_handle_render_cairo has been deprecated in librsvg 2.52
  #if LIBRSVG_CHECK_VERSION(2,52,0)
    RsvgRectangle viewport = {
      .x = offset_x,
      .y = offset_y,
      .width = width,
      .height = height,
    };
    rsvg_handle_render_document(svg, cr, &viewport, NULL);
  #else
    rsvg_handle_render_cairo(svg, cr);
  #endif
}

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
