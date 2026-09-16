.text
.p2align 4
.globl trampoline_start
.globl trampoline_end
.globl trampoline_gdtr
.globl trampoline_jump
.globl trampoline_root
.globl trampoline_stack
.globl trampoline_entry
.globl trampoline_argument
.globl trampoline_long
.globl trampoline_gdt
trampoline_start:
.code16
    cli
    cld
    movw %cs, %ax
    movw %ax, %ds
    movzwl %ax, %ebx
    shll $4, %ebx
    lgdtl trampoline_gdtr-trampoline_start
    movl %cr4, %eax
    orl $0x620, %eax
    movl %eax, %cr4
    movl trampoline_root-trampoline_start, %eax
    movl %eax, %cr3
    movl $0xc0000080, %ecx
    rdmsr
    orl $0x900, %eax
    wrmsr
    movl %cr0, %eax
    andl $0xfffffff3, %eax
    orl $0x80010003, %eax
    movl %eax, %cr0
    ljmpl *trampoline_jump-trampoline_start
.code64
trampoline_long:
    movw $16, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movq trampoline_stack-trampoline_start(%rbx), %rsp
    xorq %rbp, %rbp
    movq trampoline_argument-trampoline_start(%rbx), %rcx
    subq $32, %rsp
    callq *trampoline_entry-trampoline_start(%rbx)
1:
    cli
    hlt
    jmp 1b
.p2align 3
trampoline_gdt:
    .quad 0, 0x00af9a000000ffff, 0x00cf92000000ffff
trampoline_gdtr:
    .word 23
    .long 0
trampoline_jump:
    .long 0
    .word 8
.p2align 3
trampoline_root:
    .quad 0
trampoline_stack:
    .quad 0
trampoline_entry:
    .quad 0
trampoline_argument:
    .quad 0
trampoline_end:
