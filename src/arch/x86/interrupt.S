.text
.globl load_tables
load_tables:
    lgdt (%rcx)
    lidt (%rdx)
    pushq $8
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:
    movw $16, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs
    movw $40, %ax
    ltr %ax
    retq

.globl restore
restore:
    movq %rcx, %rax
    jmp resume

interrupt_common:
    cld
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rbp
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, %rcx
    andq $-16, %rsp
    subq $544, %rsp
    leaq 32(%rsp), %rdx
    fxsave64 (%rdx)
    callq dispatch
resume:
    fxrstor64 176(%rax)
    movq %rax, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rbp
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
    addq $16, %rsp
    iretq

.globl idle
idle:
    sti
1:
    hlt
    jmp 1b

.altmacro
.macro interrupt number
interrupt_\number:
    .if (\number != 8) && (\number != 10) && (\number != 11) && (\number != 12) && (\number != 13) && (\number != 14) && (\number != 17) && (\number != 21) && (\number != 29) && (\number != 30)
    pushq $0
    .endif
    pushq $\number
    jmp interrupt_common
.endm

.set vector, 0
.rept 256
    interrupt %vector
    .set vector, vector + 1
.endr

.section .rdata,"dr"
.p2align 3
.globl interrupt_stubs
interrupt_stubs:

.macro pointer number
    .quad interrupt_\number
.endm

.set vector, 0
.rept 256
    pointer %vector
    .set vector, vector + 1
.endr
