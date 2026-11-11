#!/usr/bin/env bash
# Builds the web page (build-web/RogueSquadron64Recomp.html, .js, .wasm, .data, coi_serviceworker.js) from the USA 1.0
# ROM, on Linux with Docker, in the image tools/docker/Dockerfile.web (tagged with a hash of it, built the first time):
#
#   bash tools/build_web.sh <USA 1.0 ROM> [--prepare] [cmake arguments, e.g. -DN64RECOMP_BROWSER_FAST_LINK=ON]
#   bash tools/build_web.sh --patches          step 1 alone: no ROM or Docker, and only git and CMake
#
# The checkout's parent folder is mounted in the container at its own path, since the build reads and writes the
# decompilation beside the checkout (../rogue_squadron64), as the desktop build does (tools/setup/setup.sh). ccache and
# the container's HOME are in build-web-prep.
#
# 1. The submodules, and N64Recomp-browser's web patches on them (lib/N64Recomp-browser/patches/apply.cmake, project
#    by project), but for the files where this game's own forks of rt64, plume and the runtime change the same lines:
#    the web's change to those (web/patches/files.txt) is web/patches/<name>.patch instead, written on top of this
#    game's from the N64Recomp-browser commit files.txt names, with what the web has changed in them since merged in
#    by apply.cmake --since (only a change that meets the game's own lines stops the build, for another merge by
#    hand). The runtime's librecomp/src/config.cpp is left out too: the runtime here is from before upstream added it,
#    and the web's change there is to RecompFrontend's command line, which this game doesn't have. Patched from clean
#    whenever lib/N64Recomp-browser, web/patches or the commit of rt64 or the runtime moved since the last time, which
#    build-web-prep/web-patched records: apply.cmake can't take a checkout from one version of its patches to another.
# 2. N64Recomp, RSPRecomp, RecompModTool and OfflineModRecomp, built natively from the patched runtime's N64Recomp (the
#    page needs the code the web-patched N64Recomp writes), and the game's own build tools (fixup_factor5_ucode,
#    gen_state_table, rt64's file_to_c), in build-web-prep/tools.
# 3. The game's ELF from its symbols and the decompilation at the commit below, with the ROM imported as
#    tools/setup/setup.sh does (tools/setup/import_rom.py, tools/re/make_elf_from_syms.py).
# 4. The recompiled game (RecompiledFuncs), its patches (patches/src with MIPS GCC, then RecompiledPatches and
#    patches/patches.bin, as CMakeLists.txt's Patches ELF), the Factor 5 boot and MusyX audio microcode (RSPRecomp,
#    fixed up by tools/fixup_factor5_ucode.cpp), the state table, and the code mods mods/platforms.json lists for the
#    web (tools/mods/build_code_mods.cmake), each made again only when what it reads changed. --prepare stops here.
# 5. The page, with emcmake, in build-web (web/page.cmake).
# --patches stops after step 1. N64Recomp-browser's CI runs it with its own checkout as lib/N64Recomp-browser and the
# submodules checked out, so a web change there that meets this game's own lines in a file left out is red where it
# is made: merge it into the patch by hand then.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 1 ]] || { echo "usage: $0 <USA 1.0 ROM> [--prepare] [cmake arguments] | --patches" >&2; exit 2; }
browser=lib/N64Recomp-browser
prep=build-web-prep
decomp=../rogue_squadron64
decomp_url=https://github.com/MikeSemicolonD/rogue_squadron64
decomp_commit=70929e49d9cb5d966ebbdf0bbef31b5a48f51efc
rom_sha1=ed42eed1ee2db646ff7ef94ba8c5421d164a4f0d
cd "$root"

step() { printf '\n== %s\n' "$*"; }
# A hash of files' contents and names, for the stamps that say a step's inputs haven't changed.
inputs() { (cat "$@"; echo "$*") | sha1sum | cut -c1-40; }

