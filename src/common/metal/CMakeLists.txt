# the experimental Metal runtime for darktable's OpenCL code path, see
# dtcl.h. Each target is a module darktable loads as its OpenCL library
# through the opencl_library preference; darktable itself does not link it.

find_package(Python3 COMPONENTS Interpreter REQUIRED)

set(DTCL_KERNELDIR "${CMAKE_SOURCE_DIR}/data/kernels")
set(DTCL_TOOL "${CMAKE_SOURCE_DIR}/tools/metal/metal_kernels.py")
file(GLOB DTCL_PORTS "${DTCL_KERNELDIR}/metal/*.metal")
file(GLOB DTCL_PORT_HEADERS "${DTCL_KERNELDIR}/metal/*.h")
file(GLOB DTCL_CL_SOURCES "${DTCL_KERNELDIR}/*.cl")
set(DTCL_INPUTS ${DTCL_PORTS} ${DTCL_PORT_HEADERS} ${DTCL_CL_SOURCES}
                "${DTCL_KERNELDIR}/programs.conf" "${CMAKE_SOURCE_DIR}/src/common/hdr-transfer.h" ${DTCL_TOOL})

# ports whose OpenCL source changed are reported here and skipped at run time
add_custom_target(metal_port_check ALL
  COMMAND ${Python3_EXECUTABLE} ${DTCL_TOOL} check ${DTCL_KERNELDIR}
  COMMENT "Checking the Metal kernel ports against their OpenCL sources")

# the runtime has its own floating point rules: no fast math, like Metal
# compiled with -fno-fast-math and like darktable's reference OpenCL setting
set(DTCL_C_FLAGS -fvisibility=hidden -fno-fast-math -ffp-contract=off)

if(BUILD_METAL_EMULATOR)
  # emu/metal_stdlib builds Metal's vector types on clang's ext_vector_type
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR "BUILD_METAL_EMULATOR needs clang as the C++ compiler")
  endif()
  set(EMU_OUT "${CMAKE_CURRENT_BINARY_DIR}/emu")
  set(EMU_SOURCES "${EMU_OUT}/dtcl_programs.c" "${EMU_OUT}/emu_registry.cc")
  foreach(PORT ${DTCL_PORTS})
    get_filename_component(BASE ${PORT} NAME_WE)
    list(APPEND EMU_SOURCES "${EMU_OUT}/emu_${BASE}.cc")
  endforeach()

  add_custom_command(
    OUTPUT ${EMU_SOURCES}
    COMMAND ${Python3_EXECUTABLE} ${DTCL_TOOL} programs ${DTCL_KERNELDIR} "${EMU_OUT}/dtcl_programs.c"
    COMMAND ${Python3_EXECUTABLE} ${DTCL_TOOL} emu ${DTCL_KERNELDIR} ${EMU_OUT}
    DEPENDS ${DTCL_INPUTS}
    COMMENT "Generating the Metal emulator sources")

  add_library(darktable_metal_emu MODULE dtcl.c dtcl_emu.cc ${EMU_SOURCES})
  target_include_directories(darktable_metal_emu PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR} "${CMAKE_CURRENT_SOURCE_DIR}/emu" "${EMU_OUT}/src"
    "${CMAKE_SOURCE_DIR}/src/common" "${CMAKE_SOURCE_DIR}/src/external/OpenCL")
  target_compile_definitions(darktable_metal_emu PRIVATE DTCL_EMULATOR)
  target_compile_options(darktable_metal_emu PRIVATE ${DTCL_C_FLAGS}
    $<$<COMPILE_LANGUAGE:CXX>:-std=c++17 -Wno-unknown-attributes -Wno-unused-function -Wno-unused-variable>)
  if(OpenMP_FOUND)
    target_link_libraries(darktable_metal_emu PRIVATE OpenMP::OpenMP_CXX)
  endif()
  set_target_properties(darktable_metal_emu PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${DARKTABLE_LIBDIR}")
  add_dependencies(darktable_metal_emu metal_port_check)
endif()

if(USE_METAL)
  if(NOT APPLE)
    message(FATAL_ERROR "USE_METAL needs macOS; use BUILD_METAL_EMULATOR elsewhere")
  endif()
  enable_language(OBJC)

  find_program(XCRUN xcrun REQUIRED)
  set(METAL_SDK "macosx" CACHE STRING "SDK the Metal kernels are compiled for (macosx, iphoneos)")
  set(METAL_OUT "${CMAKE_CURRENT_BINARY_DIR}/metallib")
  set(METALLIBS)
  foreach(PORT ${DTCL_PORTS})
    get_filename_component(BASE ${PORT} NAME_WE)
    # -fno-fast-math: Metal's default is fast math, the equivalent of
    # OpenCL's -cl-fast-relaxed-math, which darktable's reference path avoids
    add_custom_command(
      OUTPUT "${METAL_OUT}/${BASE}.metallib"
      COMMAND ${CMAKE_COMMAND} -E make_directory ${METAL_OUT}
      COMMAND ${XCRUN} -sdk ${METAL_SDK} metal -c -fno-fast-math -Wall
              -I "${DTCL_KERNELDIR}/metal" -I "${CMAKE_SOURCE_DIR}/src/common"
              ${PORT} -o "${METAL_OUT}/${BASE}.air"
      COMMAND ${XCRUN} -sdk ${METAL_SDK} metallib "${METAL_OUT}/${BASE}.air" -o "${METAL_OUT}/${BASE}.metallib"
      DEPENDS ${PORT} ${DTCL_PORT_HEADERS} "${CMAKE_SOURCE_DIR}/src/common/hdr-transfer.h"
      COMMENT "Compiling Metal kernels ${BASE}.metal")
    list(APPEND METALLIBS "${METAL_OUT}/${BASE}.metallib")
  endforeach()

  add_custom_command(
    OUTPUT "${METAL_OUT}/dtcl_programs.c"
    COMMAND ${Python3_EXECUTABLE} ${DTCL_TOOL} programs ${DTCL_KERNELDIR} "${METAL_OUT}/dtcl_programs.c"
            --metallib-dir ${METAL_OUT}
    DEPENDS ${DTCL_INPUTS} ${METALLIBS}
    COMMENT "Embedding the Metal kernels")

  add_library(darktable_metal MODULE dtcl.c dtcl_metal.m "${METAL_OUT}/dtcl_programs.c")
  target_include_directories(darktable_metal PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR} "${CMAKE_SOURCE_DIR}/src/external/OpenCL")
  target_compile_options(darktable_metal PRIVATE ${DTCL_C_FLAGS} $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>)
  target_link_libraries(darktable_metal PRIVATE "-framework Metal" "-framework Foundation")
  set_target_properties(darktable_metal PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${DARKTABLE_LIBDIR}")
  add_dependencies(darktable_metal metal_port_check)
  install(TARGETS darktable_metal DESTINATION ${CMAKE_INSTALL_LIBDIR}/darktable COMPONENT DTApplication)
endif()
