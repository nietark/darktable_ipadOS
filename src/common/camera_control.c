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

#include "common/camera_control.h"
#include "common/exif.h"
#include "common/image.h"
#include "control/control.h"
#include "imageio/imageio_jpeg.h"

#include <glib-2.0/gio/gmenu.h>

#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <locale.h>

typedef enum _camctl_camera_job_type_t
{
  /** Start a scan of devices and announce new and removed. */
  _JOB_TYPE_DETECT_DEVICES,
  /** Remotly executes a capture. */
  _JOB_TYPE_EXECUTE_CAPTURE,
  /** Fetch a preview for live view. */
  _JOB_TYPE_EXECUTE_LIVE_VIEW,
  /** Read a copy of remote camera config into cache. */
  _JOB_TYPE_READ_CONFIG,
  /** Writes changed properties in cache to camera */
  _JOB_TYPE_WRITE_CONFIG,
  /** Set's a property in config cache. \todo This shouldn't be a job in jobqueue !? */
  _JOB_TYPE_SET_PROPERTY_STRING,
  _JOB_TYPE_SET_PROPERTY_TOGGLE,
  _JOB_TYPE_SET_PROPERTY_CHOICE,
  /** For some reason stopping live view needs to pass an int, not a string. */
  _JOB_TYPE_SET_PROPERTY_INT,
  _JOB_TYPE_SET_PROPERTY_FLOAT,
  /** gets a property from config cache. \todo This shouldn't be a job in jobqueue !?  */
  _JOB_TYPE_GET_PROPERTY
} _camctl_camera_job_type_t;

typedef struct _camctl_camera_job_t
{
  _camctl_camera_job_type_t type;
} _camctl_camera_job_t;

typedef struct _camctl_camera_set_property_string_job_t
{
  _camctl_camera_job_type_t type;
  char *name;
  char *value;
} _camctl_camera_set_property_string_job_t;

typedef struct _camctl_camera_set_property_toggle_job_t
{
  _camctl_camera_job_type_t type;
  char *name;
} _camctl_camera_set_property_toggle_job_t;

typedef struct _camctl_camera_set_property_choice_job_t
{
  _camctl_camera_job_type_t type;
  char *name;
  int value;
} _camctl_camera_set_property_choice_job_t;

typedef struct _camctl_camera_set_property_int_job_t
{
  _camctl_camera_job_type_t type;
  char *name;
  int value;
} _camctl_camera_set_property_int_job_t;

typedef struct _camctl_camera_set_property_float_job_t
{
  _camctl_camera_job_type_t type;
  char *name;
  float value;
} _camctl_camera_set_property_float_job_t;

/** Initializes camera */
static gboolean _camera_initialize(const dt_camctl_t *c,
                                   dt_camera_t *cam);

/** Poll camera events, this one is called from the thread handling the camera. */
static void _camera_poll_events(const dt_camctl_t *c,
                                const dt_camera_t *cam);

/** Lock camera control and notify listener. \note Locks mutex and
 * signals CAMERA_CONTROL_BUSY. \remarks all interface functions
 * available to host application should lock/unlock its operation. */
static void _camctl_lock(const dt_camctl_t *c,
                         const dt_camera_t *cam);
/** Lock camera control and notify listener. \note Locks mutex and
 * signals CAMERA_CONTROL_AVAILABLE. \see _camctl_lock() */
static void _camctl_unlock(const dt_camctl_t *c);

/** Put a job on the queue */
static void _camera_add_job(const dt_camctl_t *c,
                            const dt_camera_t *camera,
                            gpointer job);
/** Get a job from the queue */
static gpointer _camera_get_job(const dt_camctl_t *c,
                                const dt_camera_t *camera);
static void _camera_process_job(const dt_camctl_t *c,
                                const dt_camera_t *camera,
                                gpointer job);

/** Dispatch functions for listener interfaces */
static const char *_dispatch_request_image_path(const dt_camctl_t *c,
                                                const dt_image_basic_exif_t *basic_exif,
                                                const dt_camera_t *camera);
static const char *_dispatch_request_image_filename(const dt_camctl_t *c,
                                                    const char *filename,
                                                    const dt_image_basic_exif_t *basic_exif,
                                                    const dt_camera_t *camera);
static void _dispatch_camera_image_downloaded(const dt_camctl_t *c,
                                              const dt_camera_t *camera,
                                              const char *in_path,
                                              const char *in_filename,
                                              const char *filename);
static void _dispatch_camera_connected(const dt_camctl_t *c,
                                       const dt_camera_t *camera);
static void _dispatch_camera_disconnected(const dt_camctl_t *c,
                                          const dt_camera_t *camera);
static void _dispatch_control_status(const dt_camctl_t *c,
                                     dt_camctl_status_t status);
static void _dispatch_camera_error(const dt_camctl_t *c,
                                   const dt_camera_t *camera,
                                   dt_camera_error_t error);
static void _dispatch_camera_property_value_changed(const dt_camctl_t *c,
                                                    const dt_camera_t *camera,
                                                    const char *name,
                                                    const char *value);

/** Helper function to destroy a dt_camera_t object */
static void _camctl_camera_destroy(const dt_camctl_t *c, dt_camera_t *cam);

void dt_camctl_backend_connection_error(const dt_camctl_t *c,
                                        const char *text)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  /* the camera updating thread should get a note about an error from here */
  GList *ci = g_list_find(camctl->cameras, camctl->active_camera);
  if(ci)
  {
    dt_camera_t *cam = (dt_camera_t *)ci->data;
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] PTP error `%s' for camera %s on port %s",
             text, cam->model, cam->port);
    dt_control_log
      (_("camera `%s' on port `%s' error %s\n"
         "\nmake sure your camera allows access and is not mounted otherwise"),
       cam->model, cam->port, text);
    cam->ptperror = TRUE;
  }

  /* notify client of camera connection broken */
  _dispatch_camera_error(camctl, camctl->active_camera, CAMERA_CONNECTION_BROKEN);

  /* notify client of camera disconnection */
  _dispatch_camera_disconnected(camctl, camctl->active_camera);
}

void dt_camctl_backend_property_changed(const dt_camctl_t *c,
                                        const dt_camera_t *cam,
                                        const char *name,
                                        const char *value)
{
  _dispatch_camera_property_value_changed(c, cam, name, value);
}

void dt_camera_property_tree_free(GList *tree)
{
  for(GList *it = tree; it; it = g_list_next(it))
  {
    dt_camera_property_node_t *node = (dt_camera_property_node_t *)it->data;
    dt_camera_property_tree_free(node->children);
    g_free(node->name);
    g_free(node);
  }
  g_list_free(tree);
}

/** Download a file to the path the listeners ask for, the file name
    falling back to the one on the camera when fallback is set */
