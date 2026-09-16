.text
.globl enter

enter:

    cli # Disable maskable interrupts.
    cld # Make string operations move forward.

    movq %rdx, %rsp # Switch to the kernel stack.
    andq $-16, %rsp # Align the stack to 16 bytes.

    xorq %rbp, %rbp # Clear the frame pointer.

    subq $32, %rsp # Reserve Microsoft x64 shadow space.

    callq *%r8 # Call the kernel entry point.

1:

    hlt # Halt this CPU.
    jmp 1b # Stay in the halt loop.
