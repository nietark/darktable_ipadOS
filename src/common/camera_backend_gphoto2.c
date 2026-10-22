/*
    This file is part of darktable,
    Copyright (C) 2010-2026 darktable developers.

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

#include "common/camera_backend.h"
#include "common/camera_control.h"
#include "control/control.h"

#if defined (_WIN32)
#ifdef interface
#undef interface
#endif
#endif //defined (_WIN32)
#include <gphoto2/gphoto2.h>
#include <gphoto2/gphoto2-file.h>

#include <fcntl.h>
#include <locale.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct _gphoto_t
{
  GPContext *context;
  /** List of gphoto2 port drivers */
  GPPortInfoList *ports;
  /** List of gphoto2 camera drivers */
  CameraAbilitiesList *abilities;
} _gphoto_t;

typedef struct _gphoto_camera_t
{
  Camera *gpcam;
  GPContext *context;
  /** Camera configuration cache */
  CameraWidget *configuration;
  /** Registered timeout func */
  CameraTimeoutFunc timeout;
  /** List of open gp_files to be closed when closing the camera */
  GList *open_gpfiles;
} _gphoto_camera_t;

static inline _gphoto_t *_gp(const dt_camctl_t *c)
{
  return (_gphoto_t *)c->backend_data;
}

static inline _gphoto_camera_t *_gpcam(const dt_camera_t *cam)
{
  return (_gphoto_camera_t *)cam->backend_data;
}

static int logid = 0;

static void _gphoto_log25(GPLogLevel level,
                          const char *domain,
                          const char *log,
                          void *data)
{
  dt_print(DT_DEBUG_CAMCTL, "[camera_control] %s %s", domain, log);
}

static void _enable_debug() __attribute__((unused));
static void _disable_debug() __attribute__((unused));

static void _enable_debug()
{
  logid = gp_log_add_func(GP_LOG_DATA, (GPLogFunc)_gphoto_log25, NULL);
}

static void _disable_debug()
{
  gp_log_remove_func(logid);
}

static void _error_func_dispatch25(GPContext *context,
                                   const char *text,
                                   void *data)
{
  dt_camctl_t *camctl = (dt_camctl_t *)data;
  dt_print(DT_DEBUG_CAMCTL, "[camera_control] gphoto2 error: %s", text);

  if(strstr(text, "PTP"))
    dt_camctl_backend_connection_error(camctl, text);
}

static void _status_func_dispatch25(GPContext *context,
                                    const char *text,
                                    void *data)
{
  dt_print(DT_DEBUG_CAMCTL, "[camera_control] gphoto2 status: %s", text);
}

static void _message_func_dispatch25(GPContext *context,
                                     const char *text,
                                     void *data)
{
  dt_print(DT_DEBUG_CAMCTL, "[camera_control] gphoto2 message: %s", text);
}

static gboolean _camera_timeout_job(gpointer data)
{
  _gphoto_camera_t *gc = (_gphoto_camera_t *)data;
  dt_print(DT_DEBUG_CAMCTL,
           "[camera_control] Calling timeout func for camera %p", gc);
  gc->timeout(gc->gpcam, gc->context);
  return TRUE;
}

static int _camera_start_timeout_func(Camera *c,
                                      const unsigned int timeout,
                                      CameraTimeoutFunc func,
                                      void *data)
{
  dt_print(DT_DEBUG_CAMCTL,
           "[camera_control] start timeout %d seconds for camera %p requested by driver.",
           timeout, data);
  _gphoto_camera_t *gc = (_gphoto_camera_t *)data;
  gc->timeout = func;
  return g_timeout_add_seconds(timeout, _camera_timeout_job, gc);
}

static void _camera_stop_timeout_func(Camera *c,
                                      const int id,
                                      void *data)
{
  _gphoto_camera_t *gc = (_gphoto_camera_t *)data;
  dt_print(DT_DEBUG_CAMCTL,
           "[camera_control] Removing timeout %d for camera %p", id, gc);
  g_source_remove(id);
  gc->timeout = NULL;
}

