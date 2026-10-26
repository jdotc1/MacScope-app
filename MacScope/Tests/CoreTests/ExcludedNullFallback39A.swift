import Foundation
import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Explicit refusal contracts for the two contract-excluded null shapes.
/// Historical equality below is source-derived bare39a equivalence for the
/// identical input, not a captured relocated baseline or numerical repair claim.
enum ExcludedNullFallback39A {
    static func requireRefusal(function: MacIRFunction, document: PseudocodeDocument,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(CFGBuilder.buildCFG(instructions: function.instructions).loopHeaders.count,
                             2, "excluded input must exceed the certified-loop admission bound", file: file, line: line)
        XCTAssertNil(document.regionTree, file: file, line: line)
        XCTAssertEqual(document.structureFallback, .unsupportedRegion, file: file, line: line)
        XCTAssertEqual(document.functionName, function.name, file: file, line: line)
        XCTAssertEqual(document.entryAddress, function.startAddress, file: file, line: line)
        XCTAssertTrue(DecompilerOptions.default.structureControlFlow, file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverSharedTails, file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverLoopExits, file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverGuardRegions, file: file, line: line)
    }

    static func requireHistorical(function: MacIRFunction, document: PseudocodeDocument,
                                  legacy: PseudocodeDocument,
                                  file: StaticString = #filePath, line: UInt = #line) {
        requireRefusal(function: function, document: document, file: file, line: line)
        // Both documents were already made by the unchanged historical factory
        // from this exact function. No extra print, renamed text or baseline normalization.
        XCTAssertNil(legacy.regionTree, file: file, line: line)
        XCTAssertEqual(legacy.structureFallback, .gotoForm, file: file, line: line)
        XCTAssertEqual(legacy.functionName, function.name, file: file, line: line)
        XCTAssertEqual(legacy.entryAddress, function.startAddress, file: file, line: line)
        XCTAssertEqual(document.text, legacy.text, file: file, line: line)
        XCTAssertEqual(document.lines, legacy.lines, file: file, line: line)
        XCTAssertEqual(document.parameters, legacy.parameters, file: file, line: line)
        XCTAssertEqual(document.returnType, legacy.returnType, file: file, line: line)
        XCTAssertEqual(document.localVariables, legacy.localVariables, file: file, line: line)
        XCTAssertEqual(document.nameBindings, legacy.nameBindings, file: file, line: line)
        XCTAssertEqual(document.callTargets, legacy.callTargets, file: file, line: line)
        XCTAssertEqual(document.callSignatures, legacy.callSignatures, file: file, line: line)
        XCTAssertEqual(document.stackFrameSize, legacy.stackFrameSize, file: file, line: line)
    }

    static func requireCaptured(_ fixture: RegionalSchema2BuiltFixture,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let restored = try fixture.capture.restoredInput()
        XCTAssertEqual(restored, fixture.input, file: file, line: line)
        XCTAssertEqual(fixture.rows, fixture.capture.input_rows, file: file, line: line)
        XCTAssertEqual(fixture.baselineText, fixture.capture.canonical_text, file: file, line: line)
        requireRefusal(function: fixture.original, document: fixture.document, file: file, line: line)
        XCTAssertEqual(fixture.capture.start, "0x3704", file: file, line: line)
        let expected = fixture.original.ssaEnabled ? nullConvert3704SSAFlatText : nullConvert3704FlatText
        XCTAssertEqual(fixture.document.text, expected,
                       "complete exact39a captured input, current flat output", file: file, line: line)
    }

