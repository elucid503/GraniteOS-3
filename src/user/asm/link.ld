ENTRY(_start)
PHDRS
{
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}
SECTIONS
{
    . = 0x8000000000;
    .text : { *(.text .text.* .ltext .ltext.*) } :text
    . = ALIGN(4096);
    .rodata : { *(.rodata .rodata.* .lrodata .lrodata.*) } :rodata
    . = ALIGN(4096);
    .data : { *(.data .data.* .ldata .ldata.* .got .got.*) } :data
    .bss : { *(.bss .bss.* .lbss .lbss.*) *(COMMON) } :data
    /DISCARD/ : { *(.eh_frame*) *(.comment*) *(.note*) }
}
