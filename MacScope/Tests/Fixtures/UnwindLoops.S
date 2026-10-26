// Owned scalar loop shape adapted from MacScope A64Oracle control_flow.s.
// CMP/B.EQ replaces CBZ; W ADDS replaces X ADD. Inspect only, never execute.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.macro sum name, count, expected
.globl _loop_\name
_loop_\name:
    mov x0, #\count
    mov x1, #0
    cmp w0, #0
    b.eq Lexit_\name
Lhead_\name:
    adds w1, w1, w0
    subs w0, w0, #1
    b.ne Lhead_\name
Lexit_\name:
    cmp w1, #\expected
    b.eq Lret_\name
    nop
Lret_\name:
    ret
Lend_\name:
.endmacro
sum zero, 0, 0
sum one, 1, 1
sum three, 3, 6
.globl _loop_unknown
_loop_unknown:
    mov x1, #0
    cmp w0, #0
    b.eq Lunknown_ret
Lunknown_head:
    adds w1, w1, w0
    subs w0, w0, #1
    b.ne Lunknown_head
Lunknown_ret:
    ret
Lend_unknown:
.globl _loop_stable
_loop_stable:
Lstable_head:
    cmp x8, #0
    b.ne Lstable_head
    ret
Lend_stable:
.globl _loop_bad_rule
_loop_bad_rule:
    sub sp, sp, #16
    mov x0, #3
Lbad_rule_head:
    subs w0, w0, #1
    b.ne Lbad_rule_head
    add sp, sp, #16
    ret
Lend_bad_rule:
.globl _loop_unknown_recovery
_loop_unknown_recovery:
    mov x9, x19
    mov x10, x20
    mov x0, #2
Lunknown_recovery_head:
    mov x19, #7
    add w20, w8, #0
    subs x0, x0, #1
    b.ne Lunknown_recovery_head
    mov x19, x9
    mov x20, x10
    ret
Lend_unknown_recovery:
.globl _loop_possible_only
_loop_possible_only:
    mov x9, x19
    cmp x0, #0
    b.eq Lpossible_head
    b Lpossible_restore
Lpossible_head:
    mov x19, #7
    subs x0, x0, #1
    b.ne Lpossible_head
Lpossible_restore:
    mov x19, x9
    ret
Lend_possible_only:
.globl _loop_no_exit
_loop_no_exit:
    mov x0, #0
Lno_exit_head:
    cmp x0, #0
    b.eq Lno_exit_head
    ret
Lend_no_exit:
.globl _loop_multiple_entry
_loop_multiple_entry:
    b.eq Lmiddle
Lmulti_head:
    nop
Lmiddle:
    nop
    b.ne Lmulti_head
    ret
Lend_multiple_entry:
.globl _loop_multiple_backedges
_loop_multiple_backedges:
Lmulti_first:
    nop
    b.ne Lmulti_first
Lmulti_second:
    nop
    b.ne Lmulti_second
    ret
Lend_multiple_backedges:
.globl _loop_call_inside
_loop_call_inside:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
Lcall_head:
    bl _loop_sink
    b.ne Lcall_head
    ldp x29, x30, [sp], #16
    ret
Lend_call_inside:
.globl _loop_frame_after
_loop_frame_after:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
.cfi_offset x30, -8
    mov x29, sp
.cfi_def_cfa x29, 16
    mov x0, #2
Lframe_head:
    subs w0, w0, #1
    b.ne Lframe_head
    bl _loop_sink
    ldp x29, x30, [sp], #16
    ret
.cfi_endproc
.globl _loop_fde_bad
_loop_fde_bad:
.cfi_startproc
.cfi_def_cfa sp, 0
.cfi_escape 0x08, 0x13
    stp x29, x30, [sp, #-16]!
.cfi_def_cfa_offset 16
.cfi_offset x29, -16
    mov x29, sp
.cfi_def_cfa x29, 16
.cfi_same_value x30
    mov x0, #2
Lfde_head:
    subs w0, w0, #1
    b.ne Lfde_head
    bl _loop_sink
    ldp x29, x30, [sp], #16
    ret
.cfi_endproc
.globl _loop_sink
_loop_sink:
    nop
    ret
Lend_sink:
.section __LD,__compact_unwind,regular,debug
.p2align 3
.macro compact name, encoding=0x02000000
.quad _loop_\name
.long Lend_\name-_loop_\name
.long \encoding
.quad 0, 0
.endmacro
compact zero
compact one
compact three
compact unknown
compact stable
compact bad_rule, 0x02002000
compact unknown_recovery
compact possible_only
compact no_exit
compact multiple_entry
compact multiple_backedges
compact call_inside, 0x04000000
compact sink
.subsections_via_symbols
