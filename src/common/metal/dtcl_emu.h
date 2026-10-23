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

// how the emulator backend calls a Metal kernel compiled as C++: every
// parameter is passed as a void pointer, in order, and converted to the
// parameter's declared type. Buffers and threadgroup memory arrive as data
// pointers, `constant T &` values as pointers to their bytes, textures as
// dtcl_emu_image_t and the five position parameters as uint3.

#pragma once

#include "dtcl.h"

#include <utility>

#include "metal_stdlib"

typedef void (*dtcl_emu_invoke_t)(void **args);

typedef struct dtcl_emu_kernel_t
{
  const char *name;
  dtcl_emu_invoke_t invoke;
} dtcl_emu_kernel_t;

typedef struct dtcl_emu_program_t
{
  const char *name;
  const dtcl_emu_kernel_t *kernels;
} dtcl_emu_program_t;

extern const dtcl_emu_program_t dtcl_emu_programs[];

template <class P> struct dtcl_emu_arg;
template <class T> struct dtcl_emu_arg<T *>
{
  static T *get(void *p) { return (T *)p; }
};
template <class T> struct dtcl_emu_arg<T &>
{
  static T &get(void *p) { return *(T *)p; }
};
template <class T, metal::access A> struct dtcl_emu_arg<metal::texture2d<T, A>>
{
  static metal::texture2d<T, A> get(void *p) { return { (const dtcl_emu_image_t *)p }; }
};
template <> struct dtcl_emu_arg<uint3>
{
  static uint3 get(void *p) { return *(uint3 *)p; }
};

template <class... P, size_t... I>
inline void dtcl_emu_call(void (*fn)(P...), void **args, std::index_sequence<I...>)
{
  fn(dtcl_emu_arg<P>::get(args[I])...);
}

template <class F> struct dtcl_emu_thunk;
template <class... P> struct dtcl_emu_thunk<void (*)(P...)>
{
  template <void (*FN)(P...)> static void invoke(void **args)
  {
    dtcl_emu_call(FN, args, std::index_sequence_for<P...>{});
  }
};

#define dtcl_emu_invoker(fn) (&dtcl_emu_thunk<decltype(&fn)>::template invoke<&fn>)

// clang-format off
// modelines: These editor modelines have been set for all relevant files by tools/update_modelines.py
// vim: shiftwidth=2 expandtab tabstop=2 cindent
// kate: tab-indents: off; indent-width 2; replace-tabs on; indent-mode cstyle; remove-trailing-spaces modified;
// clang-format on
