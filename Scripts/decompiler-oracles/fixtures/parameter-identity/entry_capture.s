.text
.p2align 2

.globl _capture_mixed
_capture_mixed:
    adrp x9, _mixed_w0@PAGE
    str w0, [x9, _mixed_w0@PAGEOFF]
    adrp x9, _mixed_d0@PAGE
    str d0, [x9, _mixed_d0@PAGEOFF]
    adrp x9, _mixed_s1@PAGE
    str s1, [x9, _mixed_s1@PAGEOFF]
    adrp x9, _mixed_x1@PAGE
    str x1, [x9, _mixed_x1@PAGEOFF]
    ret

.globl _capture_bank_collision
_capture_bank_collision:
    adrp x9, _collision_d0@PAGE
    str d0, [x9, _collision_d0@PAGEOFF]
    adrp x9, _collision_x0@PAGE
    str x0, [x9, _collision_x0@PAGEOFF]
    ret

.globl _capture_ninth_integer
_capture_ninth_integer:
    ldr x10, [sp]
    adrp x9, _ninth_stack0@PAGE
    str x10, [x9, _ninth_stack0@PAGEOFF]
    adrp x9, _ninth_x8_observation@PAGE
    str x8, [x9, _ninth_x8_observation@PAGEOFF]
    ret

.globl _capture_packed_chars
_capture_packed_chars:
    ldrb w10, [sp]
    adrp x9, _chars_stack0@PAGE
    strb w10, [x9, _chars_stack0@PAGEOFF]
    ldrb w10, [sp, #1]
    adrp x9, _chars_stack1@PAGE
    strb w10, [x9, _chars_stack1@PAGEOFF]
    ret

.globl _capture_shared_nsaa
_capture_shared_nsaa:
    ldrb w10, [sp]
    adrp x9, _shared_stack0@PAGE
    strb w10, [x9, _shared_stack0@PAGEOFF]
    adrp x9, _shared_d0@PAGE
    str d0, [x9, _shared_d0@PAGEOFF]
    ldr d9, [sp, #8]
    adrp x9, _shared_stack8@PAGE
    str d9, [x9, _shared_stack8@PAGEOFF]
    ldrb w10, [sp, #16]
    adrp x9, _shared_stack16@PAGE
    strb w10, [x9, _shared_stack16@PAGEOFF]
    ret

.globl _capture_independent_bank_spill
_capture_independent_bank_spill:
    ldr d9, [sp]
    adrp x9, _independent_stack0@PAGE
    str d9, [x9, _independent_stack0@PAGEOFF]
    adrp x9, _independent_w0@PAGE
    str w0, [x9, _independent_w0@PAGEOFF]
    ldr d9, [sp, #8]
    adrp x9, _independent_stack8@PAGE
    str d9, [x9, _independent_stack8@PAGEOFF]
    adrp x9, _independent_x1@PAGE
    str x1, [x9, _independent_x1@PAGEOFF]
    ret

.globl _capture_scalar_returns
_capture_scalar_returns:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _return_w0
    adrp x9, _returned_w0@PAGE
    str w0, [x9, _returned_w0@PAGEOFF]
    bl _return_x0
    adrp x9, _returned_x0@PAGE
    str x0, [x9, _returned_x0@PAGEOFF]
    bl _return_s0
    adrp x9, _returned_s0@PAGE
    str s0, [x9, _returned_s0@PAGEOFF]
    bl _return_d0
    adrp x9, _returned_d0@PAGE
    str d0, [x9, _returned_d0@PAGEOFF]
    ldp x29, x30, [sp], #16
    ret

.globl _capture_large_return
_capture_large_return:
    adrp x9, _large_hidden_x8@PAGE
    str x8, [x9, _large_hidden_x8@PAGEOFF]
    adrp x9, _large_formal_x0@PAGE
    str x0, [x9, _large_formal_x0@PAGEOFF]
    str x0, [x8]
    mov x10, #0x2222
    str x10, [x8, #8]
    mov x10, #0x3333
    str x10, [x8, #16]
    ret

.subsections_via_symbols