static void _camera_download_tethered(const dt_camctl_t *c,
                                      const dt_camera_t *cam,
                                      const char *folder,
                                      const char *name,
                                      const gboolean fallback)
{
  const char *output_path = _dispatch_request_image_path(c, NULL, cam);
  if(!output_path) output_path = "/tmp";

  const char *fname = _dispatch_request_image_filename(c, name, NULL, cam);
  if(!fname)
  {
    if(!fallback) return;
    fname = name;
  }

  char *output = g_build_filename(output_path, fname, (char *)NULL);

  if(c->backend->download_file(c, cam, folder, name, output))
  {
    // Notify listeners of captured image
    _dispatch_camera_image_downloaded(c, cam, NULL, NULL, output);
  }
  else
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to download file %s", output);
  g_free(output);
}

static void _camera_add_job(const dt_camctl_t *c,
                            const dt_camera_t *camera,
                            gpointer job)
{
  dt_camera_t *cam = (dt_camera_t *)camera;
  dt_pthread_mutex_lock(&cam->jobqueue_lock);
  cam->jobqueue = g_list_append(cam->jobqueue, job);
  dt_pthread_mutex_unlock(&cam->jobqueue_lock);
}

static gpointer _camera_get_job(const dt_camctl_t *c,
                                const dt_camera_t *camera)
{
  dt_camera_t *cam = (dt_camera_t *)camera;
  dt_pthread_mutex_lock(&cam->jobqueue_lock);
  gpointer job = NULL;
  if(cam->jobqueue) // are there any queued jobs?
  {
    job = cam->jobqueue->data;
    cam->jobqueue = g_list_remove(cam->jobqueue, job);
  }
  dt_pthread_mutex_unlock(&cam->jobqueue_lock);
  return job;
}


static void _camera_process_job(const dt_camctl_t *c,
                                const dt_camera_t *camera,
                                gpointer job)
{
  dt_camera_t *cam = (dt_camera_t *)camera;
  _camctl_camera_job_t *j = (_camctl_camera_job_t *)job;
  switch(j->type)
  {

    case _JOB_TYPE_EXECUTE_CAPTURE:
    {
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] executing remote camera capture job");
      char *folder = NULL, *name = NULL;
      if(c->backend->capture(c, camera, &folder, &name))
        _camera_download_tethered(c, camera, folder, name, FALSE);
      g_free(folder);
      g_free(name);
    }
    break;

    case _JOB_TYPE_EXECUTE_LIVE_VIEW:
    {
      GBytes *preview = c->backend->capture_preview(c, camera);
      if(preview)
      {
        gsize data_size = 0;
        const uint8_t *data = g_bytes_get_data(preview, &data_size);
        // everything worked
        dt_imageio_jpeg_t jpg;
        if(dt_imageio_jpeg_decompress_header(data, data_size, &jpg))
        {
          dt_print(DT_DEBUG_CAMCTL,
                   "[camera_control] live view failed to decompress jpeg header");
        }
        else
        {
          // FIXME: is the live view ever tagged with a profile?
          // testing so far (limited to Canon EOS 5D Mark III) hasn't
          // found one
          // dt_colorspaces_color_profile_type_t color_space = dt_imageio_jpeg_read_color_space(&jpg);
          //if(color_space == DT_COLORSPACE_DISPLAY)
          //  color_space = DT_COLORSPACE_SRGB;
          // no embedded colorspace, assume is sRGB
          uint8_t *const buffer =
            (uint8_t *)dt_alloc_align_uint8(4 * jpg.width * jpg.height);
          if(!buffer)
          {
            dt_print(DT_DEBUG_CAMCTL,
                     "[camera_control] live view could not allocate image buffer");
          }
          else if(dt_imageio_jpeg_decompress(&jpg, buffer))
          {
            dt_print(DT_DEBUG_CAMCTL,
                     "[camera_control] live view failed to decompress jpeg");
          }
          else
          {
            dt_pthread_mutex_lock(&cam->live_view_buffer_mutex);
            // FIXME: don't need to alloc/dealloc if the image dimensions haven't changed
            if(cam->live_view_buffer) dt_free_align(cam->live_view_buffer);
            cam->live_view_buffer = buffer;
            cam->live_view_width = jpg.width;
            cam->live_view_height = jpg.height;
            //cam->live_view_color_space = color_space;
            dt_pthread_mutex_unlock(&cam->live_view_buffer_mutex);
          }
        }
        g_bytes_unref(preview);
      }
      dt_pthread_mutex_BAD_unlock(&cam->live_view_synch);
      dt_control_queue_redraw_center();
    }
    break;

    case _JOB_TYPE_SET_PROPERTY_STRING:
    {
      _camctl_camera_set_property_string_job_t *spj =
        (_camctl_camera_set_property_string_job_t *)job;
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] executing set camera config job %s=%s",
               spj->name, spj->value);

      dt_pthread_mutex_lock(&cam->config_lock);
      c->backend->property_set_string(c, cam, spj->name, spj->value);
      dt_pthread_mutex_unlock(&cam->config_lock);
      g_free(spj->name);
      g_free(spj->value);
    }
    break;

    case _JOB_TYPE_SET_PROPERTY_CHOICE:
    {
      _camctl_camera_set_property_choice_job_t *spj =
        (_camctl_camera_set_property_choice_job_t *)job;
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] executing set camera config job %s=%d",
               spj->name, spj->value);

      dt_pthread_mutex_lock(&cam->config_lock);
      c->backend->property_set_choice(c, cam, spj->name, spj->value);
      dt_pthread_mutex_unlock(&cam->config_lock);
      dt_print(DT_DEBUG_CAMCTL, "\n");
      g_free(spj->name);
    }
    break;
    case _JOB_TYPE_SET_PROPERTY_TOGGLE:
    {
      _camctl_camera_set_property_toggle_job_t *spj =
        (_camctl_camera_set_property_toggle_job_t *)job;
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] executing camera config job to toggle %s",
               spj->name);

      dt_pthread_mutex_lock(&cam->config_lock);
      c->backend->property_set_toggle(c, cam, spj->name);
      dt_pthread_mutex_unlock(&cam->config_lock);
      g_free(spj->name);
    }
      break;
    case _JOB_TYPE_SET_PROPERTY_INT:
    {
      _camctl_camera_set_property_int_job_t *spj =
        (_camctl_camera_set_property_int_job_t *)job;
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] executing set camera config job %s=%d",
               spj->name, spj->value);

      dt_pthread_mutex_lock(&cam->config_lock);
      c->backend->property_set_int(c, cam, spj->name, spj->value);
      dt_pthread_mutex_unlock(&cam->config_lock);
      g_free(spj->name);
    }
    break;
    case _JOB_TYPE_SET_PROPERTY_FLOAT:
    {
      _camctl_camera_set_property_float_job_t *spj =
        (_camctl_camera_set_property_float_job_t *)job;
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] executing set camera config float job %s=%.2f",
               spj->name, spj->value);

      dt_pthread_mutex_lock(&cam->config_lock);
      c->backend->property_set_float(c, cam, spj->name, spj->value);
      dt_pthread_mutex_unlock(&cam->config_lock);
      g_free(spj->name);
    }
      break;
    default:
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] process of unknown job type 0x%x", j->type);
      break;
  }

  g_free(j);
}

