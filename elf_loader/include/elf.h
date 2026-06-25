#ifndef ELF_H
#define ELF_H

#include <stdint.h>

/* Standard scalar type mappings */
typedef uint32_t Elf32_Addr;
typedef uint32_t Elf32_Off;
typedef uint32_t Elf32_Word;
typedef int32_t  Elf32_Sword;
typedef uint16_t Elf32_Half;

#define EI_NIDENT   16
#define EI_CLASS    4
#define EI_DATA     5
#define EI_VERSION  6

#define ELFCLASS32  1
#define ELFDATA2LSB 1
#define EV_CURRENT  1

#define EM_RISCV    243
#define ET_EXEC     2
#define PT_LOAD     1

/* Segment permissions */
#define PF_X        1
#define PF_W        2
#define PF_R        4

#define ELFMAG      "\177ELF"
#define SELFMAG     4

typedef struct {
    unsigned char e_ident[EI_NIDENT];
    Elf32_Half    e_type;
    Elf32_Half    e_machine;
    Elf32_Word    e_version;
    Elf32_Addr    e_entry;
    Elf32_Off     e_phoff;
    Elf32_Off     e_shoff;
    Elf32_Word    e_flags;
    Elf32_Half    e_ehsize;
    Elf32_Half    e_phentsize;
    Elf32_Half    e_phnum;
    Elf32_Half    e_shentsize;
    Elf32_Half    e_shnum;
    Elf32_Half    e_shstrndx;
} Elf32_Ehdr;

typedef struct {
    Elf32_Word p_type;
    Elf32_Off  p_offset;
    Elf32_Addr p_vaddr;
    Elf32_Addr p_paddr;
    Elf32_Word p_filesz;
    Elf32_Word p_memsz;
    Elf32_Word p_flags;
    Elf32_Word p_align;
} Elf32_Phdr;

#endif // ELF_H
