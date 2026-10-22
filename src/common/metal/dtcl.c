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

// the cl* entry points of the Metal runtime. See dtcl.h for the overall
// design. Only the 43 functions src/common/dlopencl.c binds are exported;
// they follow the OpenCL 1.2 specification as far as darktable relies on it.
//
// Every command runs to completion in order. Reads, writes and maps wait for
// the device first, so the blocking flags and event wait lists can be
// ignored safely; that costs speed, not correctness.

#include "dtcl.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DTCL_EXPORT __attribute__((visibility("default")))

#ifdef DTCL_EMULATOR
#define DTCL_PLATFORM_NAME "darktable Metal emulator"
#else
#define DTCL_PLATFORM_NAME "darktable Metal"
#endif
#define DTCL_VERSION "OpenCL 1.2 darktable-metal"
#define DTCL_BINARY_TAG "dtcl-program:"

struct _cl_platform_id { int dummy; };
struct _cl_device_id { int dummy; };
struct _cl_context { int dummy; };
struct _cl_command_queue { int dummy; };

static struct _cl_platform_id _platform;
static struct _cl_device_id _device;
static struct _cl_context _context;
static struct _cl_command_queue _queue;

static dtcl_device_props_t _props;
static int _inited = 0;
static int _init_ok = 0;
static pthread_mutex_t _lock = PTHREAD_MUTEX_INITIALIZER;

void dtcl_log(const char *fmt, ...)
{
  static int enabled = -1;
  if(enabled < 0) enabled = getenv("DT_METAL_DEBUG") != NULL;
  if(!enabled) return;
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "[dtcl] ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
}

static int _init(void)
{
  pthread_mutex_lock(&_lock);
  if(!_inited)
  {
    _inited = 1;
    _init_ok = dtclb_init(&_props) == CL_SUCCESS;
    dtcl_log("device '%s': %s", _props.name, _init_ok ? "ready" : "failed");
  }
  pthread_mutex_unlock(&_lock);
  return _init_ok;
}

static cl_int _ret_info(const void *value, size_t size,
                        size_t param_value_size, void *param_value, size_t *size_ret)
{
  if(size_ret) *size_ret = size;
  if(param_value)
  {
    if(param_value_size < size) return CL_INVALID_VALUE;
    memcpy(param_value, value, size);
  }
  return CL_SUCCESS;
}

#define RET_STR(s) return _ret_info((s), strlen(s) + 1, param_value_size, param_value, param_value_size_ret)
#define RET_VAL(type, v) do { const type _v = (v); \
  return _ret_info(&_v, sizeof(type), param_value_size, param_value, param_value_size_ret); } while(0)

static void _event_out(cl_event *event)
{
  if(!event) return;
  *event = calloc(1, sizeof(struct _cl_event));
  if(*event) (*event)->refcount = 1;
}

// --- platform, device, context, queue ---