/*************/
/* LIVE VIEW */
/*************/

static void *_camctl_camera_get_live_view(void *data)
{
  dt_camctl_t *camctl = (dt_camctl_t *)data;
  dt_camera_t *cam = (dt_camera_t *)camctl->active_camera;

  dt_pthread_setname("live view");

  dt_print(DT_DEBUG_CAMCTL, "[camera_control] live view thread started");

  int frames = 0;
  double capture_time = dt_get_wtime();
  const int fps = dt_conf_get_int("plugins/capture/camera/live_view_fps");

  while(cam->is_live_viewing)
  {
    dt_pthread_mutex_BAD_lock(&cam->live_view_synch);

    // calculate FPS
    double current_time = dt_get_wtime();
    if(current_time - capture_time >= 1.0)
    {
      // a second has passed
      dt_print(DT_DEBUG_CAMCTL, "%d fps", frames + 1);
      frames = 0;
      capture_time = current_time;
    }
    else
    {
      // just increase the frame counter
      frames++;
    }

    _camctl_camera_job_t *job = g_malloc(sizeof(_camctl_camera_job_t));
    job->type = _JOB_TYPE_EXECUTE_LIVE_VIEW;
    _camera_add_job(camctl, cam, job);

    g_usleep((1.0 / fps) * G_USEC_PER_SEC); // going too fast will result in
                                            // too many redraws without a real benefit
  }
  dt_print(DT_DEBUG_CAMCTL, "[camera_control] live view thread stopped");
  return NULL;
}

gboolean dt_camctl_camera_start_live_view(const dt_camctl_t *c)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_camera_t *cam = (dt_camera_t *)camctl->active_camera;
  if(cam == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] Failed to start live view, camera==NULL");
    return FALSE;
  }
  else
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] Starting live view");

  if(cam->can_live_view == FALSE)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] Camera does not support live view");
    return FALSE;
  }
  cam->is_live_viewing = TRUE;
  dt_camctl_camera_set_property_int(camctl, NULL, "eosviewfinder", 1);
  dt_camctl_camera_set_property_int(camctl, NULL, "viewfinder", 1);

  dt_pthread_create(&cam->live_view_thread,
                    &_camctl_camera_get_live_view, (void *)camctl);

  return TRUE;
}

void dt_camctl_camera_stop_live_view(const dt_camctl_t *c)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_camera_t *cam = (dt_camera_t *)camctl->active_camera;
  if(!cam) return;
  if(cam->is_live_viewing == FALSE)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] Not in live view mode, nothing to stop");
    return;
  }
  dt_print(DT_DEBUG_CAMCTL, "[camera_control] Stopping live view");
  cam->is_live_viewing = FALSE;
  dt_pthread_join(cam->live_view_thread);
  // tell camera to get back to normal state (close mirror)
  dt_camctl_camera_set_property_int(camctl, NULL, "eosviewfinder", 0);
  dt_camctl_camera_set_property_int(camctl, NULL, "viewfinder", 0);
}

static void _camctl_lock(const dt_camctl_t *c, const dt_camera_t *cam)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_pthread_mutex_BAD_lock(&camctl->lock);
  dt_print(DT_DEBUG_CAMCTL,
           "[camera_control] camera control locked for %s", cam->model);
  camctl->active_camera = cam;
  _dispatch_control_status(c, CAMERA_CONTROL_BUSY);
}

static void _camctl_unlock(const dt_camctl_t *c)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  const dt_camera_t *cam = camctl->active_camera;
  camctl->active_camera = NULL;
  dt_pthread_mutex_BAD_unlock(&camctl->lock);
  if(cam)
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] camera control un-locked for %s", cam->model);
  else
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] camera control un-locked for unknown camera");
  _dispatch_control_status(c, CAMERA_CONTROL_AVAILABLE);
}

static void *_update_cameras_thread(void *ptr);
dt_camctl_t *dt_camctl_new()
{
  dt_camctl_t *camctl = g_try_malloc0(sizeof(dt_camctl_t));
  if(!camctl)
    return NULL;

  dt_print(DT_DEBUG_CAMCTL, "[camera_control] creating new context %p", camctl);

  camctl->backend = dt_camera_backend_default();
  camctl->ticker = 1;
  camctl->tickmask = 0x0F;

  if(!camctl->backend->init(camctl))
  {
    g_free(camctl);
    return NULL;
  }

  dt_pthread_mutex_init(&camctl->lock);
  dt_pthread_mutex_init(&camctl->listeners_lock);

  /* create thread taking care of connecting camera devices */
  if(dt_control_running())
  {
    dt_control_t *control = darktable.control;
    if(dt_pthread_create(&control->update_gphoto_thread, _update_cameras_thread, camctl))
      dt_print(DT_DEBUG_ALWAYS, "could not start camera update thread");
  }
  return camctl;
}

static void _camctl_camera_destroy_struct(dt_camera_t *cam)
{
  if(!cam) return;
  if(cam->live_view_buffer)
  {
    dt_free_align(cam->live_view_buffer);
    cam->live_view_buffer = NULL; // just in case someone else is using this
  }
  g_free(cam->model);
  g_free(cam->port);
  g_free(cam->summary);
  g_free(cam->current_choice.name);
  dt_pthread_mutex_destroy(&cam->jobqueue_lock);
  dt_pthread_mutex_destroy(&cam->config_lock);
  dt_pthread_mutex_destroy(&cam->live_view_buffer_mutex);
  dt_pthread_mutex_destroy(&cam->live_view_synch);
  // TODO: cam->jobqueue
  g_free(cam);
}

static void _camctl_camera_destroy(const dt_camctl_t *c, dt_camera_t *cam)
{
  if(!cam) return;
  dt_print(DT_DEBUG_CAMCTL,
           "[camera_control] destroy %s on port %s", cam->model, cam->port);

  c->backend->close((dt_camctl_t *)c, cam);
  _camctl_camera_destroy_struct(cam);
}

static void _camctl_unused_camera_destroy(dt_camera_unused_t *cam)
{
  if(!cam) return;
  g_free(cam->model);
  g_free(cam->port);
  g_free(cam);
}