static gboolean _init(dt_camctl_t *c)
{
  _gphoto_t *gp = g_malloc0(sizeof(_gphoto_t));
  c->backend_data = gp;

  // Initialize gphoto2 context and setup dispatch callbacks
  gp->context = gp_context_new();

  gp_context_set_status_func(gp->context,
                             (GPContextStatusFunc)_status_func_dispatch25, c);
  gp_context_set_error_func(gp->context,
                            (GPContextErrorFunc)_error_func_dispatch25, c);
  gp_context_set_message_func(gp->context,
                              (GPContextMessageFunc)_message_func_dispatch25, c);

  // Load all camera drivers we know...
  gp_abilities_list_new(&gp->abilities);
  gp_abilities_list_load(gp->abilities, gp->context);
  dt_print(DT_DEBUG_CAMCTL,
           "[camera_control] loaded %d camera drivers",
           gp_abilities_list_count(gp->abilities));
  return TRUE;
}

static void _cancel(dt_camctl_t *c)
{
  gp_context_cancel(_gp(c)->context);
}

static void _cleanup(dt_camctl_t *c)
{
  _gphoto_t *gp = _gp(c);
  if(!gp) return;
  gp_context_unref(gp->context);
  gp_abilities_list_free(gp->abilities);
  gp_port_info_list_free(gp->ports);
  g_free(gp);
  c->backend_data = NULL;
}

static int ports_cnt = -1;

static GList *_detect(dt_camctl_t *c)
{
  _gphoto_t *gp = _gp(c);

  /* reload portdrivers */
  if(gp->ports) gp_port_info_list_free(gp->ports);

  gp_port_info_list_new(&gp->ports);
  gp_port_info_list_load(gp->ports);
  const int ports_available = gp_port_info_list_count(gp->ports);
  if(ports_available != ports_cnt)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] loaded %d port drivers", ports_available);
    ports_cnt = ports_available;
  }

  CameraList *available_cameras = NULL;
  gp_list_new(&available_cameras);
  gp_abilities_list_detect(gp->abilities, gp->ports, available_cameras, gp->context);

  GList *found = NULL;
  for(int i = 0; i < gp_list_count(available_cameras); i++)
  {
    dt_camera_unused_t *testcam = g_malloc0(sizeof(dt_camera_unused_t));
    const gchar *s;
    gp_list_get_name(available_cameras, i, &s);
    testcam->model = g_strdup(s);
    gp_list_get_value(available_cameras, i, &s);
    testcam->port = g_strdup(s);
    found = g_list_prepend(found, testcam);
  }
  gp_list_unref(available_cameras);
  return g_list_reverse(found);
}

static void _free_gphoto_camera(_gphoto_camera_t *gc)
{
  for(GList *it = gc->open_gpfiles; it; it = g_list_delete_link(it, it))
  {
    gp_file_free((CameraFile *)it->data);
  }
  if(gc->gpcam)
  {
    gp_camera_exit(gc->gpcam, gc->context);
    gp_camera_unref(gc->gpcam);
  }
  if(gc->configuration) gp_widget_unref(gc->configuration);
  g_free(gc);
}

