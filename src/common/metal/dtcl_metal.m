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

// the Metal backend: runs the kernel ports on the GPU of a Mac or iPad.
//
// Buffers live in shared storage, so reads, writes and maps are memcpy on
// the host once the GPU is idle (dtcl.c calls dtclb_finish() first).
// Images are textures; on a GPU with its own memory they are managed and
// synchronized with a blit before the host reads them.
//
// Dispatches are encoded into one open command buffer and committed in
// batches, as an OpenCL in-order queue would run them. Only finish, a
// profiled dispatch and a full batch commit.
//
// Compiled with ARC (-fobjc-arc). Objects stored in the void * backend
// fields of dtcl.h are retained there with __bridge_retained and released
// with CFBridgingRelease().

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <string.h>

#include "dtcl.h"

// commit after this many dispatches even without a finish, so the GPU
// starts on a long pipe while the host is still encoding
#define DTCL_BATCH 64

static id<MTLDevice> _device;
static id<MTLCommandQueue> _queue;
static id<MTLCommandBuffer> _cmd;
static id<MTLComputeCommandEncoder> _compute;
static id<MTLCommandBuffer> _last_committed;
static int _batched = 0;
static pthread_mutex_t _lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct _metal_image_t
{
  id<MTLTexture> texture;
  int managed;
} _metal_image_t;

static id<MTLCommandBuffer> _command_buffer(void)
{
  if(!_cmd) _cmd = [_queue commandBuffer];
  return _cmd;
}

static void _end_compute(void)
{
  if(_compute)
  {
    [_compute endEncoding];
    _compute = nil;
  }
}

static id<MTLComputeCommandEncoder> _compute_encoder(void)
{
  if(!_compute) _compute = [_command_buffer() computeCommandEncoder];
  return _compute;
}

static id<MTLBlitCommandEncoder> _blit_encoder(void)
{
  _end_compute();
  return [_command_buffer() blitCommandEncoder];
}

static void _commit(void)
{
  _end_compute();
  if(_cmd)
  {
    [_cmd commit];
    _last_committed = _cmd;
    _cmd = nil;
  }
  _batched = 0;
}

static int _wait(void)
{
  _commit();
  int err = CL_SUCCESS;
  if(_last_committed)
  {
    [_last_committed waitUntilCompleted];
    if(_last_committed.status == MTLCommandBufferStatusError)
    {
      dtcl_log("command buffer failed: %s",
               _last_committed.error.localizedDescription.UTF8String);
      err = CL_OUT_OF_RESOURCES;
    }
    _last_committed = nil;
  }
  return err;
}

static MTLPixelFormat _pixel_format(const cl_mem m)
{
  switch(m->pixel)
  {
    case DTCL_PIXEL_FLOAT:
      return m->channels == 1 ? MTLPixelFormatR32Float
           : m->channels == 2 ? MTLPixelFormatRG32Float
                              : MTLPixelFormatRGBA32Float;
    case DTCL_PIXEL_UINT16:
      return m->channels == 1 ? MTLPixelFormatR16Uint
           : m->channels == 2 ? MTLPixelFormatRG16Uint
                              : MTLPixelFormatRGBA16Uint;
    case DTCL_PIXEL_UINT8:
      return m->channels == 1 ? MTLPixelFormatR8Uint
           : m->channels == 2 ? MTLPixelFormatRG8Uint
                              : MTLPixelFormatRGBA8Uint;
  }
  return MTLPixelFormatInvalid;
}

int dtclb_init(dtcl_device_props_t *p)
{
  @autoreleasepool
  {
    _device = MTLCreateSystemDefaultDevice();
    if(!_device) return CL_DEVICE_NOT_FOUND;
    _queue = [_device newCommandQueue];
    if(!_queue) return CL_DEVICE_NOT_AVAILABLE;

    snprintf(p->name, sizeof(p->name), "%s", _device.name.UTF8String);
    snprintf(p->vendor, sizeof(p->vendor), "Apple");
    snprintf(p->driver_version, sizeof(p->driver_version), "Metal");
    p->global_mem = _device.recommendedMaxWorkingSetSize;
    p->max_alloc = _device.maxBufferLength;
    // Apple3 and later, every iPad and Mac darktable could run on
    p->max_image_width = p->max_image_height = 16384;
    p->max_group_size = _device.maxThreadsPerThreadgroup.width;
    p->local_mem = _device.maxThreadgroupMemoryLength;
    // Metal does not report core counts; darktable only uses it for logging
    // and a rough tuning hint
    p->compute_units = 8;
    p->unified_memory = _device.hasUnifiedMemory;
  }
  return CL_SUCCESS;
}