void dt_camctl_destroy(dt_camctl_t *camctl)
{
  if(!camctl) return;
  // Go thru all c->cameras and release them..
  dt_print(DT_DEBUG_CAMCTL, "[camera_control] destroy darktable camcontrol");
  camctl->backend->cancel(camctl);

  for(GList *it = camctl->cameras; it; it = g_list_delete_link(it, it))
  {
    _camctl_camera_destroy(camctl, (dt_camera_t *)it->data);
  }
  // Go thru all c->unused_cameras and free them
  for(GList *itl = camctl->unused_cameras; itl; itl = g_list_delete_link(itl, itl))
  {
    _camctl_unused_camera_destroy((dt_camera_unused_t *)itl->data);
  }
  camctl->backend->cleanup(camctl);
  dt_pthread_mutex_destroy(&camctl->lock);
  dt_pthread_mutex_destroy(&camctl->listeners_lock);
  g_free(camctl);
}


gboolean dt_camctl_have_cameras(const dt_camctl_t *c)
{
  return (c->cameras) ? TRUE : FALSE;
}

gboolean dt_camctl_have_unused_cameras(const dt_camctl_t *c)
{
  return (c->unused_cameras) ? TRUE : FALSE;
}

void dt_camctl_register_listener(const dt_camctl_t *c,
                                 dt_camctl_listener_t *listener)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  // Just locking mutex and prevent signalling CAMERA_CONTROL_BUSY
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  if(g_list_find(camctl->listeners, listener) == NULL)
  {
    camctl->listeners = g_list_append(camctl->listeners, listener);
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] registering listener %p", listener);
  }
  else
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] registering already registered listener %p", listener);
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
}

void dt_camctl_unregister_listener(const dt_camctl_t *c,
                                   dt_camctl_listener_t *listener)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  // Just locking mutex and prevent signalling CAMERA_CONTROL_BUSY
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  dt_print(DT_DEBUG_CAMCTL, "[camera_control] unregistering listener %p", listener);
  camctl->listeners = g_list_remove(camctl->listeners, listener);
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
}

static gboolean _have_camera_on_port(const dt_camera_unused_t *const testcam,
                                     const GList *const cameras)
{
  for(const GList *camera = cameras; camera; camera = g_list_next(camera))
  {
    const dt_camera_unused_t *caminfo = (dt_camera_unused_t*)camera->data;
    if(g_strcmp0(testcam->model, caminfo->model) == 0 &&
       g_strcmp0(testcam->port, caminfo->port) == 0)
      return TRUE;
  }
  return FALSE;
}

static int cameras_cnt = -1;

static gboolean _camctl_update_cameras(const dt_camctl_t *c)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!camctl) return FALSE;

  dt_pthread_mutex_lock(&camctl->lock);
  camctl->changed_camera = FALSE;

  GList *available_cameras = camctl->backend->detect(camctl);

  const int connected_cnt = g_list_length(available_cameras);
  if(connected_cnt != cameras_cnt)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] %d cameras connected", connected_cnt);
    cameras_cnt = connected_cnt;
  }

  for(GList *ac = available_cameras; ac; ac = g_list_next(ac))
  {
    const dt_camera_unused_t *testcam = (dt_camera_unused_t *)ac->data;

    // FIXME we might better test elsewhere for special port drivers,
    // have it active while debugging
    if(!(strncmp(testcam->port, "disk:", 5)) && !(darktable.unmuted & DT_DEBUG_CAMCTL))
      continue;

    // look for freshly connected cameras -- neither in mounted-cameras list nor unmounted-cameras list
    if(!_have_camera_on_port(testcam, c->cameras) &&
       !_have_camera_on_port(testcam, c->unused_cameras))
    {
      dt_camera_unused_t *unused_camera = g_malloc0(sizeof(dt_camera_unused_t));
      unused_camera->model = g_strdup(testcam->model);
      unused_camera->port = g_strdup(testcam->port);
      camctl->unused_cameras = g_list_append(camctl->unused_cameras, unused_camera);
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] found new %s on port %s",
               testcam->model, testcam->port);
      camctl->changed_camera = TRUE;
    }
  }

  /* check unused_cameras being unplugged */
  if(dt_camctl_have_unused_cameras(camctl))
  {
    GList *unused_item = c->unused_cameras;
    do
    {
      dt_camera_unused_t *cam = (dt_camera_unused_t *)unused_item->data;
      const gboolean removed = !_have_camera_on_port(cam, available_cameras);
      if(removed)
      {
        dt_print(DT_DEBUG_CAMCTL,
                 "[camera_control] remove %s on port %s from unused camera list",
                 cam->model, cam->port);
        dt_camera_unused_t *oldcam = (dt_camera_unused_t *)unused_item->data;
        camctl->unused_cameras = unused_item =
          g_list_delete_link(c->unused_cameras, unused_item);
        _camctl_unused_camera_destroy(oldcam);
        camctl->changed_camera = TRUE;
      }
      else
      {
        if(cam->trymount)
        {
          cam->trymount = FALSE;
          dt_camera_t *camera = g_malloc0(sizeof(dt_camera_t));
          camera->model = g_strdup(cam->model);
          camera->port = g_strdup(cam->port);

          if(_camera_initialize(camctl, camera) == FALSE)
          {
            dt_print(DT_DEBUG_CAMCTL,
                     "[camera_control] failed to initialize %s on port %s, likely "
                     "causes are: locked by another application, no access to udev etc",
                     camera->model, camera->port);
            dt_control_log
              (_("failed to initialize `%s' on port `%s', likely "
                 "causes are: locked by another application, no access to devices etc"),
               camera->model, camera->port);
            _camctl_camera_destroy_struct(camera);
            cam->used = TRUE;
            continue;
          }

          if(camera->can_import == FALSE && camera->can_tether == FALSE)
          {
            dt_print(DT_DEBUG_CAMCTL,
                     "[camera_control] %s on port %s doesn't support import or tether",
                     camera->model, camera->port);
            dt_control_log(_("`%s' on port `%s' is not interesting"
                             " because it supports neither tethering nor import"),
                               camera->model, camera->port);
            _camctl_camera_destroy(camctl, camera);
            cam->boring = TRUE;
            continue;
          }

          // Add to camera list
          camctl->cameras = g_list_append(camctl->cameras, camera);
          camctl->changed_camera = TRUE;

          dt_print(DT_DEBUG_CAMCTL,
                   "[camera_control] remove %s on port %s from"
                   " unused camera list as mounted",
                   cam->model, cam->port);
          dt_camera_unused_t *oldcam = (dt_camera_unused_t *)unused_item->data;
          camctl->unused_cameras = unused_item =
            g_list_delete_link(c->unused_cameras, unused_item);
          _camctl_unused_camera_destroy(oldcam);
         // Notify listeners of connected camera
         _dispatch_camera_connected(camctl, camera);
        }
      }
    } while(unused_item && (unused_item = g_list_next(unused_item)) != NULL);
  }

  if(dt_camctl_have_cameras(camctl))
  {
    GList *citem = c->cameras;
    do
    {
      dt_camera_t *cam = (dt_camera_t *)citem->data;
      const dt_camera_unused_t testcam = { .model = cam->model, .port = cam->port };
      const gboolean removed = !_have_camera_on_port(&testcam, available_cameras);
      if(removed)
      {
        dt_camera_t *oldcam = (dt_camera_t *)citem->data;
        camctl->cameras = citem = g_list_delete_link(c->cameras, citem);
        dt_print(DT_DEBUG_CAMCTL,
                 "[camera_control] ERROR: %s on port %s disconnected while mounted",
                 cam->model, cam->port);
        dt_control_log(_("camera `%s' on port `%s' disconnected while mounted"),
                       cam->model, cam->port);
        _camctl_camera_destroy_struct(oldcam);
        camctl->changed_camera = TRUE;
      }
      else if((cam->ptperror) || (cam->unmount))
      {
        if(cam->ptperror)
          dt_control_log(_("camera `%s' on port `%s' needs to be remounted\n"
                         "make sure it allows access and is not mounted otherwise"),
                         cam->model, cam->port);

        dt_camera_unused_t *unused_camera = g_malloc0(sizeof(dt_camera_unused_t));
        unused_camera->model = g_strdup(cam->model);
        unused_camera->port = g_strdup(cam->port);
        camctl->unused_cameras = g_list_append(camctl->unused_cameras, unused_camera);

        dt_camera_t *oldcam = (dt_camera_t *)citem->data;
        camctl->cameras = citem = g_list_delete_link(c->cameras, citem);
        _camctl_camera_destroy(camctl, oldcam);
        camctl->changed_camera = TRUE;
      }
    } while(citem && (citem = g_list_next(citem)) != NULL);
  }

  g_list_free_full(available_cameras, (GDestroyNotify)_camctl_unused_camera_destroy);

  camctl->import_ui = TRUE;
  dt_pthread_mutex_unlock(&camctl->lock);
  // tell the world that we are done. this assumes that there is just
  // one global camctl.  if there would ever be more it would be easy
  // to pass c with the signal.
  DT_CONTROL_SIGNAL_RAISE(DT_SIGNAL_CAMERA_DETECTED);

  return camctl->changed_camera;
}

