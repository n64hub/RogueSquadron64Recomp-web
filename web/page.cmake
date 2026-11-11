# The game as a page for a browser (emcmake cmake), RogueSquadron64Recomp.html, through lib/N64Recomp-browser: RT64 on
# WebGPU in the page's canvas, sound on the browser's audio thread, the ROM, saves and settings in the browser's
# storage. CMakeLists.txt includes this in place of the rest of itself when it configures with Emscripten;
# tools/build_web.sh makes what it needs first (the web patches on the submodules, the recompiled game, patches and
# audio microcode from the web-patched N64Recomp, the state table, the code mods) and passes the folder of the tools it
# built natively as RS64_WEB_TOOLS.
#
# What differs from the desktop build (CMakeLists.txt, whose steps this follows):
# - rt64, plume and the runtime are the submodules with N64Recomp-browser's web support patched in (tools/build_web.sh,
#   and web/patches where this game's own changes meet it). RT64 draws through WebGPU whatever the settings say, and
#   ray tracing is off: WebGPU has no ray queries (src/video/rt64_render_context.cpp asks the device).
# - The ROM is loaded on the page's own launcher (src/main/web_page.cpp) and kept, with the settings, the
#   saves and the mods folder, under HOME, which the page keeps in the browser's IndexedDB.
# - The mods mods/platforms.json lists for the web are the page's .data, copied into HOME's mods folder as it starts;
#   the code mods' code is recompiled ahead of time and linked in (n64recomp_browser_precompiled_mod), since a page has
#   no live recompiler. No native mods: online play (multiplayer-native, steam-relay) needs sockets a page doesn't have.
# - No MCP bridge, RenderDoc or Direct3D 11 shader precompiling: they are the desktop's debugging and Windows tools.

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
if (NOT RS64_WEB_TOOLS OR NOT EXISTS "${RS64_WEB_TOOLS}/N64Recomp")
    message(FATAL_ERROR "RS64_WEB_TOOLS: the tools tools/build_web.sh builds natively")
endif()

# Threads are pthreads (SharedArrayBuffer), and the runtime ends a game thread by throwing. -msimd128 is wasm SIMD,
# which every browser with WebGPU has; -mtail-call makes the recompiled code's tail calls return_calls. With -msimd128
# xxHash would take its NEON path through Emscripten's arm_neon.h, which doesn't compile in C++ there.
add_compile_options(-pthread -fwasm-exceptions -msimd128 -mtail-call "-DXXH_HAS_INCLUDE(x)=0" -sUSE_SDL=2)
include_directories(SYSTEM "${EMSCRIPTEN_SYSROOT}/include/SDL2")
add_link_options(-pthread -fwasm-exceptions -mtail-call)
add_compile_definitions(HLSL_CPU)
# ccache when it is on PATH, for shorter builds; before rt64 and the runtime are added.
include(${CMAKE_SOURCE_DIR}/lib/N64Recomp-browser/frontend/build_speed.cmake)
# The shaders the page specializes at build time and builds before the game draws with them (web/rt64_shaders.txt
# says how it was recorded); before rt64 is added.
if (EXISTS "${CMAKE_SOURCE_DIR}/web/rt64_shaders.txt")
    set(RT64_PREBUILT_SHADER_LIST "${CMAKE_SOURCE_DIR}/web/rt64_shaders.txt" CACHE FILEPATH "" FORCE)
endif()

set(RT64_STATIC ON CACHE BOOL "" FORCE)
# rt64 runs file_to_c at build time, so a cross build (this one) takes one built for the host.
set(RT64_HOST_FILE_TO_C "${RS64_WEB_TOOLS}/file_to_c" CACHE FILEPATH "" FORCE)
add_subdirectory(${CMAKE_SOURCE_DIR}/lib/rt64 ${CMAKE_BINARY_DIR}/rt64 EXCLUDE_FROM_ALL)
add_subdirectory(${CMAKE_SOURCE_DIR}/lib/N64ModernRuntime ${CMAKE_BINARY_DIR}/N64ModernRuntime EXCLUDE_FROM_ALL)
add_subdirectory(${CMAKE_SOURCE_DIR}/lib/N64Recomp-browser/frontend ${CMAKE_BINARY_DIR}/web_frontend)
# fmt (N64Recomp's) leans on <cstdlib> arriving through other headers, which Emscripten's libc++ doesn't do.
if (TARGET fmt)
    target_compile_options(fmt PRIVATE -include cstdlib)
endif()