    // Exact refused flat presentations for both producer modes. SSA retains
    // its values and edge copies; neither snapshot claims native structuring.
    static let nullConvert3704FlatText = """
        int64_t _null_convert(int64_t arg0, int64_t arg1, int64_t arg2, int32_t arg3, int32_t arg4) {
            // entry 0x0000000000003704; no stack frame; calls none
            tmp0 = *(uint32_t *)(arg0 + 0x5c);
            tmp1 = *(uint32_t *)(arg0 + 0x30);
            if (tmp0 == 0x3) goto L_378c; // conditional branch
            if (tmp0 != 0x4) goto L_37f0; // conditional branch
            if (arg4 < 0x1) goto L_3850; // conditional branch
            L_3724:
            if (tmp1 == 0x0) goto L_3774; // conditional branch
            tmp2, tmp3 = *(uint64_t *)(arg2), *(uint64_t *)(arg2 + 0x8); // restores register pair
            tmp4 = *(tmp2 + ((uint64_t)((uint32_t)(unavailable_w3)) << 0x3));
            tmp5 = *(tmp3 + ((uint64_t)((uint32_t)(unavailable_w3)) << 0x3));
            tmp6, tmp7 = *(uint64_t *)(arg2 + 0x10), *(uint64_t *)((arg2 + 0x10) + 0x8); // restores register pair
            tmp8 = *(tmp6 + ((uint64_t)((uint32_t)(unavailable_w3)) << 0x3));
            tmp9 = *(tmp7 + ((uint64_t)((uint32_t)(unavailable_w3)) << 0x3));
            tmp10 = (uint64_t)((uint32_t)(tmp1));
            tmp11 = *(unavailable_x1);
            L_3748:
            tmp12 = *(uint8_t *)(unavailable_x14);
            *(uint8_t *)(unavailable_x9), tmp13 = tmp12, unavailable_x9 + 0x1;
            tmp14 = *(uint8_t *)(unavailable_x14 + 0x1);
            *(uint8_t *)(unavailable_x10), tmp15 = tmp14, unavailable_x10 + 0x1;
            tmp16 = *(uint8_t *)(unavailable_x14 + 0x2);
            *(uint8_t *)(unavailable_x11), tmp17 = tmp16, unavailable_x11 + 0x1;
            tmp18 = *(uint8_t *)(unavailable_x14 + 0x3);
            *(uint8_t *)(unavailable_x12), tmp19 = tmp18, unavailable_x12 + 0x1;
            tmp20 = unavailable_x14 + 0x4;
            tmp21 = unavailable_x13 - 0x1;
            if (unavailable_x13 != 0x1) goto L_3748; // conditional branch
            L_3774:
            x1_1 = unavailable_x1 + 0x8;
            w3_1 = unavailable_w3 + 0x1;
            __compare(unavailable_w4, 0x2); // sets condition flags
            w4_1 = unavailable_w4 - 0x1;
            if ((uint64_t)(unavailable_w4) < (uint64_t)(0x2)) goto L_3850; // conditional branch
            goto L_3724; // unconditional branch
            L_378c:
            __compare(unavailable_w4, 0x1); // sets condition flags
            if (unavailable_w4 < 0x1) goto L_3850; // conditional branch
            L_3794:
            if (tmp1 == 0x0) goto L_37d8; // conditional branch
            tmp22, tmp23 = *(uint64_t *)(arg2), *(uint64_t *)(arg2 + 0x8); // restores register pair
            tmp24 = *(tmp22 + ((uint64_t)((uint32_t)(unavailable_w3)) << 0x3));
            tmp25 = *(tmp23 + ((uint64_t)((uint32_t)(unavailable_w3)) << 0x3));
            tmp26 = *(arg2 + 0x10);
            tmp27 = *(tmp26 + ((uint64_t)((uint32_t)(unavailable_w3)) << 0x3));
            tmp28 = *(unavailable_x1);
            tmp29 = (uint64_t)((uint32_t)(tmp1));
            L_37b4:
            tmp30 = *(uint8_t *)(unavailable_x12);
            *(uint8_t *)(unavailable_x9), tmp31 = tmp30, unavailable_x9 + 0x1;
            tmp32 = *(uint8_t *)(unavailable_x12 + 0x1);
            *(uint8_t *)(unavailable_x10), tmp33 = tmp32, unavailable_x10 + 0x1;
            tmp34 = *(uint8_t *)(unavailable_x12 + 0x2);
            *(uint8_t *)(unavailable_x11), tmp35 = tmp34, unavailable_x11 + 0x1;
            tmp36 = unavailable_x12 + 0x3;
            tmp37 = unavailable_x13 - 0x1;
            if (unavailable_x13 != 0x1) goto L_37b4; // conditional branch
            L_37d8:
            x1_2 = unavailable_x1 + 0x8;
            w3_2 = unavailable_w3 + 0x1;
            __compare(unavailable_w4, 0x2); // sets condition flags
            w4_2 = unavailable_w4 - 0x1;
            if ((uint64_t)(unavailable_w4) < (uint64_t)(0x2)) goto L_3850; // conditional branch
            goto L_3794; // unconditional branch
            L_37f0:
            __compare(unavailable_w4, 0x1); // sets condition flags
            if (unavailable_w4 < 0x1) goto L_3850; // conditional branch
            tmp38 = (int32_t)(tmp0);
            L_37fc:
            if ((int32_t)((uint32_t)(tmp38)) < 0x1) goto L_383c; // conditional branch
            tmp39 = 0x0;
            L_3808:
            if (tmp1 == 0x0) goto L_3830; // conditional branch
            tmp40 = *(arg2 + (unavailable_x11 << 0x3));
            tmp41 = *(tmp40 + ((uint64_t)((uint32_t)(unavailable_w3)) << 0x3));
            tmp42 = *(unavailable_x1);
            tmp43 = (uint64_t)((uint32_t)(tmp1));
            L_381c:
            tmp44 = *(uint8_t *)(unavailable_x13 + unavailable_x11);
            *(uint8_t *)(unavailable_x12), tmp45 = tmp44, unavailable_x12 + 0x1;
            tmp46 = unavailable_x13 + tmp38;
            tmp47 = unavailable_x14 - 0x1;
            if (unavailable_x14 != 0x1) goto L_381c; // conditional branch
            L_3830:
            tmp48 = unavailable_x11 + 0x1;
            __compare(tmp48, unavailable_x9); // sets condition flags
            if (tmp48 != unavailable_x9) goto L_3808; // conditional branch
            L_383c:
            x1_3 = unavailable_x1 + 0x8;
            w3_3 = unavailable_w3 + 0x1;
            __compare(unavailable_w4, 0x1); // sets condition flags
            w4_3 = unavailable_w4 - 0x1;
            if (unavailable_w4 > 0x1) goto L_37fc; // conditional branch
            L_3850:
            return unresolved_return_contract; // return
        }
        """