static void *_update_cameras_thread(void *ptr)
{
  dt_pthread_setname("gphoto_update");
  dt_camctl_t *camctl = (dt_camctl_t *)ptr;
  while(dt_control_running())
  {
    if(camctl->import_ui == FALSE
         && dt_view_get_current() == DT_VIEW_LIGHTTABLE)
    {
      camctl->ticker += 1;
      if((camctl->ticker & camctl->tickmask) == 0)
      {
        // we've rolled over the current scan interval, so check for
        // new/removed cameras and decide how long to wait until the
        // next scan based on the result: one second if there was a
        // change, eight seconds if not
        camctl->tickmask = _camctl_update_cameras(camctl) ? 0x03 : 0x1F;
      }
    }
    else
      camctl->tickmask = 3; // want to be responsive in one sec right after other modes are done
    g_usleep(250000);  // 1/4 second
  }
  return 0;
}

static void *_camera_event_thread(void *data)
{
  dt_camctl_t *camctl = (dt_camctl_t *)data;

  dt_pthread_setname("tethering");

  const dt_camera_t *camera = camctl->active_camera;

  dt_print(DT_DEBUG_CAMCTL,
           "[camera_control] starting camera event thread of context %p", data);

  while(camera->is_tethering)
  {
    // Poll event from camera
    _camera_poll_events(camctl, camera);

    // Let's check if there are jobs in queue to process
    gpointer job;
    while((job = _camera_get_job(camctl, camera)) != NULL)
      _camera_process_job(camctl, camera, job);
  }

  dt_print(DT_DEBUG_CAMCTL, "[camera_control] exiting camera thread.");

  return NULL;
}

static gboolean _camera_initialize(const dt_camctl_t *c,
                                   dt_camera_t *cam)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;

  dt_pthread_mutex_init(&cam->jobqueue_lock);
  dt_pthread_mutex_init(&cam->config_lock);
  dt_pthread_mutex_init(&cam->live_view_buffer_mutex);
  dt_pthread_mutex_init(&cam->live_view_synch);

  if(cam->backend_data == NULL)
  {
    if(!camctl->backend->open(camctl, cam))
      return FALSE;

    // TODO: find a more robust way for this, once we find out how to do it with non-EOS cameras
    cam->can_live_view_advanced =
      cam->can_live_view
      && (dt_camctl_camera_property_exists(camctl, cam, "eoszoomposition")
          || dt_camctl_camera_property_exists(camctl, cam, "manualfocusdrive"));

    cam->is_importing = FALSE;

    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] %s on port %s initialized", cam->model, cam->port);
  }
  return TRUE;
}

static int _sort_filename(gchar *a, gchar *b)
{
  return g_strcmp0(a, b);
}

void dt_camctl_import(const dt_camctl_t *c,
                      const dt_camera_t *cam,
                      GList *images)
{
  // Copy the list structure first. g_list_sort sorts in-place and modifies the list nodes,
  // which would change the head pointer seen by the caller (params->images).
  // Copying preserves the original list structure so the caller can successfully free it.
  GList *ifiles = g_list_copy(images);
  ifiles = g_list_sort(ifiles, (GCompareFunc)_sort_filename);
  char *prev_file = NULL;
  char *prev_output = NULL;

  _camctl_lock(c, cam);

  for(GList *ifile = ifiles; ifile; ifile = g_list_next(ifile))
  {
    // Split file into folder and filename
    char *eos;
    char folder[PATH_MAX] = { 0 };
    char filename[PATH_MAX] = { 0 };
    char *file = (char *)ifile->data;
    eos = file + strlen(file);
    while(--eos > file && *eos != '/')
      ;
    char *_file = g_strndup(file, eos - file);
    g_strlcat(folder, _file, sizeof(folder));
    g_strlcat(filename, eos + 1, sizeof(filename));
    g_free(_file);

    dt_image_basic_exif_t basic_exif = {0};

    GBytes *camfile = c->backend->get_file(c, (dt_camera_t *)cam, folder, filename);
    if(!camfile)
      continue;
    gsize size = 0;
    const char *data = g_bytes_get_data(camfile, &size);

    char *output = NULL;
    if(dt_has_same_path_basename(file, prev_file))
    {
      // make sure we keep the same output filename, changing only the extension
      output = dt_copy_filename_extension(prev_output, file);
      if(!output)
      {
        g_bytes_unref(camfile);
        continue;
      }
    }
    else
    {
      dt_exif_get_basic_data((uint8_t *)data, size, &basic_exif);

      const char *output_path = _dispatch_request_image_path(c, &basic_exif, cam);
      const char *fname = _dispatch_request_image_filename(c, filename, &basic_exif, cam);
      if(!fname)
      {
        g_bytes_unref(camfile);
        continue;
      }

      output = g_build_filename(output_path, fname, (char *)NULL);
    }

    if(!g_file_set_contents(output, data, size, NULL))
       dt_print(DT_DEBUG_CAMCTL, "[camera_control] failed to write file %s", output);
    else
      _dispatch_camera_image_downloaded(c, cam, folder, filename, output);

    g_bytes_unref(camfile);
    g_free(prev_output);
    prev_output = output;
    prev_file = file;
  }
  g_free(prev_output);

  // Free only the copied list nodes. The actual filename strings are still owned
  // by the original list 'images' and will be freed by the caller's cleanup handler.
  // Using g_list_free_full here would result in a use-after-free or double-free.
  g_list_free(ifiles);

  _dispatch_control_status(c, CAMERA_CONTROL_AVAILABLE);
  _camctl_unlock(c);
}