patch_submodules() {
    step "Submodules"
    [[ -f lib/rt64/CMakeLists.txt && -f lib/N64ModernRuntime/N64Recomp/CMakeLists.txt && -f $browser/patches/apply.cmake ]] ||
        git submodule update --init --recursive lib/rt64 lib/N64ModernRuntime syms $browser

    step "Patches"
    mkdir -p $prep
    # <name> <checkout> [files left to web/patches/<name>.patch, merged from the commit files.txt names]
    shared() { awk -v p="$1" '!/^#/ && $1 == p { printf "%s ", $2 }' web/patches/files.txt; }
    local merged_from web_patches stamp name checkout skip extra
    merged_from="$(sed -n 's/^# merged from N64Recomp-browser //p' web/patches/files.txt)"
    web_patches="rt64 lib/rt64 $(shared rt64)
plume lib/rt64/src/contrib/plume $(shared plume)
hlslpp lib/rt64/src/contrib/hlslpp
N64ModernRuntime lib/N64ModernRuntime $(shared N64ModernRuntime)
N64Recomp lib/N64ModernRuntime/N64Recomp $(shared N64Recomp)"
    stamp="$(git -C $browser rev-parse HEAD) $(git -C lib/rt64 rev-parse HEAD) $(git -C lib/N64ModernRuntime rev-parse HEAD) $( (cat web/patches/*.patch web/patches/files.txt tools/build_web.sh; echo "$web_patches") | sha1sum | cut -c1-40)"
    [[ "$(cat $prep/web-patched 2> /dev/null)" != "$stamp" ]] || return 0
    for s in lib/rt64 lib/N64ModernRuntime; do
        git -C $s submodule foreach --recursive -q 'git reset -q --hard && git clean -fdq'
        git -C $s reset -q --hard && git -C $s clean -fdq
    done
    while read -r name checkout skip; do
        extra=""
        [[ $name != N64ModernRuntime ]] || extra=librecomp/src/config.cpp
        cmake -P $browser/patches/apply.cmake "$name" "$checkout" $skip $extra
        # From the repository's top: run in a folder of it (his N64Recomp is N64ModernRuntime's), git apply would leave
        # out every path, which it takes from the top.
        prefix="$(git -C "$checkout" rev-parse --show-prefix)"
        [[ ! -f web/patches/$name.patch ]] || git -C "$(git -C "$checkout" rev-parse --show-toplevel)" apply \
            --whitespace=nowarn ${prefix:+--directory="${prefix%/}"} "$root/web/patches/$name.patch"
        [[ -z "$skip" ]] || cmake -P $browser/patches/apply.cmake "$name" "$checkout" --since "$merged_from" $skip
    done <<< "$web_patches"
    echo "$stamp" > $prep/web-patched
}

if [[ "$1" == --patches ]]; then
    [[ -z "${RS_WEB_INSIDE:-}" ]] || git config --global --add safe.directory '*'
    patch_submodules
    exit 0
fi

# Outside the container: the image, then this script inside it twice, for the patches (so the host needs no CMake) and
# for the rest, with the ROM copied in.
if [[ -z "${RS_WEB_INSIDE:-}" ]]; then
    rom="$(realpath "$1")"
    shift
    image="rs-web:$(sha256sum tools/docker/Dockerfile.web | cut -c1-12)"
    docker image inspect "$image" > /dev/null 2>&1 ||
        docker build -q -t "$image" -f tools/docker/Dockerfile.web tools/docker > /dev/null
    mkdir -p $prep/home $prep/ccache
    cmp -s "$rom" $prep/rom.input || cp "$rom" $prep/rom.input
    parent="$(dirname "$root")"
    inside() {
        docker run --rm -u "$(id -u):$(id -g)" -v "$parent:$parent" -w "$root" -e RS_WEB_INSIDE=1 \
            -e HOME="$root/$prep/home" -e CCACHE_DIR="$root/$prep/ccache" "$image" bash tools/build_web.sh "$@"
    }
    inside --patches
    inside "$prep/rom.input" "$@"
    exit
fi

rom="$1"
shift
prepare_only=0
if [[ "${1:-}" == --prepare ]]; then
    prepare_only=1
    shift
fi
jobs="$(nproc)"
git config --global --add safe.directory '*'

# --- 2. The tools ---
step "Tools"
tools=$prep/tools
[[ -f $tools/build.ninja ]] || cmake -S lib/N64ModernRuntime/N64Recomp -B $tools -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ > /dev/null
ninja -C $tools N64RecompCLI RSPRecomp RecompModTool OfflineModRecomp > /dev/null
# <tool> <sources and flags>: built again when the command or a source changed.
host_tool() {
    local out=$tools/$1 sum
    shift
    sum="$(inputs $(printf '%s\n' "$@" | grep -v '^-'))"
    [[ -x $out && "$(cat $out.stamp 2> /dev/null)" == "$sum" ]] && return 0
    clang++ -O2 -std=c++17 -o $out "$@"
    echo "$sum" > $out.stamp
}
host_tool fixup_factor5_ucode tools/fixup_factor5_ucode.cpp
host_tool gen_state_table tools/state/gen_state_table.cpp -Ilib/N64ModernRuntime/N64Recomp/lib/tomlplusplus/include
host_tool file_to_c lib/rt64/src/tools/file_to_c/file_to_c.cpp

# --- 3. The game's ELF ---
step "Game ELF"
if [[ "$(git -C $decomp rev-parse HEAD 2> /dev/null)" != $decomp_commit ]]; then
    [[ -d $decomp/.git ]] || git clone -q $decomp_url $decomp
    git -C $decomp fetch -q origin $decomp_commit 2> /dev/null || true
    git -C $decomp checkout -q $decomp_commit
fi
[[ -f $decomp/rogue_squadron.z64 && "$(sha1sum < rogue_squadron.z64 2> /dev/null | cut -c1-40)" == $rom_sha1 ]] ||
    python3 -I tools/setup/import_rom.py "$rom"
elf=$decomp/build/roguesquadron.elf
sum="$decomp_commit $(inputs tools/re/make_elf_from_syms.py syms/rogue_squadron.syms.toml rogue_squadron.toml)"
if [[ "$(cat $prep/elf-stamp 2> /dev/null)" != "$sum" || ! -f $elf ]]; then
    python3 tools/re/make_elf_from_syms.py > $prep/elf.log 2>&1 || { tail -20 $prep/elf.log; exit 1; }
    echo "$sum" > $prep/elf-stamp
fi

# --- 4. The recompiled code ---
step "Recompiled game"
sum="$(inputs rogue_squadron.toml $elf $tools/N64Recomp)"
if [[ "$(cat $prep/recompiled-stamp 2> /dev/null)" != "$sum" || ! -f RecompiledFuncs/funcs.h ]]; then
    $tools/N64Recomp rogue_squadron.toml > $prep/n64recomp.log 2>&1 || { tail -20 $prep/n64recomp.log; exit 1; }
    echo "$sum" > $prep/recompiled-stamp
fi

step "Patches"
# CMakeLists.txt's Patches ELF, its flags from tools/mods/code_mod.cmake.
mips_cflags="$(cmake -DMIPS_GCC=/usr/bin/mips-linux-gnu-gcc -DMIPS_LD=/usr/bin/mips-linux-gnu-ld -P web/mips_cflags.cmake)"
sum="$(inputs patches.toml patches/patches.ld patches/syms.ld syms/rogue_squadron.syms.toml syms/rogue_squadron.datasyms.toml \
    $(find syms/include patches/src -name '*.[ch]' | sort) $tools/N64Recomp) $mips_cflags"
