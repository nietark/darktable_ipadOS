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

// the emulator backend: runs the Metal kernel ports on the CPU so they, and
// dtcl.c, can be tested where there is no Metal. It is a test tool, slow by
// design, and not meant for real editing.
//
// Work-groups run in parallel. Inside a group that uses barriers, every
// work-item is a ucontext fiber: threadgroup_barrier() switches back to the
// scheduler, which resumes the next item, so all items of a group reach a
// barrier before any of them passes it, as on a GPU.

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <vector>
#include <ucontext.h>
#ifdef _OPENMP
#include <omp.h>
#endif

#include "dtcl_emu.h"

namespace
{

struct emu_kernel
{
  dtcl_emu_invoke_t invoke;
};

struct emu_fiber
{
  ucontext_t ctx;
  std::vector<char> stack;
  bool done;
  void **args;
};

constexpr size_t FIBER_STACK = 128 * 1024;
constexpr size_t MAX_GROUP = 256;

thread_local ucontext_t *t_scheduler = nullptr;
thread_local emu_fiber *t_current = nullptr;
thread_local dtcl_emu_invoke_t t_invoke = nullptr;

void _fiber_main()
{
  t_invoke(t_current->args);
  t_current->done = true;
  // returning resumes uc_link, the scheduler
}

uint64_t _now_ns()
{
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
           std::chrono::steady_clock::now().time_since_epoch()).count();
}

} // namespace

extern "C" void dtcl_emu_barrier(void)
{
  // a kernel without barriers runs outside any fiber
  if(t_current) swapcontext(&t_current->ctx, t_scheduler);
}

extern "C" int dtclb_init(dtcl_device_props_t *p)
{
  snprintf(p->name, sizeof(p->name), "CPU emulation of Metal kernels");
  snprintf(p->vendor, sizeof(p->vendor), "darktable");
  snprintf(p->driver_version, sizeof(p->driver_version), "emulator 1");
  p->global_mem = 8ull << 30;
  p->max_alloc = 4ull << 30;
  p->max_image_width = p->max_image_height = 16384; // Metal's texture size limit
  p->max_group_size = MAX_GROUP;
  p->local_mem = 32 * 1024; // as on Apple GPUs
#ifdef _OPENMP
  p->compute_units = omp_get_max_threads();
#else
  p->compute_units = 1;
#endif
  p->unified_memory = 1;
  return CL_SUCCESS;
}

extern "C" int dtclb_mem_create(cl_mem m)
{
  // calloc: OpenCL leaves new memory undefined, zero makes runs repeatable
  if(m->is_image)
  {
    dtcl_emu_image_t *img = (dtcl_emu_image_t *)calloc(1, sizeof(dtcl_emu_image_t));
    if(!img) return CL_OUT_OF_HOST_MEMORY;
    img->data = (unsigned char *)calloc(1, m->size);
    if(!img->data)
    {
      free(img);
      return CL_MEM_OBJECT_ALLOCATION_FAILURE;
    }
    img->width = m->width;
    img->height = m->height;
    img->channels = m->channels;
    img->pixel = m->pixel;
    img->element_size = m->element_size;
    m->backend = img;
  }
  else
  {
    m->backend = calloc(1, m->size);
    if(!m->backend) return CL_MEM_OBJECT_ALLOCATION_FAILURE;
  }
  return CL_SUCCESS;
}

extern "C" void dtclb_mem_release(cl_mem m)
{
  if(m->is_image && m->backend) free(((dtcl_emu_image_t *)m->backend)->data);
  free(m->backend);
  m->backend = nullptr;
}

extern "C" int dtclb_buffer_read(cl_mem m, size_t offset, size_t size, void *dst)
{
  memcpy(dst, (char *)m->backend + offset, size);
  return CL_SUCCESS;
}

extern "C" int dtclb_buffer_write(cl_mem m, size_t offset, size_t size, const void *src)
{
  memcpy((char *)m->backend + offset, src, size);
  return CL_SUCCESS;
}