static gboolean _open(dt_camctl_t *c, dt_camera_t *cam)
{
  _gphoto_t *gp = _gp(c);
  CameraAbilities a;
  GPPortInfo pi;

  _gphoto_camera_t *gc = g_malloc0(sizeof(_gphoto_camera_t));
  gc->context = gp->context;

  gp_camera_new(&gc->gpcam);
  const int m = gp_abilities_list_lookup_model(gp->abilities, cam->model);
  int err = gp_abilities_list_get_abilities(gp->abilities, m, &a);
  if(err != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to gp_abilities_list_get_abilities %s",
             cam->model);
    gp_camera_unref(gc->gpcam);
    g_free(gc);
    return FALSE;
  }

  err = gp_camera_set_abilities(gc->gpcam, a);
  if(err != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to gp_camera_set_abilities %s",
             cam->model);
    gp_camera_unref(gc->gpcam);
    g_free(gc);
    return FALSE;
  }

  const int p = gp_port_info_list_lookup_path(gp->ports, cam->port);
  err = gp_port_info_list_get_info(gp->ports, p, &pi);
  if(err != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to gp_port_info_list_get_info %s",
             cam->model);
    gp_camera_unref(gc->gpcam);
    g_free(gc);
    return FALSE;
  }
  err = gp_camera_set_port_info(gc->gpcam, pi);
  if(err != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to gp_camera_set_port_info %s",
             cam->model);
    gp_camera_unref(gc->gpcam);
    g_free(gc);
    return FALSE;
  }

  // Check for abilities
  if((a.operations & GP_OPERATION_CAPTURE_IMAGE))
    cam->can_tether = TRUE;
  if((a.operations & GP_OPERATION_CAPTURE_PREVIEW))
    cam->can_live_view = TRUE;
  if(cam->can_tether && (a.operations & GP_OPERATION_CONFIG))
    cam->can_config = TRUE;
  if(!(a.file_operations & GP_FILE_OPERATION_NONE))
    cam->can_import = TRUE;
  if(cam->can_import && (a.file_operations & GP_FILE_OPERATION_PREVIEW))
    cam->can_file_preview = TRUE;
  if(cam->can_import && (a.file_operations & GP_FILE_OPERATION_EXIF))
    cam->can_file_exif = TRUE;
  if(!(a.folder_operations & GP_FOLDER_OPERATION_NONE))
    cam->can_directory = TRUE;

  if(gp_camera_init(gc->gpcam, gp->context) != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to initialize %s on port %s", cam->model,
             cam->port);
    gp_camera_unref(gc->gpcam);
    g_free(gc);
    return FALSE;
  }

  // Calling gp_camera_get_config can cause a crash (seen with
  // libgphoto2 2.5.31) due to a stack smashing when working with
  // some specific locales. At least this was seen with Ukrainian
  // and Czech locales. This is clearly a bug in libgphoto2, which
  // we will have to work around by temporarily switching to a safe
  // locale. Note that for safety we should either use thread-safe
  // functions (newlocale/uselocale), or this locale switching should
  // be for the current thread only (on Windows where there is no
  // implementation of newlocale/uselocale).
#if defined(WIN32)
  char *locale = strdup(setlocale(LC_ALL, NULL));
  _configthreadlocale(_ENABLE_PER_THREAD_LOCALE);
  setlocale(LC_ALL, "C");
#else
  locale_t nlocale = newlocale(LC_ALL_MASK, "C", (locale_t) 0);
  locale_t locale = uselocale(nlocale);
#endif
  // read a full copy of config to configuration cache
  gp_camera_get_config(gc->gpcam, &gc->configuration, gp->context);

#if defined(WIN32)
  if(locale)
  {
    setlocale(LC_ALL, locale);
    free(locale);
  }
  _configthreadlocale(_DISABLE_PER_THREAD_LOCALE);
#else
  uselocale(locale);
  freelocale(nlocale);
#endif

  // initialize timeout callbacks eg. keep alive, some cameras needs it.
  gp_camera_set_timeout_funcs(gc->gpcam,
                              (CameraTimeoutStartFunc)_camera_start_timeout_func,
                              (CameraTimeoutStopFunc)_camera_stop_timeout_func, gc);

  cam->backend_data = gc;

  // Fetch some summary of camera
  CameraText summary;
  if(gp_camera_get_summary(gc->gpcam, &summary, gp->context) == GP_OK)
  {
    // Remove device property summary:
    char *eos = strstr(summary.text, "Device Property Summary:\n");
    if(eos) eos[0] = '\0';
    cam->summary = g_strdup(summary.text);
  }
  return TRUE;
}

static void _close(dt_camctl_t *c, dt_camera_t *cam)
{
  if(!cam->backend_data) return;
  _free_gphoto_camera(_gpcam(cam));
  cam->backend_data = NULL;
}

static gboolean _list_folder(const dt_camctl_t *c,
                             const dt_camera_t *cam,
                             const char *folder,
                             GList **files,
                             GList **subfolders)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  const char *name;
  gboolean ok = TRUE;

  CameraList *list;
  gp_list_new(&list);
  if(gp_camera_folder_list_files(gc->gpcam, folder, list, gc->context) == GP_OK)
  {
    for(int i = 0; i < gp_list_count(list); i++)
    {
      gp_list_get_name(list, i, &name);
      *files = g_list_append(*files, g_strdup(name));
    }
  }
  else
    ok = FALSE;
  gp_list_free(list);

  gp_list_new(&list);
  if(gp_camera_folder_list_folders(gc->gpcam, folder, list, gc->context) == GP_OK)
  {
    for(int i = 0; i < gp_list_count(list); i++)
    {
      gp_list_get_name(list, i, &name);
      *subfolders = g_list_append(*subfolders, g_strdup(name));
    }
  }
  gp_list_free(list);
  return ok;
}