int dtclb_mem_create(cl_mem m)
{
  @autoreleasepool
  {
    if(m->is_image)
    {
      const MTLPixelFormat format = _pixel_format(m);
      if(format == MTLPixelFormatInvalid) return CL_IMAGE_FORMAT_NOT_SUPPORTED;
      MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:m->width
                                                          height:m->height
                                                       mipmapped:NO];
      desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
      int managed = 0;
#if TARGET_OS_OSX
      if(!_device.hasUnifiedMemory)
      {
        desc.storageMode = MTLStorageModeManaged;
        managed = 1;
      }
      else
#endif
        desc.storageMode = MTLStorageModeShared;
      id<MTLTexture> tex = [_device newTextureWithDescriptor:desc];
      if(!tex) return CL_MEM_OBJECT_ALLOCATION_FAILURE;
      _metal_image_t *img = calloc(1, sizeof(_metal_image_t));
      if(!img) return CL_OUT_OF_HOST_MEMORY;
      img->managed = managed;
      // the struct holds a strong reference under ARC
      img->texture = tex;
      m->backend = img;
    }
    else
    {
      id<MTLBuffer> buf = [_device newBufferWithLength:m->size options:MTLResourceStorageModeShared];
      if(!buf) return CL_MEM_OBJECT_ALLOCATION_FAILURE;
      // OpenCL leaves new memory undefined, zero makes runs repeatable
      memset(buf.contents, 0, m->size);
      m->backend = (__bridge_retained void *)buf;
    }
  }
  return CL_SUCCESS;
}

void dtclb_mem_release(cl_mem m)
{
  // a command buffer retains what it uses, so nothing waits here
  if(!m->backend) return;
  if(m->is_image)
  {
    _metal_image_t *img = m->backend;
    img->texture = nil;
    free(img);
  }
  else
    CFBridgingRelease(m->backend);
  m->backend = NULL;
}

static id<MTLBuffer> _buffer(const cl_mem m)
{
  return (__bridge id<MTLBuffer>)m->backend;
}

int dtclb_buffer_read(cl_mem m, size_t offset, size_t size, void *dst)
{
  memcpy(dst, (const char *)_buffer(m).contents + offset, size);
  return CL_SUCCESS;
}

int dtclb_buffer_write(cl_mem m, size_t offset, size_t size, const void *src)
{
  memcpy((char *)_buffer(m).contents + offset, src, size);
  return CL_SUCCESS;
}

int dtclb_buffer_copy(cl_mem src, cl_mem dst, size_t src_offset, size_t dst_offset, size_t size)
{
  pthread_mutex_lock(&_lock);
  @autoreleasepool
  {
    id<MTLBlitCommandEncoder> blit = _blit_encoder();
    [blit copyFromBuffer:_buffer(src) sourceOffset:src_offset
                toBuffer:_buffer(dst) destinationOffset:dst_offset
                    size:size];
    [blit endEncoding];
  }
  pthread_mutex_unlock(&_lock);
  return CL_SUCCESS;
}

void *dtclb_buffer_map(cl_mem m)
{
  return _buffer(m).contents;
}

int dtclb_image_read(cl_mem m, const size_t origin[2], const size_t region[2],
                     size_t row_pitch, void *dst)
{
  _metal_image_t *img = m->backend;
  int err = CL_SUCCESS;
  @autoreleasepool
  {
#if TARGET_OS_OSX
    if(img->managed)
    {
      // bring the GPU's copy back to the host before getBytes
      pthread_mutex_lock(&_lock);
      id<MTLBlitCommandEncoder> blit = _blit_encoder();
      [blit synchronizeResource:img->texture];
      [blit endEncoding];
      err = _wait();
      pthread_mutex_unlock(&_lock);
    }
#endif
    [img->texture getBytes:dst
               bytesPerRow:row_pitch
                fromRegion:MTLRegionMake2D(origin[0], origin[1], region[0], region[1])
               mipmapLevel:0];
  }
  return err;
}

int dtclb_image_write(cl_mem m, const size_t origin[2], const size_t region[2],
                      size_t row_pitch, const void *src)
{
  _metal_image_t *img = m->backend;
  @autoreleasepool
  {
    [img->texture replaceRegion:MTLRegionMake2D(origin[0], origin[1], region[0], region[1])
                    mipmapLevel:0
                      withBytes:src
                    bytesPerRow:row_pitch];
  }
  return CL_SUCCESS;
}

int dtclb_image_copy(cl_mem src, cl_mem dst, const size_t src_origin[2],
                     const size_t dst_origin[2], const size_t region[2])
{
  _metal_image_t *s = src->backend, *d = dst->backend;
  pthread_mutex_lock(&_lock);
  @autoreleasepool
  {
    id<MTLBlitCommandEncoder> blit = _blit_encoder();
    [blit copyFromTexture:s->texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(src_origin[0], src_origin[1], 0)
               sourceSize:MTLSizeMake(region[0], region[1], 1)
                toTexture:d->texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(dst_origin[0], dst_origin[1], 0)];
    [blit endEncoding];
  }
  pthread_mutex_unlock(&_lock);
  return CL_SUCCESS;
}

