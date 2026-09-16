.text
.globl load_tables

load_tables:

    lgdt (%rcx) # Load the segment table.
    lidt (%rdx) # Load the interrupt table.
    pushq $8 # Select the kernel code segment.
    leaq 1f(%rip), %rax # Find the next label.
    pushq %rax # Push the continuation address.
    lretq # Reload the code segment and continue.

1:

    movw $16, %ax # Select the kernel data segment.
    movw %ax, %ds # Load the data segment.
    movw %ax, %es # Load the extra data segment.
    movw %ax, %ss # Load the stack segment.
    xorw %ax, %ax # Select the null segment.
    movw %ax, %fs # Clear the FS segment.
    movw %ax, %gs # Clear the GS segment.
    movw $40, %ax # Select the task-state segment.
    ltr %ax # Load the task-state segment.
    retq # Return to the caller.

.globl restore

restore:

    movq %rcx, %rax # Pass the context to resume.
    jmp resume # Restore the selected context.

interrupt_common:

    cld # Make string operations move forward.
    pushq %rax # Save RAX.
    pushq %rbx # Save RBX.
    pushq %rcx # Save RCX.
    pushq %rdx # Save RDX.
    pushq %rbp # Save RBP.
    pushq %rsi # Save RSI.
    pushq %rdi # Save RDI.
    pushq %r8 # Save R8.
    pushq %r9 # Save R9.
    pushq %r10 # Save R10.
    pushq %r11 # Save R11.
    pushq %r12 # Save R12.
    pushq %r13 # Save R13.
    pushq %r14 # Save R14.
    pushq %r15 # Save R15.
    movq %rsp, %rcx # Pass the saved register frame.
    andq $-16, %rsp # Align the stack to 16 bytes.
    subq $544, %rsp # Reserve 512 state bytes and 32 shadow bytes.
    leaq 32(%rsp), %rdx # Pass the floating-point save area.
    fxsave64 (%rdx) # Save x87 and SSE state.
    callq dispatch # Handle the interrupt and select a context.

resume:

    fxrstor64 176(%rax) # Restore x87 and SSE state.
    movq %rax, %rsp # Switch to the saved register frame.
    popq %r15 # Restore R15.
    popq %r14 # Restore R14.
    popq %r13 # Restore R13.
    popq %r12 # Restore R12.
    popq %r11 # Restore R11.
    popq %r10 # Restore R10.
    popq %r9 # Restore R9.
    popq %r8 # Restore R8.
    popq %rdi # Restore RDI.
    popq %rsi # Restore RSI.
    popq %rbp # Restore RBP.
    popq %rdx # Restore RDX.
    popq %rcx # Restore RCX.
    popq %rbx # Restore RBX.
    popq %rax # Restore RAX.
    addq $16, %rsp # Discard the vector and error code.
    iretq # Restore execution state and resume.

.globl idle

idle:

    sti # Enable maskable interrupts.

1:

    hlt # Wait for an interrupt.
    jmp 1b # Return to the idle loop.

.altmacro

.macro interrupt number

interrupt_\number:

    .if (\number != 8) && (\number != 10) && (\number != 11) && (\number != 12) && (\number != 13) && (\number != 14) && (\number != 17) && (\number != 21) && (\number != 29) && (\number != 30)
        pushq $0 # Supply a missing CPU error code.
    .endif

    pushq $\number # Save the interrupt vector.
    jmp interrupt_common # Enter the shared interrupt handler.

.endm

.set vector, 0 # Start at vector zero.

.rept 256 # Cover all interrupt vectors.

    interrupt %vector # Generate this interrupt stub.
    .set vector, vector + 1 # Advance to the next vector.

.endr

.section .rdata,"dr"
.p2align 3
.globl interrupt_stubs

interrupt_stubs:

.macro pointer number

    .quad interrupt_\number # Store the stub address.

.endm

.set vector, 0 # Start at vector zero.

.rept 256 # Cover all interrupt vectors.

    pointer %vector # Add this stub to the address table.
    .set vector, vector + 1 # Advance to the next vector.

.endr
