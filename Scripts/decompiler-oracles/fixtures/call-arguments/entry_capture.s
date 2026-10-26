.text
.p2align 2

.globl _capture_fixed_direct
_capture_fixed_direct:
    adrp x9, _fixed_direct_x0@PAGE
    str x0, [x9, _fixed_direct_x0@PAGEOFF]
    adrp x9, _fixed_direct_d0@PAGE
    str d0, [x9, _fixed_direct_d0@PAGEOFF]
    adrp x9, _fixed_direct_x1@PAGE
    str x1, [x9, _fixed_direct_x1@PAGEOFF]
    ret

.globl _capture_fixed_indirect
_capture_fixed_indirect:
    adrp x9, _fixed_indirect_x0@PAGE
    str x0, [x9, _fixed_indirect_x0@PAGEOFF]
    adrp x9, _fixed_indirect_d0@PAGE
    str d0, [x9, _fixed_indirect_d0@PAGEOFF]
    adrp x9, _fixed_indirect_x1@PAGE
    str x1, [x9, _fixed_indirect_x1@PAGEOFF]
    adrp x9, _fixed_indirect_x8@PAGE
    str x8, [x9, _fixed_indirect_x8@PAGEOFF]
    ret

.globl _capture_variadic_direct
_capture_variadic_direct:
    adrp x9, _variadic_direct_x0@PAGE
    str x0, [x9, _variadic_direct_x0@PAGEOFF]
    adrp x9, _variadic_direct_d0@PAGE
    str d0, [x9, _variadic_direct_d0@PAGEOFF]
    ldr w10, [sp]
    adrp x9, _variadic_direct_stack0@PAGE
    str w10, [x9, _variadic_direct_stack0@PAGEOFF]
    ldr d16, [sp, #8]
    adrp x9, _variadic_direct_stack8@PAGE
    str d16, [x9, _variadic_direct_stack8@PAGEOFF]
    ldr x10, [sp, #16]
    adrp x9, _variadic_direct_stack16@PAGE
    str x10, [x9, _variadic_direct_stack16@PAGEOFF]
    ret

.globl _capture_variadic_indirect
_capture_variadic_indirect:
    adrp x9, _variadic_indirect_x0@PAGE
    str x0, [x9, _variadic_indirect_x0@PAGEOFF]
    adrp x9, _variadic_indirect_d0@PAGE
    str d0, [x9, _variadic_indirect_d0@PAGEOFF]
    ldr w10, [sp]
    adrp x9, _variadic_indirect_stack0@PAGE
    str w10, [x9, _variadic_indirect_stack0@PAGEOFF]
    ldr d16, [sp, #8]
    adrp x9, _variadic_indirect_stack8@PAGE
    str d16, [x9, _variadic_indirect_stack8@PAGEOFF]
    ldr x10, [sp, #16]
    adrp x9, _variadic_indirect_stack16@PAGE
    str x10, [x9, _variadic_indirect_stack16@PAGEOFF]
    adrp x9, _variadic_indirect_x8@PAGE
    str x8, [x9, _variadic_indirect_x8@PAGEOFF]
    ret

.subsections_via_symbols