static gboolean _get_file_info(const dt_camctl_t *c,
                               const dt_camera_t *cam,
                               const char *folder,
                               const char *filename,
                               dt_camera_file_info_t *info)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraFileInfo cfi;
  if(gp_camera_file_get_info(gc->gpcam, folder, filename, &cfi, gc->context) != GP_OK)
    return FALSE;
  info->has_mtime = (cfi.file.fields & GP_FILE_INFO_MTIME) != 0;
  info->mtime = cfi.file.mtime;
  info->size = cfi.file.size;
  return TRUE;
}

static GBytes *_get_file(const dt_camctl_t *c,
                         dt_camera_t *cam,
                         const char *folder,
                         const char *filename)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraFile *camfile;
  int res = GP_OK;
  const char *data = NULL;
  unsigned long int size = 0;

  gp_file_new(&camfile);
  if((res = gp_camera_file_get(gc->gpcam, folder,
                               filename, GP_FILE_TYPE_NORMAL, camfile, NULL)) < GP_OK
     || (res = gp_file_get_data_and_size(camfile, &data, &size)) < GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] gphoto import failed: %s", gp_result_as_string(res));
    gp_file_free(camfile);
    return NULL;
  }
  // the bytes point into the CameraFile, which is freed with them
  return g_bytes_new_with_free_func(data, size, (GDestroyNotify)gp_file_free, camfile);
}

static GBytes *_get_preview(const dt_camctl_t *c,
                            dt_camera_t *cam,
                            const char *folder,
                            const char *filename)
{
  _gphoto_camera_t *gc = _gpcam(cam);

  CameraFileInfo cfi;
  if(!(gp_camera_file_get_info(gc->gpcam,
                               folder, filename, &cfi, gc->context) == GP_OK))
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to get file information"
             " of %s in folder %s on device",
             filename, folder);
    return NULL;
  }
  int gotpreview = 0;

  // Fetch image preview if flagged...
  CameraFile *preview = NULL;
  gp_file_new(&preview);
  if(gp_camera_file_get(gc->gpcam, folder, filename, GP_FILE_TYPE_PREVIEW, preview,
     gc->context) == GP_OK)
    gotpreview = 1;

  if(gotpreview == 0
     && cfi.file.size > 0
     && cfi.file.size < 512000)
  {
    if(gp_camera_file_get(gc->gpcam,
                          folder, filename, GP_FILE_TYPE_NORMAL, preview,
                          gc->context) == GP_OK)
      gotpreview = 1;
  }

  // If we couldn't get preview data we clean up
  if(gotpreview == 0)
  {
    gp_file_free(preview);
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed preview of %s in folder %s", filename, folder);
    return NULL;
  }

  const char *img;
  unsigned long size;
  gp_file_get_data_and_size(preview, &img, &size);

  /* Why can't we just gp_file_free(preview) at once?

     1. we may open the dialog with thumb selection multiple times,
        if we gp_camera_file_get multiple times we oly have valid
        data the first time, **not** when re-reading.  Symptom is
        not-seeing the thumbs when reopening this dialog.

     2. Also gphoto internal mem-management get's this wrong leading
        to double-free or alike.  This has been in dt for very long.

     3. Freeing a gp_file only works if we passed an address & size
        so the gphoto de-allocation get's it right.

     4. I tried to use gp_camera_file_read (to allow passing address
        & size) but after reading gphoto issues it becomes obvious
        that this doesn't work as it's internals are not implemented
        for some drivers.

     5. As the thumbs extractor has preallocated memory gp_file_free
        works fine, this means it's the better option compare to
        reading a small file.

     6. Unfortunately this is basically a gphoto issue we can't
        solve here so we have to bypass it.

     7. We keep the open gp_files in a Glist and close them when the
        camera is disconnected
  */
  gc->open_gpfiles = g_list_append(gc->open_gpfiles, preview);

  // the data stays valid until the camera is closed
  return size > 0 ? g_bytes_new_static(img, size) : NULL;
}

