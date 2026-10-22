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
#include <stddef.h>
#include <stdint.h>
#include <time.h>

/*
  the device layer under camera control. camera_control.c owns the
  camera lists, the listeners, the job queue and the tether and live
  view threads; a backend only talks to the device. libgphoto2 is the
  backend on desktop systems (camera_backend_gphoto2.c). a platform
  backend, such as ImageCaptureCore on iPadOS where libusb has no
  access to the bus, implements the same table.

  unless stated otherwise the property functions are called with
  cam->config_lock held, and the file and capture functions with the
  camera control lock held.
*/

struct dt_camctl_t;
struct dt_camera_t;

/* numbered like gphoto2's CameraWidgetType, so that values stored or
   compared by existing code keep their meaning */
typedef enum dt_camera_property_type_t
{
  DT_CAMERA_PROPERTY_WINDOW = 0,
  DT_CAMERA_PROPERTY_SECTION = 1,
  DT_CAMERA_PROPERTY_TEXT = 2,
  DT_CAMERA_PROPERTY_RANGE = 3,
  DT_CAMERA_PROPERTY_TOGGLE = 4,
  DT_CAMERA_PROPERTY_RADIO = 5,
  DT_CAMERA_PROPERTY_MENU = 6,
  DT_CAMERA_PROPERTY_BUTTON = 7,
  DT_CAMERA_PROPERTY_DATE = 8
} dt_camera_property_type_t;

typedef enum dt_camera_event_type_t
{
  DT_CAMERA_EVENT_NONE,
  /* a new file on the camera, in folder/name */
  DT_CAMERA_EVENT_FILE_ADDED,
  /* one property changed, in name, or all of them when name is NULL */
  DT_CAMERA_EVENT_PROPERTY_CHANGED
} dt_camera_event_type_t;

typedef struct dt_camera_event_t
{
  dt_camera_event_type_t type;
  char *folder;
  char *name;
} dt_camera_event_t;

typedef struct dt_camera_file_info_t
{
  gboolean has_mtime;
  time_t mtime;
  size_t size;
} dt_camera_file_info_t;

/* one node of the property tree, used to build the property menu */
typedef struct dt_camera_property_node_t
{
  char *name;
  dt_camera_property_type_t type;
  GList *children; // of dt_camera_property_node_t
} dt_camera_property_node_t;

typedef struct dt_camera_backend_t
{
  const char *name;

  /* set up and tear down the backend's state in c->backend_data */
  gboolean (*init)(struct dt_camctl_t *c);
  void (*cleanup)(struct dt_camctl_t *c);
  /* abort whatever is blocking, called before cleanup */
  void (*cancel)(struct dt_camctl_t *c);

  /* the devices attached now, as a list of dt_camera_unused_t with
     model and port set. called with c->lock held */
  GList *(*detect)(struct dt_camctl_t *c);

  /* connect to the device named by cam->model and cam->port, fill in
     the can_* flags and summary, and read the property cache. FALSE
     leaves cam->backend_data NULL */
  gboolean (*open)(struct dt_camctl_t *c, struct dt_camera_t *cam);
  void (*close)(struct dt_camctl_t *c, struct dt_camera_t *cam);

  /* files */
  gboolean (*list_folder)(const struct dt_camctl_t *c,
                          const struct dt_camera_t *cam,
                          const char *folder,
                          GList **files,       // of char *, file names
                          GList **subfolders); // of char *, folder names
  /* FALSE when the file is unknown */
  gboolean (*get_file_info)(const struct dt_camctl_t *c,
                            const struct dt_camera_t *cam,
                            const char *folder,
                            const char *filename,
                            dt_camera_file_info_t *info);
  /* the contents of a file; the GBytes may keep device memory alive
     until it is unreferenced */
  GBytes *(*get_file)(const struct dt_camctl_t *c,
                      struct dt_camera_t *cam,
                      const char *folder,
                      const char *filename);
  /* an image to show as thumbnail: the embedded preview, or the file
     itself when it is small enough */
  GBytes *(*get_preview)(const struct dt_camctl_t *c,
                         struct dt_camera_t *cam,
                         const char *folder,
                         const char *filename);
  /* write a file straight to dest_path without holding it in memory */
  gboolean (*download_file)(const struct dt_camctl_t *c,
                            const struct dt_camera_t *cam,
                            const char *folder,
                            const char *filename,
                            const char *dest_path);

  /* tethering, called from the tether thread */
  gboolean (*capture)(const struct dt_camctl_t *c,
                      const struct dt_camera_t *cam,
                      char **folder,
                      char **filename);
  GBytes *(*capture_preview)(const struct dt_camctl_t *c,
                             const struct dt_camera_t *cam);
  /* wait up to timeout_ms for one event. the caller frees
     ev->folder and ev->name */
  gboolean (*wait_for_event)(const struct dt_camctl_t *c,
                             const struct dt_camera_t *cam,
                             const int timeout_ms,
                             dt_camera_event_t *ev);

  /* properties, read from the backend's cache */
  gboolean (*property_exists)(const struct dt_camera_t *cam,
                              const char *name);
  gboolean (*property_get_type)(const struct dt_camera_t *cam,
                                const char *name,
                                dt_camera_property_type_t *type);
  /* the returned string belongs to the cache */
  const char *(*property_get_value)(const struct dt_camera_t *cam,
                                    const char *name);
  int (*property_count_choices)(const struct dt_camera_t *cam,
                                const char *name);
  const char *(*property_get_choice)(const struct dt_camera_t *cam,
                                     const char *name,
                                     const int index);
  /* the root's children; free with dt_camera_property_tree_free() */
  GList *(*property_tree)(const struct dt_camera_t *cam);

  /* write to the device, from the tether thread */
  gboolean (*property_set_string)(const struct dt_camctl_t *c,
                                  const struct dt_camera_t *cam,
                                  const char *name,
                                  const char *value);
  gboolean (*property_set_toggle)(const struct dt_camctl_t *c,
                                  const struct dt_camera_t *cam,
                                  const char *name);
  gboolean (*property_set_choice)(const struct dt_camctl_t *c,
                                  const struct dt_camera_t *cam,
                                  const char *name,
                                  const int index);
  gboolean (*property_set_int)(const struct dt_camctl_t *c,
                               const struct dt_camera_t *cam,
                               const char *name,
                               const int value);
  gboolean (*property_set_float)(const struct dt_camctl_t *c,
                                 const struct dt_camera_t *cam,
                                 const char *name,
                                 const float value);

  /* re-read one property, or all when name is NULL, and report the
     ones that changed with dt_camctl_backend_property_changed(). takes
     cam->config_lock itself */
  void (*refresh_properties)(const struct dt_camctl_t *c,
                             const struct dt_camera_t *cam,
                             const char *name);
} dt_camera_backend_t;

/* the backend built into this binary */
const dt_camera_backend_t *dt_camera_backend_default(void);

void dt_camera_property_tree_free(GList *tree);

/* called by a backend */
void dt_camctl_backend_property_changed(const struct dt_camctl_t *c,
                                        const struct dt_camera_t *cam,
                                        const char *name,
                                        const char *value);
/* the device reported a transport error, so the active camera is
   unusable until it is remounted */
void dt_camctl_backend_connection_error(const struct dt_camctl_t *c,
                                        const char *text);

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
