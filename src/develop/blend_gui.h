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

#include "develop/blend.h"
#include "dtgtk/button.h"
#include "dtgtk/gradientslider.h"
#include "gui/color_picker_proxy.h"

G_BEGIN_DECLS

typedef struct dt_iop_gui_blendif_colorstop_t
{
  float stoppoint;
  GdkRGBA color;
} dt_iop_gui_blendif_colorstop_t;

typedef struct dt_iop_gui_blendif_channel_t
{
  char *label;
  char *tooltip;
  float increment;
  int numberstops;
  const dt_iop_gui_blendif_colorstop_t *colorstops;
  gboolean boost_factor_enabled;
  float boost_factor_offset;
  dt_develop_blendif_channels_t param_channels[2];
  dt_dev_pixelpipe_display_mask_t display_channel;
  void (*scale_print)(float value, float boost_factor, char *string, int n);
  int (*altdisplay)(GtkWidget *, dt_iop_module_t *, int);
  char *name;
} dt_iop_gui_blendif_channel_t;

// the channel table of a blend colorspace (blend_gui.c)
const dt_iop_gui_blendif_channel_t *dt_develop_blendif_channels_for_csp(const int csp);

typedef struct dt_iop_gui_blendif_filter_t
{
  GtkDarktableGradientSlider *slider;
  // the slider's display scale: 0 linear, 1 the channel's alternative one
  // (log or zoom), named by altmode_name. Named in the slider's tooltip, as
  // the row has no text label to carry it
  int altmode;
  const char *altmode_name;
} dt_iop_gui_blendif_filter_t;

extern const dt_introspection_type_enum_tuple_t dt_develop_blend_colorspace_names[];
extern const dt_introspection_type_enum_tuple_t dt_develop_blend_mode_names[];
extern const dt_introspection_type_enum_tuple_t dt_develop_blend_mode_flag_names[];
extern const dt_introspection_type_enum_tuple_t dt_develop_mask_mode_names[];
extern const dt_introspection_type_enum_tuple_t dt_develop_combine_masks_names[];
extern const dt_introspection_type_enum_tuple_t dt_develop_feathering_guide_names[];
extern const dt_introspection_type_enum_tuple_t dt_develop_invert_mask_names[];

#ifdef HAVE_AI
#define DEVELOP_MASKS_NB_SHAPES 6
#else
#define DEVELOP_MASKS_NB_SHAPES 5
#endif

