// Owned, SDK-free assembly witnesses. Not claimed executed through MacScope.
.text
.p2align 2
.globl _audit_phi_select
_audit_phi_select:
    cbz x0, 1f
    mov x1, #1
    b 2f
1:  mov x1, #2
2:  mov x0, x1
    ret

.p2align 2
.globl _audit_loop_sum
_audit_loop_sum:
    mov x1, #0
    cbz x0, 2f
1:  add x1, x1, x0
    subs x0, x0, #1
    b.ne 1b
2:  mov x0, x1
    ret

.p2align 2
.globl _audit_vector_loop
_audit_vector_loop:
    cbz x3, 2f
1:  ldr q0, [x1], #16
    ldr q1, [x2], #16
    eor v0.16b, v0.16b, v1.16b
    str q0, [x0], #16
    subs x3, x3, #1
    b.ne 1b
2:  ret
