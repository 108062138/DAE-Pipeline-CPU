# naive copy-paste part
project(my_fib LANGUAGES NONE)

# Toolchain detection — same soft-fail as test-progs/.
if(NOT DEFINED CMAKE_C_COMPILER)
    message(STATUS
        "my_fib: no CMAKE_C_COMPILER set; this is a configure-only run. "
        "Pass -DCMAKE_TOOLCHAIN_FILE=../runtime/toolchain.cmake to build.")
    return()
endif()

enable_language(C)
enable_language(ASM)

set(CMAKE_C_STANDARD          11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(REPO_ROOT       "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(RUNTIME_ROOT    "${REPO_ROOT}/runtime")
set(KERNEL_ROOT     "${REPO_ROOT}/FreeRTOS-Kernel")
set(KERNEL_PORTABLE "${KERNEL_ROOT}/portable/GCC/RISC-V")
set(KERNEL_CHIP_EXT "${KERNEL_PORTABLE}/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions")
set(GENERATED_PORT_DIR "${CMAKE_CURRENT_BINARY_DIR}/freertos_riscv_port")
file(MAKE_DIRECTORY ${GENERATED_PORT_DIR})

add_library(runtime_rt STATIC
    ${RUNTIME_ROOT}/src/crt/start.S
    ${RUNTIME_ROOT}/src/hal/halt.c
    ${RUNTIME_ROOT}/src/hal/uart.c
    ${RUNTIME_ROOT}/src/stdlib/string.c
    ${RUNTIME_ROOT}/src/stdlib/stdio.c
    ${RUNTIME_ROOT}/src/stdlib/stdlib.c
    ${RUNTIME_ROOT}/src/stdlib/assert.c
)
target_include_directories(runtime_rt PUBLIC ${RUNTIME_ROOT}/include)
target_compile_options(runtime_rt PRIVATE
    -march=rv32i_zicsr -mabi=ilp32
    -ffreestanding -fno-builtin -O2
    -Wall -Wno-unused-parameter
)

# custom part:

execute_process(
    COMMAND ${CMAKE_C_COMPILER} -march=rv32i_zicsr -mabi=ilp32
            -print-libgcc-file-name
    OUTPUT_VARIABLE RV_LIBGCC
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

add_executable(my_fib main.c)

target_compile_options(my_fib PRIVATE
    -march=rv32i_zicsr -mabi=ilp32
    -ffreestanding -fno-builtin -O2
)

target_link_libraries(my_fib PRIVATE runtime_rt ${RV_LIBGCC})

target_link_options(my_fib PRIVATE
    -nostdlib -nostartfiles -static
    -T${RUNTIME_ROOT}/link.ld
)