if [[ "$(cat $prep/patches-stamp 2> /dev/null)" != "$sum" || ! -f RecompiledPatches/patches.c || ! -f patches/patches.bin ]]; then
    rm -rf $prep/patches
    mkdir -p $prep/patches
    objs=()
    while read -r src; do
        obj=$prep/patches/$(echo "${src#patches/src/}" | tr / _).o
        mips-linux-gnu-gcc $mips_cflags -c "$src" -o "$obj"
        objs+=("$obj")
    done < <(find patches/src -name '*.c' | sort)
    mips-linux-gnu-ld -nostdlib -T patches/patches.ld -T patches/syms.ld -Map $prep/patches/patches.map \
        --unresolved-symbols=ignore-all --emit-relocs --noinhibit-exec -e 0 "${objs[@]}" -o patches/patches.elf 2> /dev/null
    $tools/N64Recomp patches.toml > $prep/patches.log 2>&1 || { tail -20 $prep/patches.log; exit 1; }
    echo "$sum" > $prep/patches-stamp
fi

step "Audio microcode"
ucode=build/factor5_ucode
sum="$(inputs rsp/factor5_boot_rsp.toml rsp/musyx_rsp.toml rogue_squadron.z64 $tools/RSPRecomp tools/fixup_factor5_ucode.cpp)"
if [[ "$(cat $prep/ucode-stamp 2> /dev/null)" != "$sum" || ! -f $ucode/musyx_audio_recompiled.c ]]; then
    mkdir -p $ucode
    $tools/RSPRecomp rsp/factor5_boot_rsp.toml > /dev/null
    $tools/RSPRecomp rsp/musyx_rsp.toml > /dev/null
    $tools/fixup_factor5_ucode $ucode/factor5_boot_recompiled.c $ucode/musyx_audio_recompiled.c > /dev/null
    echo "$sum" > $prep/ucode-stamp
fi

step "State table"
[[ src/game/state_table.inl -nt tools/state/state_model.toml && src/game/state_table.inl -nt $tools/gen_state_table ]] ||
    $tools/gen_state_table tools/state/state_model.toml src/game/state_table.inl > /dev/null

step "Code mods"
sum="$(inputs mods/platforms.json $(find mods -path '*/build' -prune -o \( -name '*.c' -o -name '*.h' -o -name mod.toml -o -name CMakeLists.txt \) -print | sort) $tools/RecompModTool tools/mods/code_mod.cmake)"
if [[ "$(cat $prep/mods-stamp 2> /dev/null)" != "$sum" ]]; then
    cmake -DPLATFORM=web -DRECOMP_MOD_TOOL="$root/$tools/RecompModTool" -DMIPS_GCC=/usr/bin/mips-linux-gnu-gcc \
        -DMIPS_LD=/usr/bin/mips-linux-gnu-ld -P tools/mods/build_code_mods.cmake > $prep/mods.log 2>&1 ||
        { tail -20 $prep/mods.log; exit 1; }
    echo "$sum" > $prep/mods-stamp
fi
[[ $prepare_only == 1 ]] && exit 0

# --- 5. The page ---
step "Page"
# The ports CMake finds and ninja depends on, in the image's own cache, which goes with the container (seconds).
embuilder build sdl2-mt freetype-legacysjlj > /dev/null 2>&1
[[ -f build-web/build.ninja ]] || emcmake cmake -S . -B build-web -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DRS64_WEB_TOOLS="$root/$tools" -DPython3_EXECUTABLE="$(command -v python3)" "$@" > $prep/configure.log 2>&1 ||
    { tail -30 $prep/configure.log; rm -f build-web/build.ninja; exit 1; }
[[ $# -eq 0 ]] || cmake build-web "$@" > /dev/null
ninja -C build-web -j"$jobs" RogueSquadron64Recomp > $prep/build.log 2>&1 ||
    { grep -E ' error|FAILED|undefined|wasm-ld' $prep/build.log | head -40; exit 1; }
ls -l build-web/RogueSquadron64Recomp.{html,js,wasm,data}