static gboolean _download_file(const dt_camctl_t *c,
                               const dt_camera_t *cam,
                               const char *folder,
                               const char *filename,
                               const char *dest_path)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  gboolean ok = FALSE;
  const int handle = g_open(dest_path, O_CREAT | O_WRONLY | O_BINARY, 0666);
  if(handle != -1)
  {
    CameraFile *destination;
    gp_file_new_from_fd(&destination, handle);
    ok = gp_camera_file_get(gc->gpcam, folder,
                            filename, GP_FILE_TYPE_NORMAL, destination,
                            gc->context) == GP_OK;
    close(handle);
  }
  return ok;
}

static gboolean _capture(const dt_camctl_t *c,
                         const dt_camera_t *cam,
                         char **folder,
                         char **filename)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraFilePath fp;
  int res = GP_OK;
  if((res = gp_camera_capture(gc->gpcam, GP_CAPTURE_IMAGE, &fp, gc->context)) != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] capture job failed to capture image: %s",
             gp_result_as_string(res));
    return FALSE;
  }
  *folder = g_strdup(fp.folder);
  *filename = g_strdup(fp.name);
  return TRUE;
}

static GBytes *_capture_preview(const dt_camctl_t *c,
                                const dt_camera_t *cam)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraFile *fp = NULL;
  int res = GP_OK;
  const gchar *data = NULL;
  unsigned long int data_size = 0;
  GBytes *bytes = NULL;

  gp_file_new(&fp);

  if((res = gp_camera_capture_preview(gc->gpcam, fp, gc->context)) != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] live view failed to capture preview: %s",
             gp_result_as_string(res));
  }
  else if((res = gp_file_get_data_and_size(fp, &data, &data_size)) != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] live view failed to get preview data: %s",
             gp_result_as_string(res));
  }
  // to avoid a crash check that data is not null and data_size >
  // 0. there is cases where this occurs even if the above call to
  // gp_file_get_data_and_size returns GP_OK.
  else if(data && data_size > 0)
    bytes = g_bytes_new(data, data_size);

  if(fp) gp_file_free(fp);
  return bytes;
}

static gboolean _wait_for_event(const dt_camctl_t *c,
                                const dt_camera_t *cam,
                                const int timeout_ms,
                                dt_camera_event_t *ev)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraEventType event;
  gpointer data;
  ev->type = DT_CAMERA_EVENT_NONE;
  ev->folder = ev->name = NULL;

  if(gp_camera_wait_for_event(gc->gpcam, timeout_ms, &event, &data, gc->context) != GP_OK)
    return FALSE;

  if(event == GP_EVENT_UNKNOWN)
  {
    /* this is really some undefined behavior, seems like it's
    camera driver dependent... very ugly! */
    if(strstr((char *)data, "4006") || // Nikon PTP driver
       (strstr((char *)data, "PTP Property")
        && strstr((char *)data, "changed")) // Some Canon driver maybe all ??
       )
    {
      // Property change event occurred on camera
      // let's update cache and signalling

      dt_print
        (DT_DEBUG_CAMCTL,
         "[camera_control] Camera configuration change event '%s', lets update internal "
         "configuration cache", (char*)data);
      ev->type = DT_CAMERA_EVENT_PROPERTY_CHANGED;
      // Update individual properties with gp_camera_get_single_config
      if(strstr((char*)data, "PTP Property") && strstr((char*)data, "changed"))
      {
        // Use the property name if provided (GUI elements use this
        // name and won't update if the numeric code is used
        // instead)
        if(strstr((char*)data, "changed,"))
        {
          char * nameStart = strchr(data + strlen("PTP Property "), '"');
          if(nameStart != NULL)
          {
            // Skip quotation marks
            nameStart += 1;
            const char *nameEnd = strchr(nameStart, '"');
            if(nameEnd != NULL)
            {
              ev->name = g_strndup(nameStart, nameEnd - nameStart);
              return TRUE;
            }
          }
          dt_print(DT_DEBUG_CAMCTL, "[camera_control] Unable to parse event '%s', \
              falling back to updating by code", (char*)data);
        }
        ev->name = g_strndup(data + strlen("PTP Property "), 4);
      }
    }
  }
  else if(event == GP_EVENT_FILE_ADDED)
  {
    CameraFilePath *fp = (CameraFilePath *)data;
    ev->type = DT_CAMERA_EVENT_FILE_ADDED;
    ev->folder = g_strdup(fp->folder);
    ev->name = g_strdup(fp->name);
  }
  return TRUE;
}

