// Owned DW_CFA_def_cfa_register witnesses. This image is inspected, never run.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _cfa_register_agree
_cfa_register_agree:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa_register x29
    bl _cfa_register_sink
    ldp x29, x30, [sp], #16
    ret
.cfi_endproc

.globl _cfa_register_bad_lr
_cfa_register_bad_lr:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
    mov x29, sp
.cfi_def_cfa_register x29
.cfi_same_value x30
    bl _cfa_register_sink
    ldp x29, x30, [sp], #16
    ret
.cfi_endproc

.globl _cfa_register_sink
_cfa_register_sink:
    nop
    ret