void dt_camctl_select_camera(const dt_camctl_t *c,
                             const dt_camera_t *cam)
{
  _camctl_lock(c, cam);
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  camctl->wanted_camera = cam;
  _camctl_unlock(c);
}

time_t dt_camctl_get_image_file_timestamp(const dt_camctl_t *c,
                                          const char *path,
                                          const char *filename)
{
  time_t timestamp = 0;
  if(!path || !filename)
    return 0;
  // Lets check the type of file...
  dt_camera_file_info_t info;
  if(!c->backend->get_file_info(c, c->active_camera, path, filename, &info))
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to get file information"
             " of %s in folder %s on device",
             filename, path);
  }
  else
    timestamp = info.mtime;

  return timestamp;
}

static GList *_camctl_recursive_get_list(const dt_camctl_t *c,
                                         char *path)
{
  GList *imgs = NULL;
  GList *files = NULL;
  GList *folders = NULL;
  c->backend->list_folder(c, c->active_camera, path, &files, &folders);

  // Process files in current folder...
  for(GList *f = files; f; f = g_list_next(f))
  {
    const char *filename = (const char *)f->data;

    // Lets check the type of file...
    dt_camera_file_info_t info;
    if(!c->backend->get_file_info(c, c->active_camera, path, filename, &info))
    {
      dt_print(DT_DEBUG_CAMCTL,
               "[camera_control] failed to get file information"
               " of %s in folder %s on device",
               filename, path);
    }
    else
    {
      dt_camera_files_t *file = g_malloc0(sizeof(dt_camera_files_t));
      if(info.has_mtime)
        file->timestamp = info.mtime;
      file->filename = g_build_filename(path, filename, NULL);
      imgs = g_list_prepend(imgs, file);
    }
  }
  g_list_free_full(files, g_free);

  // Recurse into folders in current folder...
  for(GList *f = folders; f; f = g_list_next(f))
  {
    char buffer[PATH_MAX] = { 0 };
    g_strlcat(buffer, path, sizeof(buffer));
    if(path[1] != '\0') g_strlcat(buffer, "/", sizeof(buffer));
    g_strlcat(buffer, (const char *)f->data, sizeof(buffer));
    GList *simgs = _camctl_recursive_get_list(c, buffer);
    if(simgs)
      imgs = g_list_concat(imgs, simgs);
  }
  g_list_free_full(folders, g_free);
  return imgs;
}

GList *dt_camctl_get_images_list(const dt_camctl_t *c,
                                 dt_camera_t *cam)
{
  _camctl_lock(c, cam);
  GList *imgs = _camctl_recursive_get_list(c, "/");
  _camctl_unlock(c);
  return imgs;
}

GBytes *dt_camctl_get_preview(const dt_camctl_t *c,
                              dt_camera_t *cam,
                              const gchar *filename)
{
  char *folder = g_strdup(filename);
  char *fn = g_strrstr(folder, "/");
  if(fn)
  {
    fn[0] = '\0';
    fn++;
  }
  else fn = folder;

  _camctl_lock(c, cam);
  GBytes *preview = c->backend->get_preview(c, cam, folder, fn);
  _camctl_unlock(c);

  g_free(folder);
  return preview;
}

int dt_camctl_can_enter_tether_mode(const dt_camctl_t *c,
                                    const dt_camera_t *cam)
{
  /* first check if camera is provided else use wanted cam */
  if(cam == NULL)
    cam = c->wanted_camera;

  /* check if wanted cam is available else use active camera */
  if(cam == NULL)
    cam = c->active_camera;

  /* check if active cam is available else use first detected one */
  if(cam == NULL && c->cameras)
    cam = c->cameras->data;

  if(cam && cam->can_tether)
  {
    dt_camctl_t *camctl = (dt_camctl_t *)c;
    camctl->wanted_camera = cam;
    return 1;
  }

  return 0;
}

void dt_camctl_tether_mode(const dt_camctl_t *c,
                           const dt_camera_t *cam,
                           gboolean enable)
{
  /* first check if camera is provided else use wanted cam */
  if(cam == NULL)
    cam = c->wanted_camera;

  /* check if wanted cam is available else use active camera */
  if(cam == NULL)
    cam = c->active_camera;

  /* check if active cam is available else use first detected one */
  if(cam == NULL && c->cameras)
    cam = c->cameras->data;

  if(cam && cam->can_tether)
  {
    dt_camctl_t *camctl = (dt_camctl_t *)c;
    dt_camera_t *camera = (dt_camera_t *)cam;

    if(enable && !camera->is_tethering)
    {
      _camctl_lock(c, cam);
      // Start up camera event polling thread
      dt_print(DT_DEBUG_CAMCTL, "[camera_control] enabling tether mode");
      camctl->active_camera = camera;
      camera->is_tethering = TRUE;
      dt_pthread_create(&camctl->camera_event_thread, &_camera_event_thread, (void *)c);
    }
    else
    {
      camera->is_live_viewing = FALSE;
      camera->is_tethering = FALSE;
      dt_print(DT_DEBUG_CAMCTL, "[camera_control] disabling tether mode");
      _camctl_unlock(c);
      // Wait for tether thread with join??
    }
  }
  else
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to set tether mode with reason: %s",
             cam ? "device does not support tethered capture" : "no active camera");
}

const char *dt_camctl_camera_get_model(const dt_camctl_t *c,
                                       const dt_camera_t *cam)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to get model of camera, camera==NULL");
    return NULL;
  }
  return cam->model;
}


