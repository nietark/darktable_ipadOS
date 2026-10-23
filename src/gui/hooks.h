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

// the functions of gui/gtk.h that the core calls, declared apart from it so
// that the core builds without GTK. gui/gtk.c defines them

#include <glib.h>

G_BEGIN_DECLS

/** \brief draw user's attention */
void dt_ui_notify_user();

// control whether the mouse pointer displays as a "busy" cursor, e.g. watch or timer
// the calls may be nested, but must be matched
void dt_gui_cursor_set_busy();
void dt_gui_cursor_clear_busy();

// run all pending Gtk/GDK events
// should be called after making Gtk calls if we won't resume the main event loop for a while
// (i.e. the current function will do a lot of work before returning)
void dt_gui_process_events();

// show a dialog box with 2 buttons in case some user interaction is
// required BEFORE dt's gui is initialised.  this expects gtk_init()
// to be called already which should be the case during most of dt's
// init phase.
gboolean dt_gui_show_standalone_yes_no_dialog(const char *title,
                                              const char *markup,
                                              const char *no_text,
                                              const char *yes_text);

// what to do with a database that cannot be opened, as the user chose
typedef enum dt_gui_database_choice_t
{
  DT_GUI_DATABASE_CLOSE,   // quit darktable, to restore it by hand
  DT_GUI_DATABASE_RESTORE, // replace it with its most recent snapshot
  DT_GUI_DATABASE_DELETE   // delete it and start with a new one
} dt_gui_database_choice_t;

// ask what to do with the corrupted database `filename`, showing what
// sqlite's quick_check said (may be empty). Restoring is offered only when
// there is a snapshot
dt_gui_database_choice_t dt_gui_database_corrupt_dialog(const char *filename,
                                                        const char *quick_check_text,
                                                        const gboolean has_snapshot);

G_END_DECLS

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