int dtclb_program_load(cl_program p)
{
  if(!p->info->metallib || !p->info->metallib_size) return CL_BUILD_PROGRAM_FAILURE;
  @autoreleasepool
  {
    dispatch_data_t data = dispatch_data_create(p->info->metallib, p->info->metallib_size, NULL,
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error = nil;
    id<MTLLibrary> lib = [_device newLibraryWithData:data error:&error];
    if(!lib)
    {
      dtcl_log("%s: cannot load metallib: %s", p->info->name,
               error.localizedDescription.UTF8String);
      return CL_BUILD_PROGRAM_FAILURE;
    }
    p->backend = (__bridge_retained void *)lib;
  }
  return CL_SUCCESS;
}

void dtclb_program_release(cl_program p)
{
  if(p->backend) CFBridgingRelease(p->backend);
  p->backend = NULL;
}

int dtclb_kernel_create(cl_kernel k)
{
  @autoreleasepool
  {
    id<MTLLibrary> lib = (__bridge id<MTLLibrary>)k->program->backend;
    id<MTLFunction> fn = [lib newFunctionWithName:@(k->info->name)];
    if(!fn) return CL_INVALID_KERNEL_NAME;
    NSError *error = nil;
    id<MTLComputePipelineState> pso = [_device newComputePipelineStateWithFunction:fn error:&error];
    if(!pso)
    {
      dtcl_log("%s: cannot build pipeline: %s", k->info->name,
               error.localizedDescription.UTF8String);
      return CL_INVALID_KERNEL;
    }
    k->max_group_size = pso.maxTotalThreadsPerThreadgroup;
    k->backend = (__bridge_retained void *)pso;
  }
  return CL_SUCCESS;
}

void dtclb_kernel_release(cl_kernel k)
{
  if(k->backend) CFBridgingRelease(k->backend);
  k->backend = NULL;
}

int dtclb_dispatch(cl_kernel k, cl_uint dims, const size_t *global, const size_t *local,
                   cl_event ev)
{
  id<MTLComputePipelineState> pso = (__bridge id<MTLComputePipelineState>)k->backend;
  int err = CL_SUCCESS;
  pthread_mutex_lock(&_lock);
  @autoreleasepool
  {
    id<MTLComputeCommandEncoder> enc = _compute_encoder();
    [enc setComputePipelineState:pso];
    for(int i = 0; i < k->num_args; i++)
    {
      const dtcl_arg_t *a = &k->args[i];
      switch(a->kind)
      {
        case 'B':
          [enc setBuffer:(a->mem ? _buffer(a->mem) : nil) offset:0 atIndex:i];
          break;
        case 'T':
          [enc setTexture:(a->mem ? ((_metal_image_t *)a->mem->backend)->texture : nil) atIndex:i];
          break;
        case 'V':
          [enc setBytes:a->bytes length:a->size atIndex:i];
          break;
        case 'L':
          [enc setThreadgroupMemoryLength:((a->size + 15) & ~(size_t)15) atIndex:i];
          break;
      }
    }

    MTLSize grid = MTLSizeMake(global[0], dims > 1 ? global[1] : 1, dims > 2 ? global[2] : 1);
    if(local)
    {
      const MTLSize group = MTLSizeMake(local[0], dims > 1 ? local[1] : 1, dims > 2 ? local[2] : 1);
      // dtcl.c checked that local divides global, as OpenCL 1.2 requires
      [enc dispatchThreadgroups:MTLSizeMake(grid.width / group.width, grid.height / group.height,
                                            grid.depth / group.depth)
          threadsPerThreadgroup:group];
    }
    else
    {
      // non-uniform groups, as in the emulator: the last group of a row
      // may be partial, so kernels still see exactly the global size
      const NSUInteger w = pso.threadExecutionWidth;
      const NSUInteger h = dims > 1 ? MAX(1, pso.maxTotalThreadsPerThreadgroup / w / 2) : 1;
      [enc dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(w, h, 1)];
    }

    if(ev)
    {
      // darktable only asks for events when profiling, so timing one
      // dispatch on its own command buffer is fine
      id<MTLCommandBuffer> cmd = _cmd;
      err = _wait();
      ev->start_ns = (uint64_t)(cmd.GPUStartTime * 1e9);
      ev->end_ns = (uint64_t)(cmd.GPUEndTime * 1e9);
    }
    else if(++_batched >= DTCL_BATCH)
      _commit();
  }
  pthread_mutex_unlock(&_lock);
  return err;
}

int dtclb_finish(void)
{
  pthread_mutex_lock(&_lock);
  int err;
  @autoreleasepool
  {
    err = _wait();
  }
  pthread_mutex_unlock(&_lock);
  return err;
}

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