static void _camera_build_property_menu(GList *nodes,
                                        GMenu *menu,
                                        GCallback item_activate,
                                        gpointer user_data)
{
  /* if widget has children lets add menutitem and recurse into container */
  for(GList *it = nodes; it; it = g_list_next(it))
  {
    const dt_camera_property_node_t *child = (dt_camera_property_node_t *)it->data;
    const char *sk = child->name;

    /* Check if widget is submenu */
    if(child->children)
    {
      /* create submenu item */
      GMenu *submenu = g_menu_new();

      /* recurse into submenu */
      _camera_build_property_menu(child->children,
                                  submenu,
                                  item_activate,
                                  user_data);

      g_menu_append_submenu(menu, sk, G_MENU_MODEL(submenu));
      g_object_unref(submenu);
    }
    else
    {
      /* check widget type */
      if(child->type == DT_CAMERA_PROPERTY_MENU
         || child->type == DT_CAMERA_PROPERTY_TEXT
         || child->type == DT_CAMERA_PROPERTY_RADIO)
      {
        /* construct menu item for property */
        gchar *action = g_strdup_printf("camera.activate::%s", sk);
        GMenuItem *item = g_menu_item_new(sk, action);
        g_free(action);
        g_menu_append_item(menu, item);
        g_object_unref(item);
      }
    }
  }
}

void dt_camctl_camera_build_property_menu(const dt_camctl_t *c,
                                          const dt_camera_t *cam,
                                          GMenu **menu,
                                          GCallback item_activate,
                                          gpointer user_data)
{
  /* get active camera */
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to build property menu from camera, camera==NULL");
    return;
  }

  dt_print(DT_DEBUG_CAMCTL,
           "[camera_control] building property menu from camera configuration");

  /* lock camera config mutex while recursive building property menu */
  dt_camera_t *camera = (dt_camera_t *)cam;
  dt_pthread_mutex_lock(&camera->config_lock);
  *menu = g_menu_new();
  GList *tree = c->backend->property_tree(camera);
  _camera_build_property_menu(tree, *menu, item_activate, user_data);
  dt_camera_property_tree_free(tree);
  dt_pthread_mutex_unlock(&camera->config_lock);
}



void dt_camctl_camera_set_property_string(const dt_camctl_t *c,
                                          const dt_camera_t *cam,
                                          const char *property_name,
                                          const char *value)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to set property from camera, camera==NULL");
    return;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;

  _camctl_camera_set_property_string_job_t *job =
    g_try_malloc(sizeof(_camctl_camera_set_property_string_job_t));
  if(!job) return;
  job->type = _JOB_TYPE_SET_PROPERTY_STRING;
  job->name = g_strdup(property_name);
  job->value = g_strdup(value);

  // Push the job on the jobqueue
  _camera_add_job(camctl, camera, job);
}

void dt_camctl_camera_set_property_toggle(const dt_camctl_t *c,
                                          const dt_camera_t *cam,
                                          const char *property_name)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to set property from camera, camera==NULL");
    return;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;

  _camctl_camera_set_property_toggle_job_t *job =
    g_try_malloc(sizeof(_camctl_camera_set_property_toggle_job_t));
  if(!job) return;
  job->type = _JOB_TYPE_SET_PROPERTY_TOGGLE;
  job->name = g_strdup(property_name);

  // Push the job on the jobqueue
  _camera_add_job(camctl, camera, job);
}

void dt_camctl_camera_set_property_choice(const dt_camctl_t *c,
                                          const dt_camera_t *cam,
                                          const char *property_name,
                                          const int value)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to set property from camera, camera==NULL");
    return;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;

  _camctl_camera_set_property_choice_job_t *job =
    g_try_malloc(sizeof(_camctl_camera_set_property_choice_job_t));
  if(!job) return;
  job->type = _JOB_TYPE_SET_PROPERTY_CHOICE;
  job->name = g_strdup(property_name);
  job->value = value;

  // Push the job on the jobqueue
  _camera_add_job(camctl, camera, job);
}

void dt_camctl_camera_set_property_int(const dt_camctl_t *c,
                                       const dt_camera_t *cam,
                                       const char *property_name,
                                       const int value)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to set property from camera, camera==NULL");
    return;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;

  _camctl_camera_set_property_int_job_t *job =
    g_try_malloc(sizeof(_camctl_camera_set_property_int_job_t));
  if(!job) return;
  job->type = _JOB_TYPE_SET_PROPERTY_INT;
  job->name = g_strdup(property_name);
  job->value = value;

  // Push the job on the jobqueue
  _camera_add_job(camctl, camera, job);
}

void dt_camctl_camera_set_property_float(const dt_camctl_t *c,
                                         const dt_camera_t *cam,
                                         const char *property_name,
                                         const float value)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to set property from camera, camera==NULL");
    return;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;

  _camctl_camera_set_property_float_job_t *job =
    g_try_malloc(sizeof(_camctl_camera_set_property_float_job_t));
  if(!job) return;
  job->type = _JOB_TYPE_SET_PROPERTY_FLOAT;
  job->name = g_strdup(property_name);
  job->value = value;

  // Push the job on the jobqueue
  _camera_add_job(camctl, camera, job);
}

const char *dt_camctl_camera_get_property(const dt_camctl_t *c,
                                          const dt_camera_t *cam,
                                          const char *property_name)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to get property from camera, camera==NULL");
    return NULL;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;
  dt_pthread_mutex_lock(&camera->config_lock);
  const char *value = c->backend->property_get_value(camera, property_name);
  dt_pthread_mutex_unlock(&camera->config_lock);
  return value;
}

int dt_camctl_camera_property_exists(const dt_camctl_t *c,
                                     const dt_camera_t *cam,
                                     const char *property_name)
{
  int exists = 0;
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to check if property exists"
             " in camera configuration, camera == NULL");
    return 0;
  }

  dt_camera_t *camera = (dt_camera_t *)cam;

  if(camera->backend_data == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to check if property exists"
             " in camera configuration, camera not open");
    return 0;
  }

  dt_pthread_mutex_lock(&camera->config_lock);

  if(c->backend->property_exists(camera, property_name))
    exists = 1;

  dt_pthread_mutex_unlock(&camera->config_lock);

  return exists;
}

int dt_camctl_camera_get_property_type(const dt_camctl_t *c,
                                       const dt_camera_t *cam,
                                       const char *property_name,
                                       dt_camera_property_type_t *widget_type)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to get property type from camera, camera==NULL");
    return -1;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;
  dt_pthread_mutex_lock(&camera->config_lock);
  const gboolean ok = c->backend->property_get_type(camera, property_name, widget_type);
  dt_pthread_mutex_unlock(&camera->config_lock);

  return !ok;
}

const char *dt_camctl_camera_property_get_first_choice(const dt_camctl_t *c,
                                                       const dt_camera_t *cam,
                                                       const char *property_name)
{
  const char *value = NULL;
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] failed to get first choice of property from camera,"
             " camera==NULL");
    return NULL;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;
  dt_pthread_mutex_lock(&camera->config_lock);
  g_free(camera->current_choice.name);
  camera->current_choice.name = NULL;
  if(c->backend->property_exists(camera, property_name))
  {
    camera->current_choice.name = g_strdup(property_name);
    camera->current_choice.index = 0;
    value = c->backend->property_get_choice(camera, property_name,
                                            camera->current_choice.index);
  }
  else
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] property name '%s' not found in camera configuration",
             property_name);

  dt_pthread_mutex_unlock(&camera->config_lock);

  return value;
}