extern "C" int dtclb_buffer_copy(cl_mem src, cl_mem dst, size_t src_offset, size_t dst_offset, size_t size)
{
  memmove((char *)dst->backend + dst_offset, (char *)src->backend + src_offset, size);
  return CL_SUCCESS;
}

extern "C" void *dtclb_buffer_map(cl_mem m)
{
  return m->backend;
}

static unsigned char *_pixel(cl_mem m, size_t x, size_t y)
{
  const dtcl_emu_image_t *img = (const dtcl_emu_image_t *)m->backend;
  return img->data + (y * img->width + x) * img->element_size;
}

extern "C" int dtclb_image_read(cl_mem m, const size_t origin[2], const size_t region[2],
                                size_t row_pitch, void *dst)
{
  for(size_t y = 0; y < region[1]; y++)
    memcpy((char *)dst + y * row_pitch, _pixel(m, origin[0], origin[1] + y), region[0] * m->element_size);
  return CL_SUCCESS;
}

extern "C" int dtclb_image_write(cl_mem m, const size_t origin[2], const size_t region[2],
                                 size_t row_pitch, const void *src)
{
  for(size_t y = 0; y < region[1]; y++)
    memcpy(_pixel(m, origin[0], origin[1] + y), (const char *)src + y * row_pitch, region[0] * m->element_size);
  return CL_SUCCESS;
}

extern "C" int dtclb_image_copy(cl_mem src, cl_mem dst, const size_t src_origin[2],
                                const size_t dst_origin[2], const size_t region[2])
{
  for(size_t y = 0; y < region[1]; y++)
    memmove(_pixel(dst, dst_origin[0], dst_origin[1] + y), _pixel(src, src_origin[0], src_origin[1] + y),
            region[0] * src->element_size);
  return CL_SUCCESS;
}

extern "C" int dtclb_program_load(cl_program p)
{
  for(const dtcl_emu_program_t *ep = dtcl_emu_programs; ep->name; ep++)
    if(!strcmp(ep->name, p->info->name))
    {
      p->backend = (void *)ep;
      return CL_SUCCESS;
    }
  return CL_BUILD_PROGRAM_FAILURE;
}

extern "C" void dtclb_program_release(cl_program p)
{
}

extern "C" int dtclb_kernel_create(cl_kernel k)
{
  const dtcl_emu_program_t *ep = (const dtcl_emu_program_t *)k->program->backend;
  for(const dtcl_emu_kernel_t *ek = ep->kernels; ek->name; ek++)
    if(!strcmp(ek->name, k->info->name))
    {
      k->backend = (void *)ek->invoke;
      k->max_group_size = MAX_GROUP;
      return CL_SUCCESS;
    }
  return CL_INVALID_KERNEL_NAME;
}

extern "C" void dtclb_kernel_release(cl_kernel k)
{
}

