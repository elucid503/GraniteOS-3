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

.code16 # Assemble for 16-bit real mode.

    cli # Disable maskable interrupts.
    cld # Make string operations move forward.

    movw %cs, %ax # Read the trampoline segment.
    movw %ax, %ds # Load the data segment.
    movzwl %ax, %ebx # Copy the segment into a 32-bit register.
    shll $4, %ebx # Convert the segment to a physical address.
    lgdtl trampoline_gdtr-trampoline_start # Load the bootstrap segment table.

    movl %cr4, %eax # Read the extended CPU controls.
    orl $0x620, %eax # Enable PAE and SSE state support.
    movl %eax, %cr4 # Apply the extended CPU controls.

    movl trampoline_root-trampoline_start, %eax # Read the kernel page-table address.
    movl %eax, %cr3 # Load the kernel page tables.

    movl $0xc0000080, %ecx # Select the extended feature register.
    rdmsr # Read the selected CPU register.
    orl $0x900, %eax # Enable long mode and non-executable pages.
    wrmsr # Apply the extended features.

    movl %cr0, %eax # Read the primary CPU controls.
    andl $0xfffffff3, %eax # Allow floating-point instructions.
    orl $0x80010003, %eax # Enable paging, protection, and FPU monitoring.
    movl %eax, %cr0 # Apply the primary CPU controls.
    ljmpl *trampoline_jump-trampoline_start # Enter the 64-bit code segment.

.code64 # Assemble for 64-bit mode.

trampoline_long:

    movw $16, %ax # Select the kernel data segment.
    movw %ax, %ds # Load the data segment.
    movw %ax, %es # Load the extra data segment.
    movw %ax, %ss # Load the stack segment.

    movq trampoline_stack-trampoline_start(%rbx), %rsp # Switch to this CPU's stack.
    xorq %rbp, %rbp # Clear the frame pointer.

    movq trampoline_argument-trampoline_start(%rbx), %rcx # Pass this CPU's core record.
    subq $32, %rsp # Reserve Microsoft x64 shadow space.
    callq *trampoline_entry-trampoline_start(%rbx) # Call the secondary CPU entry point.

1:

    cli # Disable maskable interrupts.
    hlt # Halt this CPU.
    jmp 1b # Stay in the halt loop.

.p2align 3 # Align the table to eight bytes.

trampoline_gdt:

    .quad 0, 0x00af9a000000ffff, 0x00cf92000000ffff # Null, kernel code, and data segments.

trampoline_gdtr:

    .word 23 # Segment-table size minus one.
    .long 0 # Segment-table address, patched at startup.

trampoline_jump:

    .long 0 # 64-bit entry address, patched at startup.
    .word 8 # Kernel code segment selector.

.p2align 3 # Align the startup fields to eight bytes.

trampoline_root:

    .quad 0 # Kernel page-table address.

trampoline_stack:

    .quad 0 # Stack top for this CPU.

trampoline_entry:

    .quad 0 # Secondary CPU entry point.

trampoline_argument:

    .quad 0 # Core record passed to the entry point.

trampoline_end:
