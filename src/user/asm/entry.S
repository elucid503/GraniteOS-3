.text
.globl _start

_start:

    xorq %rbp, %rbp # Clear the frame pointer.
    callq app_main # Run the application.
    ud2 # Fault if the application returns.

.globl invoke

invoke:

    pushq %rbx # Preserve the caller's RBX.
    movq %rdi, %rbx # Keep the request address across the call.

    movq 0(%rbx), %rax # Load the syscall number.
    movq 8(%rbx), %rdi # Load the first argument.
    movq 16(%rbx), %rsi # Load the second argument.
    movq 24(%rbx), %rdx # Load the third argument.

    int $0x80 # Enter the kernel syscall handler.

    movq %rax, 0(%rbx) # Store the returned status.
    movq %rdi, 8(%rbx) # Store the first result.
    movq %rsi, 16(%rbx) # Store the second result.
    movq %rdx, 24(%rbx) # Store the third result.

    popq %rbx # Restore the caller's RBX.
    retq # Return to the caller.

.globl burn

burn:

    movq %rdi, %xmm0 # Keep the test value in an SSE register.
    movq $20000000, %rcx # Set the preemption test loop count.

1:

    pause # Pause briefly in the busy loop.
    decq %rcx # Count down one iteration.
    jnz 1b # Repeat until the counter reaches zero.

    movq %xmm0, %rax # Return the preserved SSE value.
    retq # Return to the caller.