    // Row68 @0x3814, 2d0040f9: LDR X13,[X1] is an unsigned64 load.
    // Its signed64 phi storage requires the explicit defined projection below.
    // All signed same-type copies retain their literal identity expectations.
    static let nullConvert3704SSAFlatText = """
        int64_t _null_convert(int64_t arg0, int64_t arg1, int64_t arg2, int32_t arg3, int32_t arg4) {
            // entry 0x0000000000003704; no stack frame; calls none
            int64_t x1_4;
            int32_t w3_4;
            int32_t w4_4;
            uint64_t x9_8;
            uint64_t x10_8;
            uint64_t x11_9;
            uint64_t x12_9;
            uint64_t x13_7;
            uint64_t x14_8;
            int64_t x1_5;
            int32_t w3_5;
            int32_t w4_5;
            uint64_t x9_9;
            uint64_t x10_9;
            uint64_t x11_10;
            uint64_t x12_10;
            uint64_t x13_8;
            int64_t x1_6;
            int32_t w3_6;
            int32_t w4_6;
            uint64_t x11_11;
            uint64_t x12_11;
            int64_t x13_9;
            uint64_t x14_9;
            tmp0 = *(uint32_t *)(arg0 + 0x5c);
            tmp1 = *(uint32_t *)(arg0 + 0x30);
            if (tmp0 == 0x3) goto L_378c; // conditional branch
            if (tmp0 != 0x4) goto L_37f0; // conditional branch
            if (arg4 < 0x1) goto L_3850; // conditional branch
                int64_t __edge_2_3_0 = arg1;
                int32_t __edge_2_3_1 = arg3;
                int32_t __edge_2_3_2 = arg4;
                x1_4 = __edge_2_3_0;
                w3_4 = __edge_2_3_1;
                w4_4 = __edge_2_3_2;
            L_3724:
            if (tmp1 == 0x0) goto L_3774; // conditional branch
            tmp2, tmp3 = *(uint64_t *)(arg2), *(uint64_t *)(arg2 + 0x8); // restores register pair
            tmp4 = *(tmp2 + ((uint64_t)((uint32_t)(w3_4)) << 0x3));
            tmp5 = *(tmp3 + ((uint64_t)((uint32_t)(w3_4)) << 0x3));
            tmp6, tmp7 = *(uint64_t *)(arg2 + 0x10), *(uint64_t *)((arg2 + 0x10) + 0x8); // restores register pair
            tmp8 = *(tmp6 + ((uint64_t)((uint32_t)(w3_4)) << 0x3));
            tmp9 = *(tmp7 + ((uint64_t)((uint32_t)(w3_4)) << 0x3));
            tmp10 = (uint64_t)((uint32_t)(tmp1));
            tmp11 = *(x1_4);
                uint64_t __edge_4_5_0 = tmp4;
                uint64_t __edge_4_5_1 = tmp5;
                uint64_t __edge_4_5_2 = tmp8;
                uint64_t __edge_4_5_3 = tmp9;
                uint64_t __edge_4_5_4 = tmp10;
                uint64_t __edge_4_5_5 = tmp11;
                x9_8 = __edge_4_5_0;
                x10_8 = __edge_4_5_1;
                x11_9 = __edge_4_5_2;
                x12_9 = __edge_4_5_3;
                x13_7 = __edge_4_5_4;
                x14_8 = __edge_4_5_5;
            L_3748:
            tmp12 = *(uint8_t *)(x14_8);
            *(uint8_t *)(x9_8), tmp13 = tmp12, x9_8 + 0x1;
            tmp14 = *(uint8_t *)(x14_8 + 0x1);
            *(uint8_t *)(x10_8), tmp15 = tmp14, x10_8 + 0x1;
            tmp16 = *(uint8_t *)(x14_8 + 0x2);
            *(uint8_t *)(x11_9), tmp17 = tmp16, x11_9 + 0x1;
            tmp18 = *(uint8_t *)(x14_8 + 0x3);
            *(uint8_t *)(x12_9), tmp19 = tmp18, x12_9 + 0x1;
            tmp20 = x14_8 + 0x4;
            tmp21 = x13_7 - 0x1;
            if (x13_7 != 0x1) goto L_edge_5_5; // conditional branch
            L_3774:
            x1_1 = x1_4 + 0x8;
            w3_1 = w3_4 + 0x1;
            w4_1 = w4_4 - 0x1;
            if ((uint32_t)(w4_4) < (uint32_t)(0x2)) goto L_3850; // conditional branch
                int64_t __edge_7_3_0 = x1_1;
                int32_t __edge_7_3_1 = w3_1;
                int32_t __edge_7_3_2 = w4_1;
                x1_4 = __edge_7_3_0;
                w3_4 = __edge_7_3_1;
                w4_4 = __edge_7_3_2;
            goto L_3724; // unconditional branch
            L_378c:
            if (arg4 < 0x1) goto L_3850; // conditional branch
                int64_t __edge_8_9_0 = arg1;
                int32_t __edge_8_9_1 = arg3;
                int32_t __edge_8_9_2 = arg4;
                x1_5 = __edge_8_9_0;
                w3_5 = __edge_8_9_1;
                w4_5 = __edge_8_9_2;
            L_3794:
            if (tmp1 == 0x0) goto L_37d8; // conditional branch
            tmp22, tmp23 = *(uint64_t *)(arg2), *(uint64_t *)(arg2 + 0x8); // restores register pair
            tmp24 = *(tmp22 + ((uint64_t)((uint32_t)(w3_5)) << 0x3));
            tmp25 = *(tmp23 + ((uint64_t)((uint32_t)(w3_5)) << 0x3));
            tmp26 = *(arg2 + 0x10);
            tmp27 = *(tmp26 + ((uint64_t)((uint32_t)(w3_5)) << 0x3));
            tmp28 = *(x1_5);
            tmp29 = (uint64_t)((uint32_t)(tmp1));
                uint64_t __edge_10_11_0 = tmp24;
                uint64_t __edge_10_11_1 = tmp25;
                uint64_t __edge_10_11_2 = tmp27;
                uint64_t __edge_10_11_3 = tmp28;
                uint64_t __edge_10_11_4 = tmp29;
                x9_9 = __edge_10_11_0;
                x10_9 = __edge_10_11_1;
                x11_10 = __edge_10_11_2;
                x12_10 = __edge_10_11_3;
                x13_8 = __edge_10_11_4;
            L_37b4:
            tmp30 = *(uint8_t *)(x12_10);
            *(uint8_t *)(x9_9), tmp31 = tmp30, x9_9 + 0x1;
            tmp32 = *(uint8_t *)(x12_10 + 0x1);
            *(uint8_t *)(x10_9), tmp33 = tmp32, x10_9 + 0x1;
            tmp34 = *(uint8_t *)(x12_10 + 0x2);
            *(uint8_t *)(x11_10), tmp35 = tmp34, x11_10 + 0x1;
            tmp36 = x12_10 + 0x3;
            tmp37 = x13_8 - 0x1;
            if (x13_8 != 0x1) goto L_edge_11_11; // conditional branch
            L_37d8:
            x1_2 = x1_5 + 0x8;
            w3_2 = w3_5 + 0x1;
            w4_2 = w4_5 - 0x1;
            if ((uint32_t)(w4_5) < (uint32_t)(0x2)) goto L_3850; // conditional branch
                int64_t __edge_13_9_0 = x1_2;
                int32_t __edge_13_9_1 = w3_2;
                int32_t __edge_13_9_2 = w4_2;
                x1_5 = __edge_13_9_0;
                w3_5 = __edge_13_9_1;
                w4_5 = __edge_13_9_2;
            goto L_3794; // unconditional branch
            L_37f0:
            if (arg4 < 0x1) goto L_3850; // conditional branch
            tmp38 = (int32_t)(tmp0);
                int64_t __edge_15_16_0 = arg1;
                int32_t __edge_15_16_1 = arg3;
                int32_t __edge_15_16_2 = arg4;
                x1_6 = __edge_15_16_0;
                w3_6 = __edge_15_16_1;
                w4_6 = __edge_15_16_2;
            L_37fc:
            if (((((uint32_t)(tmp38) & 0x80000000) == 0 ? (int32_t)(uint32_t)(tmp38) : -1 - (int32_t)(uint32_t)~(uint32_t)(tmp38))) < 0x1) goto L_383c; // conditional branch
            tmp39 = 0x0;
                uint64_t __edge_17_18_0 = tmp39;
                x11_11 = __edge_17_18_0;
            L_3808:
            if (tmp1 == 0x0) goto L_3830; // conditional branch
            tmp40 = *(arg2 + (x11_11 << 0x3));
            tmp41 = *(tmp40 + ((uint64_t)((uint32_t)(w3_6)) << 0x3));
            tmp42 = *(x1_6);
            tmp43 = (uint64_t)((uint32_t)(tmp1));
                uint64_t __edge_19_20_0 = tmp41;
                int64_t __edge_19_20_1 = (((uint64_t)(tmp42) & 0x8000000000000000) == 0 ? (int64_t)(uint64_t)(tmp42) : -1 - (int64_t)(uint64_t)~(uint64_t)(tmp42));
                uint64_t __edge_19_20_2 = tmp43;
                x12_11 = __edge_19_20_0;
                x13_9 = __edge_19_20_1;
                x14_9 = __edge_19_20_2;
            L_381c:
            tmp44 = *(uint8_t *)(x13_9 + x11_11);
            *(uint8_t *)(x12_11), tmp45 = tmp44, x12_11 + 0x1;
            tmp46 = x13_9 + tmp38;
            tmp47 = x14_9 - 0x1;
            if (x14_9 != 0x1) goto L_edge_20_20; // conditional branch
            L_3830:
            tmp48 = x11_11 + 0x1;
            if (tmp48 != (uint64_t)((uint32_t)(tmp0))) goto L_edge_21_18; // conditional branch
            L_383c:
            x1_3 = x1_6 + 0x8;
            w3_3 = w3_6 + 0x1;
            w4_3 = w4_6 - 0x1;
            if ((((w4_6 & 0x80000000) == 0 ? (int32_t)w4_6 : -1 - (int32_t)(uint32_t)~w4_6)) > 0x1) goto L_edge_22_16; // conditional branch
            L_3850:
            return unresolved_return_contract; // return
            L_edge_5_5:
                uint64_t __edge_5_5_0 = tmp13;
                uint64_t __edge_5_5_1 = tmp15;
                uint64_t __edge_5_5_2 = tmp17;
                uint64_t __edge_5_5_3 = tmp19;
                uint64_t __edge_5_5_4 = tmp21;
                uint64_t __edge_5_5_5 = tmp20;
                x9_8 = __edge_5_5_0;
                x10_8 = __edge_5_5_1;
                x11_9 = __edge_5_5_2;
                x12_9 = __edge_5_5_3;
                x13_7 = __edge_5_5_4;
                x14_8 = __edge_5_5_5;
            goto L_3748;
            L_edge_11_11:
                uint64_t __edge_11_11_0 = tmp31;
                uint64_t __edge_11_11_1 = tmp33;
                uint64_t __edge_11_11_2 = tmp35;
                uint64_t __edge_11_11_3 = tmp36;
                uint64_t __edge_11_11_4 = tmp37;
                x9_9 = __edge_11_11_0;
                x10_9 = __edge_11_11_1;
                x11_10 = __edge_11_11_2;
                x12_10 = __edge_11_11_3;
                x13_8 = __edge_11_11_4;
            goto L_37b4;
            L_edge_20_20:
                uint64_t __edge_20_20_0 = tmp45;
                int64_t __edge_20_20_1 = tmp46;
                uint64_t __edge_20_20_2 = tmp47;
                x12_11 = __edge_20_20_0;
                x13_9 = __edge_20_20_1;
                x14_9 = __edge_20_20_2;
            goto L_381c;
            L_edge_21_18:
                uint64_t __edge_21_18_0 = tmp48;
                x11_11 = __edge_21_18_0;
            goto L_3808;
            L_edge_22_16:
                int64_t __edge_22_16_0 = x1_3;
                int32_t __edge_22_16_1 = w3_3;
                int32_t __edge_22_16_2 = w4_3;
                x1_6 = __edge_22_16_0;
                w3_6 = __edge_22_16_1;
                w4_6 = __edge_22_16_2;
            goto L_37fc;
        }
        """
}
