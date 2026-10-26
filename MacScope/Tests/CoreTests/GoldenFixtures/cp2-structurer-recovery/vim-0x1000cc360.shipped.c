int64_t sub_0x00000001000cc360(int64_t arg0, int64_t arg1, int64_t arg2) {
    // entry 0x00000001000cc360; stack frame 0xb0 bytes; calls sub_0x0000000100107e28, sub_0x0000000100107d9c, sub_0x00000001000cd100, sub_0x0000000100091a54, sub_0x0000000100110208, sub_0x0000000100036d38, sub_0x0000000100049eac, sub_0x000000010004602c, sub_0x00000001001427fc, sub_0x0000000100199218, sub_0x00000001000e3da4, sub_0x00000001000e3d9c, sub_0x00000001002075d4, sub_0x00000001000ce000, sub_0x0000000100206b80, sub_0x000000010006c914, sub_0x0000000100206440, sub_0x0000000100206468, sub_0x0000000100110d40, sub_0x0000000100106fa8, sub_0x00000001000696ec, sub_0x000000010020a768, sub_0x0000000100105c44, sub_0x0000000100069140, sub_0x0000000100036dcc, sub_0x000000010011c890, sub_0x0000000100015754, sub_0x00000001000e3db0, sub_0x00000001001207b4
    int32_t local_4;
    int32_t local_8;
    int32_t local_c;
    int64_t local_10;
    int32_t local_1c;
    int64_t local_20;
    int64_t local_28;
    int64_t local_30;
    int64_t local_38;
    int32_t local_44;
    int64_t local_48;
    int64_t local_50;
    int64_t local_58;
    int64_t local_60;
    int64_t local_68;
    int64_t local_70;
    int64_t local_78;
    int64_t local_80;
    int64_t local_88;
    int64_t local_90;
    int64_t local_98;
    __pacibsp();
    __stack_alloc(0xb0); // allocates 0xb0 stack bytes
    local_50, local_58 = x28_0, x27_0; // saves register pair
    local_60, local_68 = x26_0, x25_0; // saves register pair
    local_70, local_78 = x24_0, x23_0; // saves register pair
    local_80, local_88 = x22_0, x21_0; // saves register pair
    local_90, local_98 = x20_0, x19_0; // saves register pair
    __save_pair(x29_0, x30_0, stack[0xa0]); // saves register pair
    x29_1 = sp_1 + 0xa0;
    x27_1 = arg2;
    x25_1 = arg1;
    w21_1 = 0x0;
    tmp0 = 0xa;
    __compare((uint32_t)arg1, 0xa); // sets condition flags
    tmp1 = ((uint32_t)arg1 < 0xa) ? (uint32_t)arg1 : tmp0; // conditional select
    local_30 = (uint64_t)(uint32_t)tmp1; // stack store
    tmp2 = (int32_t)tmp1;
    local_20, local_28 = arg0, tmp2; // saves register pair
    tmp3 = (uint32_t)arg2 - 0x4;
    local_1c = tmp3; // stack store
    tmp4 = (uint32_t)arg2 - 0x2;
    local_c = tmp4; // stack store
    tmp5 = (uint32_t)arg2 + 0x1;
    local_4 = tmp5; // stack store
    tmp6 = (uint32_t)arg2;
    local_10 = (uint64_t)(uint32_t)tmp6; // stack store
    x26_1 = __adrp(0x1002b2000); // Page-relative address
    x26_2 = x26_1 + 0x838;
    x20_1 = __adrp(0x1002b2000); // Page-relative address
    x20_2 = x20_1 + 0x618;
    local_8 = (uint32_t)arg1; // stack store
    tmp7 = *(x26_2);
    tmp8 = __adrp(0x1002b2000); // Page-relative address
    tmp9 = tmp8 + 0x840;
    tmp10 = *(tmp9);
    tmp11 = (int32_t)(uint32_t)tmp7;
    __compare(tmp11, tmp10); // sets condition flags
    __conditional_compare_gt(tmp10, 0x0, 0x4);
    w19_1 = ((tmp11 > tmp10) && (tmp10 > 0x0)) ? (uint32_t)tmp10 : (uint32_t)tmp7; // conditional select
    w24_1 = *(x20_2);
    x22_1 = __adrp(0x1002ac000); // Page-relative address
    tmp12 = 0x1;
    *(x22_1 + 0x290) = (uint64_t)(uint32_t)tmp12;
    x0_1 = sub_0x0000000100107e28(arg0, arg1, arg2); // call
    *(x22_1 + 0x290) = 0x0;
    tmp13 = __adrp(0x1002b2000); // Page-relative address
    tmp14 = tmp13 + 0x668;
    tmp15 = *(tmp14);
    tmp16 = __adrp(0x1002ac000); // Page-relative address
    *(tmp16 + 0x298) = tmp15;
    tmp17 = __adrp(0x100284000); // Page-relative address
    tmp18 = tmp17 + 0x738;
    tmp19 = *(tmp18);
    if (((tmp19 >> 0x3) & 0x1) == 0x0) { // conditional branch
        tmp20 = *(tmp15 + 0x344);
        tmp21 = *(tmp15 + 0x14c);
        tmp22 = *(tmp15 + 0x410);
        tmp23 = tmp21 + tmp20;
        tmp24 = tmp23 + tmp22;
    } else {
        tmp25 = *(x20_2);
    }
    x20_3 = __adrp(0x1002ac000); // Page-relative address
    tmp26 = __adrp(0x1002ac000); // Page-relative address
    *(tmp26 + 0x2a0) = tmp25;
    tmp27 = *(tmp15 + 0x150);
    tmp28 = __adrp(0x1002ac000); // Page-relative address
    *(tmp28 + 0x2a4) = tmp27;
    tmp29 = *(tmp15 + 0x160);
    tmp30 = __adrp(0x1002ac000); // Page-relative address
    *(tmp30 + 0x2a8) = tmp29;
    tmp31 = *(tmp15 + 0x348);
    tmp32 = __adrp(0x1002ac000); // Page-relative address
    *(tmp32 + 0x2ac) = tmp31;
    tmp33 = *(tmp15 + 0x164);
    tmp34 = __adrp(0x1002ac000); // Page-relative address
    *(tmp34 + 0x2b0) = tmp33;
    tmp35 = __adrp(0x1002b2000); // Page-relative address
    tmp36 = tmp35 + 0x608;
    tmp37 = *(tmp36);
    if (tmp37 == 0x0) goto 0x1000cc4b0; // conditional branch
    tmp38 = *(tmp37 + 0x4ec);
    if (tmp38 != 0x0) goto 0x1000cc4bc; // conditional branch
    tmp39 = *(tmp37 + 0x18);
    if (tmp39 != 0x0) goto 0x1000cc4a0; // conditional branch
    w23_1 = 0x0;
    w22_1 = 0x0;
    __branch(0x1000cc4fc); // unconditional branch
    tmp40 = *(tmp39 + 0x14c);
    tmp41 = *(tmp39 + 0x410);
    tmp42 = tmp41 + tmp40;
    tmp43 = *(tmp15 + 0x14c);
    tmp44 = *(tmp15 + 0x410);
    tmp45 = tmp44 + tmp43;
    __compare(tmp42, tmp45); // sets condition flags
    if (tmp42 >= tmp45) goto 0x1000cc4e8; // conditional branch
    tmp46 = *(tmp39 + 0x150);
    w22_2 = tmp46 + tmp42;
    __branch(0x1000cc4f8); // unconditional branch
    w22_3 = 0x0;
    tmp47 = tmp45 + tmp46;
    __compare(tmp42, tmp47); // sets condition flags
    w24_2 = (tmp42 > tmp47) ? tmp42 : w24_1; // conditional select
    w23_2 = 0x1;
    tmp48, tmp49 = local_28, local_30; // restores register pair; recovered stack[0x28], stack[0x30]
    tmp50 = __adrp(0x1002ac000); // Page-relative address
    *(tmp50 + 0x2b4) = (uint32_t)tmp49;
    tmp51 = __adrp(0x1002b2000); // Page-relative address
    tmp52 = tmp51 + 0x830;
    tmp53 = *(tmp52);
    __compare(tmp53, 0x1); // sets condition flags
    __conditional_compare_ge(tmp53, tmp48, 0x0);
    if ((tmp53 < 0x1) || (tmp53 >= tmp48)) goto 0x1000cc52c; // conditional branch
    tmp54 = __adrp(0x1002ac000); // Page-relative address
    *(tmp54 + 0x2b4) = (uint32_t)tmp53;
    tmp55 = tmp53;
    tmp56 = tmp25 + 0x2;
    tmp57 = w24_2 - (uint32_t)tmp55;
    __compare(tmp56, tmp57); // sets condition flags
    if (tmp56 < tmp57) goto 0x1000cc570; // conditional branch
    tmp58 = tmp25 - w22_3;
    tmp59 = w24_2 - w22_3;
    tmp60 = tmp59 + (tmp59 >> 0x1f);
    __compare(tmp58, tmp60 >> 0x1); // sets condition flags
    if (tmp58 <= (tmp60 >> 0x1)) goto 0x1000cc570; // conditional branch
    if (((tmp19 >> 0x3) & 0x1) != 0x0) goto 0x1000cc5f0; // conditional branch
    tmp61 = *(tmp15 + 0x344);
    tmp62 = *(tmp15 + 0x338);
    tmp63 = tmp61 - tmp62;
    __compare(tmp63, 0x2); // sets condition flags
    tmp64 = 0x2;
    tmp65 = (tmp63 < 0x2) ? tmp63 : tmp64; // conditional select
    __branch(0x1000cc5f4); // unconditional branch
    if (((tmp64 >> 0x3) & 0x1) == 0x0) { // conditional branch
        x0_2 = sub_0x0000000100107d9c(x0_1); // call
        tmp66 = __adrp(0x1002b2000); // Page-relative address
        tmp67 = tmp66 + 0x668;
        tmp68 = *(tmp67);
        tmp69 = *(tmp68 + 0x338);
        tmp70 = *(tmp68 + 0x330);
        tmp71 = *(tmp68 + 0x344);
        tmp72 = tmp70 + tmp69;
        tmp73 = tmp72 - tmp71;
        __compare(tmp73, 0x3); // sets condition flags
        tmp74 = 0x3;
        tmp75 = (tmp73 < 0x3) ? tmp73 : tmp74; // conditional select
        tmp76 = __adrp(0x1002ac000); // Page-relative address
        tmp77 = *(tmp76 + 0x2a0);
        tmp78 = __adrp(0x1002b2000); // Page-relative address
        tmp79 = tmp78 + 0x830;
        tmp80 = *(tmp79);
    } else {
        tmp81 = 0x0;
    }
    tmp82 = tmp77 + tmp81;
    tmp83 = w24_2 - tmp82;
    __compare(tmp83, (uint32_t)x25_1); // sets condition flags
    tmp84 = (tmp83 < (uint32_t)x25_1) ? tmp83 : (uint32_t)x25_1; // conditional select
    tmp85 = (int32_t)tmp84;
    *(x20_3 + 0x2b8) = tmp82;
    tmp86 = __adrp(0x1002ac000); // Page-relative address
    *(tmp86 + 0x2b4) = tmp84;
    __compare(tmp80, 0x1); // sets condition flags
    __conditional_compare_ge(tmp80, tmp85, 0x0);
    if ((tmp80 < 0x1) || (tmp80 >= tmp85)) goto 0x1000cc624; // conditional branch
    __branch(0x1000cc63c); // unconditional branch
    tmp87 = 0x0;
    tmp88 = tmp77 - tmp87;
    tmp89 = tmp87 + (uint32_t)x25_1;
    tmp90 = tmp77 - tmp89;
    tmp91 = (tmp77 < tmp89) ? 0x0 : tmp90; // conditional select
    tmp92 = (tmp77 < tmp89) ? tmp88 : (uint32_t)x25_1; // conditional select
    *(x20_3 + 0x2b8) = tmp91;
    tmp93 = __adrp(0x1002ac000); // Page-relative address
    *(tmp93 + 0x2b4) = tmp92;
    tmp94 = (int32_t)tmp92;
    __compare(tmp80, 0x1); // sets condition flags
    __conditional_compare_ge(tmp80, tmp94, 0x0);
    if ((tmp80 >= 0x1) && (tmp80 < tmp94)) goto 0x1000cc630; // conditional branch
    __compare(tmp92, 0x1); // sets condition flags
    if (tmp92 < 0x1) goto 0x1000cd0e0; // conditional branch
    __branch(0x1000cc648); // unconditional branch
    tmp95 = tmp92 - (uint32_t)tmp80;
    tmp96 = tmp95 + tmp91;
    *(x20_3 + 0x2b8) = tmp96;
    tmp97 = tmp80;
    tmp98 = __adrp(0x1002ac000); // Page-relative address
    *(tmp98 + 0x2b4) = (uint32_t)tmp97;
    __compare((uint32_t)x25_1, 0x2); // sets condition flags
    if ((uint32_t)x25_1 < 0x2) goto 0x1000cc658; // conditional branch
    __compare((uint32_t)tmp97, 0x1); // sets condition flags
    if ((uint32_t)tmp97 == 0x1) goto 0x1000cd0e0; // conditional branch
    __compare((uint32_t)tmp97, w22_3); // sets condition flags
    __conditional_compare_gt(tmp96, w22_3, 0x0);
    tmp99 = (((uint32_t)tmp97 <= w22_3) || (tmp96 >= w22_3)) ? 0x0 : w23_2; // conditional select
    if (tmp99 == 0x1) { // conditional branch
        *(x20_3 + 0x2b8) = w22_3;
        tmp100 = tmp77 - w22_3;
        tmp101 = __adrp(0x1002ac000); // Page-relative address
        *(tmp101 + 0x2b4) = tmp100;
    }
    tmp102 = __adrp(0x1002ac000); // Page-relative address
    tmp103 = local_20; // recovered stack[0x20]
    *(tmp102 + 0x290) = tmp103;
    tmp104 = __adrp(0x1002ac000); // Page-relative address
    *(tmp104 + 0x2bc) = (uint32_t)x25_1;
    x0_3 = sub_0x00000001000cd100(x0_2); // call
    tmp105 = __adrp(0x1002ac000); // Page-relative address
    tmp106 = *(tmp105 + 0x2c0);
    tmp107 = __adrp(0x1002b2000); // Page-relative address
    tmp108 = tmp107 + 0x840;
    tmp109 = *(tmp108);
    __compare(tmp109, (uint32_t)tmp106); // sets condition flags
    __conditional_compare_lt(tmp109, 0x0, 0x4);
    w20_1 = ((tmp109 < (uint32_t)tmp106) && (tmp109 > 0x0)) ? (uint32_t)tmp109 : tmp106; // conditional select
    tmp110 = __adrp(0x100284000); // Page-relative address
    tmp111 = tmp110 + 0x738;
    tmp112 = *(tmp111);
    if (((tmp112 >> 0x3) & 0x1) == 0x0) { // conditional branch
        tmp113 = __adrp(0x1002b2000); // Page-relative address
        tmp114 = tmp113 + 0x668;
        tmp115 = *(tmp114);
        tmp116 = *(tmp115 + 0x348);
        tmp117 = *(tmp115 + 0x164);
        tmp118 = tmp116 / tmp117;
        tmp119 = tmp116 - tmp118 * tmp117;
        tmp120 = *(tmp115 + 0x160);
        w0_1 = tmp120 + tmp119;
    } else {
        x0_4 = sub_0x0000000100091a54(w0_1); // call
    }
    tmp121 = __adrp(0x1002ac000); // Page-relative address
    w23_3 = *(tmp121 + 0x2b4);
    tmp122 = w23_3 < (uint32_t)x25_1; // compare to bool
    tmp123 = (w23_3 >= (uint32_t)x25_1) ? w20_1 : w20_1 + 0x1; // conditional select
    tmp124 = __adrp(0x1002ac000); // Page-relative address
    *(tmp124 + 0x2c4) = tmp122;
    __compare(tmp123, w19_1); // sets condition flags
    tmp125 = (tmp123 > w19_1) ? tmp123 : w19_1; // conditional select
    tmp126 = (int32_t)(uint32_t)x0_4;
    tmp127 = __adrp(0x100283000); // Page-relative address
    tmp128 = tmp127 + 0xa60;
    tmp129 = *(tmp128);
    tmp130 = *(x26_2);
    tmp131 = tmp129 - tmp130;
    __compare(tmp131, (int32_t)(uint32_t)x0_4); // sets condition flags
    if (tmp131 > (int32_t)(uint32_t)x0_4) goto 0x1000cc740; // conditional branch
    tmp132 = tmp129 - (uint32_t)tmp123;
    __compare(tmp132, tmp126); // sets condition flags
    if (tmp132 <= tmp126) goto 0x1000cc854; // conditional branch
    tmp133 = w23_3 < (uint32_t)x25_1; // compare to bool
    tmp134 = __adrp(0x1002ac000); // Page-relative address
    *(tmp134 + 0x2c8) = (uint32_t)x0_4;
    tmp135 = (w23_3 >= (uint32_t)x25_1) ? 0x0 : ~0x0; // conditional select
    tmp136 = tmp129 - tmp126;
    tmp137 = tmp136 - (uint64_t)(uint32_t)tmp133;
    x16_1 = __adrp(0x1002ac000); // Page-relative address
    *(x16_1 + 0x2cc) = (uint32_t)tmp137;
    tmp138 = __adrp(0x1002ac000); // Page-relative address
    tmp139 = *(tmp138 + 0x2d0);
    tmp140 = __adrp(0x1002ac000); // Page-relative address
    tmp141 = *(tmp140 + 0x2d4);
    tmp142 = tmp139 + tmp141;
    tmp143 = tmp123 + tmp142;
    tmp144 = tmp143 + 0x1;
    __compare(tmp130, (uint32_t)(uint32_t)tmp137); // sets condition flags
    if (tmp130 >= (uint32_t)(uint32_t)tmp137) goto 0x1000cc7bc; // conditional branch
    __compare(tmp144, (uint32_t)tmp137); // sets condition flags
    if (tmp144 >= (uint32_t)tmp137) goto 0x1000cc7bc; // conditional branch
    __compare(tmp130, (uint32_t)tmp144); // sets condition flags
    tmp145 = (tmp130 > (uint32_t)tmp144) ? tmp130 : (uint64_t)(uint32_t)tmp144; // conditional select
    *(x16_1 + 0x2cc) = (uint32_t)tmp145;
    tmp146 = __adrp(0x1002b2000); // Page-relative address
    tmp147 = tmp146 + 0x840;
    tmp148 = *(tmp147);
    __compare(tmp148, 0x1); // sets condition flags
    if (tmp148 < 0x1) goto 0x1000cc92c; // conditional branch
    __compare(tmp148, (int32_t)(uint32_t)tmp145); // sets condition flags
    if (tmp148 < (int32_t)(uint32_t)tmp145) goto 0x1000cc928; // conditional branch
    __branch(0x1000cc92c); // unconditional branch
    __compare(tmp145, tmp126); // sets condition flags
    if (tmp145 < tmp126) goto 0x1000cc7cc; // conditional branch
    __compare((uint32_t)x0_4, tmp123); // sets condition flags
    if ((uint32_t)x0_4 <= tmp123) goto 0x1000cc92c; // conditional branch
    __compare(tmp145, (uint32_t)tmp123); // sets condition flags
    if (tmp145 < (uint32_t)tmp123) goto 0x1000cc800; // conditional branch
    tmp149 = (uint32_t)tmp148 - tmp123;
    tmp150 = tmp149 + (uint32_t)tmp135;
    tmp151 = __adrp(0x1002b2000); // Page-relative address
    tmp152 = tmp151 + 0x668;
    tmp153 = *(tmp152);
    tmp154 = *(tmp153 + 0x160);
    if (tmp154 > tmp150) { // conditional branch
        w0_2 = tmp150 & ~(tmp150 >> 0x1f);
        tmp155 = __adrp(0x1002ac000); // Page-relative address
        *(tmp155 + 0x2c8) = w0_2;
    }
    tmp156 = tmp148 - (uint32_t)w0_2;
    tmp157 = tmp156 + tmp135;
    tmp158 = (int32_t)(uint32_t)tmp157;
    *(x16_1 + 0x2cc) = (uint32_t)tmp157;
    __compare(tmp158, tmp145); // sets condition flags
    if (tmp158 >= tmp145) goto 0x1000cc8d0; // conditional branch
    *(x16_1 + 0x2cc) = (uint32_t)tmp145;
    tmp159 = __adrp(0x1002b2000); // Page-relative address
    tmp160 = tmp159 + 0x840;
    tmp161 = *(tmp160);
    if (tmp161 >= 0x1 && tmp161 < (int32_t)(uint32_t)tmp145) { // conditional branch
        *(x16_1 + 0x2cc) = (uint32_t)tmp161;
        tmp162 = tmp161;
    }
    tmp163 = tmp148 - (int32_t)w0_2;
    __compare(tmp163, (int32_t)(uint32_t)tmp162); // sets condition flags
    if (tmp163 > (int32_t)(uint32_t)tmp162) goto 0x1000cc92c; // conditional branch
    tmp164 = (uint32_t)tmp163 - 0x1;
    __branch(0x1000cc928); // unconditional branch
    __compare((uint64_t)(uint32_t)tmp164, (uint32_t)(uint32_t)tmp161); // sets condition flags
    x16_2 = __adrp(0x1002ac000); // Page-relative address
    if ((uint64_t)(uint32_t)tmp164 >= (uint32_t)(uint32_t)tmp161) goto 0x1000cc894; // conditional branch
    tmp165 = __adrp(0x1002ac000); // Page-relative address
    *(tmp165 + 0x2c8) = 0x0;
    tmp166 = tmp164 - 0x1;
    *(x16_2 + 0x2cc) = tmp166;
    tmp167 = __adrp(0x1002b2000); // Page-relative address
    tmp168 = tmp167 + 0x840;
    tmp169 = *(tmp168);
    __compare(tmp169, 0x1); // sets condition flags
    if (tmp169 < 0x1) goto 0x1000cc92c; // conditional branch
    tmp170 = (int32_t)tmp166;
    __compare(tmp169, tmp170); // sets condition flags
    if (tmp169 < tmp170) goto 0x1000cc928; // conditional branch
    __branch(0x1000cc92c); // unconditional branch
    tmp171 = w23_3 < (uint32_t)x25_1; // compare to bool
    __compare(tmp170, tmp158); // sets condition flags
    tmp172 = (tmp170 < tmp158) ? tmp170 : tmp158; // conditional select
    tmp173 = __adrp(0x1002b2000); // Page-relative address
    tmp174 = tmp173 + 0x840;
    tmp175 = *(tmp174);
    __compare(tmp175, (int32_t)(uint32_t)tmp172); // sets condition flags
    __conditional_compare_lt(tmp175, 0x0, 0x4);
    tmp176 = ((tmp175 < (int32_t)(uint32_t)tmp172) && (tmp175 > 0x0)) ? (uint32_t)tmp175 : (uint32_t)tmp172; // conditional select
    tmp177 = (uint32_t)tmp169 - tmp176;
    tmp178 = __adrp(0x1002ac000); // Page-relative address
    *(tmp178 + 0x2c8) = tmp177;
    tmp179 = tmp176 - tmp171;
    __branch(0x1000cc928); // unconditional branch
    __compare(tmp171, (uint32_t)tmp157); // sets condition flags
    if (tmp171 >= (uint32_t)tmp157) goto 0x1000cc90c; // conditional branch
    __compare(tmp178, (uint64_t)(uint32_t)tmp176); // sets condition flags
    if (tmp178 <= (uint64_t)(uint32_t)tmp176) goto 0x1000cc90c; // conditional branch
    __compare((uint64_t)(uint32_t)tmp176, (uint32_t)tmp171); // sets condition flags
    tmp180 = ((uint64_t)(uint32_t)tmp176 > (uint32_t)tmp171) ? (uint64_t)(uint32_t)tmp176 : (uint64_t)(uint32_t)tmp171; // conditional select
    *(x16_2 + 0x2cc) = (uint32_t)tmp180;
    tmp181 = __adrp(0x1002b2000); // Page-relative address
    tmp182 = tmp181 + 0x840;
    tmp183 = *(tmp182);
    __compare(tmp183, 0x1); // sets condition flags
    if (tmp183 < 0x1) goto 0x1000cc92c; // conditional branch
    __compare(tmp183, (int32_t)(uint32_t)tmp180); // sets condition flags
    if (tmp183 < (int32_t)(uint32_t)tmp180) goto 0x1000cc928; // conditional branch
    __branch(0x1000cc92c); // unconditional branch
    tmp184 = __adrp(0x1002b2000); // Page-relative address
    tmp185 = tmp184 + 0x840;
    tmp186 = *(tmp185);
    if (tmp186 >= 0x1 && tmp186 < tmp178) { // conditional branch
        *(x16_2 + 0x2cc) = (uint32_t)tmp186;
    }
    x20_4 = __adrp(0x1002ac000); // Page-relative address
    w28_1 = *(x20_4 + 0x2e0);
    x0_5 = sub_0x0000000100110208(w0_2); // call
    *(x20_4 + 0x2e0) = (uint32_t)x27_1;
    x20_5 = __adrp(0x1002b2000); // Page-relative address
    x20_6 = x20_5 + 0x49c;
    tmp187 = __adrp(0x1002ac000); // Page-relative address
    if ((((uint32_t)x27_1 >> 0x1f) & 0x1) != 0x0) goto 0x1000cd0ac; // conditional branch
    tmp188 = __adrp(0x1002ac000); // Page-relative address
    tmp189 = *(tmp188 + 0x2bc);
    __compare((uint32_t)x27_1, tmp189); // sets condition flags
    if ((uint32_t)x27_1 >= tmp189) goto 0x1000cd0ac; // conditional branch
    x22_2 = x0_5;
    tmp190 = __adrp(0x1002ac000); // Page-relative address
    tmp191 = *(tmp190 + 0x2b4);
    tmp192 = *(tmp187 + 0x2dc);
    tmp193 = local_1c; // recovered stack[0x1c]
    __compare(tmp192, tmp193); // sets condition flags
    if (tmp192 <= tmp193) goto 0x1000cc9a4; // conditional branch
    tmp194 = x27_1;
    tmp195 = local_c; // recovered stack[0xc]
    __compare(tmp192, tmp195); // sets condition flags
    if (tmp192 <= tmp195) goto 0x1000cc9e0; // conditional branch
    tmp196 = tmp192 - tmp191;
    tmp197 = tmp196 + 0x2;
    __compare(tmp197, (uint32_t)x27_1); // sets condition flags
    tmp198 = (tmp197 < (uint32_t)x27_1) ? tmp197 : (uint32_t)x27_1; // conditional select
    __compare(tmp197, 0x0); // sets condition flags
    tmp199 = (tmp197 < 0x0) ? 0x0 : tmp198; // conditional select
    __branch(0x1000cc9e0); // unconditional branch
    tmp200 = (uint32_t)x27_1 - tmp191;
    tmp201 = tmp200 + 0x5;
    tmp202 = (uint64_t)(uint32_t)tmp198;
    __compare(tmp198, tmp201); // sets condition flags
    if (tmp198 >= tmp201) goto 0x1000cc9e0; // conditional branch
    tmp203 = tmp200 + 0x3;
    if (tmp198 < tmp203) { // conditional branch
        tmp204 = tmp191 + tmp198;
        tmp205 = tmp204 - 0x2;
        tmp206 = tmp200 + 0x1;
        __compare(tmp205, tmp206); // sets condition flags
        tmp207 = (tmp205 > tmp206) ? tmp205 : tmp200 + 0x1; // conditional select
    } else {
        tmp208 = tmp200 + 0x1;
    }
    tmp209 = w23_3 + (w23_3 >> 0x1f);
    tmp210 = tmp209 >> 0x1;
    __compare(tmp210, 0x3); // sets condition flags
    tmp211 = 0x3;
    tmp212 = (tmp210 < 0x3) ? tmp210 : tmp211; // conditional select
    __compare(tmp191, 0x3); // sets condition flags
    if (tmp191 < 0x3) goto 0x1000cca24; // conditional branch
    tmp213 = (uint32_t)x27_1 - tmp212;
    __compare(tmp208, tmp213); // sets condition flags
    if (tmp208 <= tmp213) goto 0x1000cca10; // conditional branch
    tmp214 = tmp213 & ~(tmp213 >> 0x1f);
    __branch(0x1000cca24); // unconditional branch
    tmp215 = local_4; // recovered stack[0x4]
    tmp216 = tmp215 + tmp212;
    tmp217 = tmp216 - tmp191;
    __compare(tmp214, tmp217); // sets condition flags
    tmp218 = (tmp214 > tmp217) ? tmp214 : tmp217; // conditional select
    tmp219 = tmp189 - tmp191;
    __compare(tmp218, tmp219); // sets condition flags
    tmp220 = (tmp218 < tmp219) ? tmp218 : tmp219; // conditional select
    *(tmp187 + 0x2dc) = tmp220;
    tmp221 = __adrp(0x1002ac000); // Page-relative address
    tmp222 = *(tmp221 + 0x290);
    tmp223 = local_10; // recovered stack[0x10]
    tmp224 = tmp223 + (tmp223 << 0x1);
    tmp225 = tmp222 + (tmp224 << 0x4);
    tmp226 = *(tmp225 + 0x18);
    if (tmp226 == 0x0) goto 0x1000cd0ac; // conditional branch
    tmp227 = __adrp(0x100283000); // Page-relative address
    tmp228 = tmp227 + 0xa58;
    tmp229 = *(tmp228);
    __compare(tmp229, 0xb); // sets condition flags
    if (tmp229 < 0xb) goto 0x1000cd0ac; // conditional branch
    __compare(w21_1, 0x1); // sets condition flags
    if (w21_1 > 0x1) goto 0x1000cd0ac; // conditional branch
    tmp230 = (uint32_t)x22_2 & 0x38;
    if (tmp230 == 0x0) goto 0x1000cd0ac; // conditional branch
    if ((((uint32_t)x22_2 >> 0x3) & 0x1) == 0x0) goto 0x1000cca88; // conditional branch
    tmp231 = __adrp(0x1002b2000); // Page-relative address
    tmp232 = tmp231 + 0x4e4;
    tmp233 = *(tmp232);
    if (tmp233 != 0x0) goto 0x1000cd0ac; // conditional branch
    x24_1 = x25_1;
    tmp234 = __adrp(0x1002b2000); // Page-relative address
    tmp235 = tmp234 + 0x668;
    tmp236 = *(tmp235);
    local_48 = tmp236; // stack store
    tmp237 = __adrp(0x1002b2000); // Page-relative address
    tmp238 = tmp237 + 0x680;
    tmp239 = *(tmp238);
    local_38 = tmp239; // stack store
    x25_2 = (uint64_t)(uint32_t)w21_1;
    if ((((uint32_t)x22_2 >> 0x5) & 0x1) != 0x0) goto 0x1000ccacc; // conditional branch
    w23_4 = 0x1;
    if ((((uint32_t)x22_2 >> 0x4) & 0x1) != 0x0) goto 0x1000ccad0; // conditional branch
    x21_1 = x27_1;
    w23_5 = 0x0;
    w19_2 = 0x1;
    __branch(0x1000ccadc); // unconditional branch
    w23_6 = 0x2;
    x21_2 = x27_1;
    x0_6 = sub_0x0000000100036d38(x0_5); // call
    w19_3 = 0x0;
    local_44 = w28_1; // stack store
    x27_2 = x26_2;
    tmp240 = 0x3;
    *(x20_6) = tmp240;
    tmp241 = __adrp(0x1002b2000); // Page-relative address
    tmp242 = tmp241 + 0xc90;
    tmp243 = *(tmp242);
    tmp244 = tmp243 - 0x1;
    if (tmp244 <= 0x1) { // conditional branch
        *(x20_6) = (uint32_t)tmp243;
    }
    x28_1 = __adrp(0x1002b2000); // Page-relative address
    x28_2 = x28_1 + 0x384;
    tmp245 = *(x28_2);
    tmp246 = tmp245 + 0x1;
    *(x28_2) = tmp246;
    x26_3 = __adrp(0x1002b2000); // Page-relative address
    x26_4 = x26_3 + 0x348;
    tmp247 = *(x26_4);
    tmp248 = tmp247 + 0x1;
    *(x26_4) = tmp248;
    w0_3 = 0x0;
    w1_1 = 0x0;
    x2_1 = (uint64_t)(uint32_t)w23_6;
    x0_7 = sub_0x0000000100049eac(w0_3, w1_1, x2_1); // call
    x23_1 = x0_7;
    tmp249 = *(x26_4);
    tmp250 = tmp249 - 0x1;
    *(x26_4) = tmp250;
    tmp251 = *(x28_2);
    tmp252 = tmp251 - 0x1;
    if (tmp251 < 0x1) goto 0x1000ccb60; // conditional branch
    *(x28_2) = tmp252;
    *(x20_6) = 0x0;
    tmp253 = __adrp(0x1002b2000); // Page-relative address
    tmp254 = tmp253 + 0x668;
    tmp255 = *(tmp254);
    tmp256 = *(tmp255 + 0x4ec);
    x26_5 = x27_2;
    if (tmp256 != 0x0) goto 0x1000ccb90; // conditional branch
    tmp257 = *(tmp255 + 0x19d);
    if (((tmp257 >> 0x1) & 0x1) != 0x0) goto 0x1000ccb90; // conditional branch
    x27_3 = x21_2;
    x21_3 = x25_2;
    __branch(0x1000ccd04); // unconditional branch
    x27_4 = x21_3;
    if ((uint32_t)x23_1 != 0x0) goto 0x1000ccbb8; // conditional branch
    tmp258 = __adrp(0x1002b2000); // Page-relative address
    tmp259 = tmp258 + 0x238;
    x0_8 = *(tmp259);
    tmp260 = *(x0_8 + 0x80);
    __compare(tmp260, 0x1); // sets condition flags
    if (tmp260 != 0x1) goto 0x1000ccbb8; // conditional branch
    tmp261 = *(x0_8 + 0xa0);
    if (tmp261 == 0x0) goto 0x1000cd04c; // conditional branch
    x20_7 = __adrp(0x1002b2000); // Page-relative address
    x20_8 = x20_7 + 0x348;
    tmp262 = *(x20_8);
    tmp263 = tmp262 + 0x1;
    *(x20_8) = tmp263;
    w0_4 = 0x0;
    x1_1 = 0x0;
    x2_2 = 0x0;
    x3_1 = 0x0;
    w4_1 = 0x1;
    w5_1 = 0x0;
    x6_1 = 0x0;
    x0_9 = sub_0x000000010004602c(w0_4, x1_1, x2_2, x3_1, w4_1, w5_1, x6_1); // call
    tmp264 = *(x20_8);
    tmp265 = tmp264 - 0x1;
    *(x20_8) = tmp265;
    __compare((uint32_t)x0_9, 0x1); // sets condition flags
    x21_4 = x25_2;
    if ((uint32_t)x0_9 != 0x1) goto 0x1000ccd04; // conditional branch
    x0_10 = __adrp(0x100255000); // Page-relative address
    x0_11 = x0_10 + 0xcdb;
    x1_2 = 0x0;
    x2_3 = 0x0;
    w3_1 = 0x4;
    x0_12 = sub_0x00000001001427fc(x0_11, x1_2, x2_3, w3_1); // call
    x0_13 = __adrp(0x100255000); // Page-relative address
    x0_14 = x0_13 + 0xcdf;
    x1_3 = 0x0;
    x2_4 = 0x0;
    w3_2 = 0x4;
    x0_15 = sub_0x00000001001427fc(x0_14, x1_3, x2_4, w3_2); // call
    x0_16 = __adrp(0x100252000); // Page-relative address
    x0_17 = x0_16 + 0x6;
    x1_4 = 0x0;
    x2_5 = __adrp(0x100252000); // Page-relative address
    x2_6 = x2_5 + 0x9;
    w3_3 = 0x4;
    x0_18 = sub_0x00000001001427fc(x0_17, x1_4, x2_6, w3_3); // call
    x0_19 = __adrp(0x100255000); // Page-relative address
    x0_20 = x0_19 + 0xce2;
    x1_5 = 0x0;
    x2_7 = __adrp(0x100255000); // Page-relative address
    x2_8 = x2_7 + 0xb6a;
    w3_4 = 0x4;
    x0_21 = sub_0x00000001001427fc(x0_20, x1_5, x2_8, w3_4); // call
    x0_22 = __adrp(0x10024d000); // Page-relative address
    x0_23 = x0_22 + 0x770;
    x1_6 = 0x0;
    x2_9 = 0x0;
    w3_5 = 0x4;
    x0_24 = sub_0x00000001001427fc(x0_23, x1_6, x2_9, w3_5); // call
    x24_2 = (uint64_t)(uint32_t)w19_3;
    x25_3 = x27_4;
    tmp266 = __adrp(0x1002ac000); // Page-relative address
    tmp267 = *(tmp266 + 0x290);
    tmp268 = __adrp(0x1002ac000); // Page-relative address
    tmp269 = *(tmp268 + 0x2e0);
    tmp270 = tmp269 + (tmp269 << 0x1);
    tmp271 = tmp267 + (tmp270 << 0x4);
    x28_3 = *(tmp271 + 0x18);
    tmp272 = *(x28_3);
    if (tmp272 == 0x0) goto 0x1000ccd10; // conditional branch
    x27_5 = 0x0;
    x0_25 = x28_3;
    w1_2 = 0xa;
    x0_26 = sub_0x0000000100199218(x0_25, w1_2); // call
    if (x0_26 == 0x0) goto 0x1000ccd18; // conditional branch
    x26_6 = x0_26;
    *(x0_26) = 0x0;
    x20_9 = x27_5 + 0x1;
    tmp273 = (uint32_t)x26_6 - (uint32_t)x28_3;
    w2_1 = tmp273 + 0x1;
    x0_27 = x27_5;
    x1_7 = x28_3;
    w3_6 = 0x0;
    x0_28 = sub_0x00000001000e3da4(x0_27, x1_7, w2_1, w3_6); // call
    tmp274 = 0xa;
    *(x26_6) = tmp274;
    x26_7, tmp275 = x26_6 + 0x1, *(x26_6 + 0x1);
    x27_6 = x20_9;
    x28_4 = x26_7;
    if (tmp275 != 0x0) goto 0x1000cccb4; // conditional branch
    __branch(0x1000ccd30); // unconditional branch
    x25_4 = x24_2;
    x24_3 = (uint64_t)(uint32_t)w19_3;
    __branch(0x1000ccfa4); // unconditional branch
    x20_10 = 0x0;
    __branch(0x1000ccd30); // unconditional branch
    x20_11 = x27_6 + 0x1;
    x0_29 = x27_6;
    x1_8 = x28_4;
    w2_2 = 0x0;
    w3_7 = 0x0;
    x0_30 = sub_0x00000001000e3da4(x0_29, x1_8, w2_2, w3_7); // call
    tmp276 = __adrp(0x1002b2000); // Page-relative address
    tmp277 = tmp276 + 0x238;
    tmp278 = *(tmp277);
    x0_31 = *(tmp278);
    x0_32 = sub_0x00000001000e3d9c(x0_31); // call
    __compare((uint32_t)x21_4, 0x0); // sets condition flags
    tmp279 = (uint32_t)x24_3 ^ 0x1;
    tmp280 = __adrp(0x1002b2000); // Page-relative address
    tmp281 = tmp280 + 0x668;
    x0_33 = *(tmp281);
    tmp282 = ((uint32_t)x21_4 == 0x0) ? tmp279 : 0x0 + 0x1; // conditional select
    if (((tmp282 >> 0x0) & 0x1) != 0x0) goto 0x1000ccdac; // conditional branch
    tmp283 = __adrp(0x1002b2000); // Page-relative address
    tmp284 = tmp283 + 0xc90;
    tmp285 = *(tmp284);
    __compare(x20_11, tmp285); // sets condition flags
    tmp286 = (x20_11 < tmp285) ? x20_11 : tmp285; // conditional select
    tmp287 = *(x0_33 + 0x150);
    __compare(tmp286, tmp287); // sets condition flags
    x27_7 = x25_4;
    w25_1 = local_8; // recovered stack[0x8]
    x20_12 = local_48; // recovered stack[0x48]
    w19_4 = local_44; // recovered stack[0x44]
    if (tmp286 <= tmp287) goto 0x1000ccdbc; // conditional branch
    x0_34 = tmp286;
    x0_35 = sub_0x00000001002075d4(x0_34); // call
    tmp288 = __adrp(0x1002b2000); // Page-relative address
    tmp289 = tmp288 + 0x668;
    x0_36 = *(tmp289);
    w23_7 = 0x1;
    __branch(0x1000ccdbc); // unconditional branch
    x27_8 = (uint64_t)(uint32_t)w25_1;
    w25_2 = local_8; // recovered stack[0x8]
    x20_13 = local_48; // recovered stack[0x48]
    w19_5 = local_44; // recovered stack[0x44]
    tmp290 = __adrp(0x1002b2000); // Page-relative address
    tmp291 = tmp290 + 0x238;
    tmp292 = *(tmp291);
    *(tmp292 + 0xc8) = 0x0;
    *(tmp292 + 0x1d30) = 0x0;
    tmp293 = __adrp(0x1002ac000); // Page-relative address
    tmp294 = *(tmp293 + 0x2e0);
    __compare(tmp294, w19_5); // sets condition flags
    x26_8 = __adrp(0x1002b2000); // Page-relative address
    x26_9 = x26_8 + 0x838;
    if (tmp294 != w19_5) goto 0x1000cce08; // conditional branch
    tmp295 = *(x0_36 + 0xf8);
    tmp296 = *(tmp292);
    __compare(tmp295, tmp296); // sets condition flags
    x19_1 = local_38; // recovered stack[0x38]
    if (tmp295 <= tmp296) goto 0x1000cce1c; // conditional branch
    *(x0_36 + 0xf8) = tmp296;
    tmp297 = tmp296;
    __branch(0x1000cce1c); // unconditional branch
    *(x0_36 + 0x1ec) = 0x0;
    tmp298 = 0x1;
    *(x0_36 + 0xf8) = (uint64_t)(uint32_t)tmp298;
    tmp299 = 0x1;
    x19_2 = local_38; // recovered stack[0x38]
    *(x0_36 + 0x38) = (uint64_t)(uint32_t)tmp299;
    *(x0_36 + 0x40) = 0x0;
    if ((((uint32_t)x24_3 >> 0x0) & 0x1) != 0x0) goto 0x1000cce44; // conditional branch
    x0_37 = sub_0x00000001000ce000(x0_36); // call
    x0_38 = x20_13;
    x0_39 = sub_0x0000000100206b80(x0_38); // call
    if ((uint32_t)x0_39 != 0x0) { // conditional branch
        x0_40 = x20_13;
        w1_3 = 0x23;
        x0_41 = sub_0x000000010006c914(x0_40, w1_3); // call
    }
    tmp300 = __adrp(0x1002b2000); // Page-relative address
    tmp301 = tmp300 + 0x668;
    tmp302 = *(tmp301);
    __compare(tmp302, x20_13); // sets condition flags
    if (tmp302 == x20_13) goto 0x1000cce64; // conditional branch
    x0_42 = x20_13;
    x0_43 = sub_0x0000000100206b80(x0_42); // call
    if ((uint32_t)x0_43 != 0x0) goto 0x1000cce84; // conditional branch
    tmp303 = __adrp(0x1002b2000); // Page-relative address
    tmp304 = tmp303 + 0x680;
    tmp305 = *(tmp304);
    __compare(tmp305, x19_2); // sets condition flags
    if (tmp305 == x19_2) goto 0x1000ccfa4; // conditional branch
    x0_44 = x19_2;
    x0_45 = sub_0x0000000100206440(x0_44); // call
    if ((uint32_t)x0_45 == 0x0) goto 0x1000ccfa4; // conditional branch
    tmp306 = __adrp(0x1002b2000); // Page-relative address
    tmp307 = tmp306 + 0x680;
    tmp308 = *(tmp307);
    __compare(tmp308, x19_2); // sets condition flags
    if (tmp308 == x19_2) goto 0x1000cceb4; // conditional branch
    x0_46 = x19_2;
    x0_47 = sub_0x0000000100206440(x0_46); // call
    if ((uint32_t)x0_47 != 0x0) { // conditional branch
        x0_48 = x19_2;
        w1_4 = 0x0;
        w2_3 = 0x0;
        x0_49 = sub_0x0000000100206468(x0_48, w1_4, w2_3); // call
    }
    x0_50 = sub_0x0000000100110d40(x0_49); // call
    if ((uint32_t)x0_50 == 0x0) goto 0x1000cced0; // conditional branch
    if (!w23_7) { // conditional branch
        tmp309 = __adrp(0x1002b2000); // Page-relative address
        tmp310 = tmp309 + 0x668;
        tmp311 = *(tmp310);
        *(tmp311 + 0x3a0) = 0x0;
    }
    x0_51 = sub_0x0000000100106fa8(x0_50); // call
    w0_5 = 0x23;
    x0_52 = sub_0x00000001000696ec(w0_5); // call
    if (w23_7 == 0x0) goto 0x1000ccf1c; // conditional branch
    x0_53 = x20_13;
    x0_54 = sub_0x0000000100206b80(x0_53); // call
    if ((uint32_t)x0_54 != 0x0) { // conditional branch
        x19_3 = __adrp(0x1002b2000); // Page-relative address
        x19_4 = x19_3 + 0x348;
        tmp312 = *(x19_4);
        tmp313 = tmp312 + 0x1;
        *(x19_4) = tmp313;
        x0_55 = x20_13;
        w1_5 = 0x1;
        x0_56 = sub_0x000000010020a768(x0_55, w1_5); // call
        tmp314 = *(x19_4);
        tmp315 = tmp314 - 0x1;
        *(x19_4) = tmp315;
        x0_57 = sub_0x0000000100105c44(x0_56); // call
    }
    w19_6 = w23_7 == 0x0; // compare to bool
    tmp316 = 0x1;
    x26_10 = __adrp(0x1002ac000); // Page-relative address
    *(x26_10 + 0x2e8) = tmp316;
    x28_5 = __adrp(0x1002b2000); // Page-relative address
    x28_6 = x28_5 + 0x220;
    *(x28_6) = w19_6;
    tmp317 = local_48; // recovered stack[0x48]
    w20_2 = *(tmp317 + 0x3a0);
    tmp318 = local_48; // recovered stack[0x48]
    *(tmp318 + 0x3a0) = 0x0;
    w0_6 = 0x0;
    x0_58 = sub_0x0000000100069140(w0_6); // call
    *(x26_10 + 0x2e8) = 0x0;
    *(x28_6) = 0x0;
    tmp319 = local_48; // recovered stack[0x48]
    *(tmp319 + 0x3a0) = w20_2;
    x20_14 = local_48; // recovered stack[0x48]
    if (w23_7 == 0x0) goto 0x1000ccfe8; // conditional branch
    tmp320 = 0x1;
    x20_15 = __adrp(0x1002ac000); // Page-relative address
    *(x20_15 + 0x2e8) = tmp320;
    x22_3 = __adrp(0x1002b2000); // Page-relative address
    x22_4 = x22_3 + 0x220;
    *(x22_4) = w19_6;
    w0_7 = 0x0;
    x0_59 = sub_0x0000000100069140(w0_7); // call
    *(x20_15 + 0x2e8) = 0x0;
    *(x22_4) = 0x0;
    tmp321 = __adrp(0x1002ac000); // Page-relative address
    *(tmp321 + 0x2d8) = 0x0;
    x26_11 = __adrp(0x1002b2000); // Page-relative address
    x26_12 = x26_11 + 0x838;
    tmp322 = __adrp(0x1002b2000); // Page-relative address
    tmp323 = tmp322 + 0x668;
    tmp324 = *(tmp323);
    tmp325 = *(tmp324 + 0x19c);
    x20_16 = __adrp(0x1002b2000); // Page-relative address
    x20_17 = x20_16 + 0x618;
    if (tmp325) { // conditional branch
        tmp326 = __adrp(0x1002b2000); // Page-relative address
        tmp327 = tmp326 + 0x608;
        x0_60 = *(tmp327);
        w1_6 = 0x1;
        x0_61 = sub_0x000000010020a768(x0_60, w1_6); // call
    }
    if ((((uint32_t)x24_3 >> 0x0) & 0x1) == 0x0) { // conditional branch
        x0_62 = sub_0x0000000100036dcc(x0_61); // call
    }
    w21_2 = (uint32_t)x21_4 + 0x1;
    if (w23_7 != 0x0) goto 0x1000cc3dc; // conditional branch
    __branch(0x1000cd0b0); // unconditional branch
    x0_63 = x20_17;
    x0_64 = sub_0x0000000100206b80(x0_63); // call
    if ((uint32_t)x0_64 == 0x0) goto 0x1000ccf6c; // conditional branch
    tmp328 = __adrp(0x1002b2000); // Page-relative address
    tmp329 = tmp328 + 0x668;
    x26_13 = *(tmp329);
    tmp330 = __adrp(0x1002b2000); // Page-relative address
    tmp331 = tmp330 + 0x348;
    x0_65 = x20_17;
    x20_18 = tmp331;
    tmp332 = *(tmp331);
    tmp333 = tmp332 + 0x1;
    *(x20_18) = tmp333;
    w1_7 = 0x1;
    x0_66 = sub_0x000000010020a768(x0_65, w1_7); // call
    tmp334 = *(x20_18);
    tmp335 = tmp334 - 0x1;
    *(x20_18) = tmp335;
    if ((((uint32_t)x22_4 >> 0x5) & 0x1) == 0x0) goto 0x1000ccf6c; // conditional branch
    x0_67 = x26_13;
    x0_68 = sub_0x0000000100206b80(x0_67); // call
    if ((uint32_t)x0_68 == 0x0) goto 0x1000ccf6c; // conditional branch
    x0_69 = x26_13;
    x0_70 = sub_0x000000010011c890(x0_69); // call
    __branch(0x1000ccf6c); // unconditional branch
    x0_71 = sub_0x0000000100015754(x0_70); // call
    if ((uint32_t)x0_71 == 0x0) goto 0x1000ccbb8; // conditional branch
    tmp336 = __adrp(0x1002b2000); // Page-relative address
    tmp337 = tmp336 + 0x238;
    tmp338 = *(tmp337);
    tmp339 = *(tmp338 + 0x1b58);
    tmp340 = *(tmp339);
    __compare(tmp340, 0x77); // sets condition flags
    if (tmp340 != 0x77) goto 0x1000ccbb8; // conditional branch
    x21_5 = (uint64_t)(uint32_t)w25_2;
    x24_4 = (uint64_t)(uint32_t)w19_6;
    tmp341 = *(tmp338);
    __compare(tmp341, 0x1); // sets condition flags
    if (tmp341 != 0x1) goto 0x1000cd094; // conditional branch
    w0_8 = 0x1;
    x0_72 = sub_0x00000001000e3db0(w0_8); // call
    tmp342 = *(x0_72);
    if (tmp342 == 0x0) goto 0x1000ccc88; // conditional branch
    w0_9 = 0x1;
    x0_73 = sub_0x00000001000e3d9c(w0_9); // call
    tmp343 = __adrp(0x1002b2000); // Page-relative address
    tmp344 = tmp343 + 0x238;
    tmp345 = *(tmp344);
    __branch(0x1000cd078); // unconditional branch
    x0_74 = sub_0x00000001001207b4(x0_73); // call
    x29_2, x30_1 = x29_0, x30_0; // restores register pair; recovered stack[0xa0], stack[0xa8]
    x20_19, x19_5 = local_90, local_98; // restores register pair; recovered stack[0x90], stack[0x98]
    x22_5, x21_6 = local_80, local_88; // restores register pair; recovered stack[0x80], stack[0x88]
    x24_5, x23_2 = local_70, local_78; // restores register pair; recovered stack[0x70], stack[0x78]
    x26_14, x25_5 = local_60, local_68; // restores register pair; recovered stack[0x60], stack[0x68]
    x28_7, x27_9 = local_50, local_58; // restores register pair; recovered stack[0x50], stack[0x58]
    __stack_free(0xb0); // releases 0xb0 stack bytes
    __autibsp();
    x16_3 = x30_1 ^ (x30_1 << 0x1);
    if (((x16_3 >> 0x3e) & 0x1) != 0x0) { // conditional branch
        __brk(0xc471);
    }
    __branch(0x1000cd1f0); // unconditional branch
    __restore_pair(x29_3, x30_2, stack[0xa0]); // restores register pair
    x20_20, x19_6 = local_90, local_98; // restores register pair
    x22_6, x21_7 = local_80, local_88; // restores register pair
    x24_6, x23_3 = local_70, local_78; // restores register pair
    x26_15, x25_6 = local_60, local_68; // restores register pair
    x28_8, x27_10 = local_50, local_58; // restores register pair
    __stack_free(0xb0); // releases 0xb0 stack bytes
    return x0_74; // return
}
