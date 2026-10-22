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

#include <glib.h>

G_BEGIN_DECLS

/** available views flags, a view should return its type and
    is also used in modules flags available in src/libs to
    control which view the module should be available in also
    which placement in the panels the module have.
*/
typedef enum dt_view_type_flags_t
{
  DT_VIEW_NONE       = 0,
  DT_VIEW_LIGHTTABLE = 1 << 0,
  DT_VIEW_DARKROOM   = 1 << 1,
  DT_VIEW_TETHERING  = 1 << 2,
  DT_VIEW_MAP        = 1 << 3,
  DT_VIEW_SLIDESHOW  = 1 << 4,
  DT_VIEW_PRINT      = 1 << 5,
  DT_VIEW_MULTI      = 1 << 28,
  DT_VIEW_FALLBACK   = 1 << 29,
  DT_VIEW_OTHER      = 1 << 30, // for your own unpublished user view
  DT_VIEW_ALL        = ~DT_VIEW_FALLBACK,
} dt_view_type_flags_t;

G_END_DECLS

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on

