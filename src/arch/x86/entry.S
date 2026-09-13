.text
.globl enter

enter:

    cli
    cld

    movq %rdx, %rsp # Set stack pointer to the top of the stack
    andq $-16, %rsp # Align stack pointer to 16 bytes

    xorq %rbp, %rbp # Clear base pointer

    subq $32, %rsp # Allocate space for local variables

    callq *%r8

1:

    # Halts the CPU until the next interrupt occurs

    hlt
    jmp 1b