/** blend gui data */
typedef struct dt_iop_gui_blend_data_t
{
  gboolean blendif_support;
  gboolean blend_inited;
  gboolean masks_support;
  // FALSE for an IOP_FLAGS_NO_MASKS module (retouch, spots): its canvas edits
  // its own shapes, so its mask panel offers no shapes and leaves the canvas
  // alone
  gboolean shapes_support;
  gboolean masks_inited;

  dt_develop_blend_colorspace_t csp;
  dt_iop_module_t *module;

  GtkWidget *iopw;
  GtkBox *blend_box;
  GtkBox *refine_box;
  // switches the mask on (DEVELOP_MASK_ENABLED | DEVELOP_MASK_FLEXI) or off,
  // in the "blend mask" header (see _blendop_mask_enable_toggled)
  GtkWidget *mask_enable_toggle;
  // the arrow on the "blend mask" header that folds the panel body away, at
  // work only in the embedded position: the hosts fold themselves, and on the
  // canvas it only holds its place (see _masks_header_apply_side)
  GtkWidget *flexi_inline_collapse_btn;
  // the "blend mask" header and everything below it: what moves into the
  // host the masks panel position names (dt_iop_gui_blend_masks_panel_relocate)
  GtkBox *relocatable_box;
  // the header's place in relocatable_box, inside an event box so that a
  // click anywhere on the header but on a button folds the panel (or, in the
  // utility position, the lib)
  GtkBox *masks_header_home;
  // everything in relocatable_box below the header, folded away in the
  // embedded position while the header stays as the way back. Only this
  // wrapper is hidden, so its children keep their own visibility
  GtkBox *masks_panel_body;
  GtkBox *masks_box;

  GtkWidget *showmask;
  // renders the module without its mask while held on (module->suppress_mask),
  // for the module in focus only
  GtkWidget *suppress;
  // locks the mask against reset, presets, styles, paste and editing (see
  // dt_develop_blend_params_t's mask_lock). Left of showmask in the header
  GtkWidget *mask_lock_btn;
  GtkWidget *soloedit_mode;
  GtkWidget *masks_combine_combo;
  GtkWidget *blend_modes_combo;
  GtkWidget *blend_modes_blend_order;
  GtkWidget *blend_mode_parameter_slider;
  GtkWidget *opacity_slider;
  GtkWidget *blend_opacity_lowop_badge;
  GtkWidget *masks_feathering_guide_combo;
  GtkWidget *feathering_radius_slider;
  GtkWidget *blur_radius_slider;
  GtkWidget *contrast_slider;
  GtkWidget *brightness_slider;

  dt_develop_blend_colorspace_t blend_modes_csp;

  // the channel preview under the pointer: the parametric range slider or
  // "add channel" button it is over, the channel display bits it stands for,
  // and whether the preview is on
  GtkWidget *hovered_channel_widget;
  dt_dev_pixelpipe_display_mask_t hovered_channel_display;
  gboolean hover_preview_active;
  // the pointer has to rest on a channel button before the preview starts
  // (_preview_on_hover_enter). Remove it on every teardown path, or it fires
  // into freed blend_data
  guint preview_dwell_timer;
  dt_dev_pixelpipe_display_mask_t save_for_leave;
  GtkWidget *details_slider;

  // opens the menu that links or copies elements of other modules' masks, or
  // adds or uses another module's whole mask (_masks_import_btn_pressed)
  GtkWidget *masks_import_btn;
  GtkWidget *masks_shapes[DEVELOP_MASKS_NB_SHAPES];
  int masks_type[DEVELOP_MASKS_NB_SHAPES];
  GtkWidget *masks_edit;
  dt_masks_edit_mode_t masks_shown;
  // the edit mode folding the panel away turned off, for unfolding it to
  // restore (dt_iop_gui_blend_masks_panel_collapsed). DT_MASKS_EDIT_OFF:
  // nothing to restore
  dt_masks_edit_mode_t masks_shown_stash;

  // one button per channel of the module's blend colorspace, in masks_toolbar:
  // a click adds a single-channel parametric form for that channel, hovering
  // previews its mask. masks_param_channels_inner holds the buttons, rebuilt
  // only when the colorspace changes from param_channels_csp
  GtkWidget *masks_param_channels_box;
  GtkWidget *masks_param_channels_inner;
  int param_channels_csp;
  // the "add group" button and its wrapper in masks_toolbar. Its menu picks an
  // operator, and nests a new empty group with it in the target group,
  // selected so that the next shape drawn joins it (_stage_new_group)
  GtkWidget *masks_new_op;
  GtkWidget *masks_new_op_box;
  // the toolbar of every "add to the mask" action, above masks_list_box:
  // add group, the shapes, the parametric channels and import, plus the group
  // layout presets at the top right. It wraps onto two or three rows when the
  // panel is narrow. A height-for-width container (masks_gui_toolbar.c) lays
  // it out in GTK's own measure and allocate passes: do not move widgets
  // between rows by hand, which races GTK's layout. Every button is inserted
  // once (the channel buttons once the colorspace is known)
  GtkWidget *masks_toolbar;
  // the "blend mask" section header. Reading order:
  //
  //   toggle | <space> | edit run | show_mask_overlay | eye | lock
  //   | <space> | expander
  //
  // (the two sides swap when the canvas panel is docked on the left, see
  // _masks_header_apply_side)
  GtkWidget *masks_blend_header;
  // edit run + show_mask_overlay + eye + lock, the header's center widget
  // between the toggle and the expander (_masks_header_cluster_new)
  GtkWidget *masks_header_cluster;
  // the edit run on the panel header: edit on canvas and solo edit (see
  // _pack_header_edit_run). Whole-mask canvas controls, so on the header
  // wherever the panel is hosted, never on the mask's own group
  GtkWidget *masks_header_edit_box;
  // the mask list: each group's header, its element rows indented under it
  // (_pack_group_elements), reorderable by drag and drop
  GtkBox *masks_list_box;
  // masks_toolbar and masks_list_box on one ground, so the add buttons read as
  // part of the list. Not the list box itself: dt_masks_gui_build_list wipes that
  GtkWidget *masks_list_area;
  // formid -> its row (the "mask-row" row_vbox), so that hover sync, selection
  // and row refreshes need no walk of the widget tree on every pointer motion.
  // Filled by _make_shape_row, emptied by dt_masks_gui_build_list; the widget
  // tree owns the rows
  GHashTable *masks_row_map;
  // what the last dt_masks_gui_build_list built from (dt_masks_gui_list_signature):
  // an unchanged signature would build the same list, so the rebuild is
  // skipped. DT_INVALID_HASH: never built
  dt_hash_t masks_list_sig;
  // the smoothing and cleanup sliders of the AI object being created, built
  // once by the pending row and kept while it is created, so that a value
  // change does not rebuild them mid-drag. NULL otherwise. Canvas scrolling
  // updates them (dt_iop_gui_blend_sync_pending_ai_sliders)
  GtkWidget *pending_ai_smoothing_slider;
  GtkWidget *pending_ai_cleanup_slider;
  float pending_ai_smoothing_last;
  float pending_ai_cleanup_last;
  // the area the module's parametric pickers last set a range from: with
  // "reuse the last picked area" on, arming any of them samples it again
  // (see _param_row_master_picker_pressed). param_pick_box_set is FALSE until
  // the first pick
  dt_pickerbox_t param_pick_box;
  gboolean param_pick_box_set;
  // the selected row's element; INVALID = none
  dt_mask_id_t panel_selected_formid;
  // the selected group, by its marker's id: where the next shape drawn lands
  // and what the refinement acts on. With no other group selected the mask's
  // own is (_select_mask_group_if_none), so it is never INVALID while the mask
  // has a group
  dt_mask_id_t panel_selected_group_cid;
  // the element under the cursor on the canvas. The selection panel shows it in place
  // of the selection, which it leaves alone; INVALID = none
  dt_mask_id_t canvas_hovered_formid;
  // where dt_masks_group_insert_point puts the next element, while
  // insert_active: after the point insert_after_fid, the group's top member,
  // or its marker for an empty group
  gboolean insert_active;
  dt_mask_id_t insert_after_fid;
  // cluster key -> expanded (gboolean), for the clusters of adjacent shapes
  // of one kind within a group, a purely visual grouping, across list
  // rebuilds. Created on first use
  GHashTable *masks_cluster_expanded;
  // the soloed element, the others hidden; INVALID when none. Solo alone sets
  // DT_MASKS_STATE_HIDDEN, so ending it clears every hidden bit
  dt_mask_id_t solo_formid;
  // the soloed group's key; 0 when none (keys are >= 16)
  guint solo_group_key;
  // solo edit: only these outlines can be edited on the canvas, while the mask
  // still renders whole. An element, or a group's marker for all its members
  // (_soloedit_formids); INVALID when none
  dt_mask_id_t soloedit_formid;

  // the mask refinement sliders act on the selection
  // (_flexi_refine_follow_selection): the whole mask, a group or an element.
  // masks_refine_scope_kind/_formid name it; masks_refine_updating keeps a
  // slider update from committing back
  GtkWidget *masks_refine_reset_btn;  // resets the refinement of the active scope
  int masks_refine_scope_kind;
  dt_mask_id_t masks_refine_scope_formid;
  gboolean masks_refine_updating;
  // the next release on a row or group header does nothing: an alt+click on
  // a handle, or a group drag ending in a release. Cleared on a plain press
  gboolean masks_skip_group_select_release;
  // set while _auto_expand_selected_row toggles row expanders itself: toggling
  // an expander selects its row, which would re-enter it without end. Not
  // DT_ENTER_GUI_UPDATE, which makes _props_row_toggled skip the update the
  // toggle still needs
  gboolean masks_suppress_toggle_select;
  // "auto-expand selected": the last selected element that has an expander
  // (dt_masks_model_row_is_expandable), apart from panel_selected_formid, so
  // that selecting one with nothing to expand leaves the open one open.
  // NO_MASKID: none yet
  dt_mask_id_t masks_last_expanded_elem;
  // the same for groups (_auto_expand_selected_group), which open their
  // members. Selecting an element selects its group too, so both open
  dt_mask_id_t masks_last_expanded_group;
  // a group the user just folded with its own chevron, for the next
  // _auto_expand_selected_group not to reopen: the same click selects it.
  // INVALID_MASKID when none
  dt_mask_id_t masks_group_collapse_click;
  // a press on a row turned into a drag (_row_drag_begin), which selects what
  // it settles on (_masks_drag_end). A release still reaching the row must
  // not run the click's select or toggle, which would deselect it again. On
  // macOS a drag source can start for a plain click
  gboolean masks_row_click_handled;
  // suppresses dt_masks_gui_build_list while set: dt_masks_form_remove()
  // rebuilds the list for every shape it removes, so a caller removing several
  // sets this around its loop and rebuilds once afterwards
  gboolean masks_rebuild_suppressed;
  // a deferred rebuild is queued (_queue_masks_list_rebuild), so that the
  // requests of one gesture make one rebuild
  gboolean masks_rebuild_pending;
  // its idle source, for dt_iop_gui_cleanup_blending to remove: run after the
  // module is gone, it would touch destroyed widgets. 0 when none
  guint masks_rebuild_idle_id;
  // the selection panel under the list: the selection's icon and name
  // (masks_selection_icon_box, masks_selection_name_label, see
  // _refine_update_header) with the button deleting it on their right, then
  // the properties and the refinement, which act on it
  GtkWidget *masks_selection_area;
  GtkWidget *masks_selection_icon_box;
  GtkWidget *masks_selection_name_label;
  GtkWidget *masks_selection_delete_btn;
  // the refinement section's title; its tooltip says why the section is
  // inactive, when it is (see _update_refine_sensitivity)
  GtkWidget *masks_refine_section_label;
  GtkWidget *masks_refine_expander;
  GtkWidget *masks_refine_bypass_btn;
  GtkWidget *masks_refine_toggle_btn;
  GtkBox *masks_refine_sliders_box;
  // "element properties in subpanel": the selected element's or group's
  // properties, or the creation controls of a shape being drawn, in a
  // collapsible of their own above the refinements (see _props_panel_sync).
  // props_panel_box is the wrapped section, props_panel_content the box the
  // editor goes in, props_panel_formid the element or group
  // (props_panel_is_group) it holds the editor of, and pending_props_box the
  // creation controls a pending row built for it
  GtkBox *props_panel_box;
  GtkWidget *props_panel_expander;
  GtkWidget *props_panel_content;
  GtkWidget *props_panel_toggle_btn;
  dt_mask_id_t props_panel_formid;
  gboolean props_panel_is_group;
  GtkWidget *pending_props_box;
  // "mask consumers": the modules downstream reading this module's raster
  // mask, one row each, in a collapsible below the refinements (see
  // _consumers_sync). consumers_sig hashes the rows shown, so an unchanged
  // list is not rebuilt
  GtkBox *consumers_box;
  GtkWidget *consumers_expander;
  GtkWidget *consumers_content;
  GtkWidget *consumers_toggle_btn;
  dt_hash_t consumers_sig;
  // the refinements the user previews switched off, never stored, keyed by
  // dt_masks_refine_key_*() below. Changed on the GTK thread under `lock`,
  // which commit_params takes to snapshot it (dt_masks_refine_bypass_commit);
  // the renderer reads only the snapshot
  GHashTable *masks_refine_bypassed;
  // row/group key -> expanded (see _remember_expanded): element rows by form
  // id, groups by their marker's id, nested group rows by their form id.
  // Created on first use
  GHashTable *masks_props_expanded;
  // group cid -> the page its preset note shows (see _make_group_note), so a
  // list rebuild keeps it. Created on first use
  GHashTable *masks_note_page;
  // group cid -> its preset note switched on (1) or off (2) with the info
  // icon by its name; wins over masks_notes_all_open and the selection (see
  // _group_note_is_open). Created on first use
  GHashTable *masks_note_open;
  // a preset was just applied: every note is open until another group is
  // selected
  gboolean masks_notes_all_open;
  // group cid -> its displayed number (see _group_ordinal_any)
  GHashTable *group_ordinals;

  dt_pthread_mutex_t lock;
} dt_iop_gui_blend_data_t;

