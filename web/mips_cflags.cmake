# cmake [-DMIPS_GCC=<path>] -P web/mips_cflags.cmake: prints the flags tools/mods/code_mod.cmake compiles the code mods
# and the patches ELF with (RS64_MIPS_CFLAGS), for tools/build_web.sh, which builds the patches ELF outside CMake.
include("${CMAKE_CURRENT_LIST_DIR}/../tools/mods/code_mod.cmake")
list(JOIN RS64_MIPS_CFLAGS " " flags)
execute_process(COMMAND "${CMAKE_COMMAND}" -E echo "${flags}")