static CameraWidget *_widget(const dt_camera_t *cam, const char *name)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraWidget *widget;
  if(!gc->configuration
     || gp_widget_get_child_by_name(gc->configuration, name, &widget) != GP_OK)
    return NULL;
  return widget;
}

static gboolean _property_exists(const dt_camera_t *cam, const char *name)
{
  return _widget(cam, name) != NULL;
}

static gboolean _property_get_type(const dt_camera_t *cam,
                                   const char *name,
                                   dt_camera_property_type_t *type)
{
  CameraWidget *widget = _widget(cam, name);
  if(!widget)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to get property %s from camera config", name);
    return FALSE;
  }
  CameraWidgetType gptype;
  const int res = gp_widget_get_type(widget, &gptype);
  if(res != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to get property type for %s from camera config."
             " Error Code: %d",
             name, res);
    return FALSE;
  }
  // dt_camera_property_type_t is numbered like CameraWidgetType
  *type = (dt_camera_property_type_t)gptype;
  return TRUE;
}

static const char *_property_get_value(const dt_camera_t *cam, const char *name)
{
  const char *value = NULL;
  CameraWidget *widget = _widget(cam, name);
  if(widget) gp_widget_get_value(widget, &value);
  return value;
}

static int _property_count_choices(const dt_camera_t *cam, const char *name)
{
  CameraWidget *widget = _widget(cam, name);
  return widget ? gp_widget_count_choices(widget) : -1;
}

static const char *_property_get_choice(const dt_camera_t *cam,
                                        const char *name,
                                        const int index)
{
  const char *value = NULL;
  CameraWidget *widget = _widget(cam, name);
  if(widget) gp_widget_get_choice(widget, index, &value);
  return value;
}

static GList *_property_subtree(CameraWidget *widget)
{
  GList *nodes = NULL;
  const int num_children = gp_widget_count_children(widget);
  for(int i = 0; i < num_children; i++)
  {
    CameraWidget *child = NULL;
    const char *name;
    CameraWidgetType type;
    gp_widget_get_child(widget, i, &child);
    gp_widget_get_name(child, &name);
    gp_widget_get_type(child, &type);

    dt_camera_property_node_t *node = g_malloc0(sizeof(dt_camera_property_node_t));
    node->name = g_strdup(name);
    node->type = (dt_camera_property_type_t)type;
    node->children = _property_subtree(child);
    nodes = g_list_prepend(nodes, node);
  }
  return g_list_reverse(nodes);
}

static GList *_property_tree(const dt_camera_t *cam)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  return gc->configuration ? _property_subtree(gc->configuration) : NULL;
}

static gboolean _property_set_string(const dt_camctl_t *c,
                                     const dt_camera_t *cam,
                                     const char *name,
                                     const char *value)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraWidget *widget = _widget(cam, name);
  if(!widget) return FALSE;
  gp_widget_set_value(widget, value);
  return gp_camera_set_single_config(gc->gpcam, name, widget, gc->context) == GP_OK;
}

static gboolean _property_set_choice(const dt_camctl_t *c,
                                     const dt_camera_t *cam,
                                     const char *name,
                                     const int index)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraWidget *widget = _widget(cam, name);
  if(!widget) return FALSE;
  if(index < 0 || index >= gp_widget_count_choices(widget)) return FALSE;

  const char *choice;
  gp_widget_get_choice(widget, index, &choice);
  dt_print(DT_DEBUG_CAMCTL, " (%s)", choice);

  gp_widget_set_value(widget, choice);
  return gp_camera_set_single_config(gc->gpcam, name, widget, gc->context) == GP_OK;
}