extern "C" int dtclb_dispatch(cl_kernel k, cl_uint dims, const size_t *global, const size_t *local,
                              cl_event ev)
{
  const dtcl_emu_invoke_t invoke = (dtcl_emu_invoke_t)k->backend;
  const int nargs = k->num_args;
  const uint64_t start = _now_ns();

  uint gsz[3] = { 1, 1, 1 }, lsz[3] = { 1, 1, 1 };
  for(cl_uint d = 0; d < dims; d++) gsz[d] = global[d];
  if(local)
    for(cl_uint d = 0; d < dims; d++) lsz[d] = local[d];
  else
  {
    // like Metal's dispatchThreads: the last group of a row may be partial
    lsz[0] = gsz[0] < 16 ? gsz[0] : 16;
    if(dims > 1) lsz[1] = gsz[1] < 16 ? gsz[1] : 16;
  }
  uint ngroups[3];
  for(int d = 0; d < 3; d++) ngroups[d] = (gsz[d] + lsz[d] - 1) / lsz[d];
  const size_t total_groups = (size_t)ngroups[0] * ngroups[1] * ngroups[2];
  const size_t group_items = (size_t)lsz[0] * lsz[1] * lsz[2];

  // the argument array every work-item starts from
  std::vector<void *> base(nargs + 5, nullptr);
  std::vector<size_t> tg_size(nargs, 0);
  for(int i = 0; i < nargs; i++)
  {
    dtcl_arg_t *a = &k->args[i];
    switch(a->kind)
    {
      case 'B': base[i] = a->mem ? a->mem->backend : nullptr; break;
      case 'T': base[i] = a->mem ? a->mem->backend : nullptr; break;
      case 'V': base[i] = a->bytes; break;
      case 'L': tg_size[i] = (a->size + 15) & ~(size_t)15; break;
    }
  }

  const bool barriers = k->info->uses_barrier;

#ifdef _OPENMP
#pragma omp parallel
#endif
  {
    std::vector<std::vector<char>> tg(nargs);
    for(int i = 0; i < nargs; i++)
      if(tg_size[i]) tg[i].resize(tg_size[i]);
    std::vector<emu_fiber> fibers(barriers ? group_items : 0);
    for(auto &f : fibers) f.stack.resize(FIBER_STACK);
    std::vector<std::vector<void *>> item_args(barriers ? group_items : 1, base);
    std::vector<uint3> pos(5 * (barriers ? group_items : 1));
    ucontext_t scheduler;

#ifdef _OPENMP
#pragma omp for schedule(dynamic, 4)
#endif
    for(size_t g = 0; g < total_groups; g++)
    {
      const uint gx = g % ngroups[0], gy = (g / ngroups[0]) % ngroups[1], gz = g / ((size_t)ngroups[0] * ngroups[1]);
      for(int i = 0; i < nargs; i++)
        if(tg_size[i]) memset(tg[i].data(), 0, tg_size[i]);

      size_t n = 0;
      for(uint lz = 0; lz < lsz[2]; lz++)
        for(uint ly = 0; ly < lsz[1]; ly++)
          for(uint lx = 0; lx < lsz[0]; lx++)
          {
            const uint x = gx * lsz[0] + lx, y = gy * lsz[1] + ly, z = gz * lsz[2] + lz;
            if(x >= gsz[0] || y >= gsz[1] || z >= gsz[2]) continue;
            const size_t slot = barriers ? n : 0;
            std::vector<void *> &args = item_args[slot];
            uint3 *p = &pos[5 * slot];
            p[0] = (uint3){ x, y, z };
            p[1] = (uint3){ lx, ly, lz };
            p[2] = (uint3){ gx, gy, gz };
            p[3] = (uint3){ lsz[0], lsz[1], lsz[2] };
            p[4] = (uint3){ gsz[0], gsz[1], gsz[2] };
            for(int i = 0; i < nargs; i++)
              if(tg_size[i]) args[i] = tg[i].data();
            for(int i = 0; i < 5; i++) args[nargs + i] = &p[i];

            if(!barriers)
              invoke(args.data());
            else
            {
              emu_fiber &f = fibers[n];
              f.done = false;
              f.args = args.data();
              getcontext(&f.ctx);
              f.ctx.uc_stack.ss_sp = f.stack.data();
              f.ctx.uc_stack.ss_size = f.stack.size();
              f.ctx.uc_link = &scheduler;
              makecontext(&f.ctx, _fiber_main, 0);
            }
            n++;
          }

      if(barriers)
      {
        // round robin until every item ran to the end
        t_scheduler = &scheduler;
        t_invoke = invoke;
        bool running = true;
        while(running)
        {
          running = false;
          for(size_t i = 0; i < n; i++)
          {
            if(fibers[i].done) continue;
            t_current = &fibers[i];
            swapcontext(&scheduler, &fibers[i].ctx);
            running |= !fibers[i].done;
          }
        }
        t_current = nullptr;
      }
    }
  }

  if(ev)
  {
    ev->start_ns = start;
    ev->end_ns = _now_ns();
  }
  return CL_SUCCESS;
}

extern "C" int dtclb_finish(void)
{
  // everything already ran synchronously
  return CL_SUCCESS;
}

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
