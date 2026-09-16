.text
.globl _start
_start:
    xorq %rbp, %rbp
    callq app_main
    ud2

.globl invoke
invoke:
    pushq %rbx
    movq %rdi, %rbx
    movq 0(%rbx), %rax
    movq 8(%rbx), %rdi
    movq 16(%rbx), %rsi
    movq 24(%rbx), %rdx
    int $0x80
    movq %rax, 0(%rbx)
    movq %rdi, 8(%rbx)
    movq %rsi, 16(%rbx)
    movq %rdx, 24(%rbx)
    popq %rbx
    retq

.globl burn
burn:
    movq %rdi, %xmm0
    movq $20000000, %rcx
1:
    pause
    decq %rcx
    jnz 1b
    movq %xmm0, %rax
    retq
