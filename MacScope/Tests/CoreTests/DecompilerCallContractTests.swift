import XCTest
@testable import MacScope

final class DecompilerCallContractTests: XCTestCase {
    func testAllocSmallDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_alloc_small",
            callAddress: 0x46984,
            bytes: "e7 fe ff 97",
            mnemonic: "bl",
            operands: "_alloc_small",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void *", parameterCount: 3,
                      parameters: "j_common_ptr cinfo, int pool_id, size_t sizeofobject", evidence: "src/jmemmgr.c:266"),
            ]
        )
    }

    func testCreateColorindexDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_create_colorindex",
            callAddress: 0x47a58,
            bytes: "af 00 00 94",
            mnemonic: "bl",
            operands: "_create_colorindex",
            capturedArgumentCount: 6,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "j_decompress_ptr cinfo", evidence: "src/jquant1.c:337"),
            ]
        )
    }

    func testEmitByteDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_emit_byte",
            callAddress: 0x4ccd8,
            bytes: "4f 00 00 94",
            mnemonic: "bl",
            operands: "_emit_byte",
            capturedArgumentCount: 3,
            variants: [
                .init(returnType: "void", parameterCount: 2,
                      parameters: "int val, j_compress_ptr cinfo", evidence: "src/jcarith.c:121"),
            ]
        )
    }

    func testEmitEobrunDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_emit_eobrun",
            callAddress: 0x1d03c,
            bytes: "84 00 00 94",
            mnemonic: "bl",
            operands: "_emit_eobrun",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "phuff_entropy_ptr entropy", evidence: "src/jcphuff.c:396"),
            ]
        )
    }

    func testExamineApp14DirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_examine_app14",
            callAddress: 0x33948,
            bytes: "a6 01 00 94",
            mnemonic: "bl",
            operands: "_examine_app14",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_decompress_ptr cinfo, JOCTET *data, unsigned int datalen,\n              JLONG remaining", evidence: "src/jdmarker.c:678"),
            ]
        )
    }

    func testFillInverseCmapDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_fill_inverse_cmap",
            callAddress: 0x499ec,
            bytes: "84 01 00 94",
            mnemonic: "bl",
            operands: "_fill_inverse_cmap",
            capturedArgumentCount: 8,
            variants: [
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_decompress_ptr cinfo, int c0, int c1, int c2", evidence: "src/jquant2.c:837"),
            ]
        )
    }

    func testFinishPassDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_finish_pass",
            callAddress: 0x4cb18,
            bytes: "46 fc ff 97",
            mnemonic: "bl",
            operands: "_finish_pass",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "j_compress_ptr cinfo", evidence: "src/jcarith.c:138"),
            ]
        )
    }

    func testGetByteDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_get_byte",
            callAddress: 0x4dfc8,
            bytes: "42 00 00 94",
            mnemonic: "bl",
            operands: "_get_byte",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "int", parameterCount: 1,
                      parameters: "j_decompress_ptr cinfo", evidence: "src/jdarith.c:73"),
            ]
        )
    }

    func testInitSimdDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_init_simd",
            callAddress: 0x58234,
            bytes: "5c fe ff 97",
            mnemonic: "bl",
            operands: "_init_simd",
            capturedArgumentCount: 0,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "j_common_ptr cinfo", evidence: "simd/jsimd.c:54"),
            ]
        )
    }

    func testJ12copySampleRowsDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_j12copy_sample_rows",
            callAddress: 0x377fc,
            bytes: "3f 50 00 94",
            mnemonic: "bl",
            operands: "_j12copy_sample_rows",
            capturedArgumentCount: 7,
            variants: [
                .init(returnType: "void", parameterCount: 6,
                      parameters: "J12SAMPARRAY input_array, int source_row,\n                   J12SAMPARRAY output_array, int dest_row, int num_rows,\n                   JDIMENSION num_cols", evidence: "src/jpegint.h:650"),
            ]
        )
    }

    func testJ12initDDiffControllerDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_j12init_d_diff_controller",
            callAddress: 0x34ea0,
            bytes: "aa de ff 97",
            mnemonic: "bl",
            operands: "_j12init_d_diff_controller",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, boolean need_full_buffer", evidence: "src/jpegint.h:631"),
            ]
        )
    }

    func testJ12initForwardDctDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_j12init_forward_dct",
            callAddress: 0x170c4,
            bytes: "3b bf ff 97",
            mnemonic: "bl",
            operands: "_j12init_forward_dct",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "j_compress_ptr cinfo", evidence: "src/jpegint.h:567"),
            ]
        )
    }

    func testJ16initDDiffControllerDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_j16init_d_diff_controller",
            callAddress: 0x34ea8,
            bytes: "6a e0 ff 97",
            mnemonic: "bl",
            operands: "_j16init_d_diff_controller",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, boolean need_full_buffer", evidence: "src/jpegint.h:633"),
            ]
        )
    }

    func testJ16initDPostControllerDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_j16init_d_post_controller",
            callAddress: 0x34ddc,
            bytes: "d0 17 00 94",
            mnemonic: "bl",
            operands: "_j16init_d_post_controller",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, boolean need_full_buffer", evidence: "src/jpegint.h:625"),
            ]
        )
    }

    func testJcopyBlockRowDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jcopy_block_row",
            callAddress: 0x24a20,
            bytes: "b0 9b 00 94",
            mnemonic: "bl",
            operands: "_jcopy_block_row",
            capturedArgumentCount: 8,
            variants: [
                .init(returnType: "void", parameterCount: 3,
                      parameters: "JBLOCKROW input_row, JBLOCKROW output_row,\n                JDIMENSION num_blocks", evidence: "src/jpegint.h:658"),
            ]
        )
    }

    func testJcopySampleRowsDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jcopy_sample_rows",
            callAddress: 0x35658,
            bytes: "8d 58 00 94",
            mnemonic: "bl",
            operands: "_jcopy_sample_rows",
            capturedArgumentCount: 7,
            variants: [
                .init(returnType: "void", parameterCount: 6,
                      parameters: "JSAMPARRAY input_array, int source_row,\n                   JSAMPARRAY output_array, int dest_row, int num_rows,\n                   JDIMENSION num_cols", evidence: "src/jpegint.h:647"),
            ]
        )
    }

    func testJinitDCoefControllerDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jinit_d_coef_controller",
            callAddress: 0x34f40,
            bytes: "da ba ff 97",
            mnemonic: "bl",
            operands: "_jinit_d_coef_controller",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, boolean need_full_buffer", evidence: "src/jpegint.h:597"),
            ]
        )
    }

    func testJpegAllocHuffTableDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jpeg_alloc_huff_table",
            callAddress: 0x968c,
            bytes: "d7 47 00 94",
            mnemonic: "bl",
            operands: "_jpeg_alloc_huff_table",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "JHUFF_TBL *", parameterCount: 1,
                      parameters: "j_common_ptr cinfo", evidence: "src/jpeglib.h:1017"),
            ]
        )
    }

    func testJpegFillBitBufferDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jpeg_fill_bit_buffer",
            callAddress: 0x2dbf8,
            bytes: "a4 ff ff 97",
            mnemonic: "bl",
            operands: "_jpeg_fill_bit_buffer",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "boolean", parameterCount: 4,
                      parameters: "bitread_working_state *state,\n                     register bit_buf_type get_buffer, register int bits_left,\n                     int nbits", evidence: "src/jdhuff.h:178"),
            ]
        )
    }

    func testJpegMakeCDerivedTblDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jpeg_make_c_derived_tbl",
            callAddress: 0x9330,
            bytes: "16 fe ff 97",
            mnemonic: "bl",
            operands: "_jpeg_make_c_derived_tbl",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_compress_ptr cinfo, boolean isDC, int tblno,\n                        c_derived_tbl **pdtbl", evidence: "src/jchuff.h:45"),
            ]
        )
    }

    func testJpegOpenBackingStoreDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jpeg_open_backing_store",
            callAddress: 0x46e5c,
            bytes: "1c 02 00 94",
            mnemonic: "bl",
            operands: "_jpeg_open_backing_store",
            capturedArgumentCount: 4,
            variants: [
                .init(returnType: "void", parameterCount: 3,
                      parameters: "j_common_ptr cinfo, backing_store_ptr info,\n                        long total_bytes_needed", evidence: "src/jmemsys.h:129"),
            ]
        )
    }

    func testJpegSimdCpuSupportDirectCallUsesSourceContract() throws {
        // Retained: recovery still rejects zero parameters before direct-call routing is reached.
        XCTExpectFailure("Callee parameter recovery rejects a complete leaf body that reads no argument register.", strict: true)
        try assertCallContract(
            label: "_jpeg_simd_cpu_support",
            callAddress: 0x57c00,
            bytes: "cc ff ff 97",
            mnemonic: "bl",
            operands: "_jpeg_simd_cpu_support",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "unsigned int", parameterCount: 0,
                      parameters: "void", evidence: "simd/jsimdint.h:36"),
            ]
        )
    }

    func testJsimdSetHuffEncodeOneBlockDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jsimd_set_huff_encode_one_block",
            callAddress: 0x9234,
            bytes: "ab 3c 01 94",
            mnemonic: "bl",
            operands: "_jsimd_set_huff_encode_one_block",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "unsigned int", parameterCount: 1,
                      parameters: "j_compress_ptr cinfo", evidence: "simd/jsimd.h:111"),
            ]
        )
    }

    func testJzeroFarDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_jzero_far",
            callAddress: 0x480d8,
            bytes: "07 0e 00 94",
            mnemonic: "bl",
            operands: "_jzero_far",
            capturedArgumentCount: 4,
            variants: [
                .init(returnType: "void", parameterCount: 2,
                      parameters: "void *target, size_t bytestozero", evidence: "src/jpegint.h:660"),
            ]
        )
    }

    func testProcessRestartDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_process_restart",
            callAddress: 0x399ec,
            bytes: "73 02 00 94",
            mnemonic: "bl",
            operands: "_process_restart",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "boolean", parameterCount: 1,
                      parameters: "j_decompress_ptr cinfo", evidence: "src/jdphuff.c:231"),
            ]
        )
    }

    func testReadAndDiscardScanlinesDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_read_and_discard_scanlines",
            callAddress: 0x22204,
            bytes: "56 00 00 94",
            mnemonic: "bl",
            operands: "_read_and_discard_scanlines",
            capturedArgumentCount: 8,
            variants: [
                .init(returnType: "void", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, JDIMENSION num_lines", evidence: "src/jdapistd.c:398"),
            ]
        )
    }

    func testSnprintfDirectCallUsesSourceContract() throws {
        // Retained: this catalog-only fixture needs runtime-format stack-tail authority, not authored routing.
        XCTExpectFailure("Known variadic calls do not yet consume an exact contiguous outgoing stack tail when the format is chosen at run time.", strict: true)
        try assertCallContract(
            label: "_snprintf",
            callAddress: 0x3ccf8,
            bytes: "72 6e 00 94",
            mnemonic: "bl",
            operands: "_snprintf",
            capturedArgumentCount: 3,
            variants: [
                .init(returnType: "int", parameterCount: 4,
                      parameters: "buffer, JMSG_LENGTH_MAX, msgtext, err->msg_parm.s", evidence: "src/jerror.c:189-190"),
                .init(returnType: "int", parameterCount: 11,
                      parameters: "buffer, JMSG_LENGTH_MAX, msgtext, err->msg_parm.i[0...7]", evidence: "src/jerror.c:191-196"),
            ]
        )
    }

    func testSscanfDirectCallUsesSourceContract() throws {
        // Retained: this catalog-only fixture needs scanf conversion parsing, not authored routing.
        XCTExpectFailure("The format string parser does not yet parse scanf conversions.", strict: true)
        try assertCallContract(
            label: "_sscanf",
            callAddress: 0x464c0,
            bytes: "83 48 00 94",
            mnemonic: "bl",
            operands: "_sscanf",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "int", parameterCount: 4,
                      parameters: "memenv, \"%ld%c\", &max_to_use, &ch", evidence: "src/jmemmgr.c:1274-1280"),
            ]
        )
    }

    func testStartIMCURowDirectCallUsesSourceContract() throws {
        try assertCallContract(
            label: "_start_iMCU_row",
            callAddress: 0x1bb0,
            bytes: "34 00 00 94",
            mnemonic: "bl",
            operands: "_start_iMCU_row",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "j_compress_ptr cinfo", evidence: "src/jccoefct.c:74"),
            ]
        )
    }

    func testJpegColorConverterColorConvertSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_color_converter.color_convert",
            callAddress: 0x1d6c0,
            bytes: "20 01 3f d6",
            mnemonic: "blr",
            operands: "x9",
            capturedArgumentCount: 7,
            variants: [
                .init(returnType: "void", parameterCount: 5,
                      parameters: "j_compress_ptr cinfo, JSAMPARRAY input_buf, JSAMPIMAGE output_buf, JDIMENSION output_row, int num_rows", evidence: "src/jpegint.h:168"),
            ]
        )
    }

    func testJpegColorConverterColorConvert12SlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_color_converter.color_convert_12",
            callAddress: 0x1de70,
            bytes: "20 01 3f d6",
            mnemonic: "blr",
            operands: "x9",
            capturedArgumentCount: 7,
            variants: [
                .init(returnType: "void", parameterCount: 5,
                      parameters: "j_compress_ptr cinfo, J12SAMPARRAY input_buf, J12SAMPIMAGE output_buf, JDIMENSION output_row, int num_rows", evidence: "src/jpegint.h:171"),
            ]
        )
    }

    func testJpegColorConverterColorConvert16SlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_color_converter.color_convert_16",
            callAddress: 0x1e620,
            bytes: "20 01 3f d6",
            mnemonic: "blr",
            operands: "x9",
            capturedArgumentCount: 7,
            variants: [
                .init(returnType: "void", parameterCount: 5,
                      parameters: "j_compress_ptr cinfo, J16SAMPARRAY input_buf, J16SAMPIMAGE output_buf, JDIMENSION output_row, int num_rows", evidence: "src/jpegint.h:175"),
            ]
        )
    }

    func testJpegDCoefControllerDecompressDataSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_d_coef_controller.decompress_data",
            callAddress: 0x310f0,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 4,
            variants: [
                .init(returnType: "int", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, JSAMPIMAGE output_buf", evidence: "src/jpegint.h:335"),
            ]
        )
    }

    func testJpegDCoefControllerDecompressData12SlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_d_coef_controller.decompress_data_12",
            callAddress: 0x317d8,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 4,
            variants: [
                .init(returnType: "int", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, J12SAMPIMAGE output_buf", evidence: "src/jpegint.h:336"),
            ]
        )
    }

    func testJpegDCoefControllerDecompressData16SlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_d_coef_controller.decompress_data_16",
            callAddress: 0x31ec0,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 4,
            variants: [
                .init(returnType: "int", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, J16SAMPIMAGE output_buf", evidence: "src/jpegint.h:338"),
            ]
        )
    }

    func testJpegDestinationMgrEmptyOutputBufferSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_destination_mgr.empty_output_buffer",
            callAddress: 0x1a0d0,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "boolean", parameterCount: 1,
                      parameters: "j_compress_ptr cinfo", evidence: "src/jpeglib.h:858"),
            ]
        )
    }

    func testJpegEntropyDecoderProcessRestartSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_entropy_decoder.process_restart",
            callAddress: 0x2c714,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "boolean", parameterCount: 1,
                      parameters: "j_decompress_ptr cinfo", evidence: "src/jpegint.h:408"),
            ]
        )
    }

    func testJpegEntropyEncoderEncodeMcuSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_entropy_encoder.encode_mcu",
            callAddress: 0x21208,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 5,
            variants: [
                .init(returnType: "boolean", parameterCount: 2,
                      parameters: "j_compress_ptr cinfo, JBLOCKROW *MCU_data", evidence: "src/jpegint.h:233"),
            ]
        )
    }

    func testJpegErrorMgrEmitMessageSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_error_mgr.emit_message",
            callAddress: 0x2dcac,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 3,
            variants: [
                .init(returnType: "void", parameterCount: 2,
                      parameters: "j_common_ptr cinfo, int msg_level", evidence: "src/jpeglib.h:787"),
            ]
        )
    }

    func testJpegErrorMgrErrorExitSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_error_mgr.error_exit",
            callAddress: 0x1250,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "j_common_ptr cinfo", evidence: "src/jpeglib.h:785"),
            ]
        )
    }

    func testJpegErrorMgrOutputMessageSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_error_mgr.output_message",
            callAddress: 0x3cba0,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "j_common_ptr cinfo", evidence: "src/jpeglib.h:789"),
            ]
        )
    }

    func testJpegForwardDctStartPassSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_forward_dct.start_pass",
            callAddress: 0x7744,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "void", parameterCount: 1,
                      parameters: "j_compress_ptr cinfo", evidence: "src/jpegint.h:214"),
            ]
        )
    }

    func testJpegInputControllerConsumeInputSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_input_controller.consume_input",
            callAddress: 0x240b0,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "int", parameterCount: 1,
                      parameters: "j_decompress_ptr cinfo", evidence: "src/jpegint.h:305"),
            ]
        )
    }

    func testJpegInverseDctInverseDCTSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_inverse_dct.inverse_DCT",
            callAddress: 0x25294,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 8,
            variants: [
                .init(returnType: "void", parameterCount: 5,
                      parameters: "j_decompress_ptr cinfo, jpeg_component_info *compptr, JCOEFPTR coef_block, JSAMPARRAY output_buf, JDIMENSION output_col", evidence: "src/jpegint.h:435"),
            ]
        )
    }

    func testJpegInverseDctInverseDCT12SlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_inverse_dct.inverse_DCT_12",
            callAddress: 0x26b58,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 8,
            variants: [
                .init(returnType: "void", parameterCount: 5,
                      parameters: "j_decompress_ptr cinfo, jpeg_component_info *compptr, JCOEFPTR coef_block, J12SAMPARRAY output_buf, JDIMENSION output_col", evidence: "src/jpegint.h:436"),
            ]
        )
    }

    func testJpegMarkerReaderReadRestartMarkerSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_marker_reader.read_restart_marker",
            callAddress: 0x2e35c,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 3,
            variants: [
                .init(returnType: "boolean", parameterCount: 1,
                      parameters: "j_decompress_ptr cinfo", evidence: "src/jpegint.h:387"),
            ]
        )
    }

    func testJpegMemoryMgrAccessVirtBarraySlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_memory_mgr.access_virt_barray",
            callAddress: 0x24708,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 3,
            variants: [
                .init(returnType: "JBLOCKARRAY", parameterCount: 5,
                      parameters: "j_common_ptr cinfo, jvirt_barray_ptr ptr, JDIMENSION start_row, JDIMENSION num_rows, boolean writable", evidence: "src/jpeglib.h:924"),
            ]
        )
    }

    func testJpegMemoryMgrAccessVirtSarraySlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_memory_mgr.access_virt_sarray",
            callAddress: 0x3a730,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 6,
            variants: [
                .init(returnType: "JSAMPARRAY", parameterCount: 5,
                      parameters: "j_common_ptr cinfo, jvirt_sarray_ptr ptr, JDIMENSION start_row, JDIMENSION num_rows, boolean writable", evidence: "src/jpeglib.h:921"),
            ]
        )
    }

    func testJpegMemoryMgrAllocSarraySlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_memory_mgr.alloc_sarray",
            callAddress: 0x3a540,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 3,
            variants: [
                .init(returnType: "JSAMPARRAY", parameterCount: 4,
                      parameters: "j_common_ptr cinfo, int pool_id, JDIMENSION samplesperrow, JDIMENSION numrows", evidence: "src/jpeglib.h:906"),
            ]
        )
    }

    func testJpegSourceMgrFillInputBufferSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_source_mgr.fill_input_buffer",
            callAddress: 0x23958,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 2,
            variants: [
                .init(returnType: "boolean", parameterCount: 1,
                      parameters: "j_decompress_ptr cinfo", evidence: "src/jpeglib.h:870"),
            ]
        )
    }

    func testJpegSourceMgrResyncToRestartSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_source_mgr.resync_to_restart",
            callAddress: 0x333ec,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "boolean", parameterCount: 2,
                      parameters: "j_decompress_ptr cinfo, int desired", evidence: "src/jpeglib.h:872"),
            ]
        )
    }

    func testJpegUpsamplerUpsampleSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_upsampler.upsample",
            callAddress: 0x3a68c,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void", parameterCount: 7,
                      parameters: "j_decompress_ptr cinfo, JSAMPIMAGE input_buf, JDIMENSION *in_row_group_ctr, JDIMENSION in_row_groups_avail, JSAMPARRAY output_buf, JDIMENSION *out_row_ctr, JDIMENSION out_rows_avail", evidence: "src/jpegint.h:449"),
            ]
        )
    }

    func testJpegUpsamplerUpsample12SlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "jpeg_upsampler.upsample_12",
            callAddress: 0x3aaf4,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void", parameterCount: 7,
                      parameters: "j_decompress_ptr cinfo, J12SAMPIMAGE input_buf, JDIMENSION *in_row_group_ctr, JDIMENSION in_row_groups_avail, J12SAMPARRAY output_buf, JDIMENSION *out_row_ctr, JDIMENSION out_rows_avail", evidence: "src/jpegint.h:453"),
            ]
        )
    }

    func testMyDownsamplerMethodsSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "my_downsampler.methods",
            callAddress: 0x1ed38,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 5,
            variants: [
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_compress_ptr cinfo, jpeg_component_info *compptr, JSAMPARRAY input_data, JSAMPARRAY output_data", evidence: "src/jcsample.c:77"),
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_compress_ptr cinfo, jpeg_component_info *compptr, J12SAMPARRAY input_data, J12SAMPARRAY output_data", evidence: "src/jcsample.c:77"),
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_compress_ptr cinfo, jpeg_component_info *compptr, J16SAMPARRAY input_data, J16SAMPARRAY output_data", evidence: "src/jcsample.c:77"),
            ]
        )
    }

    func testMyFdctControllerConvsampSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "my_fdct_controller.convsamp",
            callAddress: 0x6a1c,
            bytes: "20 03 3f d6",
            mnemonic: "blr",
            operands: "x25",
            capturedArgumentCount: 7,
            variants: [
                .init(returnType: "void", parameterCount: 3,
                      parameters: "JSAMPARRAY sample_data, JDIMENSION start_col, DCTELEM *workspace", evidence: "src/jcdctmgr.c:43"),
                .init(returnType: "void", parameterCount: 3,
                      parameters: "J12SAMPARRAY sample_data, JDIMENSION start_col, DCTELEM *workspace", evidence: "src/jcdctmgr.c:43"),
            ]
        )
    }

    func testMyFdctControllerFloatConvsampSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "my_fdct_controller.float_convsamp",
            callAddress: 0x6abc,
            bytes: "20 03 3f d6",
            mnemonic: "blr",
            operands: "x25",
            capturedArgumentCount: 7,
            variants: [
                .init(returnType: "void", parameterCount: 3,
                      parameters: "JSAMPARRAY sample_data, JDIMENSION start_col, FAST_FLOAT *workspace", evidence: "src/jcdctmgr.c:58"),
                .init(returnType: "void", parameterCount: 3,
                      parameters: "J12SAMPARRAY sample_data, JDIMENSION start_col, FAST_FLOAT *workspace", evidence: "src/jcdctmgr.c:58"),
            ]
        )
    }

    func testMyMergedUpsamplerUpmethodSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "my_merged_upsampler.upmethod",
            callAddress: 0x35680,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 1,
            variants: [
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_decompress_ptr cinfo, JSAMPIMAGE input_buf, JDIMENSION in_row_group_ctr, JSAMPARRAY output_buf", evidence: "src/jdmerge.h:25"),
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_decompress_ptr cinfo, J12SAMPIMAGE input_buf, JDIMENSION in_row_group_ctr, J12SAMPARRAY output_buf", evidence: "src/jdmerge.h:25"),
            ]
        )
    }

    func testMyUpsamplerMethodsSlotCallUsesSourceContract() throws {
        try assertCallContract(
            label: "my_upsampler.methods",
            callAddress: 0x3b218,
            bytes: "00 01 3f d6",
            mnemonic: "blr",
            operands: "x8",
            capturedArgumentCount: 7,
            variants: [
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_decompress_ptr cinfo, jpeg_component_info *compptr, JSAMPARRAY input_data, JSAMPARRAY *output_data_ptr", evidence: "src/jdsample.h:38"),
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_decompress_ptr cinfo, jpeg_component_info *compptr, J12SAMPARRAY input_data, J12SAMPARRAY *output_data_ptr", evidence: "src/jdsample.h:38"),
                .init(returnType: "void", parameterCount: 4,
                      parameters: "j_decompress_ptr cinfo, jpeg_component_info *compptr, J16SAMPARRAY input_data, J16SAMPARRAY *output_data_ptr", evidence: "src/jdsample.h:38"),
            ]
        )
    }

    func testNeutralDirectCallFollowsCalleeBodyArity() throws {
        let caller = callerRows(callAddress: 0x7100, bytes: "00 00 00 94", mnemonic: "bl", operands: "_neutral_target")
        try assertNeutralDirectBody(rows: [
            row(0x7200, "add", "x9, x0, #1"), row(0x7204, "ret", "")
        ], expectedCount: 1, caller: caller, callAddress: 0x7100)
        try assertNeutralDirectBody(rows: [
            row(0x7200, "add", "x9, x0, x1"), row(0x7204, "add", "x10, x2, #1"),
            row(0x7208, "ret", "")
        ], expectedCount: 3, caller: caller, callAddress: 0x7100)
    }

    func testNeutralSlotCallFollowsAddressKeyedContractArity() throws {
        let caller = callerRows(callAddress: 0x7300, bytes: "00 01 3f d6", mnemonic: "blr", operands: "x8")
        try assertCensusSlotFrame(label: "neutral_slot", callAddress: 0x7300, caller: caller,
            contract: contract(returnType: "void", parameterCount: 1), expectedCount: 1)
        try assertCensusSlotFrame(label: "neutral_slot", callAddress: 0x7300, caller: caller,
            contract: contract(returnType: "void", parameterCount: 2), expectedCount: 2)
    }

    func testNeutralVariadicCallFollowsFormatTailAuthority() throws {
        // Retained: positional format parsing remains unsupported independently of authored routing.
        XCTExpectFailure("The format string parser rejects positional %n$ conversions.", strict: true)
        let oneTail = try neutralVariadicFrame(format: "%1$s")
        XCTAssertEqual(oneTail.arguments.count, 4,
            "one positional conversion must produce three fixed plus one anonymous argument")

        let eightTails = try neutralVariadicFrame(
            format: "%1$d %2$d %3$d %4$d %5$d %6$d %7$d %8$d"
        )
        XCTAssertEqual(eightTails.arguments.count, 11,
            "eight positional conversions must produce three fixed plus eight anonymous arguments")
    }

    // Two independent byte-backed witnesses per scalar/void rule exercise both lifters.
    func testAuthoredScalarFreeOverridesVoidCatalogInBothModes() throws {
        try assertAuthoredRouting(target: "_free", declaration: "uint64_t free(uint64_t first, uint64_t second);",
                                  returnType: "uint64_t", returnsVoid: false)
    }

    func testAuthoredScalarReleaseOverridesVoidCatalogInBothModes() throws {
        try assertAuthoredRouting(target: "_swift_release", declaration: "uint64_t swift_release(uint64_t first, uint64_t second);",
                                  returnType: "uint64_t", returnsVoid: false)
    }

    func testAuthoredVoidMallocOverridesScalarCatalogInBothModes() throws {
        try assertAuthoredRouting(target: "_malloc", declaration: "void malloc(uint64_t first, uint64_t second);",
                                  returnType: "void", returnsVoid: true)
    }

    func testAuthoredVoidStrlenOverridesScalarCatalogInBothModes() throws {
        try assertAuthoredRouting(target: "_strlen", declaration: "void strlen(uint64_t first, uint64_t second);",
                                  returnType: "void", returnsVoid: true)
    }

    func testNoAuthoredMallocKeepsScalarCatalogInBothModes() throws {
        try assertCatalogRouting(target: "_malloc", returnsVoid: false)
    }

    func testNoAuthoredStrlenKeepsScalarCatalogInBothModes() throws {
        try assertCatalogRouting(target: "_strlen", returnsVoid: false)
    }

    func testNoAuthoredFreeKeepsVoidCatalogInBothModes() throws {
        try assertCatalogRouting(target: "_free", returnsVoid: true)
    }

    func testNoAuthoredReleaseKeepsVoidCatalogInBothModes() throws {
        try assertCatalogRouting(target: "_swift_release", returnsVoid: true)
    }

    private func routingRows(_ target: String, branch: Bool = false) -> [InstructionRow] {
        // BL/B 0x9000 from 0x8000; RET. No decoder is needed to retain the witness bytes.
        [InstructionRow(address: 0x8000, bytes: branch ? "00 04 00 14" : "00 04 00 94",
                        mnemonic: branch ? "b" : "bl", operands: target, hasBreakpoint: false, comment: nil),
         InstructionRow(address: 0x8004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                        hasBreakpoint: false, comment: nil)]
    }

    private func routingFunction(target: String, authored: [String: FunctionSignatureOverride],
                                 directVoid: [String: FunctionSignatureOverride] = [:],
                                 types: [TypeDefinition] = [], ssa: Bool, branch: Bool = false) -> MacIRFunction {
        PseudocodePrinter().buildFunction(functionName: "_caller", startAddress: 0x8000,
            signatureOverrides: [0x8000: callerSignature], authoredCallSignaturesByTarget: authored,
            directCallVoidResultTargets: directVoid, types: types, explicitCFGEnabled: ssa, ssaEnabled: ssa,
            instructions: routingRows(target, branch: branch))
    }

    private func importedRoutingSnapshot(target: String, declaration: String) throws -> WorkspaceSnapshot {
        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(id: UUID(), name: target, startAddress: 0x9000,
                                               endAddress: 0x9004, confidence: 1)]
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "routing", path: "/tmp/routing",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        let imported = HeaderImportCore.prepare(source: declaration, typeDefinitions: [],
            exports: [ExportSummary(id: UUID(), name: target, address: 0x9000,
                                    source: "export trie", terminalFlags: 0)],
            functions: analysis.functions, importedPrototypes: [:], slot: .primary)
        XCTAssertEqual(imported.importedPrototypeCount, 1)
        XCTAssertEqual(imported.diagnostics, [])
        snapshot.importedPrototypes = imported.prototypes
        snapshot.typeDefinitions = imported.types
        return snapshot
    }

    private func assertAuthoredRouting(target: String, declaration: String,
                                       returnType: String, returnsVoid: Bool) throws {
        let snapshot = try importedRoutingSnapshot(target: target, declaration: declaration)
        let authored = snapshot.authoredCallSignaturesByTarget(in: .primary)
        XCTAssertEqual(authored.count, 1)
        XCTAssertEqual(authored[target]?.returnType, returnType)
        let catalog = try XCTUnwrap(MacIRBuilder.knownCallSignature(for: target))
        XCTAssertNotEqual(catalog.returnsVoid, returnsVoid)
        for ssa in [false, true] {
            let function = routingFunction(target: target, authored: authored,
                                           types: snapshot.typeDefinitions, ssa: ssa)
            XCTAssertEqual(function.ssaEnabled, ssa)
            let frame = try callFrame(function: function, address: 0x8000, label: target, file: #filePath, line: #line)
            let signature = try XCTUnwrap(frame.knownSignature)
            XCTAssertEqual(signature.source, "authored-declaration")
            XCTAssertEqual(signature.returnType, returnType)
            XCTAssertEqual(signature.parameters.map(\.register), ["x0", "x1"])
            XCTAssertEqual(signature.parameters.map(\.index), [0, 1])
            XCTAssertEqual(signature.parameters.map(\.name), ["first", "second"])
            XCTAssertEqual(frame.arguments.count, 2)
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x8000 })
            guard case let .call(_, result) = call.operation else { return XCTFail("Expected BL call") }
            XCTAssertEqual(result == nil, returnsVoid)
            let text = PseudocodePrinter().print(function: function).text
            XCTAssertTrue(text.contains(target + "("), text)
            XCTAssertEqual(text.contains("= " + target + "("), !returnsVoid, text)
        }
    }

    private func assertCatalogRouting(target: String, returnsVoid: Bool) throws {
        let expected = try XCTUnwrap(MacIRBuilder.knownCallSignature(for: target))
        XCTAssertEqual(expected.returnsVoid, returnsVoid)
        for ssa in [false, true] {
            let baseline = routingFunction(target: target, authored: [:], ssa: ssa)
            let unrelated = routingFunction(target: target,
                authored: ["_unrelated": signature(returnType: "void", parameterCount: 2)], ssa: ssa)
            XCTAssertEqual(baseline.ssaEnabled, ssa)
            let frame = try callFrame(function: baseline, address: 0x8000, label: target, file: #filePath, line: #line)
            XCTAssertEqual(frame.knownSignature, expected)
            XCTAssertEqual(frame.arguments.count, expected.parameters.count)
            let call = try XCTUnwrap(baseline.instructions.first { $0.source.address == 0x8000 })
            guard case let .call(_, result) = call.operation else { return XCTFail("Expected BL call") }
            XCTAssertEqual(result == nil, returnsVoid)
            XCTAssertEqual(PseudocodePrinter().print(function: baseline).text,
                           PseudocodePrinter().print(function: unrelated).text)
        }
    }

    func testVariadicAuthoredDeclarationDoesNotOverrideCatalogInBothModes() throws {
        var variadic = signature(returnType: "void", parameterCount: 2)
        variadic.variadicState = .variadic
        let expected = try XCTUnwrap(MacIRBuilder.knownCallSignature(for: "_malloc"))
        for ssa in [false, true] {
            let function = routingFunction(target: "_malloc", authored: ["_malloc": variadic], ssa: ssa)
            let frame = try callFrame(function: function, address: 0x8000, label: "_malloc", file: #filePath, line: #line)
            XCTAssertEqual(frame.knownSignature, expected)
            XCTAssertEqual(frame.arguments.count, 1)
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x8000 })
            guard case let .call(_, result) = call.operation,
                  case let .register(name, _)? = result else { return XCTFail("Catalog scalar result must remain defined") }
            XCTAssertEqual(name, "x0")
        }
    }

    func testAuthoredFloatingTypedefKeepsBoundResultRegisterInBothModes() throws {
        let parsed = CTypeHeaderParser.parse("typedef double Sample;")
        XCTAssertEqual(parsed.diagnostics, [])
        let authored = signature(returnType: "Sample", parameterCount: 1)
        for ssa in [false, true] {
            let function = routingFunction(target: "_malloc", authored: ["_malloc": authored],
                                           types: parsed.types, ssa: ssa)
            let frame = try callFrame(function: function, address: 0x8000, label: "_malloc", file: #filePath, line: #line)
            XCTAssertEqual(frame.knownSignature?.returnType, "Sample")
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x8000 })
            guard case let .call(_, result) = call.operation,
                  case let .register(name, _)? = result else { return XCTFail("Expected bound FP result") }
            XCTAssertEqual(name, "d0")
        }
    }

    func testMacroRenamedTargetsRequireExactAuthoredNameInBothModes() throws {
        let base = signature(returnType: "void", parameterCount: 2)
        for target in ["_jpeg12_write_scanlines", "_jpeg16_write_scanlines"] {
            for ssa in [false, true] {
                let wrong = routingFunction(target: target,
                    authored: ["_jpeg_write_scanlines": base], ssa: ssa)
                let baseline = routingFunction(target: target, authored: [:], ssa: ssa)
                XCTAssertEqual(PseudocodePrinter().print(function: wrong).text,
                               PseudocodePrinter().print(function: baseline).text)
                let exact = routingFunction(target: target, authored: [target: base], ssa: ssa)
                let frame = try callFrame(function: exact, address: 0x8000, label: target, file: #filePath, line: #line)
                XCTAssertEqual(frame.knownSignature?.source, "authored-declaration")
                XCTAssertEqual(frame.arguments.count, 2)
            }
        }
    }

    func testSameNameInAnotherImageCannotSupplyAuthoredDeclarationInBothModes() throws {
        var snapshot = try importedRoutingSnapshot(target: "_malloc",
            declaration: "void malloc(uint64_t first, uint64_t second);")
        let sibling = ImageSlot(rawValue: 7)
        var other = ImageAnalysis()
        other.functions = [FunctionSummary(id: UUID(), name: "_malloc", startAddress: 0x9000,
                                          endAddress: 0x9004, confidence: 1)]
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "other", path: "/tmp/other",
            kind: "executable", architecture: "arm64", slot: sibling), analysis: other)
        XCTAssertNotNil(snapshot.authoredCallSignaturesByTarget(in: .primary)["_malloc"])
        let otherAuthored = snapshot.authoredCallSignaturesByTarget(in: sibling)
        XCTAssertTrue(otherAuthored.isEmpty)
        for ssa in [false, true] {
            let function = routingFunction(target: "_malloc", authored: otherAuthored, ssa: ssa)
            let frame = try callFrame(function: function, address: 0x8000, label: "_malloc", file: #filePath, line: #line)
            XCTAssertEqual(frame.knownSignature, MacIRBuilder.knownCallSignature(for: "_malloc"))
        }
    }

    func testUnprovenTailBranchDoesNotBecomeAuthoredBLInBothModes() {
        for ssa in [false, true] {
            let function = routingFunction(target: "_malloc",
                authored: ["_malloc": signature(returnType: "void", parameterCount: 2)],
                ssa: ssa, branch: true)
            XCTAssertFalse(function.instructions.contains {
                if case .call = $0.operation { return true }
                return false
            })
        }
    }

    func testAuthoredScalarBeatsReturnOnlyVoidEvidenceInBothModes() throws {
        for ssa in [false, true] {
            let function = routingFunction(target: "_free",
                authored: ["_free": signature(returnType: "uint64_t", parameterCount: 2)],
                directVoid: ["_free": .init(returnType: "void")], ssa: ssa)
            let frame = try callFrame(function: function, address: 0x8000, label: "_free", file: #filePath, line: #line)
            XCTAssertEqual(frame.knownSignature?.source, "authored-declaration")
            XCTAssertEqual(frame.knownSignature?.returnType, "uint64_t")
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x8000 })
            guard case let .call(_, result) = call.operation,
                  case let .register(name, _)? = result else { return XCTFail("Authored scalar must define a result") }
            XCTAssertEqual(name, "x0")
        }
    }

    private struct ContractVariant {
        let returnType: String
        let parameterCount: Int
        let parameters: String
        let evidence: String
    }

    private func assertCallContract(
        label: String,
        callAddress: UInt64,
        bytes: String,
        mnemonic: String,
        operands: String,
        capturedArgumentCount: Int,
        variants: [ContractVariant],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(variants.isEmpty, file: file, line: line)
        let expectedCounts = Set(variants.map(\.parameterCount))
        XCTAssertFalse(expectedCounts.isEmpty, file: file, line: line)
        let variantEvidence = variants.map { variant in
            "\(variant.returnType)(\(variant.parameters)) [\(variant.evidence)]"
        }.joined(separator: " | ")
        let caller = callerRows(callAddress: callAddress, bytes: bytes, mnemonic: mnemonic, operands: operands)

        if mnemonic == "blr" {
            for variant in variants {
                try assertCensusSlotFrame(label: label, callAddress: callAddress, caller: caller,
                    contract: contract(returnType: variant.returnType, parameterCount: variant.parameterCount),
                    expectedCount: variant.parameterCount, evidence: variantEvidence, file: file, line: line)
            }
        } else if label == "_snprintf" {
            try assertSnprintfPaths(callAddress: callAddress, bytes: bytes, variants: variants,
                                    evidence: variantEvidence, file: file, line: line)
        } else if label == "_sscanf" {
            try assertScanfFrame(callAddress: callAddress, bytes: bytes, expectedCount: 4,
                                 evidence: variantEvidence, file: file, line: line)
        } else {
            let calleeBody = capturedCalleeEntryRows(label: label)
            XCTAssertFalse(calleeBody.isEmpty, "\(label): missing captured callee entry rows", file: file, line: line)
            let variant = try XCTUnwrap(variants.first, file: file, line: line)
            if label == "_jpeg_simd_cpu_support" {
                try assertZeroParameterBodyRecovery(label: label, rows: calleeBody,
                    returnType: variant.returnType, expectedCount: variant.parameterCount,
                    caller: caller, callAddress: callAddress, evidence: variantEvidence,
                    file: file, line: line)
            } else {
                let calleeSignature: FunctionSignatureOverride
                if explicitPrototypeDirects.contains(label) {
                    calleeSignature = signature(returnType: variant.returnType,
                                                parameterCount: variant.parameterCount)
                } else {
                    calleeSignature = try recoveredDirectSignature(label: label, rows: calleeBody,
                        returnType: variant.returnType, expectedCount: variant.parameterCount,
                        file: file, line: line)
                }
                try assertDirectFrame(label: label, callAddress: callAddress, caller: caller,
                    signature: calleeSignature,
                    expectedCount: variant.parameterCount, evidence: variantEvidence, file: file, line: line)
            }
        }

        XCTAssertGreaterThanOrEqual(capturedArgumentCount, 0, file: file, line: line)
    }

    private func assertDirectFrame(
        label: String, callAddress: UInt64, caller: [InstructionRow],
        signature calleeSignature: FunctionSignatureOverride, expectedCount: Int,
        evidence: String = "neutral control", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let function = PseudocodePrinter().buildFunction(functionName: "_caller", startAddress: callAddress,
            signatureOverrides: [callAddress: callerSignature],
            authoredCallSignaturesByTarget: [caller.first?.operands ?? label: calleeSignature],
            // Named boolean returns need the same real typedef authority as slot contracts.
            types: libjpegHeaderTypes(file: file, line: line), instructions: caller)
        let frame = try callFrame(function: function, address: callAddress, label: label, file: file, line: line)
        XCTAssertEqual(frame.arguments.count, expectedCount,
            "\(label): scalar authority should render \(expectedCount) arguments from \(evidence)", file: file, line: line)
    }

    private func assertCensusSlotFrame(
        label: String, callAddress: UInt64, caller: [InstructionRow],
        contract slotContract: FunctionPointerSignatureV1, expectedCount: Int,
        evidence: String = "neutral control", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var input = PseudocodeRenderInput(imageSlot: .primary, functionName: "_caller",
            startAddress: callAddress, jumpTables: [:], objcSelectors: [:], nameOverrides: [:],
            signatureOverrides: [callAddress: callerSignature], registerNameOverrides: [:],
            types: libjpegHeaderTypes(file: file, line: line), instructions: caller)
        input.slotCallContracts = [callAddress: slotContract]
        let function = DecompilerC2DataflowCensusTests.buildFunction(printer: PseudocodePrinter(), input: input)
        let frame = try callFrame(function: function, address: callAddress, label: label, file: file, line: line)
        XCTAssertEqual(frame.typedIndirectSignature?.parameters.count, expectedCount,
            "\(label): the census render seam dropped its address-keyed slot contract; \(evidence)", file: file, line: line)
    }

    private func assertSnprintfPaths(
        callAddress: UInt64, bytes: String, variants: [ContractVariant], evidence: String,
        file: StaticString, line: UInt
    ) throws {
        let expected = variants.first?.parameterCount ?? -1
        XCTAssertEqual(expected, 4, "snprintf grouped source paths must retain distinct 4 and 11 counts", file: file, line: line)
        let stringStart: UInt64 = 0x3ccc4
        let stringPath = [
            row(0x3ccc4, "add", "x8, x8, #0x2c"), row(0x3ccc8, "str", "x8, [sp]"),
            row(0x3ccf0, "mov", "x0, x19"), row(0x3ccf4, "mov", "w1, #0xc8"),
            InstructionRow(address: callAddress, bytes: bytes, mnemonic: "bl", operands: "_snprintf",
                           hasBreakpoint: false, comment: nil), row(callAddress + 4, "ret", "")
        ]
        let stringFunction = PseudocodePrinter().buildFunction(functionName: "_caller", startAddress: stringStart,
            signatureOverrides: [stringStart: callerSignature], instructions: stringPath)
        let stringFrame = try callFrame(function: stringFunction, address: callAddress,
                                        label: "_snprintf", file: file, line: line)
        XCTAssertEqual(stringFrame.arguments.count, 4,
            "_snprintf must bind the source string path's exact outgoing suffix store; \(evidence)",
            file: file, line: line)

        let integerStart: UInt64 = 0x3ccd0
        let integerPath = [
            row(0x3ccd0, "ldp", "w9, w10, [x8, #0x2c]"),
            row(0x3ccd4, "ldp", "w11, w12, [x8, #0x34]"),
            row(0x3ccd8, "ldp", "w13, w14, [x8, #0x3c]"),
            row(0x3ccdc, "ldp", "w15, w8, [x8, #0x44]"),
            row(0x3cce0, "stp", "x15, x8, [sp, #0x30]"),
            row(0x3cce4, "stp", "x13, x14, [sp, #0x20]"),
            row(0x3cce8, "stp", "x11, x12, [sp, #0x10]"),
            row(0x3ccec, "stp", "x9, x10, [sp]"),
            row(0x3ccf0, "mov", "x0, x19"), row(0x3ccf4, "mov", "w1, #0xc8"),
            InstructionRow(address: callAddress, bytes: bytes, mnemonic: "bl", operands: "_snprintf",
                           hasBreakpoint: false, comment: nil), row(callAddress + 4, "ret", ""),
        ]
        let integerFunction = PseudocodePrinter().buildFunction(functionName: "_caller", startAddress: integerStart,
            signatureOverrides: [integerStart: callerSignature], instructions: integerPath)
        let integerFrame = try callFrame(function: integerFunction, address: callAddress,
                                         label: "_snprintf", file: file, line: line)
        XCTAssertEqual(integerFrame.arguments.count, 11,
            "_snprintf must bind the source integer path's eight exact outgoing suffix stores; \(evidence)",
            file: file, line: line)
    }

    private func assertScanfFrame(
        callAddress: UInt64, bytes: String, expectedCount: Int, evidence: String,
        file: StaticString, line: UInt
    ) throws {
        let formatAddress: UInt64 = 0x5ba04
        let rows = [
            row(0x464a4, "add", "x8, sp, #0x20"), row(0x464a8, "add", "x9, sp, #0x1f"),
            row(0x464ac, "stp", "x8, x9, [sp]"), row(0x464b0, "adrp", "x1, 0x5b000"),
            row(0x464b4, "add", "x1, x1, #0xa04"), row(0x464b8, "mov", "x0, x19"),
            InstructionRow(address: callAddress, bytes: bytes, mnemonic: "bl", operands: "_sscanf",
                           hasBreakpoint: false, comment: nil), row(callAddress + 4, "ret", "")
        ]
        let function = PseudocodePrinter().buildFunction(functionName: "_caller", startAddress: 0x464a4,
            constantStrings: [formatAddress: .init(text: "%ld%c", kind: .cString)],
            signatureOverrides: [0x464a4: callerSignature], instructions: rows)
        let frame = try callFrame(function: function, address: callAddress, label: "_sscanf", file: file, line: line)
        XCTAssertEqual(frame.arguments.count, expectedCount,
            "_sscanf should bind two fixed and two pointer actuals from %ld%c; \(evidence)", file: file, line: line)
    }

    private func recoveredDirectSignature(
        label: String, rows: [InstructionRow], returnType: String, expectedCount: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> FunctionSignatureOverride {
        let start = try XCTUnwrap(rows.first?.address, file: file, line: line)
        let end = try XCTUnwrap(rows.last?.address, file: file, line: line) + 4
        let summary = FunctionSummary(id: UUID(), name: label, startAddress: start,
                                      endAddress: end, confidence: 1)
        let recovered = try XCTUnwrap(NativeDecompilerSnapshotBuilder.recoveredCalleeParameters(
            target: start, functionsByStart: [start: [summary]], instructions: rows),
            "\(label): captured body did not yield a conservative direct-call contract",
            file: file, line: line)
        XCTAssertEqual(recovered.count, expectedCount,
            "\(label): captured body and source declaration disagree", file: file, line: line)
        return FunctionSignatureOverride(returnType: returnType, args: recovered.enumerated().map {
            ArgOverride(index: $0.offset, name: $0.element.name, type: $0.element.type)
        })
    }

    private func assertZeroParameterBodyRecovery(
        label: String, rows: [InstructionRow], returnType: String, expectedCount: Int,
        caller: [InstructionRow], callAddress: UInt64, evidence: String,
        file: StaticString, line: UInt
    ) throws {
        let start = try XCTUnwrap(rows.first?.address, file: file, line: line)
        let end = try XCTUnwrap(rows.last?.address, file: file, line: line) + 4
        let summary = FunctionSummary(id: UUID(), name: label, startAddress: start,
                                      endAddress: end, confidence: 1)
        let recovered = try XCTUnwrap(NativeDecompilerSnapshotBuilder.recoveredCalleeParameters(
            target: start, functionsByStart: [start: [summary]], instructions: rows),
            "\(label): complete leaf body should authorize an empty parameter list; \(evidence)",
            file: file, line: line)
        XCTAssertEqual(recovered.count, expectedCount, file: file, line: line)
        try assertDirectFrame(label: label, callAddress: callAddress, caller: caller,
            signature: FunctionSignatureOverride(returnType: returnType, args: recovered.enumerated().map {
                ArgOverride(index: $0.offset, name: $0.element.name, type: $0.element.type)
            }), expectedCount: expectedCount, evidence: "complete zero-read callee body",
            file: file, line: line)
    }

    private func assertNeutralDirectBody(
        rows: [InstructionRow], expectedCount: Int, caller: [InstructionRow], callAddress: UInt64
    ) throws {
        let start = try XCTUnwrap(rows.first?.address)
        let summary = FunctionSummary(id: UUID(), name: "_neutral_target", startAddress: start,
                                      endAddress: (rows.last?.address ?? start) + 4, confidence: 1)
        let recovered = try XCTUnwrap(NativeDecompilerSnapshotBuilder.recoveredCalleeParameters(
            target: start, functionsByStart: [start: [summary]], instructions: rows))
        XCTAssertEqual(recovered.count, expectedCount)
        try assertDirectFrame(label: "neutral_target", callAddress: callAddress, caller: caller,
            signature: FunctionSignatureOverride(returnType: "void", args: recovered.enumerated().map {
                ArgOverride(index: $0.offset, name: $0.element.name, type: $0.element.type)
            }), expectedCount: expectedCount, evidence: "neutral callee entry-read inference")
    }

    private func neutralVariadicFrame(format: String) throws -> MacIRCallFrame {
        let formatAddress: UInt64 = 0x5fb00
        let callAddress: UInt64 = 0x7440
        let caller = [
            row(0x7400, "stp", "x8, x9, [sp]"),
            row(0x7404, "stp", "x10, x11, [sp, #0x10]"),
            row(0x7408, "stp", "x12, x13, [sp, #0x20]"),
            row(0x740c, "stp", "x14, x15, [sp, #0x30]"),
            row(0x7410, "adr", "x2, 0x\(String(formatAddress, radix: 16))"),
            row(0x7414, "mov", "x0, x19"),
            row(0x7418, "mov", "x1, #0xc8"),
            row(callAddress, "bl", "neutral_variadic_sink"),
        ]
        var state = BuilderState()
        state.constantStrings = [formatAddress: .init(text: format, kind: .cString)]
        let builder = MacIRBuilder()
        for instruction in caller.dropLast() {
            let source = MacIRSourceSpan(address: instruction.address, byteText: instruction.bytes,
                mnemonic: instruction.mnemonic.lowercased(), operands: instruction.operands,
                comment: instruction.comment, structuredOperands: instruction.structuredOperands)
            _ = builder.operationForVectorRegion(for: source, state: &state)
        }
        let signature = MacIRCallSignature(target: "neutral_variadic_sink", returnType: "int32_t",
            parameters: [
                .init(index: 0, register: "x0", type: "char *", name: "destination"),
                .init(index: 1, register: "x1", type: "size_t", name: "capacity"),
                .init(index: 2, register: "x2", type: "const char *", name: "format"),
            ], isVariadic: true, source: "source-correlated",
            format: .init(kind: "printf", formatIndex: 3, firstArgIndex: 4))
        return try XCTUnwrap(state.callFrame(target: "neutral_variadic_sink",
            knownSignature: signature, controlInputs: .none, recoverObjectiveCTail: false))
    }

    /// The return typedefs the slot contracts name, as the header import produces them
    /// (`CTypeHeaderParser.parse(_:).types`). The pasted-header parser admits no
    /// preprocessing, so the declarations are the libjpeg-turbo 3.2.0 lines with
    /// HAVE_BOOLEAN undefined and DCTSIZE2 expanded:
    /// - JSAMPLE: Fixtures/libjpeg-turbo-3.2.0/jmorecfg.h:49
    /// - JCOEF: jmorecfg.h:78
    /// - boolean: jmorecfg.h:203-204 (#ifndef HAVE_BOOLEAN)
    /// - JSAMPROW, JSAMPARRAY: jpeglib.h:89, jpeglib.h:91
    /// - JBLOCK: jpeglib.h:111, with DCTSIZE2 = 64 from jpeglib.h:67
    /// - JBLOCKROW, JBLOCKARRAY: jpeglib.h:112-113
    private func libjpegHeaderTypes(file: StaticString, line: UInt) -> [TypeDefinition] {
        let parsed = CTypeHeaderParser.parse("""
            typedef unsigned char JSAMPLE;
            typedef short JCOEF;
            typedef int boolean;
            typedef JSAMPLE *JSAMPROW;
            typedef JSAMPROW *JSAMPARRAY;
            typedef JCOEF JBLOCK[64];
            typedef JBLOCK *JBLOCKROW;
            typedef JBLOCKROW *JBLOCKARRAY;
            """)
        XCTAssertEqual(parsed.diagnostics, [], file: file, line: line)
        XCTAssertEqual(parsed.types.map(\.name),
            ["JSAMPLE", "JCOEF", "boolean", "JSAMPROW", "JSAMPARRAY", "JBLOCK", "JBLOCKROW", "JBLOCKARRAY"],
            "the header import must admit every libjpeg typedef the slot returns name", file: file, line: line)
        return parsed.types
    }

    private var callerSignature: FunctionSignatureOverride {
        signature(returnType: "void", parameterCount: 8)
    }

    private var explicitPrototypeDirects: Set<String> {
        [
            "_examine_app14",
            "_fill_inverse_cmap",
            "_j16init_d_post_controller",
            "_jpeg_open_backing_store",
            "_jzero_far",
        ]
    }

    private func signature(returnType: String, parameterCount: Int) -> FunctionSignatureOverride {
        FunctionSignatureOverride(returnType: returnType, args: (0..<parameterCount).map {
            ArgOverride(index: $0, name: "arg\($0)", type: "uint64_t")
        })
    }

    private func contract(returnType: String, parameterCount: Int) -> FunctionPointerSignatureV1 {
        FunctionPointerSignatureV1(returnType: returnType, parameters: (0..<parameterCount).map {
            .init(name: "arg\($0)", type: "uint64_t")
        })
    }

    private func callerRows(callAddress: UInt64, bytes: String, mnemonic: String, operands: String) -> [InstructionRow] {
        [InstructionRow(address: callAddress, bytes: bytes, mnemonic: mnemonic, operands: operands,
                        hasBreakpoint: false, comment: nil), row(callAddress + 4, "ret", "")]
    }

    private func callFrame(
        function: MacIRFunction, address: UInt64, label: String,
        file: StaticString, line: UInt
    ) throws -> MacIRCallFrame {
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == address },
                                        "\(label): missing captured call row", file: file, line: line)
        guard case let .call(frame, _) = instruction.operation else {
            XCTFail("\(label): captured row did not lift as a call", file: file, line: line)
            throw NSError(domain: "CallContractFixture", code: 1)
        }
        return frame
    }

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                       hasBreakpoint: false, comment: nil)
    }

    private func capturedCalleeEntryRows(label: String) -> [InstructionRow] {
        let specs: [String: [(UInt64, String, String)]] = [
            "_alloc_small": [(0x46520, "stp", "d9, d8, [sp, #-0x70]!"), (0x46524, "stp", "x28, x27, [sp, #0x10]"), (0x46528, "stp", "x26, x25, [sp, #0x20]"), (0x4652c, "stp", "x24, x23, [sp, #0x30]"), (0x46530, "stp", "x22, x21, [sp, #0x40]"), (0x46534, "stp", "x20, x19, [sp, #0x50]"), (0x46538, "stp", "x29, x30, [sp, #0x60]"), (0x4653c, "add", "x29, sp, #0x60"), (0x46540, "mov", "x21, x2"), (0x46544, "mov", "x19, x1"), (0x46548, "mov", "x20, x0")],
            "_create_colorindex": [(0x47d14, "stp", "x22, x21, [sp, #-0x30]!"), (0x47d18, "stp", "x20, x19, [sp, #0x10]"), (0x47d1c, "stp", "x29, x30, [sp, #0x20]"), (0x47d20, "add", "x29, sp, #0x20"), (0x47d24, "mov", "x19, x0")],
            "_emit_byte": [(0x4ce14, "stp", "x20, x19, [sp, #-0x20]!"), (0x4ce18, "stp", "x29, x30, [sp, #0x10]"), (0x4ce1c, "add", "x29, sp, #0x10"), (0x4ce20, "ldr", "x8, [x1, #0x28]"), (0x4ce24, "ldr", "x9, [x8]"), (0x4ce28, "add", "x10, x9, #0x1"), (0x4ce2c, "str", "x10, [x8]"), (0x4ce30, "strb", "w0, [x9]"), (0x4ce34, "ldr", "x9, [x8, #0x8]"), (0x4ce38, "subs", "x9, x9, #0x1"), (0x4ce3c, "str", "x9, [x8, #0x8]"), (0x4ce40, "b.ne", "0x4ce58"), (0x4ce44, "mov", "x19, x1"), (0x4ce48, "ldr", "x8, [x8, #0x18]"), (0x4ce4c, "mov", "x0, x1"), (0x4ce50, "blr", "x8"), (0x4ce54, "cbz", "w0, 0x4ce64")],
            "_emit_eobrun": [(0x1d24c, "ldr", "w8, [x0, #0x7c]")],
            "_examine_app14": [(0x33fe0, "stp", "x22, x21, [sp, #-0x30]!"), (0x33fe4, "stp", "x20, x19, [sp, #0x10]"), (0x33fe8, "stp", "x29, x30, [sp, #0x20]"), (0x33fec, "add", "x29, sp, #0x20"), (0x33ff0, "mov", "x19, x0"), (0x33ff4, "cmp", "w2, #0xc"), (0x33ff8, "b.lo", "0x34094"), (0x33ffc, "ldrb", "w8, [x1]"), (0x34000, "cmp", "w8, #0x41"), (0x34004, "b.ne", "0x34094"), (0x34008, "ldrb", "w8, [x1, #0x1]"), (0x3400c, "cmp", "w8, #0x64"), (0x34010, "b.ne", "0x34094"), (0x34014, "ldrb", "w8, [x1, #0x2]"), (0x34018, "cmp", "w8, #0x6f"), (0x3401c, "b.ne", "0x34094"), (0x34020, "ldrb", "w8, [x1, #0x3]"), (0x34024, "cmp", "w8, #0x62"), (0x34028, "b.ne", "0x34094"), (0x3402c, "ldrb", "w8, [x1, #0x4]"), (0x34030, "cmp", "w8, #0x65"), (0x34034, "b.ne", "0x34094"), (0x34038, "ldurh", "w8, [x1, #0x5]"), (0x3403c, "rev16", "w8, w8"), (0x34040, "ldurh", "w9, [x1, #0x7]"), (0x34044, "rev16", "w9, w9"), (0x34048, "ldurh", "w10, [x1, #0x9]"), (0x3404c, "rev16", "w10, w10"), (0x34050, "ldrb", "w20, [x1, #0xb]"), (0x34054, "ldr", "x11, [x19]"), (0x34058, "stp", "w9, w10, [x11, #0x30]"), (0x3405c, "str", "w20, [x11, #0x38]"), (0x34060, "mov", "w9, #0x4e"), (0x34064, "stp", "w9, w8, [x11, #0x28]"), (0x34068, "ldr", "x8, [x11, #0x8]"), (0x3406c, "mov", "w21, #0x1"), (0x34070, "mov", "x0, x19"), (0x34074, "mov", "w1, #0x1"), (0x34078, "blr", "x8"), (0x3407c, "str", "w21, [x19, #0x184]"), (0x34080, "strb", "w20, [x19, #0x188]"), (0x34084, "ldp", "x29, x30, [sp, #0x20]"), (0x34088, "ldp", "x20, x19, [sp, #0x10]"), (0x3408c, "ldp", "x22, x21, [sp], #0x30"), (0x34090, "ret", ""), (0x34094, "ldr", "x8, [x19]"), (0x34098, "mov", "w9, #0x50"), (0x3409c, "add", "w10, w2, w3")],
            "_fill_inverse_cmap": [(0x4b44c, "stp", "x28, x27, [sp, #-0x60]!"), (0x4b450, "stp", "x26, x25, [sp, #0x10]"), (0x4b454, "stp", "x24, x23, [sp, #0x20]"), (0x4b458, "stp", "x22, x21, [sp, #0x30]"), (0x4b45c, "stp", "x20, x19, [sp, #0x40]"), (0x4b460, "stp", "x29, x30, [sp, #0x50]"), (0x4b464, "add", "x29, sp, #0x50"), (0x4b468, "mov", "w9, #0xa160"), (0x4b46c, "adrp", "x16, 21 ; 0x60000"), (0x4b470, "ldr", "x16, [x16] ; literal pool symbol address: ___chkstk_darwin"), (0x4b474, "blr", "x16"), (0x4b478, "sub", "sp, sp, #0xa, lsl #12"), (0x4b47c, "sub", "sp, sp, #0x160"), (0x4b480, "adrp", "x8, 21 ; 0x60000"), (0x4b484, "ldr", "x8, [x8, #0x18] ; literal pool symbol address: ___stack_chk_guard"), (0x4b488, "ldr", "x8, [x8]"), (0x4b48c, "stur", "x8, [x29, #-0x60]"), (0x4b490, "ldr", "x8, [x0, #0x288]"), (0x4b494, "ldr", "x6, [x8, #0x38]"), (0x4b498, "ldr", "w8, [x0, #0x9c]"), (0x4b49c, "cmp", "w8, #0x0"), (0x4b4a0, "stp", "x6, x3, [sp, #0x10]"), (0x4b4a4, "stp", "w1, w2, [sp, #0x8]"), (0x4b4a8, "b.le", "0x4b7bc")],
            "_finish_pass": [(0x4bc30, "stp", "x20, x19, [sp, #-0x20]!"), (0x4bc34, "stp", "x29, x30, [sp, #0x10]"), (0x4bc38, "add", "x29, sp, #0x10"), (0x4bc3c, "mov", "x19, x0")],
            "_get_byte": [(0x4e0d0, "stp", "x20, x19, [sp, #-0x20]!"), (0x4e0d4, "stp", "x29, x30, [sp, #0x10]"), (0x4e0d8, "add", "x29, sp, #0x10"), (0x4e0dc, "ldr", "x20, [x0, #0x28]")],
            "_init_simd": [(0x57ba4, "sub", "sp, sp, #0x40"), (0x57ba8, "stp", "x22, x21, [sp, #0x10]"), (0x57bac, "stp", "x20, x19, [sp, #0x20]"), (0x57bb0, "stp", "x29, x30, [sp, #0x30]"), (0x57bb4, "add", "x29, sp, #0x30"), (0x57bb8, "strh", "wzr, [sp, #0xe]"), (0x57bbc, "ldr", "w8, [x0, #0x20]")],
            "_j12copy_sample_rows": [(0x4b8f8, "cmp", "w4, #0x1"), (0x4b8fc, "b.lt", "0x4b948"), (0x4b900, "stp", "x22, x21, [sp, #-0x30]!"), (0x4b904, "stp", "x20, x19, [sp, #0x10]"), (0x4b908, "stp", "x29, x30, [sp, #0x20]"), (0x4b90c, "add", "x29, sp, #0x20"), (0x4b910, "ubfiz", "x19, x5, #1, #32"), (0x4b914, "add", "x20, x2, w3, sxtw #3"), (0x4b918, "add", "w21, w4, #0x1"), (0x4b91c, "add", "x22, x0, w1, sxtw #3"), (0x4b920, "ldr", "x1, [x22], #0x8")],
            "_j12init_d_diff_controller": [(0x2c948, "stp", "x28, x27, [sp, #-0x60]!"), (0x2c94c, "stp", "x26, x25, [sp, #0x10]"), (0x2c950, "stp", "x24, x23, [sp, #0x20]"), (0x2c954, "stp", "x22, x21, [sp, #0x30]"), (0x2c958, "stp", "x20, x19, [sp, #0x40]"), (0x2c95c, "stp", "x29, x30, [sp, #0x50]"), (0x2c960, "add", "x29, sp, #0x50"), (0x2c964, "mov", "x21, x1"), (0x2c968, "mov", "x20, x0")],
            "_j12init_forward_dct": [(0x6db0, "stp", "x22, x21, [sp, #-0x30]!"), (0x6db4, "stp", "x20, x19, [sp, #0x10]"), (0x6db8, "stp", "x29, x30, [sp, #0x20]"), (0x6dbc, "add", "x29, sp, #0x20"), (0x6dc0, "mov", "x19, x0")],
            "_j16init_d_diff_controller": [(0x2d050, "stp", "x28, x27, [sp, #-0x60]!"), (0x2d054, "stp", "x26, x25, [sp, #0x10]"), (0x2d058, "stp", "x24, x23, [sp, #0x20]"), (0x2d05c, "stp", "x22, x21, [sp, #0x30]"), (0x2d060, "stp", "x20, x19, [sp, #0x40]"), (0x2d064, "stp", "x29, x30, [sp, #0x50]"), (0x2d068, "add", "x29, sp, #0x50"), (0x2d06c, "mov", "x21, x1"), (0x2d070, "mov", "x20, x0")],
            "_j16init_d_post_controller": [(0x3ad1c, "stp", "x20, x19, [sp, #-0x20]!"), (0x3ad20, "stp", "x29, x30, [sp, #0x10]"), (0x3ad24, "add", "x29, sp, #0x10"), (0x3ad28, "mov", "x19, x0"), (0x3ad2c, "ldr", "x8, [x0, #0x238]"), (0x3ad30, "ldr", "w9, [x8, #0x14]"), (0x3ad34, "ldr", "w8, [x0, #0x128]"), (0x3ad38, "cbz", "w9, 0x3adb8"), (0x3ad3c, "sub", "w9, w8, #0x11"), (0x3ad40, "cmn", "w9, #0x4"), (0x3ad44, "b.hs", "0x3ad64"), (0x3ad48, "ldr", "x9, [x19]"), (0x3ad4c, "mov", "w10, #0x10"), (0x3ad50, "stp", "w10, w8, [x9, #0x28]"), (0x3ad54, "ldr", "x8, [x19]"), (0x3ad58, "ldr", "x8, [x8]"), (0x3ad5c, "mov", "x0, x19"), (0x3ad60, "blr", "x8"), (0x3ad64, "ldr", "x8, [x19, #0x8]"), (0x3ad68, "ldr", "x8, [x8]"), (0x3ad6c, "mov", "x0, x19"), (0x3ad70, "mov", "w1, #0x1"), (0x3ad74, "mov", "w2, #0x40"), (0x3ad78, "blr", "x8"), (0x3ad7c, "str", "x0, [x19, #0x250]"), (0x3ad80, "adrp", "x8, 0 ; 0x3a000"), (0x3ad84, "add", "x8, x8, #0xdd0"), (0x3ad88, "str", "x8, [x0]"), (0x3ad8c, "stp", "xzr, xzr, [x0, #0x20]"), (0x3ad90, "ldr", "w8, [x19, #0x6c]"), (0x3ad94, "cbz", "w8, 0x3adc4"), (0x3ad98, "ldr", "x8, [x19]"), (0x3ad9c, "mov", "w9, #0x30"), (0x3ada0, "str", "w9, [x8, #0x28]"), (0x3ada4, "ldr", "x1, [x8]"), (0x3ada8, "mov", "x0, x19"), (0x3adac, "ldp", "x29, x30, [sp, #0x10]"), (0x3adb0, "ldp", "x20, x19, [sp], #0x20"), (0x3adb4, "br", "x1")],
            "_jcopy_block_row": [(0x4b8e0, "mov", "x8, x0"), (0x4b8e4, "ubfiz", "x2, x2, #7, #32"), (0x4b8e8, "mov", "x0, x1")],
            "_jcopy_sample_rows": [(0x4b88c, "cmp", "w4, #0x1"), (0x4b890, "b.lt", "0x4b8dc"), (0x4b894, "stp", "x22, x21, [sp, #-0x30]!"), (0x4b898, "stp", "x20, x19, [sp, #0x10]"), (0x4b89c, "stp", "x29, x30, [sp, #0x20]"), (0x4b8a0, "add", "x29, sp, #0x20"), (0x4b8a4, "mov", "w19, w5"), (0x4b8a8, "add", "x20, x2, w3, sxtw #3"), (0x4b8ac, "add", "w21, w4, #0x1"), (0x4b8b0, "add", "x22, x0, w1, sxtw #3"), (0x4b8b4, "ldr", "x1, [x22], #0x8")],
            "_jinit_d_coef_controller": [(0x23aa8, "stp", "x26, x25, [sp, #-0x50]!"), (0x23aac, "stp", "x24, x23, [sp, #0x10]"), (0x23ab0, "stp", "x22, x21, [sp, #0x20]"), (0x23ab4, "stp", "x20, x19, [sp, #0x30]"), (0x23ab8, "stp", "x29, x30, [sp, #0x40]"), (0x23abc, "add", "x29, sp, #0x40"), (0x23ac0, "mov", "x21, x1"), (0x23ac4, "mov", "x19, x0")],
            "_jpeg_alloc_huff_table": [(0x1b5e8, "stp", "x29, x30, [sp, #-0x10]!"), (0x1b5ec, "mov", "x29, sp"), (0x1b5f0, "ldr", "x8, [x0, #0x8]")],
            "_jpeg_fill_bit_buffer": [(0x2da88, "stp", "x26, x25, [sp, #-0x50]!"), (0x2da8c, "stp", "x24, x23, [sp, #0x10]"), (0x2da90, "stp", "x22, x21, [sp, #0x20]"), (0x2da94, "stp", "x20, x19, [sp, #0x30]"), (0x2da98, "stp", "x29, x30, [sp, #0x40]"), (0x2da9c, "add", "x29, sp, #0x40"), (0x2daa0, "mov", "x23, x3"), (0x2daa4, "mov", "x21, x2"), (0x2daa8, "mov", "x20, x1"), (0x2daac, "mov", "x19, x0")],
            "_jpeg_make_c_derived_tbl": [(0x8b88, "stp", "x28, x27, [sp, #-0x60]!"), (0x8b8c, "stp", "x26, x25, [sp, #0x10]"), (0x8b90, "stp", "x24, x23, [sp, #0x20]"), (0x8b94, "stp", "x22, x21, [sp, #0x30]"), (0x8b98, "stp", "x20, x19, [sp, #0x40]"), (0x8b9c, "stp", "x29, x30, [sp, #0x50]"), (0x8ba0, "add", "x29, sp, #0x50"), (0x8ba4, "sub", "sp, sp, #0x520"), (0x8ba8, "mov", "x22, x3"), (0x8bac, "mov", "x20, x2"), (0x8bb0, "mov", "x21, x1"), (0x8bb4, "mov", "x19, x0")],
            "_jpeg_open_backing_store": [(0x476cc, "ldr", "x8, [x0]"), (0x476d0, "mov", "w9, #0x33"), (0x476d4, "str", "w9, [x8, #0x28]"), (0x476d8, "ldr", "x1, [x8]"), (0x476dc, "br", "x1")],
            "_jpeg_simd_cpu_support": [(0x57b30, "mov", "w0, #0x10"), (0x57b34, "ret", "")],
            "_jsimd_set_huff_encode_one_block": [(0x584e0, "stp", "x20, x19, [sp, #-0x20]!"), (0x584e4, "stp", "x29, x30, [sp, #0x10]"), (0x584e8, "add", "x29, sp, #0x10"), (0x584ec, "mov", "x19, x0")],
            "_jzero_far": [(0x4b8f4, "b", "0x58618 ; symbol stub for: _bzero")],
            "_process_restart": [(0x3a3b8, "stp", "x20, x19, [sp, #-0x20]!"), (0x3a3bc, "stp", "x29, x30, [sp, #0x10]"), (0x3a3c0, "add", "x29, sp, #0x10"), (0x3a3c4, "mov", "x19, x0")],
            "_read_and_discard_scanlines": [(0x2235c, "sub", "sp, sp, #0x50"), (0x22360, "stp", "x24, x23, [sp, #0x10]"), (0x22364, "stp", "x22, x21, [sp, #0x20]"), (0x22368, "stp", "x20, x19, [sp, #0x30]"), (0x2236c, "stp", "x29, x30, [sp, #0x40]"), (0x22370, "add", "x29, sp, #0x40"), (0x22374, "mov", "x20, x1"), (0x22378, "mov", "x19, x0")],
            "_start_iMCU_row": [(0x1c80, "ldr", "x8, [x0, #0x208]")],
        ]
        return (specs[label] ?? []).map { row($0.0, $0.1, $0.2) }
    }
}