static gboolean _property_set_toggle(const dt_camctl_t *c,
                                     const dt_camera_t *cam,
                                     const char *name)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraWidget *widget = _widget(cam, name);
  if(!widget) return FALSE;
  const int value = 1;
  gp_widget_set_value(widget, &value);
  return gp_camera_set_single_config(gc->gpcam, name, widget, gc->context) == GP_OK;
}

static gboolean _property_set_int(const dt_camctl_t *c,
                                  const dt_camera_t *cam,
                                  const char *name,
                                  const int value)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraWidget *widget = _widget(cam, name);
  if(!widget) return FALSE;
  const int set_value_succeeds = gp_widget_set_value(widget, &value);
  if(set_value_succeeds != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] setting int value %d on %s failed with code %d",
             value, name, set_value_succeeds);
  }
  const int set_config_succeeds =
    gp_camera_set_single_config(gc->gpcam, name, widget, gc->context);
  if(set_value_succeeds != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] setting config failed with code %d",
             set_config_succeeds);
  }
  return set_config_succeeds == GP_OK;
}

static gboolean _property_set_float(const dt_camctl_t *c,
                                    const dt_camera_t *cam,
                                    const char *name,
                                    const float value)
{
  _gphoto_camera_t *gc = _gpcam(cam);
  CameraWidget *widget = _widget(cam, name);
  if(!widget) return FALSE;
  const int set_value_succeeds = gp_widget_set_value(widget, &value);
  if(set_value_succeeds != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] setting int value %.2f on %s failed with code %d",
             value, name, set_value_succeeds);
  }
  const int set_config_succeeds =
    gp_camera_set_single_config(gc->gpcam, name, widget, gc->context);
  if(set_value_succeeds != GP_OK)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] setting config failed with code %d",
             set_config_succeeds);
  }
  return set_config_succeeds == GP_OK;
}

/** Compares new_config with old_config and notifies listeners of the changes. */
static void _camera_configuration_notify_change(const dt_camctl_t *c,
                                                const dt_camera_t *camera,
                                                CameraWidget *new_config,
                                                CameraWidget *old_config)
{
  const char *new_config_name = NULL;
  if(gp_widget_get_name(new_config, &new_config_name) != GP_OK) return;

  // If new_config widget has children let's recurse into each children
  int children = gp_widget_count_children(new_config);
  if(children > 0)
  {
    CameraWidget *child = NULL;
    for(int i = 0; i < children; i++)
    {
      if(gp_widget_get_child(new_config, i, &child) == GP_OK)
        _camera_configuration_notify_change(c, camera, child, old_config);
    }
  }
  else
  {
    CameraWidget *old_config_child = NULL;
    if(gp_widget_get_child_by_name(old_config,
                                   new_config_name, &old_config_child) != GP_OK)
      return;

    CameraWidgetType new_config_type, old_config_type;
    if(gp_widget_get_type(new_config, &new_config_type) != GP_OK)
      return;
    if(gp_widget_get_type(old_config_child, &old_config_type) != GP_OK)
      return;


    //
    // First of all check if widget has change accessibility
    //
    /// TODO: Resolve this 2.4.8 libgphoto2 dependency
    /*
    int sa,da;
    gp_widget_get_readonly( new_config, &sa );
    gp_widget_get_readonly( old_config_child, &da );

    if(  notify_all || ( sa != da ) ) {
      // update old_config widget to new accessibility if differ then notify of the change
      if( ( sa != da )  )
        gp_widget_set_readonly( old_config_child, sa );

      _dispatch_camera_property_accessibility_changed(c, camera,new_config_name, ( sa == 1 ) ? TRUE: FALSE) ;
    }
    */

    //
    // Lets compare values and notify on change or by notifyAll flag
    //
    if(new_config_type == GP_WIDGET_MENU
       || new_config_type == GP_WIDGET_TEXT
       || new_config_type == GP_WIDGET_RADIO
       || old_config_type == GP_WIDGET_MENU
       || old_config_type == GP_WIDGET_TEXT
       || old_config_type == GP_WIDGET_RADIO)
    {
      char *new_config_value = NULL;
      char *old_config_value = NULL;

      // gphoto2 has a "feature" that turns RANGE with a small value
      // range and step size of 1 into a MENU.  that can for example
      // happen when detaching the lens. the focus range suddenly
      // shrinks to 0 .. 0 and becomes a MENU. See
      // https://redmine.darktable.org/issues/12004 for the crash
      // resulting from that.

      // Get new_config and old_config value to be compared independent from locale
      if(new_config_type == GP_WIDGET_RANGE)
      {
        float value;
        if(gp_widget_get_value(new_config, &value) != GP_OK)
          goto end;
        new_config_value = (char *)g_malloc(G_ASCII_DTOSTR_BUF_SIZE);
        g_ascii_dtostr(new_config_value, G_ASCII_DTOSTR_BUF_SIZE, value);
      }
      else
        if(gp_widget_get_value(new_config, &new_config_value) != GP_OK)
          goto end;

      if(old_config_type == GP_WIDGET_RANGE)
      {
        float value;
        if(gp_widget_get_value(old_config_child, &value) != GP_OK)
          goto end;
        old_config_value = (char *)g_malloc(G_ASCII_DTOSTR_BUF_SIZE);
        g_ascii_dtostr(old_config_value, G_ASCII_DTOSTR_BUF_SIZE, value);
      }
      else
        if(gp_widget_get_value(old_config_child, &old_config_value) != GP_OK)
          goto end;

      if(g_strcmp0(new_config_value, old_config_value) != 0)
        dt_camctl_backend_property_changed(c, camera, new_config_name,
                                           new_config_value);

end:
      if(new_config_type == GP_WIDGET_RANGE)
        g_free(new_config_value);
      if(old_config_type == GP_WIDGET_RANGE)
        g_free(old_config_value);
    }
  }
}