DTCL_EXPORT cl_int clGetPlatformIDs(cl_uint num_entries, cl_platform_id *platforms, cl_uint *num_platforms)
{
  const cl_uint n = _init() ? 1 : 0;
  if(num_platforms) *num_platforms = n;
  if(platforms && num_entries > 0 && n) platforms[0] = &_platform;
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clGetPlatformInfo(cl_platform_id platform, cl_platform_info param_name,
                                     size_t param_value_size, void *param_value,
                                     size_t *param_value_size_ret)
{
  switch(param_name)
  {
    case CL_PLATFORM_NAME: RET_STR(DTCL_PLATFORM_NAME);
    case CL_PLATFORM_VENDOR: RET_STR("darktable");
    case CL_PLATFORM_PROFILE: RET_STR("FULL_PROFILE");
    case CL_PLATFORM_VERSION: RET_STR(DTCL_VERSION);
    case CL_PLATFORM_EXTENSIONS: RET_STR("");
    default: return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_int clGetDeviceIDs(cl_platform_id platform, cl_device_type device_type,
                                  cl_uint num_entries, cl_device_id *devices, cl_uint *num_devices)
{
  if(!_init()) return CL_DEVICE_NOT_FOUND;
  if(!(device_type & (CL_DEVICE_TYPE_GPU | CL_DEVICE_TYPE_DEFAULT))) return CL_DEVICE_NOT_FOUND;
  if(num_devices) *num_devices = 1;
  if(devices && num_entries > 0) devices[0] = &_device;
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clGetDeviceInfo(cl_device_id device, cl_device_info param_name,
                                   size_t param_value_size, void *param_value,
                                   size_t *param_value_size_ret)
{
  if(device != &_device) return CL_INVALID_DEVICE;
  switch(param_name)
  {
    case CL_DEVICE_AVAILABLE: RET_VAL(cl_bool, CL_TRUE);
    case CL_DEVICE_VENDOR: RET_STR(_props.vendor);
    case CL_DEVICE_VENDOR_ID: RET_VAL(cl_uint, 0);
    case CL_DEVICE_NAME: RET_STR(_props.name);
    case CL_DEVICE_PLATFORM: RET_VAL(cl_platform_id, &_platform);
    case CL_DRIVER_VERSION: RET_STR(_props.driver_version);
    case CL_DEVICE_VERSION: RET_STR(DTCL_VERSION);
    case CL_DEVICE_EXTENSIONS: RET_STR("");
    case CL_DEVICE_TYPE: RET_VAL(cl_device_type, CL_DEVICE_TYPE_GPU | CL_DEVICE_TYPE_DEFAULT);
    case CL_DEVICE_IMAGE_SUPPORT: RET_VAL(cl_bool, CL_TRUE);
    case CL_DEVICE_IMAGE2D_MAX_WIDTH: RET_VAL(size_t, _props.max_image_width);
    case CL_DEVICE_IMAGE2D_MAX_HEIGHT: RET_VAL(size_t, _props.max_image_height);
    case CL_DEVICE_MAX_MEM_ALLOC_SIZE: RET_VAL(cl_ulong, _props.max_alloc);
    case CL_DEVICE_GLOBAL_MEM_SIZE: RET_VAL(cl_ulong, _props.global_mem);
    case CL_DEVICE_ENDIAN_LITTLE: RET_VAL(cl_bool, CL_TRUE);
    case CL_DEVICE_MAX_CONSTANT_BUFFER_SIZE: RET_VAL(cl_ulong, 64 * 1024);
    case CL_DEVICE_MAX_COMPUTE_UNITS: RET_VAL(cl_uint, _props.compute_units);
    case CL_DEVICE_MAX_WORK_GROUP_SIZE: RET_VAL(size_t, _props.max_group_size);
    case CL_DEVICE_LOCAL_MEM_SIZE: RET_VAL(cl_ulong, _props.local_mem);
    // no claim of correctly rounded division: Metal does not promise it
    case CL_DEVICE_SINGLE_FP_CONFIG:
      RET_VAL(cl_device_fp_config, CL_FP_INF_NAN | CL_FP_ROUND_TO_NEAREST | CL_FP_FMA);
    case CL_DEVICE_HOST_UNIFIED_MEMORY: RET_VAL(cl_bool, _props.unified_memory ? CL_TRUE : CL_FALSE);
    case CL_DEVICE_MAX_WORK_ITEM_DIMENSIONS: RET_VAL(cl_uint, 3);
    case CL_DEVICE_MAX_WORK_ITEM_SIZES:
    {
      const size_t s[3] = { _props.max_group_size, _props.max_group_size, 64 };
      return _ret_info(s, sizeof(s), param_value_size, param_value, param_value_size_ret);
    }
    default:
      dtcl_log("clGetDeviceInfo: unsupported query 0x%x", param_name);
      return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_context clCreateContext(const cl_context_properties *properties, cl_uint num_devices,
                                       const cl_device_id *devices,
                                       void (*pfn_notify)(const char *, const void *, size_t, void *),
                                       void *user_data, cl_int *errcode_ret)
{
  const int ok = _init() && num_devices == 1 && devices && devices[0] == &_device;
  if(errcode_ret) *errcode_ret = ok ? CL_SUCCESS : CL_INVALID_DEVICE;
  return ok ? &_context : NULL;
}

DTCL_EXPORT cl_command_queue clCreateCommandQueue(cl_context context, cl_device_id device,
                                                  cl_command_queue_properties properties,
                                                  cl_int *errcode_ret)
{
  if(errcode_ret) *errcode_ret = CL_SUCCESS;
  return &_queue;
}

DTCL_EXPORT cl_int clReleaseCommandQueue(cl_command_queue q)
{
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clReleaseContext(cl_context c)
{
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clFinish(cl_command_queue q)
{
  return dtclb_finish();
}

// --- programs ---

static uint64_t _fnv1a(const unsigned char *p, size_t n, uint64_t h)
{
  for(size_t i = 0; i < n; i++)
  {
    h ^= p[i];
    h *= 0x100000001b3ull;
  }
  return h;
}

static cl_program _program_new(const dtcl_program_info_t *info, cl_int *errcode_ret)
{
  cl_program p = calloc(1, sizeof(struct _cl_program));
  if(!p)
  {
    if(errcode_ret) *errcode_ret = CL_OUT_OF_HOST_MEMORY;
    return NULL;
  }
  p->refcount = 1;
  p->info = info;
  if(errcode_ret) *errcode_ret = CL_SUCCESS;
  return p;
}

DTCL_EXPORT cl_program clCreateProgramWithSource(cl_context context, cl_uint count, const char **strings,
                                                 const size_t *lengths, cl_int *errcode_ret)
{
  // darktable passes the source of one data/kernels/*.cl file; the hash of
  // the text tells which program it is, since the name is not passed
  uint64_t h = 0xcbf29ce484222325ull;
  for(cl_uint i = 0; i < count; i++)
  {
    const size_t len = (lengths && lengths[i]) ? lengths[i] : strlen(strings[i]);
    h = _fnv1a((const unsigned char *)strings[i], len, h);
  }

  const dtcl_program_info_t *info = NULL;
  for(int i = 0; i < dtcl_num_programs; i++)
    if(dtcl_programs[i].source_hash == h) info = &dtcl_programs[i];

  if(!info)
    dtcl_log("program source with hash %016llx is unknown, it gets no kernels", (unsigned long long)h);
  return _program_new(info, errcode_ret);
}

DTCL_EXPORT cl_program clCreateProgramWithBinary(cl_context context, cl_uint num_devices,
                                                 const cl_device_id *device_list, const size_t *lengths,
                                                 const unsigned char **binaries, cl_int *binary_status,
                                                 cl_int *errcode_ret)
{
  // the "binary" darktable cached for us is the program name and hash
  char buf[256] = { 0 };
  const size_t n = lengths[0] < sizeof(buf) - 1 ? lengths[0] : sizeof(buf) - 1;
  memcpy(buf, binaries[0], n);

  const dtcl_program_info_t *info = NULL;
  const size_t tag = strlen(DTCL_BINARY_TAG);
  if(strncmp(buf, DTCL_BINARY_TAG, tag) == 0)
  {
    for(int i = 0; i < dtcl_num_programs; i++)
    {
      char expect[256];
      snprintf(expect, sizeof(expect), "%s%s:%016llx", DTCL_BINARY_TAG, dtcl_programs[i].name,
               (unsigned long long)dtcl_programs[i].source_hash);
      if(strcmp(buf, expect) == 0) info = &dtcl_programs[i];
    }
  }
  if(!info)
  {
    // darktable then removes the cache entry and builds from source
    if(binary_status) binary_status[0] = CL_INVALID_BINARY;
    if(errcode_ret) *errcode_ret = CL_INVALID_BINARY;
    return NULL;
  }
  if(binary_status) binary_status[0] = CL_SUCCESS;
  return _program_new(info, errcode_ret);
}

DTCL_EXPORT cl_int clBuildProgram(cl_program program, cl_uint num_devices, const cl_device_id *device_list,
                                  const char *options, void (*pfn_notify)(cl_program, void *),
                                  void *user_data)
{
  if(!program) return CL_INVALID_PROGRAM;
  if(!program->info || program->info->num_kernels == 0)
  {
    // a program without a Metal port builds fine and has no kernels, so
    // the modules using it fall back to their CPU code
    program->usable = 0;
    return CL_SUCCESS;
  }

  const dtcl_program_info_t *info = program->info;
  if(info->ported_md5 && strcmp(info->ported_md5, info->cl_md5) != 0 && !getenv("DT_METAL_ALLOW_STALE"))
  {
    // the OpenCL source changed after the port was made: rather run the
    // module on the CPU than run kernels that may no longer match the host code
    dtcl_log("%s: Metal port is stale (ported from %s, source is now %s), not used",
             info->name, info->ported_md5, info->cl_md5);
    program->usable = 0;
    return CL_SUCCESS;
  }

  program->usable = dtclb_program_load(program) == CL_SUCCESS;
  dtcl_log("%s: %s", info->name, program->usable ? "loaded" : "failed to load");
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clGetProgramBuildInfo(cl_program program, cl_device_id device,
                                         cl_program_build_info param_name, size_t param_value_size,
                                         void *param_value, size_t *param_value_size_ret)
{
  switch(param_name)
  {
    case CL_PROGRAM_BUILD_STATUS: RET_VAL(cl_build_status, CL_BUILD_SUCCESS);
    case CL_PROGRAM_BUILD_LOG:
    {
      char log[256];
      if(program && program->info && program->usable)
        snprintf(log, sizeof(log), "Metal port of %s with %d kernels", program->info->name,
                 program->info->num_kernels);
      else
        snprintf(log, sizeof(log), "no usable Metal port of %s",
                 program && program->info ? program->info->name : "this program");
      RET_STR(log);
    }
    default: return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_int clGetProgramInfo(cl_program program, cl_program_info param_name, size_t param_value_size,
                                    void *param_value, size_t *param_value_size_ret)
{
  if(!program) return CL_INVALID_PROGRAM;

  char binary[256] = { 0 };
  if(program->info)
    snprintf(binary, sizeof(binary), "%s%s:%016llx", DTCL_BINARY_TAG, program->info->name,
             (unsigned long long)program->info->source_hash);
  // unknown programs get an empty binary, which never loads from the cache
  const size_t binary_size = strlen(binary) + 1;

  switch(param_name)
  {
    case CL_PROGRAM_NUM_DEVICES: RET_VAL(cl_uint, 1);
    case CL_PROGRAM_DEVICES: RET_VAL(cl_device_id, &_device);
    case CL_PROGRAM_BINARY_SIZES: RET_VAL(size_t, binary_size);
    case CL_PROGRAM_BINARIES:
      if(param_value)
      {
        if(param_value_size < sizeof(unsigned char *)) return CL_INVALID_VALUE;
        unsigned char *dst = ((unsigned char **)param_value)[0];
        if(dst) memcpy(dst, binary, binary_size);
      }
      if(param_value_size_ret) *param_value_size_ret = sizeof(unsigned char *);
      return CL_SUCCESS;
    default: return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_int clReleaseProgram(cl_program program)
{
  if(!program) return CL_INVALID_PROGRAM;
  if(--program->refcount > 0) return CL_SUCCESS;
  if(program->usable) dtclb_program_release(program);
  free(program);
  return CL_SUCCESS;
}

// --- kernels ---

DTCL_EXPORT cl_kernel clCreateKernel(cl_program program, const char *kernel_name, cl_int *errcode_ret)
{
  cl_int err = CL_INVALID_KERNEL_NAME;
  cl_kernel k = NULL;
  const dtcl_kernel_info_t *info = NULL;

  if(!program)
    err = CL_INVALID_PROGRAM;
  else if(program->usable)
    for(int i = 0; i < program->info->num_kernels; i++)
      if(strcmp(program->info->kernels[i].name, kernel_name) == 0)
        info = &program->info->kernels[i];

  if(info && (k = calloc(1, sizeof(struct _cl_kernel))))
  {
    k->refcount = 1;
    k->program = program;
    k->info = info;
    k->num_args = strlen(info->args);
    for(int i = 0; i < k->num_args; i++) k->args[i].kind = info->args[i];
    err = dtclb_kernel_create(k);
    if(err != CL_SUCCESS)
    {
      free(k);
      k = NULL;
    }
  }
  if(!k)
    dtcl_log("no Metal kernel '%s' in %s", kernel_name,
             program && program->info ? program->info->name : "unknown program");
  if(errcode_ret) *errcode_ret = k ? CL_SUCCESS : err;
  return k;
}

DTCL_EXPORT cl_int clReleaseKernel(cl_kernel kernel)
{
  if(!kernel) return CL_INVALID_KERNEL;
  if(--kernel->refcount > 0) return CL_SUCCESS;
  dtclb_kernel_release(kernel);
  free(kernel);
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clSetKernelArg(cl_kernel kernel, cl_uint arg_index, size_t arg_size, const void *arg_value)
{
  if(!kernel) return CL_INVALID_KERNEL;
  if(arg_index >= (cl_uint)kernel->num_args)
  {
    dtcl_log("%s: argument %u out of range", kernel->info->name, arg_index);
    return CL_INVALID_ARG_INDEX;
  }
  dtcl_arg_t *a = &kernel->args[arg_index];
  switch(a->kind)
  {
    case 'B':
    case 'T':
    {
      if(arg_size != sizeof(cl_mem) || !arg_value) return CL_INVALID_ARG_SIZE;
      const cl_mem m = *(const cl_mem *)arg_value;
      if(m && (m->magic != DTCL_MAGIC_MEM || m->is_image != (a->kind == 'T')))
      {
        dtcl_log("%s: argument %u should be %s", kernel->info->name, arg_index,
                 a->kind == 'T' ? "an image" : "a buffer");
        return CL_INVALID_MEM_OBJECT;
      }
      a->mem = m;
      break;
    }
    case 'V':
      if(!arg_value || arg_size == 0 || arg_size > sizeof(a->bytes)) return CL_INVALID_ARG_SIZE;
      memcpy(a->bytes, arg_value, arg_size);
      break;
    case 'L':
      if(arg_value || arg_size == 0) return CL_INVALID_ARG_VALUE;
      break;
    default:
      return CL_INVALID_ARG_INDEX;
  }
  a->size = arg_size;
  a->set = 1;
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clGetKernelInfo(cl_kernel kernel, cl_kernel_info param_name, size_t param_value_size,
                                   void *param_value, size_t *param_value_size_ret)
{
  if(!kernel) return CL_INVALID_KERNEL;
  switch(param_name)
  {
    case CL_KERNEL_FUNCTION_NAME: RET_STR(kernel->info->name);
    case CL_KERNEL_NUM_ARGS: RET_VAL(cl_uint, kernel->num_args);
    default: return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_int clGetKernelWorkGroupInfo(cl_kernel kernel, cl_device_id device,
                                            cl_kernel_work_group_info param_name, size_t param_value_size,
                                            void *param_value, size_t *param_value_size_ret)
{
  if(!kernel) return CL_INVALID_KERNEL;
  switch(param_name)
  {
    case CL_KERNEL_WORK_GROUP_SIZE: RET_VAL(size_t, kernel->max_group_size);
    default: return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_int clEnqueueNDRangeKernel(cl_command_queue queue, cl_kernel kernel, cl_uint work_dim,
                                          const size_t *global_work_offset, const size_t *global_work_size,
                                          const size_t *local_work_size, cl_uint num_events_in_wait_list,
                                          const cl_event *event_wait_list, cl_event *event)
{
  if(!kernel) return CL_INVALID_KERNEL;
  if(work_dim < 1 || work_dim > 3) return CL_INVALID_WORK_DIMENSION;
  if(global_work_offset)
    for(cl_uint d = 0; d < work_dim; d++)
      if(global_work_offset[d]) return CL_INVALID_GLOBAL_OFFSET;
  for(int i = 0; i < kernel->num_args; i++)
    if(!kernel->args[i].set)
    {
      dtcl_log("%s: argument %d not set", kernel->info->name, i);
      return CL_INVALID_KERNEL_ARGS;
    }
  if(local_work_size)
  {
    size_t total = 1;
    for(cl_uint d = 0; d < work_dim; d++)
    {
      if(!local_work_size[d] || global_work_size[d] % local_work_size[d]) return CL_INVALID_WORK_GROUP_SIZE;
      total *= local_work_size[d];
    }
    if(total > kernel->max_group_size) return CL_INVALID_WORK_GROUP_SIZE;
  }
  _event_out(event);
  return dtclb_dispatch(kernel, work_dim, global_work_size, local_work_size, event ? *event : NULL);
}

// --- memory objects ---

static int _image_format(const cl_image_format *f, int *channels, dtcl_pixel_t *pixel, size_t *elem)
{
  switch(f->image_channel_order)
  {
    case CL_R: *channels = 1; break;
    case CL_RG: *channels = 2; break;
    case CL_RGBA: *channels = 4; break;
    default: return 0;
  }
  switch(f->image_channel_data_type)
  {
    case CL_FLOAT: *pixel = DTCL_PIXEL_FLOAT; *elem = 4; break;
    case CL_UNSIGNED_INT16: *pixel = DTCL_PIXEL_UINT16; *elem = 2; break;
    case CL_UNSIGNED_INT8: *pixel = DTCL_PIXEL_UINT8; *elem = 1; break;
    default: return 0;
  }
  // integer images are only used single channel, which is all the backends do
  if(*pixel != DTCL_PIXEL_FLOAT && *channels != 1) return 0;
  *elem *= *channels;
  return 1;
}

static cl_mem _mem_new(cl_mem_flags flags, size_t size, cl_int *errcode_ret)
{
  cl_mem m = calloc(1, sizeof(struct _cl_mem));
  if(!m)
  {
    if(errcode_ret) *errcode_ret = CL_OUT_OF_HOST_MEMORY;
    return NULL;
  }
  m->magic = DTCL_MAGIC_MEM;
  m->refcount = 1;
  m->flags = flags;
  m->size = size;
  return m;
}

DTCL_EXPORT cl_mem clCreateBuffer(cl_context context, cl_mem_flags flags, size_t size, void *host_ptr,
                                  cl_int *errcode_ret)
{
  if(size == 0 || size > _props.max_alloc)
  {
    if(errcode_ret) *errcode_ret = CL_INVALID_BUFFER_SIZE;
    return NULL;
  }
  if(flags & CL_MEM_USE_HOST_PTR)
    dtcl_log("clCreateBuffer: CL_MEM_USE_HOST_PTR is treated as CL_MEM_COPY_HOST_PTR");

  cl_mem m = _mem_new(flags, size, errcode_ret);
  if(!m) return NULL;
  cl_int err = dtclb_mem_create(m);
  if(err == CL_SUCCESS && host_ptr && (flags & (CL_MEM_COPY_HOST_PTR | CL_MEM_USE_HOST_PTR)))
    err = dtclb_buffer_write(m, 0, size, host_ptr);
  if(err != CL_SUCCESS)
  {
    if(m->backend) dtclb_mem_release(m);
    free(m);
    m = NULL;
  }
  if(errcode_ret) *errcode_ret = err;
  return m;
}

DTCL_EXPORT cl_mem clCreateImage(cl_context context, cl_mem_flags flags, const cl_image_format *image_format,
                                 const cl_image_desc *image_desc, void *host_ptr, cl_int *errcode_ret)
{
  int channels;
  dtcl_pixel_t pixel;
  size_t elem;
  if(!image_format || !_image_format(image_format, &channels, &pixel, &elem))
  {
    if(errcode_ret) *errcode_ret = CL_IMAGE_FORMAT_NOT_SUPPORTED;
    return NULL;
  }
  if(!image_desc || image_desc->image_type != CL_MEM_OBJECT_IMAGE2D
     || image_desc->image_width == 0 || image_desc->image_height == 0
     || image_desc->image_width > _props.max_image_width
     || image_desc->image_height > _props.max_image_height)
  {
    if(errcode_ret) *errcode_ret = CL_INVALID_IMAGE_SIZE;
    return NULL;
  }

  cl_mem m = _mem_new(flags, image_desc->image_width * image_desc->image_height * elem, errcode_ret);
  if(!m) return NULL;
  m->is_image = 1;
  m->width = image_desc->image_width;
  m->height = image_desc->image_height;
  m->channels = channels;
  m->pixel = pixel;
  m->element_size = elem;

  cl_int err = dtclb_mem_create(m);
  if(err == CL_SUCCESS && host_ptr && (flags & (CL_MEM_COPY_HOST_PTR | CL_MEM_USE_HOST_PTR)))
  {
    const size_t origin[2] = { 0, 0 };
    const size_t region[2] = { m->width, m->height };
    const size_t pitch = image_desc->image_row_pitch ? image_desc->image_row_pitch : m->width * elem;
    err = dtclb_image_write(m, origin, region, pitch, host_ptr);
  }
  if(err != CL_SUCCESS)
  {
    if(m->backend) dtclb_mem_release(m);
    free(m);
    m = NULL;
  }
  if(errcode_ret) *errcode_ret = err;
  return m;
}

DTCL_EXPORT cl_int clReleaseMemObject(cl_mem memobj)
{
  if(!memobj || memobj->magic != DTCL_MAGIC_MEM) return CL_INVALID_MEM_OBJECT;
  if(--memobj->refcount > 0) return CL_SUCCESS;
  // the backend keeps the storage alive for commands still using it
  dtclb_mem_release(memobj);
  memobj->magic = 0;
  free(memobj);
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clGetMemObjectInfo(cl_mem memobj, cl_mem_info param_name, size_t param_value_size,
                                      void *param_value, size_t *param_value_size_ret)
{
  if(!memobj || memobj->magic != DTCL_MAGIC_MEM) return CL_INVALID_MEM_OBJECT;
  switch(param_name)
  {
    case CL_MEM_SIZE: RET_VAL(size_t, memobj->size);
    case CL_MEM_CONTEXT: RET_VAL(cl_context, &_context);
    case CL_MEM_FLAGS: RET_VAL(cl_mem_flags, memobj->flags);
    case CL_MEM_TYPE:
      RET_VAL(cl_mem_object_type, memobj->is_image ? CL_MEM_OBJECT_IMAGE2D : CL_MEM_OBJECT_BUFFER);
    default: return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_int clGetImageInfo(cl_mem image, cl_image_info param_name, size_t param_value_size,
                                  void *param_value, size_t *param_value_size_ret)
{
  if(!image || image->magic != DTCL_MAGIC_MEM || !image->is_image) return CL_INVALID_MEM_OBJECT;
  switch(param_name)
  {
    case CL_IMAGE_WIDTH: RET_VAL(size_t, image->width);
    case CL_IMAGE_HEIGHT: RET_VAL(size_t, image->height);
    case CL_IMAGE_ELEMENT_SIZE: RET_VAL(size_t, image->element_size);
    case CL_IMAGE_ROW_PITCH: RET_VAL(size_t, image->width * image->element_size);
    default: return CL_INVALID_VALUE;
  }
}

static int _bad_buffer(cl_mem m, size_t offset, size_t size)
{
  return !m || m->magic != DTCL_MAGIC_MEM || m->is_image || offset + size > m->size;
}

static int _bad_region(cl_mem m, const size_t *origin, const size_t *region)
{
  return !m || m->magic != DTCL_MAGIC_MEM || !m->is_image
    || origin[0] + region[0] > m->width || origin[1] + region[1] > m->height;
}

DTCL_EXPORT cl_int clEnqueueReadBuffer(cl_command_queue q, cl_mem buffer, cl_bool blocking_read,
                                       size_t offset, size_t size, void *ptr, cl_uint num_events_in_wait_list,
                                       const cl_event *event_wait_list, cl_event *event)
{
  if(_bad_buffer(buffer, offset, size)) return CL_INVALID_VALUE;
  dtclb_finish();
  const cl_int err = dtclb_buffer_read(buffer, offset, size, ptr);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT cl_int clEnqueueWriteBuffer(cl_command_queue q, cl_mem buffer, cl_bool blocking_write,
                                        size_t offset, size_t size, const void *ptr,
                                        cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                        cl_event *event)
{
  if(_bad_buffer(buffer, offset, size)) return CL_INVALID_VALUE;
  dtclb_finish();
  const cl_int err = dtclb_buffer_write(buffer, offset, size, ptr);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT cl_int clEnqueueCopyBuffer(cl_command_queue q, cl_mem src_buffer, cl_mem dst_buffer,
                                       size_t src_offset, size_t dst_offset, size_t size,
                                       cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                       cl_event *event)
{
  if(_bad_buffer(src_buffer, src_offset, size) || _bad_buffer(dst_buffer, dst_offset, size))
    return CL_INVALID_VALUE;
  const cl_int err = dtclb_buffer_copy(src_buffer, dst_buffer, src_offset, dst_offset, size);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT cl_int clEnqueueFillBuffer(cl_command_queue q, cl_mem buffer, const void *pattern,
                                       size_t pattern_size, size_t offset, size_t size,
                                       cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                       cl_event *event)
{
  if(_bad_buffer(buffer, offset, size) || !pattern || !pattern_size || size % pattern_size)
    return CL_INVALID_VALUE;
  unsigned char *tmp = malloc(size);
  if(!tmp) return CL_OUT_OF_HOST_MEMORY;
  for(size_t i = 0; i < size; i += pattern_size) memcpy(tmp + i, pattern, pattern_size);
  dtclb_finish();
  const cl_int err = dtclb_buffer_write(buffer, offset, size, tmp);
  free(tmp);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT void *clEnqueueMapBuffer(cl_command_queue q, cl_mem buffer, cl_bool blocking_map,
                                     cl_map_flags map_flags, size_t offset, size_t size,
                                     cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                     cl_event *event, cl_int *errcode_ret)
{
  void *p = NULL;
  if(!_bad_buffer(buffer, offset, size))
  {
    dtclb_finish();
    p = dtclb_buffer_map(buffer);
  }
  if(p)
  {
    p = (char *)p + offset;
    _event_out(event);
  }
  if(errcode_ret) *errcode_ret = p ? CL_SUCCESS : CL_MAP_FAILURE;
  return p;
}

DTCL_EXPORT cl_int clEnqueueUnmapMemObject(cl_command_queue q, cl_mem memobj, void *mapped_ptr,
                                           cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                           cl_event *event)
{
  // buffers live in memory the host and the device share, see dtclb_buffer_map()
  _event_out(event);
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clEnqueueMigrateMemObjects(cl_command_queue q, cl_uint num_mem_objects,
                                              const cl_mem *mem_objects, cl_mem_migration_flags flags,
                                              cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                              cl_event *event)
{
  _event_out(event);
  return CL_SUCCESS;
}

DTCL_EXPORT cl_int clEnqueueReadImage(cl_command_queue q, cl_mem image, cl_bool blocking_read,
                                      const size_t *origin, const size_t *region, size_t row_pitch,
                                      size_t slice_pitch, void *ptr, cl_uint num_events_in_wait_list,
                                      const cl_event *event_wait_list, cl_event *event)
{
  if(_bad_region(image, origin, region)) return CL_INVALID_VALUE;
  dtclb_finish();
  const cl_int err = dtclb_image_read(image, origin, region,
                                      row_pitch ? row_pitch : region[0] * image->element_size, ptr);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT cl_int clEnqueueWriteImage(cl_command_queue q, cl_mem image, cl_bool blocking_write,
                                       const size_t *origin, const size_t *region, size_t input_row_pitch,
                                       size_t input_slice_pitch, const void *ptr,
                                       cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                       cl_event *event)
{
  if(_bad_region(image, origin, region)) return CL_INVALID_VALUE;
  dtclb_finish();
  const cl_int err = dtclb_image_write(image, origin, region,
                                       input_row_pitch ? input_row_pitch : region[0] * image->element_size,
                                       ptr);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT cl_int clEnqueueCopyImage(cl_command_queue q, cl_mem src_image, cl_mem dst_image,
                                      const size_t *src_origin, const size_t *dst_origin, const size_t *region,
                                      cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                      cl_event *event)
{
  if(_bad_region(src_image, src_origin, region) || _bad_region(dst_image, dst_origin, region)
     || src_image->element_size != dst_image->element_size || src_image->pixel != dst_image->pixel)
    return CL_INVALID_VALUE;
  const cl_int err = dtclb_image_copy(src_image, dst_image, src_origin, dst_origin, region);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT cl_int clEnqueueCopyImageToBuffer(cl_command_queue q, cl_mem src_image, cl_mem dst_buffer,
                                              const size_t *src_origin, const size_t *region, size_t dst_offset,
                                              cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                              cl_event *event)
{
  if(_bad_region(src_image, src_origin, region)) return CL_INVALID_VALUE;
  const size_t size = region[0] * region[1] * src_image->element_size;
  if(_bad_buffer(dst_buffer, dst_offset, size)) return CL_INVALID_VALUE;

  // through the host: rare in darktable, so not worth a device path yet
  void *tmp = malloc(size);
  if(!tmp) return CL_OUT_OF_HOST_MEMORY;
  dtclb_finish();
  cl_int err = dtclb_image_read(src_image, src_origin, region, region[0] * src_image->element_size, tmp);
  if(err == CL_SUCCESS) err = dtclb_buffer_write(dst_buffer, dst_offset, size, tmp);
  free(tmp);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT cl_int clEnqueueCopyBufferToImage(cl_command_queue q, cl_mem src_buffer, cl_mem dst_image,
                                              size_t src_offset, const size_t *dst_origin, const size_t *region,
                                              cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                              cl_event *event)
{
  if(_bad_region(dst_image, dst_origin, region)) return CL_INVALID_VALUE;
  const size_t size = region[0] * region[1] * dst_image->element_size;
  if(_bad_buffer(src_buffer, src_offset, size)) return CL_INVALID_VALUE;

  void *tmp = malloc(size);
  if(!tmp) return CL_OUT_OF_HOST_MEMORY;
  dtclb_finish();
  cl_int err = dtclb_buffer_read(src_buffer, src_offset, size, tmp);
  if(err == CL_SUCCESS)
    err = dtclb_image_write(dst_image, dst_origin, region, region[0] * dst_image->element_size, tmp);
  free(tmp);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

DTCL_EXPORT cl_int clEnqueueFillImage(cl_command_queue q, cl_mem image, const void *fill_color,
                                      const size_t *origin, const size_t *region,
                                      cl_uint num_events_in_wait_list, const cl_event *event_wait_list,
                                      cl_event *event)
{
  if(_bad_region(image, origin, region) || !fill_color) return CL_INVALID_VALUE;

  // fill_color is float[4] for float images and uint[4] for integer ones
  unsigned char pixel[16];
  for(int c = 0; c < image->channels; c++)
  {
    switch(image->pixel)
    {
      case DTCL_PIXEL_FLOAT: memcpy(pixel + 4 * c, (const float *)fill_color + c, 4); break;
      case DTCL_PIXEL_UINT16:
      {
        const uint16_t v = (uint16_t)((const cl_uint *)fill_color)[c];
        memcpy(pixel + 2 * c, &v, 2);
        break;
      }
      case DTCL_PIXEL_UINT8: pixel[c] = (uint8_t)((const cl_uint *)fill_color)[c]; break;
    }
  }
  const size_t n = region[0] * region[1];
  unsigned char *tmp = malloc(n * image->element_size);
  if(!tmp) return CL_OUT_OF_HOST_MEMORY;
  for(size_t i = 0; i < n; i++) memcpy(tmp + i * image->element_size, pixel, image->element_size);
  dtclb_finish();
  const cl_int err = dtclb_image_write(image, origin, region, region[0] * image->element_size, tmp);
  free(tmp);
  if(err == CL_SUCCESS) _event_out(event);
  return err;
}

// --- events ---

DTCL_EXPORT cl_int clWaitForEvents(cl_uint num_events, const cl_event *event_list)
{
  return dtclb_finish();
}

DTCL_EXPORT cl_int clGetEventInfo(cl_event event, cl_event_info param_name, size_t param_value_size,
                                  void *param_value, size_t *param_value_size_ret)
{
  if(!event) return CL_INVALID_EVENT;
  switch(param_name)
  {
    case CL_EVENT_COMMAND_EXECUTION_STATUS:
      // commands are reported complete once everything before them is
      dtclb_finish();
      RET_VAL(cl_int, CL_COMPLETE);
    case CL_EVENT_REFERENCE_COUNT: RET_VAL(cl_uint, event->refcount);
    default: return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_int clGetEventProfilingInfo(cl_event event, cl_profiling_info param_name,
                                           size_t param_value_size, void *param_value,
                                           size_t *param_value_size_ret)
{
  if(!event) return CL_INVALID_EVENT;
  dtclb_finish();
  switch(param_name)
  {
    case CL_PROFILING_COMMAND_QUEUED:
    case CL_PROFILING_COMMAND_SUBMIT:
    case CL_PROFILING_COMMAND_START: RET_VAL(cl_ulong, event->start_ns);
    case CL_PROFILING_COMMAND_END: RET_VAL(cl_ulong, event->end_ns);
    default: return CL_INVALID_VALUE;
  }
}

DTCL_EXPORT cl_int clReleaseEvent(cl_event event)
{
  if(!event) return CL_INVALID_EVENT;
  if(__atomic_sub_fetch(&event->refcount, 1, __ATOMIC_ACQ_REL) == 0) free(event);
  return CL_SUCCESS;
}

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