/** gui related stuff */
void dt_iop_gui_init_blending(GtkWidget *iopw, dt_iop_module_t *module);
void dt_iop_gui_update_blending(dt_iop_module_t *module);
void dt_iop_gui_update_masks(dt_iop_module_t *module);
// select the row of the shape selected on the canvas. Does nothing without a
// mask list
void dt_iop_gui_blend_masks_select_form(dt_iop_module_t *module, dt_mask_id_t formid);
// highlight the row of the shape hovered on the canvas, or its cluster's
// header while the cluster is folded, and show the shape in the selected
// element's panel in place of the selection. INVALID_MASKID clears both
void dt_iop_gui_blend_masks_hover_form(dt_iop_module_t *module, dt_mask_id_t formid);
// a click on empty canvas: nothing is selected in the panel any more
void dt_iop_gui_blend_masks_clear_selection(dt_iop_module_t *module);
void dt_iop_gui_cleanup_blending(dt_iop_module_t *module);
void dt_iop_gui_blending_lose_focus(dt_iop_module_t *module);
// the counterpart, when a module gains focus: moves the masks panel into its
// host, and carries the mask display and the canvas edit mode over from the
// module that lost focus
void dt_iop_gui_blending_gain_focus(dt_iop_module_t *module);
// move the masks panel out of its host and back into this module's expander.
// Call it before the module's widgets are destroyed: while hosted, the panel
// is parented in the host and would outlive its module. Does nothing if this
// module's panel is not hosted
void dt_iop_gui_blend_masks_panel_release(dt_iop_module_t *module);
// the forms were just replaced (undo, history jump, style paste, snapshot,
// history compression): drop the empty-group placeholders, which exist in the
// GUI only and would duplicate a group the reload brought back
void dt_iop_gui_blend_forms_reloaded(dt_iop_module_t *module);
// update the mask rows' warning badges in place. A badge can depend on another
// module (a raster element's source switched off or removed), so a signal
// handler calls this for every module; it returns at once without a list
void dt_iop_gui_blend_refresh_mask_badges(dt_iop_module_t *module);
// opens the blending options popover (blend colorspace, masks panel position,
// options) for the focused module, else the hosted one, else with the
// panel-wide sections only. A right-click on the toolbar's masks panel button
// opens it
void dt_iop_gui_blend_masks_options_popup(GtkButton *button, gpointer user_data);
// switch the module's mask on, flexi and empty if it has none yet; does
// nothing if it is on or the module does not blend. The folded panel's corner
// icon in gtk.c uses it, so that a click shows a live editor, not an inert one
void dt_iop_gui_blend_mask_enable(dt_iop_module_t *module);
// locks or unlocks the module's mask, as a history item. The module header's
// lock indicator unlocks through this
void dt_iop_gui_blend_set_mask_lock(dt_iop_module_t *module, const gboolean lock);
// the masks panel folded away (TRUE) or came back, wherever it is. Folding
// turns canvas editing and any armed shape tool off, keeping the edit mode in
// bd->masks_shown_stash for unfolding to restore: no editing overlay stays
// live without its panel. Called by all three ways to fold: the canvas
// panel (dt_ui_flexi_panel_set_collapsed in gtk.c), the utility module
// (masks_flexi_host.c) and the embedded header's arrow
void dt_iop_gui_blend_masks_panel_collapsed(const gboolean collapsed);
// record whether the masking panel should be folded away: a fold or unfold by
// the user. Shared by all three positions, and only ever *applied* by
// dt_iop_gui_blend_masks_panel_relocate/-release, so a caller states the intent
// and every position carries it out the same way
void dt_masks_gui_panel_set_collapsed_pref(const gboolean collapsed);
// the utility module hosting the panel was expanded or folded: records the
// user's change as the panel's fold preference, then follows it as above, as
// the other two positions do
void dt_iop_gui_blend_masks_panel_host_expanded(const gboolean expanded);
// moves the masks panel to its host and updates the header labels and tooltips
void dt_iop_gui_blend_masks_panel_relocate(dt_iop_module_t *module);
// show or hide the focused module's masks panel, wherever it is. The panel's
// arrow, the shortcut and the toolbar button all come here, so they cannot
// drift apart. Does nothing unless the focused module has a masks panel
void dt_iop_gui_blend_masks_panel_toggle(void);
// open the focused module's mask panel where it is hosted, if it is folded
void dt_iop_gui_blend_masks_panel_show(void);
// the canvas panel changed sides: lay its header out for the new one
void dt_iop_gui_blend_masks_panel_side_changed(void);
// the tooltip of both buttons that display the mask: the overlay in the mask
// header and the indicator in the module header
const char *dt_iop_gui_blend_showmask_tooltip(void);
// show the mask overlay or stop, from either of those buttons: showing it
// switches an off module and an off mask on
void dt_iop_gui_blend_mask_display(dt_iop_module_t *module, const gboolean show);
// stand the overlay and the eye down, with nothing for them to show: the
// module or its mask switched off, or no alpha channel to show the mask in
void dt_iop_gui_blend_mask_view_off(dt_iop_module_t *module);
// "reset mask": the mask starts over from the default group layout, unless it
// is locked
void dt_iop_gui_blend_mask_reset(dt_iop_module_t *module);
// fold the panel away for the focused module if it has lost its mask, as when
// it takes focus without one: the mask coming back (an undo) shows it again
void dt_iop_gui_blend_masks_panel_fold_unmasked(void);
// show the panel's state on the darkroom toolbar button: pressed while the
// panel shows, insensitive when the focused module has no masks panel
void dt_iop_gui_blend_masks_panel_sync_toolbox(void);
// show the smoothing and cleanup of the AI object being created in the
// pending-row sliders, after object.c changed them on a canvas scroll,
// without rebuilding the list mid-drag
void dt_iop_gui_blend_sync_pending_ai_sliders(dt_iop_module_t *module);
// the module's shapes, or the defaults of the shape being drawn, changed on
// the canvas: show the new values in the panel's controls without rebuilding
// it. Called from dt_dev_masks_list_change
void dt_iop_gui_blend_masks_changed(dt_iop_module_t *module);

// remove one element from this module's mask, exactly as the panel's delete
// does: only this module's use of it goes, and an emptied group stays in
// place. The canvas's delete gestures come here too (see
// dt_masks_remove_shape), so both behave the same
void dt_iop_gui_blend_delete_element(dt_iop_module_t *module, const dt_mask_id_t id);
/** the module's name changed: refresh the mask panels whose raster elements
    are named after it */
void dt_iop_gui_blend_module_renamed(dt_iop_module_t *module);

// shape creation ended for this module: queues the rebuild that drops the
// panel's pending row. Called from dt_masks_change_form_gui, which every way
// of canceling goes through, a click outside the canvas included
void dt_iop_gui_blend_masks_creation_ended(dt_iop_module_t *module);

gboolean blend_color_picker_apply(dt_iop_module_t *module,
                                  GtkWidget *picker,
                                  dt_dev_pixelpipe_t *pipe);

G_END_DECLS

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on