static void _refresh_properties(const dt_camctl_t *c,
                                const dt_camera_t *camera,
                                const char *name)
{
  dt_camera_t *cam = (dt_camera_t *)camera;
  _gphoto_camera_t *gc = _gpcam(cam);
  dt_pthread_mutex_lock(&cam->config_lock);
  CameraWidget *remote; // Copy of remote configuration
  if(name)
  {
    if(gp_camera_get_single_config(gc->gpcam, name, &remote, gc->context) != GP_OK)
    {
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] failed to get config value for property %s", name);
      dt_pthread_mutex_unlock(&cam->config_lock);
      return;
    }
    // merge remote copy with cache and notify on changed properties to host application
    _camera_configuration_notify_change(c, camera, remote, gc->configuration);
    CameraWidget *old_config_child = NULL;
    if(gp_widget_get_child_by_name(gc->configuration, name, &old_config_child) == GP_OK)
    {
      void* value = NULL;
      gp_widget_get_value(remote, value);
      gp_widget_set_value(old_config_child, value);
    }
  }
  else
  {
    gp_camera_get_config(gc->gpcam, &remote, gc->context);
    // merge remote copy with cache and notify on changed properties to host application
    _camera_configuration_notify_change(c, camera, remote, gc->configuration);
    gp_widget_free(gc->configuration);
    gc->configuration = remote;
  }
  dt_pthread_mutex_unlock(&cam->config_lock);
}

static const dt_camera_backend_t _gphoto2_backend =
{
  .name = "gphoto2",
  .init = _init,
  .cleanup = _cleanup,
  .cancel = _cancel,
  .detect = _detect,
  .open = _open,
  .close = _close,
  .list_folder = _list_folder,
  .get_file_info = _get_file_info,
  .get_file = _get_file,
  .get_preview = _get_preview,
  .download_file = _download_file,
  .capture = _capture,
  .capture_preview = _capture_preview,
  .wait_for_event = _wait_for_event,
  .property_exists = _property_exists,
  .property_get_type = _property_get_type,
  .property_get_value = _property_get_value,
  .property_count_choices = _property_count_choices,
  .property_get_choice = _property_get_choice,
  .property_tree = _property_tree,
  .property_set_string = _property_set_string,
  .property_set_toggle = _property_set_toggle,
  .property_set_choice = _property_set_choice,
  .property_set_int = _property_set_int,
  .property_set_float = _property_set_float,
  .refresh_properties = _refresh_properties,
};

const dt_camera_backend_t *dt_camera_backend_default(void)
{
  return &_gphoto2_backend;
}

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