# The recompiled game. WebAssembly turns a call to an undeclared function into a trap, so it may call none.
file(GLOB RECOMP_C_SOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/RecompiledFuncs/*.c")
file(GLOB RECOMP_CXX_SOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/RecompiledFuncs/*.cpp")
if (NOT RECOMP_C_SOURCES)
    message(FATAL_ERROR "RecompiledFuncs/ is empty: tools/build_web.sh recompiles the game first")
endif()
set(RS64_RECOMP_INCLUDES
    "${CMAKE_SOURCE_DIR}/include"
    "${CMAKE_SOURCE_DIR}/lib/N64ModernRuntime/ultramodern/include"
    "${CMAKE_SOURCE_DIR}/lib/N64ModernRuntime/librecomp/include"
    "${CMAKE_SOURCE_DIR}/lib/N64ModernRuntime/N64Recomp/include")
set(RS64_RECOMP_OPTIONS -fno-strict-aliasing -fwrapv -Wno-unused-variable -Werror=implicit-function-declaration
    -include "${CMAKE_SOURCE_DIR}/include/mem_wu.h")
add_library(RecompiledFuncs STATIC ${RECOMP_C_SOURCES} ${RECOMP_CXX_SOURCES} "${CMAKE_SOURCE_DIR}/src/game/toml_hooks.c")
target_include_directories(RecompiledFuncs PRIVATE ${RS64_RECOMP_INCLUDES})
target_compile_definitions(RecompiledFuncs PRIVATE main=rs_main)
target_compile_options(RecompiledFuncs PRIVATE ${RS64_RECOMP_OPTIONS})

# The game's patches, recompiled by tools/build_web.sh (CMakeLists.txt's Patches ELF), and the patch ELF's bytes.
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/patches/patches_bin.c ${CMAKE_BINARY_DIR}/patches/patches_bin.h
    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/patches
    COMMAND "${RS64_WEB_TOOLS}/file_to_c" ${CMAKE_SOURCE_DIR}/patches/patches.bin rs64_patches_bin
        ${CMAKE_BINARY_DIR}/patches/patches_bin.c ${CMAKE_BINARY_DIR}/patches/patches_bin.h
    DEPENDS ${CMAKE_SOURCE_DIR}/patches/patches.bin
    VERBATIM)
add_library(PatchesLib OBJECT ${CMAKE_SOURCE_DIR}/RecompiledPatches/patches.c ${CMAKE_BINARY_DIR}/patches/patches_bin.c)
target_include_directories(PatchesLib PRIVATE ${RS64_RECOMP_INCLUDES})
target_compile_definitions(PatchesLib PRIVATE main=rs_main)
target_compile_options(PatchesLib PRIVATE ${RS64_RECOMP_OPTIONS})

# The Factor 5 boot and MusyX audio microcode, recompiled and fixed up by tools/build_web.sh.
set(FACTOR5_BOOT_C ${CMAKE_SOURCE_DIR}/build/factor5_ucode/factor5_boot_recompiled.c)
set(MUSYX_AUDIO_C ${CMAKE_SOURCE_DIR}/build/factor5_ucode/musyx_audio_recompiled.c)
set_source_files_properties(${FACTOR5_BOOT_C} ${MUSYX_AUDIO_C} PROPERTIES LANGUAGE CXX
    COMPILE_OPTIONS "-Wno-unused-variable;-Wno-missing-braces;-Wno-shift-op-parentheses;-Wno-bitwise-op-parentheses")

# CMakeLists.txt's RS64_MAIN_SOURCES, but for the desktop's debugging tools.
add_executable(RogueSquadron64Recomp
    src/main/main.cpp
    src/main/web_page.cpp
    src/audio/audio.cpp
    src/main/cli.cpp
    src/main/crash.cpp
    src/input/input_host.cpp
    src/input/touch_host.cpp
    src/main/ui_panels.cpp
    src/game/game_state.cpp
    src/game/nav_sequencer.cpp
    src/input/input_bindings.cpp
    src/input/rumble.cpp
    src/input/touch_input.cpp
    src/input/touch_menu.cpp
    src/input/touch_config.cpp
    src/video/video_config.cpp
    src/game/menus/menu_config.cpp
    src/game/menus/pause_menu.cpp
    src/game/lang/lang.cpp
    src/video/rt64_render_context.cpp
    src/video/render_diag.cpp
    src/game/register_overlays.cpp
    src/game/register_patches.cpp
    src/game/upstream_compat.cpp
    src/game/hook_helpers.cpp
    src/game/mod_content/asset_overrides.cpp
    src/game/mod_content/mod_level_hooks.cpp
    src/game/static_standins.cpp
    src/lockstep/lockstep_core.cpp
    src/lockstep/lockstep.cpp
    src/main/renderdoc_capture.cpp
    src/host_api/host_api.cpp
    src/host_api/host_api_game.cpp
    src/game/builtin_hooks.cpp
    ${FACTOR5_BOOT_C}
    ${MUSYX_AUDIO_C})
set_source_files_properties(${CMAKE_SOURCE_DIR}/src/lockstep/lockstep_core.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
target_compile_definitions(RogueSquadron64Recomp PRIVATE RS64_VERSION_STRING="${RS64_VERSION}")
set(RS64_SHADER_COMBOS_FILE "${CMAKE_SOURCE_DIR}/tools/d3d11/shader_combos.txt")
file(READ "${RS64_SHADER_COMBOS_FILE}" RS64_SHADER_COMBOS)
file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/generated/rs64_shader_combos.inl" CONTENT "R\"RS64(@RS64_SHADER_COMBOS@)RS64\"\n" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${RS64_SHADER_COMBOS_FILE}")
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/generated/default_lights.c ${CMAKE_BINARY_DIR}/generated/default_lights.h
    COMMAND "${RS64_WEB_TOOLS}/file_to_c" ${CMAKE_SOURCE_DIR}/src/video/default_lights.json rs64_default_lights
        ${CMAKE_BINARY_DIR}/generated/default_lights.c ${CMAKE_BINARY_DIR}/generated/default_lights.h
    DEPENDS ${CMAKE_SOURCE_DIR}/src/video/default_lights.json
    VERBATIM)
target_sources(RogueSquadron64Recomp PRIVATE ${CMAKE_BINARY_DIR}/generated/default_lights.c)
target_include_directories(RogueSquadron64Recomp PRIVATE
    ${CMAKE_BINARY_DIR}/generated
    ${CMAKE_BINARY_DIR}/patches
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/RecompiledFuncs
    ${RS64_RECOMP_INCLUDES}
    ${CMAKE_SOURCE_DIR}/lib/rt64/src
    ${CMAKE_SOURCE_DIR}/lib/rt64/src/contrib
    ${CMAKE_SOURCE_DIR}/lib/rt64/src/contrib/hlslpp/include)
target_compile_options(RogueSquadron64Recomp PRIVATE -fno-strict-aliasing -fms-extensions)
# The src/ overrides redefine RecompiledFuncs and runtime symbols; the first definition wins (CMakeLists.txt).
target_link_options(RogueSquadron64Recomp PRIVATE -Wl,--allow-multiple-definition)
target_link_libraries(RogueSquadron64Recomp PRIVATE PatchesLib RecompiledFuncs librecomp ultramodern rt64)

# The code mods' code, recompiled ahead of time (tools/build_web.sh builds their .nrm files into mods/).
set(N64RECOMP_BROWSER_OFFLINE_MOD_RECOMP "${RS64_WEB_TOOLS}/OfflineModRecomp")
file(READ "${CMAKE_SOURCE_DIR}/mods/platforms.json" RS64_PLATFORMS)
string(JSON RS64_WEB_MOD_COUNT LENGTH "${RS64_PLATFORMS}" web)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/mods/platforms.json")
set(RS64_PRECOMPILED_MODS "")
set(RS64_WEB_MOD_FILES "")
math(EXPR last "${RS64_WEB_MOD_COUNT} - 1")
foreach(i RANGE ${last})
    string(JSON entry GET "${RS64_PLATFORMS}" web ${i})
    if (entry MATCHES "^(.*)\\.nrm$")
        set(name "${CMAKE_MATCH_1}")
        n64recomp_browser_precompiled_mod(RogueSquadron64Recomp "${CMAKE_SOURCE_DIR}/mods/${entry}"
            "${CMAKE_SOURCE_DIR}/syms/rogue_squadron.syms.toml" "${name}")
        list(APPEND RS64_PRECOMPILED_MODS "${name}")
    endif()
    list(APPEND RS64_WEB_MOD_FILES "${entry}")
endforeach()
# rs64_register_precompiled_mods(), which main() calls before the mods are scanned.
set(RS64_PRECOMPILED_DECLS "")
set(RS64_PRECOMPILED_CALLS "")
foreach(name ${RS64_PRECOMPILED_MODS})
    string(APPEND RS64_PRECOMPILED_DECLS "extern \"C\" const recomp_precompiled_mod ${name};\n")
    string(APPEND RS64_PRECOMPILED_CALLS "    recomp::mods::register_precompiled_mod(${name});\n")
endforeach()
file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/generated/precompiled_mods.cpp" CONTENT
"// Made by web/page.cmake from mods/platforms.json's web list.
#include \"librecomp/mods.hpp\"

@RS64_PRECOMPILED_DECLS@
void rs64_register_precompiled_mods()
{
@RS64_PRECOMPILED_CALLS@}
" @ONLY)
target_sources(RogueSquadron64Recomp PRIVATE "${CMAKE_BINARY_DIR}/generated/precompiled_mods.cpp")

# The page (lib/N64Recomp-browser/frontend), with the web's mods in its .data under /web-mods. No ROM: the player loads
# theirs on the page, and it stays in the browser.
n64recomp_browser_frontend_page(RogueSquadron64Recomp)
foreach(entry ${RS64_WEB_MOD_FILES})
    target_link_options(RogueSquadron64Recomp PRIVATE
        "SHELL:--preload-file ${CMAKE_SOURCE_DIR}/mods/${entry}@/web-mods/${entry}")
    set_property(TARGET RogueSquadron64Recomp APPEND PROPERTY LINK_DEPENDS "${CMAKE_SOURCE_DIR}/mods/${entry}")
endforeach()