const char *dt_camctl_camera_property_get_next_choice(const dt_camctl_t *c,
                                                      const dt_camera_t *cam,
                                                      const char *property_name)
{
  const char *value = NULL;
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam
     && (cam = camctl->active_camera) == NULL
     && (cam = camctl->wanted_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] Failed to get next choice of property from camera,"
             " camera==NULL");
    return NULL;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;
  dt_pthread_mutex_lock(&camera->config_lock);
  if(camera->current_choice.name)
  {

    if(++camera->current_choice.index
       < c->backend->property_count_choices(camera, camera->current_choice.name))
    {
      // get the choice value...
      value = c->backend->property_get_choice(camera, camera->current_choice.name,
                                              camera->current_choice.index);
    }
    else
    {
      // No more choices, reset current_choices for further use
      camera->current_choice.index = 0;
      g_free(camera->current_choice.name);
      camera->current_choice.name = NULL;
    }
  }

  dt_pthread_mutex_unlock(&camera->config_lock);
  return value;
}

void dt_camctl_camera_capture(const dt_camctl_t *c,
                              const dt_camera_t *cam)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  if(!cam && (cam = camctl->active_camera) == NULL)
  {
    dt_print(DT_DEBUG_CAMCTL,
             "[camera_control] Failed to capture from camera, camera==NULL");
    return;
  }
  dt_camera_t *camera = (dt_camera_t *)cam;

  _camctl_camera_job_t *job = g_try_malloc(sizeof(_camctl_camera_job_t));
  if(!job) return;
  job->type = _JOB_TYPE_EXECUTE_CAPTURE;
  _camera_add_job(camctl, camera, job);
}

static void _camera_poll_events(const dt_camctl_t *c,
                                const dt_camera_t *cam)
{
  dt_camera_event_t ev;
  if(c->backend->wait_for_event(c, cam, 30, &ev))
  {
    if(ev.type == DT_CAMERA_EVENT_PROPERTY_CHANGED)
      c->backend->refresh_properties(c, cam, ev.name);
    else if(ev.type == DT_CAMERA_EVENT_FILE_ADDED)
    {
      if(cam->is_tethering)
      {
        dt_print(DT_DEBUG_CAMCTL, "[camera_control] Camera file added event");
        _camera_download_tethered(c, cam, ev.folder, ev.name, TRUE);
      }
    }
    g_free(ev.folder);
    g_free(ev.name);
  }
}

static const char *_dispatch_request_image_filename(const dt_camctl_t *c,
                                                    const char *filename,
                                                    const dt_image_basic_exif_t *basic_exif,
                                                    const dt_camera_t *camera)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;

  const char *path = NULL;
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  for(GList *listener = camctl->listeners; listener; listener = g_list_next(listener))
    {
      dt_camctl_listener_t *lstnr = (dt_camctl_listener_t *)listener->data;
      if(lstnr->request_image_filename)
      {
        path = lstnr->request_image_filename(camera, filename, basic_exif, lstnr->data);
        //TODO: break here?  Do we want the first or last match?
      }
    }
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
  return path;
}

static const char *_dispatch_request_image_path(const dt_camctl_t *c,
                                                const dt_image_basic_exif_t *basic_exif,
                                                const dt_camera_t *camera)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  const char *path = NULL;
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  for(GList *listener = camctl->listeners; listener; listener = g_list_next(listener))
  {
    dt_camctl_listener_t *lstnr = (dt_camctl_listener_t *)listener->data;
    if(lstnr->request_image_path)
    {
      path = lstnr->request_image_path(camera, basic_exif, lstnr->data);
      //TODO: break here?  Do we want the first or last match?
    }
  }
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
  return path;
}

static void _dispatch_camera_connected(const dt_camctl_t *c,
                                       const dt_camera_t *camera)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  for(GList *listener = camctl->listeners; listener; listener = g_list_next(listener))
  {
    dt_camctl_listener_t *lstnr = (dt_camctl_listener_t *)listener->data;
    if(lstnr->camera_connected)
      lstnr->camera_connected(camera, lstnr->data);
  }
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
}

static void _dispatch_camera_disconnected(const dt_camctl_t *c,
                                          const dt_camera_t *camera)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  for(GList *listener = camctl->listeners; listener; listener = g_list_next(listener))
  {
    dt_camctl_listener_t *lstnr = (dt_camctl_listener_t *)listener->data;
    if(lstnr->camera_disconnected)
      lstnr->camera_disconnected(camera, lstnr->data);
  }
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
}

static void _dispatch_camera_image_downloaded(const dt_camctl_t *c,
                                              const dt_camera_t *camera,
                                              const char *in_path,
                                              const char *in_filename,
                                              const char *filename)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  for(GList *listener = camctl->listeners; listener; listener = g_list_next(listener))
  {
    dt_camctl_listener_t *lstnr = (dt_camctl_listener_t *)listener->data;
    if(lstnr->image_downloaded)
      lstnr->image_downloaded(camera, in_path, in_filename, filename, lstnr->data);
  }
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
}

static void _dispatch_control_status(const dt_camctl_t *c,
                                     dt_camctl_status_t status)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  for(GList *listener = camctl->listeners; listener; listener = g_list_next(listener))
  {
    dt_camctl_listener_t *lstnr = (dt_camctl_listener_t *)listener->data;
    if(lstnr->control_status)
      lstnr->control_status(status, lstnr->data);
  }
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
}

static void _dispatch_camera_property_value_changed(const dt_camctl_t *c,
                                                    const dt_camera_t *camera,
                                                    const char *name,
                                                    const char *value)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  for(GList *listener = camctl->listeners; listener; listener = g_list_next(listener))
  {
    dt_camctl_listener_t *lstnr = (dt_camctl_listener_t *)listener->data;
    if(lstnr->camera_property_value_changed)
      lstnr->camera_property_value_changed(camera, name, value, lstnr->data);
  }
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
}

static void _dispatch_camera_error(const dt_camctl_t *c,
                                   const dt_camera_t *camera,
                                   dt_camera_error_t error)
{
  dt_camctl_t *camctl = (dt_camctl_t *)c;
  dt_pthread_mutex_lock(&camctl->listeners_lock);
  for(GList *listener = camctl->listeners; listener; listener = g_list_next(listener))
  {
    dt_camctl_listener_t *lstnr = (dt_camctl_listener_t *)listener->data;
    if(lstnr->camera_error)
      lstnr->camera_error(camera, error, lstnr->data);
  }
  dt_pthread_mutex_unlock(&camctl->listeners_lock);
}

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
