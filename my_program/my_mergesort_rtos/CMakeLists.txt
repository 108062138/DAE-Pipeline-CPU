project(my_mergesort_rtos LANGUAGES NONE)

if(NOT DEFINED CMAKE_C_COMPILER)
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

# --- runtime ---
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
)

# --- FreeRTOS kernel ---
execute_process(
    COMMAND git -C ${KERNEL_ROOT} show HEAD:portable/GCC/RISC-V/portASM.S
    OUTPUT_FILE ${GENERATED_PORT_DIR}/portASM.S
)
execute_process(
    COMMAND git -C ${KERNEL_ROOT} show HEAD:portable/GCC/RISC-V/portContext.h
    OUTPUT_FILE ${GENERATED_PORT_DIR}/portContext.h
)
add_library(freertos_kernel STATIC
    ${KERNEL_ROOT}/list.c
    ${KERNEL_ROOT}/queue.c
    ${KERNEL_ROOT}/tasks.c
    ${KERNEL_ROOT}/timers.c
    ${KERNEL_ROOT}/portable/MemMang/heap_4.c
    ${KERNEL_PORTABLE}/port.c
    ${GENERATED_PORT_DIR}/portASM.S
)
target_include_directories(freertos_kernel PUBLIC
    ${KERNEL_ROOT}/include
    ${GENERATED_PORT_DIR}
    ${KERNEL_PORTABLE}
    ${KERNEL_CHIP_EXT}
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${RUNTIME_ROOT}/include/stdlib
)
target_compile_options(freertos_kernel PRIVATE
    -march=rv32i_zicsr -mabi=ilp32
    -ffreestanding -fno-builtin -O2
)

# --- your program ---
execute_process(
    COMMAND ${CMAKE_C_COMPILER} -march=rv32i_zicsr -mabi=ilp32
            -print-libgcc-file-name
    OUTPUT_VARIABLE RV_LIBGCC
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
add_executable(my_mergesort_rtos main.c)
target_compile_options(my_mergesort_rtos PRIVATE
    -march=rv32i_zicsr -mabi=ilp32
    -ffreestanding -fno-builtin -O2
)
target_link_libraries(my_mergesort_rtos PRIVATE freertos_kernel runtime_rt ${RV_LIBGCC})
target_link_options(my_mergesort_rtos PRIVATE
    -nostdlib -nostartfiles -static
    -T${RUNTIME_ROOT}/link.ld
)
