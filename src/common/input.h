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
#include <stdint.h>

G_BEGIN_DECLS

// modifier state, buttons and click types passed to the canvas event
// callbacks (mouse_moved, button_pressed, button_released, scrolled) of
// views, processing modules and mask forms. The values are those of GDK,
// so the GTK front end passes event state through unchanged (checked in
// gui/gtk.c), and code that handles canvas events needs no GTK headers

typedef enum dt_input_modifier_t
{
  DT_MODIFIER_NONE    = 0,
  DT_MODIFIER_SHIFT   = 1 << 0, // GDK_SHIFT_MASK
  DT_MODIFIER_CONTROL = 1 << 2, // GDK_CONTROL_MASK
  DT_MODIFIER_ALT     = 1 << 3, // GDK_MOD1_MASK
  DT_MODIFIER_BUTTON1 = 1 << 8, // GDK_BUTTON1_MASK
  DT_MODIFIER_BUTTON2 = 1 << 9, // GDK_BUTTON2_MASK
  DT_MODIFIER_BUTTON3 = 1 << 10 // GDK_BUTTON3_MASK
} dt_input_modifier_t;

typedef enum dt_input_button_t
{
  DT_BUTTON_PRIMARY   = 1, // GDK_BUTTON_PRIMARY
  DT_BUTTON_MIDDLE    = 2, // GDK_BUTTON_MIDDLE
  DT_BUTTON_SECONDARY = 3  // GDK_BUTTON_SECONDARY
} dt_input_button_t;

typedef enum dt_input_click_t
{
  DT_BUTTON_PRESS        = 4, // GDK_BUTTON_PRESS
  DT_BUTTON_DOUBLE_PRESS = 5, // GDK_2BUTTON_PRESS
  DT_BUTTON_TRIPLE_PRESS = 6  // GDK_3BUTTON_PRESS
} dt_input_click_t;

// check whether the specified mask of modifier keys exactly matches,
// among the set Shift+Control+(Alt/Meta).  ignores the state of any
// other shifting keys
gboolean dt_modifier_is(const uint32_t state,
                        const uint32_t desired_modifier_mask);

// check whether the given modifier state includes AT LEAST the
// specified mask of modifier keys
gboolean dt_modifiers_include(const uint32_t state,
                              const uint32_t desired_modifier_mask);

G_END_DECLS

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on

