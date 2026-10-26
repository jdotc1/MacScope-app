#import <Foundation/Foundation.h>

#include "NativeDecompilerWireBridge.hpp"
#include "CanonicalRequest.hpp"

#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <string>

using namespace macscope::native_decompiler;
using namespace macscope::native_decompiler::xpc_bridge;

namespace {

NSUUID *const kRequestID = [[NSUUID alloc]
    initWithUUIDString:@"00000000-0000-0000-0000-00000000000A"];
NSUUID *const kFullRequestID = [[NSUUID alloc]
    initWithUUIDString:@"00000000-0000-0000-0000-000000000042"];
NSUUID *const kPackageRequestID = [[NSUUID alloc]
    initWithUUIDString:@"00000000-0000-0000-0000-000000000077"];

NSData *binaryPlist(NSDictionary *root) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&error];
    assert(data != nil);
    assert(error == nil);
    return data;
}

NSDictionary *targetObject(NSUInteger byteCount) {
    return @{
        @"rawCPUType": @"0100000c",
        @"rawCPUSubtype": @"00000000",
        @"normalizedVariant": @"arm64",
        @"recognizedCapabilityBits": @"00000000",
        @"selectedSliceSHA256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        @"selectedSliceByteCount": [NSString stringWithFormat:@"%016lx", byteCount],
        @"profileID": @"apple-aarch64-pac-visible-clobber-v1",
        @"languageID": @"AARCH64:LE:64:AppleSilicon",
        @"compilerSpecID": @"default",
        @"contextProfileSHA256": @"6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
        @"context": @[
            @{@"name": @"ShowPAC", @"value": @1},
            @{@"name": @"PAC_clobber", @"value": @1},
            @{@"name": @"ShowBTI", @"value": @0},
            @{@"name": @"ShowMemTag", @"value": @0},
        ],
    };
}

NSDictionary *emptyAuthoredInputs() {
    return @{
        @"schemaVersion": @1,
        @"names": @[],
        @"signatures": @[],
        @"appliedTypes": @[],
        @"typeDefinitions": @[],
    };
}

NSDictionary *budgetObject(NSUInteger maxCodeBytes, NSUInteger maxOutputBytes,
                           NSString *profileID = @"native-product-budget-v1") {
    return @{
        @"profileID": profileID,
        @"maxCodeBytes": @(maxCodeBytes),
        @"maxInstructions": @65536,
        @"maxOperations": @262144,
        @"maxOutputBytes": @(maxOutputBytes),
        @"maxWallTimeMilliseconds": @"0000000000001388",
    };
}

std::uint64_t testHexUInt64(NSString *value) {
    return strtoull(value.UTF8String, nullptr, 16);
}

std::vector<std::uint8_t> testBytes(NSData *data) {
    const auto *begin = static_cast<const std::uint8_t *>(data.bytes);
    return {begin, begin + data.length};
}

std::vector<std::uint8_t> sealRequestDigest(
    NSMutableDictionary *root,
    const AuthoredInputs& authoredInputs = {}
) {
    NSMutableDictionary *body = root[@"body"];
    NSDictionary *targetObjectValue = body[@"target"];
    TargetProfile target = normalizeAppleMachOTarget(
        static_cast<std::uint32_t>(testHexUInt64(targetObjectValue[@"rawCPUType"])),
        static_cast<std::uint32_t>(testHexUInt64(targetObjectValue[@"rawCPUSubtype"])),
        std::string([targetObjectValue[@"selectedSliceSHA256"] UTF8String]),
        testHexUInt64(targetObjectValue[@"selectedSliceByteCount"])
    );
    NSDictionary *imageObject = body[@"image"];
    ImageIdentity image{
        std::string([imageObject[@"imageID"] UTF8String]),
        std::string([imageObject[@"uuid"] UTF8String]),
        testHexUInt64(imageObject[@"preferredLoadAddress"]),
    };
    NSDictionary *functionObject = body[@"function"];
    FunctionIdentity function{
        std::string([functionObject[@"functionID"] UTF8String]),
        std::string([functionObject[@"name"] UTF8String]),
        testHexUInt64(functionObject[@"entryAddress"]),
        testHexUInt64(functionObject[@"endAddressExclusive"]),
        {},
    };
    std::vector<MemoryRegion> regions;
    for (NSDictionary *region in body[@"memoryRegions"]) {
        std::vector<std::string> patches;
        for (NSString *patch in region[@"appliedPatchIDs"]) {
            patches.emplace_back(patch.UTF8String);
        }
        regions.push_back({
            std::string([region[@"name"] UTF8String]),
            testHexUInt64(region[@"startAddress"]),
            std::string([region[@"permissions"] UTF8String]),
            testBytes(region[@"rawBytes"]),
            testBytes(region[@"effectiveBytes"]),
            std::move(patches),
        });
    }
    std::vector<SymbolRecord> symbols;
    for (NSDictionary *symbol in body[@"symbols"]) {
        symbols.push_back({
            std::string([symbol[@"imageID"] UTF8String]),
            testHexUInt64(symbol[@"address"]),
            std::string([symbol[@"name"] UTF8String]),
            std::string([symbol[@"kind"] UTF8String]),
        });
    }
    ByteProvider bytes(std::move(regions));
    SymbolProvider symbolProvider(std::move(symbols));
    NSString *profileID = body[@"budgets"][@"profileID"];
    const ProfiledAnalysisBudgets budgets =
        [profileID isEqualToString:@"native-product-budget-v3"] ? productAnalysisBudgetsV3()
        : [profileID isEqualToString:@"native-product-budget-v2"] ? productAnalysisBudgetsV2()
        : productAnalysisBudgetsV1();
    NSString *operation = [root[@"operation"] isKindOfClass:[NSString class]] ? root[@"operation"] : @"decompile";
    const std::string operationText([operation UTF8String]);
    const std::string digest = canonicalRequestSha256V2({
        target, image, function, bytes, symbolProvider, authoredInputs, budgets, 3U, operationText,
    });
    body[@"requestSHA256"] = [NSString stringWithUTF8String:digest.c_str()];
    return canonicalRequestV2({
        target, image, function, bytes, symbolProvider, authoredInputs, budgets, 3U, operationText,
    });
}

NSMutableDictionary *validRequestObject() {
    static constexpr std::uint8_t rawBytes[] = {0x10, 0x20, 0x30, 0x40};
    static constexpr std::uint8_t effectiveBytes[] = {0xaa, 0xbb, 0xcc, 0xdd};
    NSMutableDictionary *root = [@{
        @"schemaVersion": @3,
        @"requestID": kRequestID.UUIDString,
        @"operation": @"decompile",
        @"body": [@{
            @"requestID": kRequestID.UUIDString,
            @"requestSHA256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            @"target": targetObject(4),
            @"image": @{
                @"imageID": @"image:main",
                @"uuid": @"10000000-0000-0000-0000-000000000001",
                @"preferredLoadAddress": @"0000000000001000",
            },
            @"function": @{
                @"functionID": @"function:main",
                @"name": @"main",
                @"entryAddress": @"0000000000001000",
                @"endAddressExclusive": @"0000000000001004",
            },
            @"memoryRegions": @[@{
                @"name": @"__text",
                @"startAddress": @"0000000000001000",
                @"permissions": @"r-x",
                @"rawBytes": [NSData dataWithBytes:rawBytes length:sizeof(rawBytes)],
                @"effectiveBytes": [NSData dataWithBytes:effectiveBytes length:sizeof(effectiveBytes)],
                @"appliedPatchIDs": @[@"patch000001"],
            }],
            @"symbols": @[@{
                @"imageID": @"image:main",
                @"address": @"0000000000001000",
                @"name": @"main",
                @"kind": @"function",
            }],
            @"authoredInputs": emptyAuthoredInputs(),
            @"budgets": budgetObject(1048576, 1048576),
        } mutableCopy],
    } mutableCopy];
    sealRequestDigest(root);
    return root;
}

NSMutableDictionary *fullFamilyRequestObject() {
    static constexpr std::uint8_t rawBytes[16] = {};
    static constexpr std::uint8_t effectiveBytes[16] = {
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    };
    NSMutableDictionary *root = [@{
        @"schemaVersion": @3,
        @"requestID": kFullRequestID.UUIDString,
        @"operation": @"decompile",
        @"body": [@{
            @"requestID": kFullRequestID.UUIDString,
            @"requestSHA256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            @"target": targetObject(16),
            @"image": @{
                @"imageID": @"image.main",
                @"uuid": @"00000000-0000-0000-0000-000000000001",
                @"preferredLoadAddress": @"0000000000001000",
            },
            @"function": @{
                @"functionID": @"function.fixture",
                @"name": @"_fixture",
                @"entryAddress": @"0000000000001000",
                @"endAddressExclusive": @"0000000000001010",
            },
            @"memoryRegions": @[@{
                @"name": @"__text",
                @"startAddress": @"0000000000001000",
                @"permissions": @"r-x",
                @"rawBytes": [NSData dataWithBytes:rawBytes length:sizeof(rawBytes)],
                @"effectiveBytes": [NSData dataWithBytes:effectiveBytes length:sizeof(effectiveBytes)],
                @"appliedPatchIDs": @[@"patch000000"],
            }],
            @"symbols": @[@{
                @"imageID": @"image.main",
                @"address": @"0000000000001000",
                @"name": @"_fixture",
                @"kind": @"function",
            }],
            @"authoredInputs": emptyAuthoredInputs(),
            @"budgets": budgetObject(1048576, 1048576),
        } mutableCopy],
    } mutableCopy];
    sealRequestDigest(root);
    return root;
}

NSMutableDictionary *packageBackedRequestObject() {
    static constexpr std::uint8_t rawBytes[64] = {};
    // mov w0, #42; ret, followed by caller-owned mapped NOP lookahead.
    static constexpr std::uint8_t effectiveBytes[64] = {
        0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6,
        0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5,
        0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5,
        0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5,
        0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5,
        0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5,
        0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5,
        0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5,
    };
    NSMutableDictionary *root = [@{
        @"schemaVersion": @3,
        @"requestID": kPackageRequestID.UUIDString,
        @"operation": @"decompile",
        @"body": [@{
            @"requestID": kPackageRequestID.UUIDString,
            @"requestSHA256": @"7777777777777777777777777777777777777777777777777777777777777777",
            @"target": targetObject(64),
            @"image": @{
                @"imageID": @"image.package-backed",
                @"uuid": @"00000000-0000-0000-0000-000000000077",
                @"preferredLoadAddress": @"0000000000001000",
            },
            @"function": @{
                @"functionID": @"function.package-backed.mov42",
                @"name": @"_returnFortyTwo",
                @"entryAddress": @"0000000000001000",
                @"endAddressExclusive": @"0000000000001008",
            },
            @"memoryRegions": @[@{
                @"name": @"__text",
                @"startAddress": @"0000000000001000",
                @"permissions": @"r-x",
                @"rawBytes": [NSData dataWithBytes:rawBytes length:sizeof(rawBytes)],
                @"effectiveBytes": [NSData dataWithBytes:effectiveBytes length:sizeof(effectiveBytes)],
                @"appliedPatchIDs": @[@"patch000077"],
            }],
            @"symbols": @[@{
                @"imageID": @"image.package-backed",
                @"address": @"0000000000001000",
                @"name": @"_returnFortyTwo",
                @"kind": @"function",
            }],
            @"authoredInputs": emptyAuthoredInputs(),
            @"budgets": budgetObject(1048576, 1048576),
        } mutableCopy],
    } mutableCopy];
    sealRequestDigest(root);
    return root;
}

void testRequestUsesEffectiveBytesAndPreservesRawBytes() {
    DecodedRequest decoded = decodeRequest(binaryPlist(validRequestObject()), kRequestID);
    const auto raw = decoded.request.rawFunctionBytes();
    const auto effective = decoded.request.effectiveFunctionBytes();
    assert((raw == std::vector<std::uint8_t>{0x10, 0x20, 0x30, 0x40}));
    assert((effective == std::vector<std::uint8_t>{0xaa, 0xbb, 0xcc, 0xdd}));
    assert(decoded.request.functionBytes() == effective);
}

void testDecodesSwiftWireCodecBinaryGolden() {
    NSString *base64 = @"YnBsaXN0MDDUAQIDBAUGBwhdc2NoZW1hVmVyc2lvbllyZXF1ZXN0SURZb3BlcmF0aW9uVGJvZHkQAV8QJDAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwQVlkZWNvbXBpbGXaAgkKCwwNDg8QEQYSExQVHCQxNT5dcmVxdWVzdFNIQTI1NlpsYW5ndWFnZUlEXmNvbXBpbGVyU3BlY0lEVWltYWdlWGZ1bmN0aW9uXW1lbW9yeVJlZ2lvbnNXc3ltYm9sc1l0eXBlSGludHNXYnVkZ2V0c18QQGFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFfEBFBQVJDSDY0OkxFOjY0OnY4QVdkZWZhdWx00xYXGBkaG1dpbWFnZUlEVHV1aWRfEBRwcmVmZXJyZWRMb2FkQWRkcmVzc1ppbWFnZTptYWluXxAkMTAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxXxAQMDAwMDAwMDAwMDAwMTAwMNQdHh8gISIbI1pmdW5jdGlvbklEVG5hbWVcZW50cnlBZGRyZXNzXxATZW5kQWRkcmVzc0V4Y2x1c2l2ZV1mdW5jdGlvbjptYWluVG1haW5fEBAwMDAwMDAwMDAwMDAxMDA0oSXWHiYnKCkqKxssLS4vXHN0YXJ0QWRkcmVzc1twZXJtaXNzaW9uc1hyYXdCeXRlc15lZmZlY3RpdmVCeXRlc18QD2FwcGxpZWRQYXRjaElEc1ZfX3RleHRTci14RBAgMEBEqrvM3aEwW3BhdGNoMDAwMDAxoTLUFjMeNBkbIg1XYWRkcmVzc1RraW5koTbVNzM4OToNGzs8PVtzdWJqZWN0S2luZFh0eXBlTmFtZVpjb25maWRlbmNlVnNvdXJjZVlpbnQodm9pZClYYXNzZXJ0ZWRWY2FsbGVy1T9AQUJDREVGR0hcbWF4Q29kZUJ5dGVzXxAPbWF4SW5zdHJ1Y3Rpb25zXW1heE9wZXJhdGlvbnNebWF4T3V0cHV0Qnl0ZXNfEBdtYXhXYWxsVGltZU1pbGxpc2Vjb25kcxAEEBAQQBIAEAAAXxAQMDAwMDAwMDAwMDAwMTM4OAAIABEAHwApADMAOAA6AGEAawCAAI4AmQCoAK4AtwDFAM0A1wDfASIBNgE+AUUBTQFSAWkBdAGbAa4BtwHCAccB1AHqAfgB/QIQAhICHwIsAjgCQQJQAmICaQJtAnICdwJ5AoUChwKQApgCnQKfAqoCtgK/AsoC0QLbAuQC6wL2AwMDFQMjAzIDTANOA1ADUgNXAAAAAAAAAgEAAAAAAAAASQAAAAAAAAAAAAAAAAAAA2o=";
    // Keep the very long generated vector readable as one source literal while
    // restoring the four-character base64 quartet at its deterministic split.
    NSString *encodedBase64 = [base64 stringByReplacingCharactersInRange:NSMakeRange(302, 0)
                                                                withString:@"FhYW"];
    NSData *payload = [[NSData alloc] initWithBase64EncodedString:encodedBase64 options:0];
    assert(payload != nil);
    NSDictionary *original = [NSPropertyListSerialization propertyListWithData:payload
                                                                        options:0
                                                                         format:nil
                                                                          error:nil];
    assert([original[@"schemaVersion"] isEqual:@1]);
    NSMutableDictionary *expected = [original mutableCopy];
    expected[@"schemaVersion"] = @3;
    NSMutableDictionary *body = [expected[@"body"] mutableCopy];
    [body removeObjectForKey:@"languageID"];
    [body removeObjectForKey:@"compilerSpecID"];
    [body removeObjectForKey:@"typeHints"];
    body[@"target"] = targetObject(4);
    body[@"authoredInputs"] = emptyAuthoredInputs();
    body[@"budgets"] = budgetObject(1'048'576, 1'048'576);
    expected[@"body"] = body;
    sealRequestDigest(expected);
    payload = binaryPlist(expected);
    DecodedRequest decoded = decodeRequest(payload, kRequestID);
    assert(decoded.request.requestSha256 ==
           std::string([expected[@"body"][@"requestSHA256"] UTF8String]));
    assert(decoded.request.image.imageId == "image:main");
    assert(decoded.request.function.functionId == "function:main");
    assert((decoded.request.effectiveFunctionBytes() ==
            std::vector<std::uint8_t>{0xaa, 0xbb, 0xcc, 0xdd}));
}

// DP03: v2 and v3 (the product default) decode; each profile ID must carry its own limits.
void testBudgetProfileV2DecodesAndMismatchedLimitsReject() {
    {
        NSMutableDictionary *root = validRequestObject();
        root[@"body"][@"budgets"] =
            budgetObject(1'048'576, 8'388'608, @"native-product-budget-v2");
        sealRequestDigest(root);
        DecodedRequest decoded = decodeRequest(binaryPlist(root), kRequestID);
        assert(decoded.request.budgets.maxOutputBytes == 8'388'608U);
    }
    {
        NSMutableDictionary *root = validRequestObject();
        root[@"body"][@"budgets"] =
            budgetObject(1'048'576, 33'554'432, @"native-product-budget-v3");
        sealRequestDigest(root);
        DecodedRequest decoded = decodeRequest(binaryPlist(root), kRequestID);
        assert(decoded.request.budgets.maxOutputBytes == 33'554'432U);
    }
    const auto rejects = [](NSDictionary *budgets) {
        NSMutableDictionary *root = validRequestObject();
        root[@"body"][@"budgets"] = budgets;
        sealRequestDigest(root);
        bool rejected = false;
        try { (void)decodeRequest(binaryPlist(root), kRequestID); }
        catch (const WireError& error) {
            rejected = error.code() == WireFailureCode::invalidRequest;
        }
        return rejected;
    };
    assert(rejects(budgetObject(1'048'576, 1'048'576, @"native-product-budget-v2")));
    assert(rejects(budgetObject(1'048'576, 8'388'608, @"native-product-budget-v1")));
    assert(rejects(budgetObject(1'048'576, 8'388'608, @"native-product-budget-v3")));
    assert(rejects(budgetObject(1'048'576, 33'554'432, @"native-product-budget-v2")));
    assert(rejects(budgetObject(1'048'576, 33'554'432, @"native-product-budget-v4")));
}

// Operation `decompile-document` decodes as a document-only request bound into its digest;
// any other operation still rejects.
void testDocumentOperationDecodes() {
    {
        NSMutableDictionary *root = validRequestObject();
        root[@"operation"] = @"decompile-document";
        sealRequestDigest(root);
        DecodedRequest decoded = decodeRequest(binaryPlist(root), kRequestID);
        assert(decoded.request.documentOnly);
    }
    {
        NSMutableDictionary *root = validRequestObject();
        sealRequestDigest(root);
        assert(!decodeRequest(binaryPlist(root), kRequestID).request.documentOnly);
        root[@"operation"] = @"decompile-document"; // digest sealed for `decompile`
        bool rejected = false;
        try { (void)decodeRequest(binaryPlist(root), kRequestID); }
        catch (const WireError& error) { rejected = error.code() == WireFailureCode::invalidRequest; }
        assert(rejected);
    }
}

void testClosedShapeAndCompilerAndRequestIDRejection() {
    {
        NSMutableDictionary *root = validRequestObject();
        root[@"schemaVersion"] = @1;
        bool rejected = false;
        try { (void)decodeRequest(binaryPlist(root), kRequestID); }
        catch (const WireError& error) {
            rejected = error.code() == WireFailureCode::unsupportedSchemaVersion;
        }
        assert(rejected);
    }
    {
        NSMutableDictionary *root = validRequestObject();
        root[@"unknown"] = @YES;
        bool rejected = false;
        try { (void)decodeRequest(binaryPlist(root), kRequestID); }
        catch (const WireError& error) { rejected = error.code() == WireFailureCode::invalidRequest; }
        assert(rejected);
    }
    {
        NSMutableDictionary *root = validRequestObject();
        NSMutableDictionary *target = [root[@"body"][@"target"] mutableCopy];
        target[@"compilerSpecID"] = @"swift";
        root[@"body"][@"target"] = target;
        bool rejected = false;
        try { (void)decodeRequest(binaryPlist(root), kRequestID); }
        catch (const WireError& error) { rejected = error.code() == WireFailureCode::invalidRequest; }
        assert(rejected);
    }
    {
        NSUUID *other = [[NSUUID alloc]
            initWithUUIDString:@"00000000-0000-0000-0000-00000000000B"];
        bool rejected = false;
        try { (void)decodeRequest(binaryPlist(validRequestObject()), other); }
        catch (const WireError& error) { rejected = error.code() == WireFailureCode::requestIDMismatch; }
        assert(rejected);
    }
}

void testCanonicalRequestDigestRejectsSemanticMutation() {
    NSMutableDictionary *root = validRequestObject();
    NSString *sealedDigest = root[@"body"][@"requestSHA256"];
    NSMutableDictionary *region = [root[@"body"][@"memoryRegions"][0] mutableCopy];
    static constexpr std::uint8_t mutatedBytes[] = {0xaa, 0xbb, 0xcc, 0xde};
    region[@"effectiveBytes"] = [NSData dataWithBytes:mutatedBytes length:sizeof(mutatedBytes)];
    root[@"body"][@"memoryRegions"] = @[region];
    assert([root[@"body"][@"requestSHA256"] isEqual:sealedDigest]);

    bool rejected = false;
    try {
        (void)decodeRequest(binaryPlist(root), kRequestID);
    } catch (const WireError& error) {
        rejected = error.code() == WireFailureCode::invalidRequest;
    }
    assert(rejected);
}

void testSharedPlistRegionExpansionIsRejectedBeforeNativeCopies() {
    NSMutableDictionary *root = validRequestObject();
    NSMutableDictionary *region = [root[@"body"][@"memoryRegions"][0] mutableCopy];
    NSMutableData *sharedBytes = [NSMutableData dataWithLength:300U * 1024U];
    region[@"rawBytes"] = sharedBytes;
    region[@"effectiveBytes"] = sharedBytes;
    NSArray *sharedRegions = [NSArray arrayWithObjects:
        region, region, region, region, region, region, region, region,
        region, region, region, region, region, region, region, region,
        nil];
    NSMutableArray *expanded = [NSMutableArray arrayWithCapacity:256U];
    for (NSUInteger index = 0; index < 16U; ++index) {
        [expanded addObjectsFromArray:sharedRegions];
    }
    root[@"body"][@"memoryRegions"] = expanded;
    NSData *payload = binaryPlist(root);
    assert(payload.length < 32U * 1024U * 1024U);

    bool rejected = false;
    try {
        (void)decodeRequest(payload, kRequestID);
    } catch (const WireError& error) {
        rejected = error.code() == WireFailureCode::invalidRequest;
    }
    assert(rejected);
}

void testDuplicateBinaryPropertyListKeysAreRejectedBeforeFoundationCollapsesThem() {
    static constexpr std::uint8_t bytes[] = {
        'b', 'p', 'l', 'i', 's', 't', '0', '0',
        0x51, 0x61, 0x10, 0x01, 0x10, 0x02, 0xd2, 0x00, 0x00, 0x01, 0x02,
        0x08, 0x0a, 0x0c, 0x0e,
        0, 0, 0, 0, 0, 0, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 4,
        0, 0, 0, 0, 0, 0, 0, 3,
        0, 0, 0, 0, 0, 0, 0, 19,
    };
    bool rejected = false;
    try {
        validateBinaryPropertyListKeysForTesting(
            [NSData dataWithBytes:bytes length:sizeof(bytes)]
        );
    } catch (const WireError& error) {
        rejected = error.code() == WireFailureCode::malformedRequest;
    }
    assert(rejected);
}

void testSchemaV3RejectsTypeHintAliasAndAcceptsAuthoredRoot() {
    NSMutableDictionary *accepted = validRequestObject();
    DecodedRequest decoded = decodeRequest(binaryPlist(accepted), kRequestID);
    assert(decoded.request.authoredInputs.names.empty());

    NSMutableDictionary *rejected = validRequestObject();
    rejected[@"body"][@"typeHints"] = @[];
    bool didReject = false;
    try {
        (void)decodeRequest(binaryPlist(rejected), kRequestID);
    } catch (const WireError& error) {
        didReject = error.code() == WireFailureCode::invalidRequest;
    }
    assert(didReject);
}

void testCalleeSignatureStorageRegisterDecodesAndPreservesCanonicalBytes() {
    for (id storageRegister in @[@"x20", [NSNull null]]) {
        const bool hasStorageRegister = [storageRegister isKindOfClass:NSString.class];
        NSMutableDictionary *parameter = [@{
            @"name": @"context",
            @"type": @{@"tag": @0, @"atom": @{@"tag": @1, @"scalarKind": @0}, @"qualifiers": @0},
        } mutableCopy];
        if (hasStorageRegister) parameter[@"storageRegister"] = storageRegister;
        NSMutableDictionary *root = validRequestObject();
        root[@"body"][@"authoredInputs"] = @{
            @"schemaVersion": @2, @"names": @[], @"signatures": @[],
            @"appliedTypes": @[], @"typeDefinitions": @[],
            @"calleeSignatureHints": @[@{
                @"name": @"callee", @"source": @4,
                @"signature": @{
                    @"functionAddress": @"0000000000002000", @"parameterListState": @1,
                    @"parameters": @[parameter], @"variadicState": @1, @"noReturnState": @1,
                },
            }],
        };
        AuthoredSignature signature;
        signature.functionAddress = 0x2000;
        signature.parameterListState = AuthoredParameterListState::authoritative;
        signature.variadicState = AuthoredVariadicState::fixed;
        signature.noReturnState = AuthoredNoReturnState::returns;
        signature.parameters.push_back({
            "context",
            {AuthoredTypeTag::qualifiedValue, AuthoredQualifiedValue{
                {AuthoredAtomTag::scalar, AuthoredScalarKind::bool_}, 0,
            }},
            hasStorageRegister ? std::optional<std::string>("x20") : std::nullopt,
        });
        AuthoredInputs authoredInputs;
        authoredInputs.schemaVersion = 2;
        authoredInputs.calleeSignatureHints.push_back({"callee", CalleeSignatureHintSource::swift, signature});
        const auto expectedBytes = sealRequestDigest(root, authoredInputs);
        const auto decoded = decodeRequest(binaryPlist(root), kRequestID);
        const auto& hints = decoded.request.authoredInputs.calleeSignatureHints;
        assert(hints.size() == 1U);
        assert(hints.front().source == CalleeSignatureHintSource::swift);
        assert(hints.front().signature.parameters.size() == 1U);
        const auto& decodedStorage = hints.front().signature.parameters.front().storageRegister;
        assert(decodedStorage == signature.parameters.front().storageRegister);
        const auto target = normalizeAppleMachOTarget(
            0x0100000cU, 0U, std::string(64, 'a'), 4U
        );
        const auto budgets = productAnalysisBudgetsV1();
        const auto actualBytes = canonicalRequestV2({
            target, decoded.request.image, decoded.request.function, decoded.request.bytes,
            decoded.request.symbols, decoded.request.authoredInputs, budgets,
        });
        assert(actualBytes == expectedBytes);
    }
}

void testCalleeSignatureStorageRegisterRejectsInvalidWireValues() {
    const auto rejects = [](NSString *storageRegister, NSNumber *source, bool extraKey,
                            const char *expectedDetail) {
        NSMutableDictionary *parameter = [@{
            @"name": @"context",
            @"type": @{@"tag": @0, @"atom": @{@"tag": @1, @"scalarKind": @0}, @"qualifiers": @0},
            @"storageRegister": storageRegister,
        } mutableCopy];
        if (extraKey) parameter[@"unexpected"] = @0;
        NSMutableDictionary *root = validRequestObject();
        root[@"body"][@"authoredInputs"] = @{
            @"schemaVersion": @2, @"names": @[], @"signatures": @[],
            @"appliedTypes": @[], @"typeDefinitions": @[],
            @"calleeSignatureHints": @[@{
                @"name": @"callee", @"source": source,
                @"signature": @{
                    @"functionAddress": @"0000000000002000", @"parameterListState": @1,
                    @"parameters": @[parameter], @"variadicState": @1, @"noReturnState": @1,
                },
            }],
        };
        bool rejected = false;
        try { (void)decodeRequest(binaryPlist(root), kRequestID); }
        catch (const WireError& error) {
            rejected = error.code() == WireFailureCode::invalidRequest &&
                std::string(error.what()) == expectedDetail;
        }
        return rejected;
    };
    assert(rejects(@"", @4, false, "authored inputs violate native contract"));
    assert(rejects(@"   ", @4, false, "authored inputs violate native contract"));
    assert(rejects([@"x" stringByPaddingToLength:1'025 withString:@"x" startingAtIndex:0],
                   @4, false, "expected bounded text"));
    assert(rejects(@"x20", @5, false, "unsupported authored enum"));
    assert(rejects(@"x20", @4, true, "wire object has an unknown key"));
}

void testReachableDictionaryBudgetAcceptsValidAggregateAboveOldCeiling() {
    constexpr NSUInteger dictionaryCount = 131'073U;
    NSMutableArray *objects = [NSMutableArray arrayWithCapacity:dictionaryCount];
    for (NSUInteger index = 0; index < dictionaryCount; ++index) {
        [objects addObject:@{@"k": @(index & 1U)}];
    }
    NSData *payload = binaryPlist(@{@"objects": objects});
    assert(payload.length < 32U * 1024U * 1024U);
    validateBinaryPropertyListKeysForTesting(payload);
}

StructuredResult validatedResult(const AnalysisRequestView& request) {
    const SourceRange range{"image:main", 0x1000, 0x1004};
    StructuredResult result;
    result.requestId = request.requestId;
    result.requestSha256 = request.requestSha256;
    result.image = request.image;
    result.function = request.function;
    result.addressSpaces = {{"space:ram", "ram", "processor", 8, true}};
    result.instructions = {{"instruction:0", 0x1000, {0xaa, 0xbb, 0xcc, 0xdd},
                            "ret", "", {"operation:0"}, {range}}};
    result.varnodes = {{"varnode:0", "space:ram", 0, 8, "register", std::nullopt, "x0"}};
    result.operations = {{"operation:0", "block:0", 0, "RETURN", std::nullopt,
                          {"varnode:0"}, std::nullopt, {range}, std::nullopt, {}}};
    result.blocks = {{"block:0", 0x1000, 0x1004, {"operation:0"}, {}, {}, "return"}};
    result.ssaValues = {{"ssa:0", "varnode:0", "functionEntry", std::nullopt, std::nullopt}};
    result.ssaBindings = {{"operation:0", {"ssa:0"}, std::nullopt}};
    result.regions = {{"region:root", "root", std::nullopt, {}, {"block:0"},
                       std::nullopt, {range}}};
    result.warnings = {{"warning", "warning", "bounded warning", {range}}};
    return result;
}

StructuredResult fullFamilyResult(const AnalysisRequestView& request) {
    const auto range = [&](Address start, Address end) {
        return SourceRange{request.image.imageId, start, end};
    };
    StructuredResult result;
    result.requestId = request.requestId;
    result.requestSha256 = request.requestSha256;
    result.image = request.image;
    result.function = request.function;
    result.addressSpaces = {
        {"space.ram", "ram", "processor", 8, true},
        {"space.unique", "unique", "unique", 8, true},
    };
    result.types = {
        TypeRecord{
            .id = "type.function", .kind = "function", .name = "fixture_t",
            .byteSize = std::nullopt, .isSigned = std::nullopt,
            .pointeeTypeId = std::nullopt, .fields = {}, .confidence = "high",
            .provenance = "contract-fixture", .returnTypeId = "type.u64",
            .parameterTypeIds = {"type.u64"},
        },
        TypeRecord{
            .id = "type.pointer", .kind = "pointer", .name = "uint64_t *",
            .byteSize = 8, .isSigned = std::nullopt, .pointeeTypeId = "type.u64",
            .fields = {}, .confidence = "asserted", .provenance = "caller-hint",
            .returnTypeId = std::nullopt, .parameterTypeIds = {},
        },
        TypeRecord{
            .id = "type.structure", .kind = "structure", .name = "fixture_struct",
            .byteSize = 8, .isSigned = std::nullopt, .pointeeTypeId = std::nullopt,
            .fields = {{"member", "type.u64", 0, 64}}, .confidence = "medium",
            .provenance = "native-recovery", .returnTypeId = std::nullopt,
            .parameterTypeIds = {},
        },
        TypeRecord{
            .id = "type.u64", .kind = "integer", .name = "uint64_t",
            .byteSize = 8, .isSigned = false, .pointeeTypeId = std::nullopt,
            .fields = {}, .confidence = "high", .provenance = "contract-fixture",
            .returnTypeId = std::nullopt, .parameterTypeIds = {},
        },
    };
    result.instructions = {
        {"instruction.0", 0x1000, {1, 2, 3, 4}, "cbz", "cbz w0, right", {"op.0"}, {range(0x1000, 0x1004)}},
        {"instruction.1", 0x1004, {5, 6, 7, 8}, "bl", "bl callee", {"op.1"}, {range(0x1004, 0x1008)}},
        {"instruction.2", 0x1008, {9, 10, 11, 12}, "mov", "mov x0, #2", {"op.2"}, {range(0x1008, 0x100c)}},
        {"instruction.3", 0x100c, {13, 14, 15, 16}, "ret", "ret", {"op.3"}, {range(0x100c, 0x1010)}},
    };
    result.varnodes = {
        {"vn.condition", "space.unique", 0, 8, "constant", "type.u64", std::nullopt},
        {"vn.result", "space.unique", 8, 8, "register", "type.u64", "x0"},
    };
    result.operations = {
        {"op.0", "block.0", 0, "CBRANCH", std::nullopt, {"vn.condition"}, 0x1008, {range(0x1000, 0x1004)}, std::nullopt, {}},
        {"op.1", "block.1", 0, "CALL", "vn.result", {"vn.condition"}, 0x2000, {range(0x1004, 0x1008)}, std::nullopt, {}},
        {"op.2", "block.2", 0, "CALLOTHER", "vn.result", {"vn.condition"}, std::nullopt, {range(0x1008, 0x100c)}, "pacia", {AuthenticationEffectKind::transformedOutput, "ssa.right"}},
        {"op.3", "block.3", 0, "RETURN", std::nullopt, {"vn.result"}, std::nullopt, {range(0x100c, 0x1010)}, std::nullopt, {}},
    };
    result.blocks = {
        {"block.0", 0x1000, 0x1004, {"op.0"}, {}, {"edge.0", "edge.1"}, "conditional"},
        {"block.1", 0x1004, 0x1008, {"op.1"}, {"edge.0"}, {"edge.2"}, "branch"},
        {"block.2", 0x1008, 0x100c, {"op.2"}, {"edge.1"}, {"edge.3"}, "branch"},
        {"block.3", 0x100c, 0x1010, {"op.3"}, {"edge.2", "edge.3"}, {}, "return"},
    };
    result.edges = {
        {"edge.0", "block.0", "block.1", 0x1004, "true", "op.0"},
        {"edge.1", "block.0", "block.2", 0x1008, "false", "op.0"},
        {"edge.2", "block.1", "block.3", 0x100c, "branch", "op.1"},
        {"edge.3", "block.2", "block.3", 0x100c, "branch", "op.2"},
    };
    result.ssaValues = {
        {"ssa.condition", "vn.condition", "constant", std::nullopt, std::nullopt},
        {"ssa.left", "vn.result", "operationResult", "op.1", std::nullopt},
        {"ssa.phi", "vn.result", "phiResult", std::nullopt, "phi.0"},
        {"ssa.right", "vn.result", "operationResult", "op.2", std::nullopt},
    };
    result.ssaBindings = {
        {"op.0", {"ssa.condition"}, std::nullopt},
        {"op.1", {"ssa.condition"}, "ssa.left"},
        {"op.2", {"ssa.condition"}, "ssa.right"},
        {"op.3", {"ssa.phi"}, std::nullopt},
    };
    result.phis = {{
        "phi.0", "block.3", "vn.result", "ssa.phi",
        {{"block.1", "edge.2", "ssa.left"}, {"block.2", "edge.3", "ssa.right"}},
    }};
    result.memoryVersions = {
        {"memory.entry", "unknown", "functionEntry", std::nullopt, std::nullopt},
        {"memory.left", "unknown", "operationResult", "op.1", std::nullopt},
        {"memory.merge", "unknown", "phiResult", std::nullopt, "memory-phi.0"},
        {"memory.right", "unknown", "operationResult", "op.2", std::nullopt},
    };
    result.memoryPhis = {{
        "memory-phi.0", "block.3", "unknown", "memory.merge",
        {{"block.1", "edge.2", "memory.left"}, {"block.2", "edge.3", "memory.right"}},
    }};
    result.memoryEffects = {
        {"effect.left", "op.1", "write", "unknown", "memory.entry", "memory.left"},
        {"effect.merge-read", "op.3", "read", "unknown", "memory.merge", std::nullopt},
        {"effect.right", "op.2", "write", "unknown", "memory.entry", "memory.right"},
    };
    result.variables = {
        {"variable.argument", "argument", "parameter", "type.u64", {"vn.condition"},
         {range(0x1000, 0x100c)}, "high", "contract-fixture"},
        {"variable.result", "result", "result", "type.u64", {"vn.result"},
         {range(0x1004, 0x1010)}, "high", "contract-fixture"},
    };
    result.calls = {{
        "call.0", "op.1", "direct", 0x2000, "_callee", "type.function",
        {"variable.argument"}, "variable.result", {range(0x1004, 0x1008)},
    }};
    result.regions = {
        {"region.child", "sequence", "region.root", {}, {"block.3"}, std::nullopt,
         {range(0x100c, 0x1010)}},
        {"region.root", "root", std::nullopt, {"region.child"},
         {"block.0", "block.1", "block.2", "block.3"}, "op.0",
         {range(0x1000, 0x1010)}},
    };
    result.tokens = {
        {"token.0", "if", "keyword", 1, 1, {range(0x1000, 0x1004)},
         {{"instruction", "instruction.0"}, {"region", "region.root"}}},
        {"token.1", "callee", "identifier", 2, 1, {range(0x1004, 0x1008)},
         {{"call", "call.0"}, {"operation", "op.1"}}},
        {"token.2", "result", "identifier", 3, 1, {range(0x100c, 0x1010)},
         {{"block", "block.3"}, {"type", "type.u64"},
          {"variable", "variable.result"}, {"varnode", "vn.result"}}},
    };
    result.pseudocodeDocument = PseudocodeDocumentRecord{
        "uint64_t fixture(uint64_t argument) {\n\treturn argument;\n}\n",
        "c",
        true,
        false,
    };
    result.warnings = {{
        "fixture-warning", "warning", "fixture warning", {range(0x1000, 0x1004)},
    }};
    return result;
}

BackendAvailability fullAvailability() {
    return {
        true,
        "",
        {"fixture-native-provider", "12.1.2", std::string(40, 'b'),
         "dcp05c-v1", std::string(40, 'c')},
        {true, true, true, true, true, true, true, true},
        PreparedGhidraRuntimeIdentity{
            "fixture-native-provider",
            "12.1.2",
            std::string(40, 'b'),
            "dcp05c-v1",
            std::string(40, 'c'),
            std::string(64, 'd'),
            std::string(64, 'e'),
            "AARCH64:LE:64:AppleSilicon",
            "default",
            "apple-aarch64-pac-visible-clobber-v1",
            "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
        },
    };
}

NSMutableDictionary *cp4RequestObject(bool authentication) {
    NSMutableDictionary *root = validRequestObject();
    if (authentication) {
        static constexpr std::uint8_t bytes[] = {0xff, 0x23, 0x03, 0xd5};
        NSMutableDictionary *region = [root[@"body"][@"memoryRegions"][0] mutableCopy];
        region[@"effectiveBytes"] = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        root[@"body"][@"memoryRegions"] = @[region];
        sealRequestDigest(root);
    }
    return root;
}

StructuredResult cp4BoundaryResult(const AnalysisRequestView& request, bool authentication) {
    auto result = validatedResult(request);
    if (authentication) {
        result.instructions.front().bytes = {0xff, 0x23, 0x03, 0xd5};
        result.instructions.front().mnemonic = "autibsp";
        auto& operation = result.operations.front();
        operation.opcode = "CALLOTHER";
        operation.inputVarnodeIds = {"varnode:0", "varnode:0", "varnode:0"};
        operation.userOperationName = "AuthIB";
        operation.authenticationEffect.kind = AuthenticationEffectKind::standaloneAuthenticationWithoutTransformedOutput;
        result.ssaBindings.front().inputSsaValueIds = {"ssa:0", "ssa:0", "ssa:0"};
        result.blocks.front().terminatorKind = "exit";
        return result;
    }
    const std::string entry = "block:cfg:0000000000000000";
    const std::string target = "block:cfg:0000000000000001";
    const SourceRange range{request.image.imageId, 0x1000, 0x1004};
    result.operations.front().blockId = target;
    result.blocks = {
        {entry, 0x1000, 0x1004, {}, {}, {"edge:splice"}, "splice"},
        {target, 0x1000, 0x1004, {"operation:0"}, {"edge:splice"}, {}, "return"},
    };
    result.edges = {{"edge:splice", entry, target, 0x1000, "splice", std::nullopt}};
    result.regions.front().blockIds = {entry, target};
    result.blockPartition = BlockPartitionRecord{
        1, entry,
        {{entry, 0, 0x1000, {range}}, {target, 1, 0x1000, {range}}},
        {{"instruction:0", "retained", {{entry, 0, 0}, {target, 0, 1}}}},
        {{"edge:splice", 0, 0, "splice"}},
    };
    return result;
}

void testCP4ProductionBoundaryAndEmitFixtures(const char *outputDirectory) {
    auto availability = fullAvailability();
    availability.capabilities = {true, true, false, false, false, true, false, true};
    for (const bool authentication : {false, true}) {
        NSData *requestPayload = binaryPlist(cp4RequestObject(authentication));
        auto decoded = decodeRequest(requestPayload, kRequestID);
        auto resultValue = cp4BoundaryResult(decoded.request, authentication);
        NSData *reply = encodeSuccessReply(kRequestID, decoded.request, availability, resultValue);
        NSDictionary *root = [NSPropertyListSerialization propertyListWithData:reply options:0 format:nil error:nil];
        assert([root[@"schemaVersion"] isEqual:@4]);
        NSDictionary *result = root[@"success"][@"result"];
        if (authentication) {
            assert(result[@"blockPartition"] == nil);
            assert(([result[@"operations"][0][@"authenticationEffect"] isEqual:
                @{@"kind": @"standalone-authentication-without-transformed-output"}]));
        } else {
            NSDictionary *partition = result[@"blockPartition"];
            assert(partition.count == 5);
            assert([partition[@"version"] isEqual:@1]);
            assert([partition[@"entryBlockID"] isEqual:@"block:cfg:0000000000000000"]);
            assert([partition[@"blocks"] count] == 2);
            assert([partition[@"blocks"][1][@"ordinal"] isEqual:@1]);
            assert([partition[@"blocks"][1][@"entryAddress"] isEqual:@"0000000000001000"]);
            assert([partition[@"blocks"][0][@"sourceRanges"] isEqual:result[@"instructions"][0][@"sourceRanges"]]);
            assert(([partition[@"instructions"] isEqual:@[@{
                @"instructionID": @"instruction:0", @"disposition": @"retained",
                @"spans": @[
                    @{@"blockID": @"block:cfg:0000000000000000", @"firstOperationIndex": @0, @"operationCount": @0},
                    @{@"blockID": @"block:cfg:0000000000000001", @"firstOperationIndex": @0, @"operationCount": @1},
                ],
            }]]));
            assert(([partition[@"edges"] isEqual:@[@{
                @"edgeID": @"edge:splice", @"sourceSlot": @0, @"targetSlot": @0, @"transferKind": @"splice",
            }]]));
            assert([result[@"blocks"][0][@"terminatorKind"] isEqual:@"splice"]);
            assert([result[@"edges"][0][@"kind"] isEqual:@"splice"]);
            resultValue.blockPartition->instructions.front().spans.back().operationCount = UINT32_MAX;
        }
        NSString *prefix = authentication ? @"authentication" : @"partition";
        NSString *directory = [NSString stringWithUTF8String:outputDirectory];
        assert([requestPayload writeToFile:[directory stringByAppendingPathComponent:
            [prefix stringByAppendingString:@"-request.bplist"]] atomically:YES]);
        assert([reply writeToFile:[directory stringByAppendingPathComponent:
            [prefix stringByAppendingString:@"-reply.bplist"]] atomically:YES]);
        if (authentication) resultValue.operations.front().authenticationEffect.outputSsaValueId = "ssa:0";
        bool rejected = false;
        try { (void)encodeSuccessReply(kRequestID, decoded.request, availability, resultValue); }
        catch (const WireError& error) { rejected = error.code() == WireFailureCode::nativeFailure; }
        assert(rejected);
    }
    auto legacyRequest = decodeRequest(binaryPlist(validRequestObject()), kRequestID);
    NSData *legacy = encodeSuccessReply(kRequestID, legacyRequest.request, availability, validatedResult(legacyRequest.request));
    NSDictionary *legacyRoot = [NSPropertyListSerialization propertyListWithData:legacy options:0 format:nil error:nil];
    assert([legacyRoot[@"schemaVersion"] isEqual:@3]);
    assert(legacyRoot[@"success"][@"result"][@"blockPartition"] == nil);
    NSMutableDictionary *unsupportedRequest = validRequestObject();
    unsupportedRequest[@"schemaVersion"] = @5;
    bool rejected = false;
    try { (void)decodeRequest(binaryPlist(unsupportedRequest), kRequestID); }
    catch (const WireError& error) { rejected = error.code() == WireFailureCode::unsupportedSchemaVersion; }
    assert(rejected);
}

void testValidatedResultMappingIsCanonicalAndDeterministic() {
    BackendAvailability availability{
        true,
        "",
        {"native-decompiler", "12.1.2", std::string(40, 'b'), "dcp05c-v1", std::string(40, 'c')},
        {true, false, false, false, false, true, false, true},
        PreparedGhidraRuntimeIdentity{
            "native-decompiler",
            "12.1.2",
            std::string(40, 'b'),
            "dcp05c-v1",
            std::string(40, 'c'),
            std::string(64, 'd'),
            std::string(64, 'e'),
            "AARCH64:LE:64:AppleSilicon",
            "default",
            "apple-aarch64-pac-visible-clobber-v1",
            "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5",
        },
    };
    DecodedRequest decoded = decodeRequest(binaryPlist(validRequestObject()), kRequestID);
    StructuredResult resultValue = validatedResult(decoded.request);
    NSData *first = encodeSuccessReply(kRequestID, decoded.request, availability, resultValue);
    NSData *second = encodeSuccessReply(kRequestID, decoded.request, availability, resultValue);
    assert([first isEqualToData:second]);

    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:first
                                                                    options:0
                                                                     format:&format
                                                                      error:nil];
    assert(format == NSPropertyListBinaryFormat_v1_0);
    NSDictionary *result = root[@"success"][@"result"];
    assert([result[@"instructions"][0][@"address"] isEqual:@"0000000000001000"]);
    assert([result[@"operations"][0][@"sequence"] isEqual:@"0000000000000000"]);
    assert([result[@"ssaValues"][0][@"kind"] isEqual:@"function-entry"]);
    assert([result[@"types"] count] == 0);
    assert([result[@"variables"] count] == 0);
    assert([result[@"calls"] count] == 0);
    assert([result[@"regions"] count] == 1);
    assert([result[@"tokens"] count] == 0);
}

void testRuntimeProfileAndOutputBudgetFailClosedBeforeSerialization() {
    DecodedRequest decoded = decodeRequest(binaryPlist(validRequestObject()), kRequestID);
    StructuredResult result = validatedResult(decoded.request);

    const auto assertNativeFailure = [&](BackendAvailability availability) {
        bool rejected = false;
        try {
            (void)encodeSuccessReply(kRequestID, decoded.request, availability, result);
        } catch (const WireError& error) {
            rejected = error.code() == WireFailureCode::nativeFailure;
        }
        assert(rejected);
    };
    BackendAvailability availability = fullAvailability();
    availability.runtimeIdentity->languageId = "AARCH64:LE:64:wrong";
    assertNativeFailure(availability);
    availability = fullAvailability();
    availability.runtimeIdentity->compilerSpecId = "wrong";
    assertNativeFailure(availability);
    availability = fullAvailability();
    availability.runtimeIdentity->targetProfileId = "wrong";
    assertNativeFailure(availability);
    availability = fullAvailability();
    availability.runtimeIdentity->contextProfileSha256 = std::string(64, 'f');
    assertNativeFailure(availability);

    result.pseudocodeDocument = PseudocodeDocumentRecord{
        std::string(1U << 20U, 'x'), "c", true, false,
    };
    bool rejectedForSize = false;
    try {
        (void)encodeSuccessReply(kRequestID, decoded.request, fullAvailability(), result);
    } catch (const WireError& error) {
        rejectedForSize = error.code() == WireFailureCode::responseTooLarge;
    }
    assert(rejectedForSize);
}

void testFullFamilyResultMappingIsCompleteAndDeterministic() {
    NSData *requestPayload = binaryPlist(fullFamilyRequestObject());
    DecodedRequest decoded = decodeRequest(requestPayload, kFullRequestID);
    StructuredResult resultValue = fullFamilyResult(decoded.request);
    BackendAvailability availability = fullAvailability();
    validateStructuredResult(decoded.request, resultValue);
    NSData *first = encodeSuccessReply(kFullRequestID, decoded.request, availability, resultValue);
    NSData *second = encodeSuccessReply(kFullRequestID, decoded.request, availability, resultValue);
    assert([first isEqualToData:second]);

    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:first
                                                                    options:0
                                                                     format:nil
                                                                      error:nil];
    NSDictionary *result = root[@"success"][@"result"];
    assert([result[@"addressSpaces"] count] == 2);
    assert([result[@"types"] count] == 4);
    assert([result[@"instructions"] count] == 4);
    assert([result[@"varnodes"] count] == 2);
    assert([result[@"operations"] count] == 4);
    assert([result[@"operations"][2][@"userOperationName"] isEqual:@"pacia"]);
    assert(([result[@"operations"][2][@"authenticationEffect"] isEqual:
        @{@"kind": @"transformed-output", @"outputSSAValueID": @"ssa.right"}]));
    assert([result[@"operations"][0][@"authenticationEffect"] isEqual:@{@"kind": @"none"}]);
    assert([result[@"blocks"] count] == 4);
    assert([result[@"edges"] count] == 4);
    assert([result[@"ssaValues"] count] == 4);
    assert([result[@"ssaBindings"] count] == 4);
    assert([result[@"phis"] count] == 1);
    assert([result[@"memoryVersions"] count] == 4);
    assert([result[@"memoryPhis"] count] == 1);
    assert([result[@"memoryEffects"] count] == 3);
    assert([result[@"variables"] count] == 2);
    assert([result[@"calls"] count] == 1);
    assert([result[@"regions"] count] == 2);
    assert([result[@"tokens"] count] == 3);
    assert([result[@"pseudocodeDocument"][@"language"] isEqual:@"c"]);
    assert([result[@"pseudocodeDocument"][@"isComplete"] boolValue]);
    assert(![result[@"pseudocodeDocument"][@"isTruncated"] boolValue]);
    assert([result[@"warnings"] count] == 1);
    assert([result[@"types"][1][@"pointeeTypeID"] isEqual:@"type.u64"]);
    assert([result[@"types"][2][@"fields"] count] == 1);
    assert([result[@"calls"][0][@"targetSymbol"] isEqual:@"_callee"]);
    assert([result[@"memoryEffects"][1][@"kind"] isEqual:@"read"]);
    assert([result[@"tokens"][2][@"entityReferences"] count] == 4);
}

void testProductionNativeTypeKindsAreRepresentableOnWireV3() {
    NSData *requestPayload = binaryPlist(fullFamilyRequestObject());
    DecodedRequest decoded = decodeRequest(requestPayload, kFullRequestID);
    StructuredResult resultValue = fullFamilyResult(decoded.request);
    const std::vector<std::pair<std::string, std::string>> nativeKinds{
        {"type.native.enum", "enum"},
        {"type.native.float", "float"},
        {"type.native.partial", "partial"},
        {"type.native.spacebase", "spacebase"},
        {"type.native.struct", "struct"},
    };
    for (const auto& [id, kind] : nativeKinds) {
        resultValue.types.push_back(TypeRecord{
            .id = id,
            .kind = kind,
            .name = id,
            .byteSize = 8,
            .isSigned = std::nullopt,
            .pointeeTypeId = std::nullopt,
            .fields = {},
            .confidence = "low",
            .provenance = "native-provider-regression",
            .returnTypeId = std::nullopt,
            .parameterTypeIds = {},
        });
    }

    NSData *reply = encodeSuccessReply(
        kFullRequestID, decoded.request, fullAvailability(), resultValue
    );
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:reply
                                                                    options:0
                                                                     format:nil
                                                                      error:nil];
    NSMutableDictionary<NSString *, NSString *> *kindsByID = [NSMutableDictionary dictionary];
    for (NSDictionary *type in root[@"success"][@"result"][@"types"]) {
        kindsByID[type[@"id"]] = type[@"kind"];
    }
    assert([kindsByID[@"type.native.enum"] isEqual:@"enumeration"]);
    assert([kindsByID[@"type.native.float"] isEqual:@"floating-point"]);
    assert([kindsByID[@"type.native.struct"] isEqual:@"structure"]);
    assert([kindsByID[@"type.native.partial"] isEqual:@"unknown"]);
    assert([kindsByID[@"type.native.spacebase"] isEqual:@"unknown"]);
}

void assertStringArrayEquals(NSArray *actual, NSArray<NSString *> *expected) {
    assert([actual isKindOfClass:NSArray.class]);
    assert([actual isEqualToArray:expected]);
}

void testMappingCoverageFixtureIsExhaustiveAndDeterministic() {
    NSData *first = encodeMappingCoverageFixtureForTesting();
    NSData *second = encodeMappingCoverageFixtureForTesting();
    assert([first isEqualToData:second]);

    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:first
                                                                    options:0
                                                                     format:nil
                                                                      error:nil];
    assert([NSSet setWithArray:root.allKeys].count == 3);
    assert([root.allKeys containsObject:@"enums"]);
    assert([root.allKeys containsObject:@"optionals"]);
    assert([root.allKeys containsObject:@"tokenEntityKinds"]);

    NSDictionary *enums = root[@"enums"];
    assert(enums.count == 16);
    assertStringArrayEquals(enums[@"addressSpaceKinds"],
        @[@"constant", @"processor", @"spacebase", @"unique", @"fspec", @"iop", @"join"]);
    assertStringArrayEquals(enums[@"typeKinds"],
        @[@"array", @"boolean", @"enumeration", @"floating-point", @"function", @"integer",
          @"pointer", @"structure", @"union", @"unknown", @"void"]);
    assertStringArrayEquals(enums[@"varnodeRoles"],
        @[@"address", @"constant", @"internal", @"join", @"memory", @"register", @"stack", @"unique"]);
    assertStringArrayEquals(enums[@"opcodes"], @[
        @"copy", @"load", @"store", @"branch", @"cbranch", @"branchind", @"call", @"callind",
        @"callother", @"return", @"int_equal", @"int_notequal", @"int_sless", @"int_slessequal",
        @"int_less", @"int_lessequal", @"int_zext", @"int_sext", @"int_add", @"int_sub",
        @"int_carry", @"int_scarry", @"int_sborrow", @"int_2comp", @"int_negate", @"int_xor",
        @"int_and", @"int_or", @"int_left", @"int_right", @"int_sright", @"int_mult", @"int_div",
        @"int_sdiv", @"int_rem", @"int_srem", @"bool_negate", @"bool_xor", @"bool_and", @"bool_or",
        @"float_equal", @"float_notequal", @"float_less", @"float_lessequal", @"float_nan", @"float_add",
        @"float_div", @"float_mult", @"float_sub", @"float_neg", @"float_abs", @"float_sqrt",
        @"float_int2float", @"float_float2float", @"float_trunc", @"float_ceil", @"float_floor",
        @"float_round", @"multiequal", @"indirect", @"piece", @"subpiece", @"cast", @"ptradd",
        @"ptrsub", @"segmentop", @"cpoolref", @"new", @"insert", @"extract", @"popcount", @"lzcount", @"spull",
    ]);
    assertStringArrayEquals(enums[@"blockTerminatorKinds"],
        @[@"branch", @"conditional", @"exit", @"fallthrough", @"return", @"switch"]);
    assertStringArrayEquals(enums[@"edgeKinds"],
        @[@"branch", @"fallthrough", @"false", @"switch-case", @"switch-default", @"true"]);
    assertStringArrayEquals(enums[@"ssaValueKinds"],
        @[@"annotation", @"constant", @"function-entry", @"operation-result", @"phi-result"]);
    assertStringArrayEquals(enums[@"memoryVersionKinds"],
        @[@"function-entry", @"operation-result", @"phi-result"]);
    assertStringArrayEquals(enums[@"memoryEffectKinds"], @[@"read", @"write", @"read-write"]);
    assertStringArrayEquals(enums[@"variableRoles"],
        @[@"global", @"local", @"parameter", @"result", @"temporary"]);
    assertStringArrayEquals(enums[@"callKinds"], @[@"direct", @"indirect"]);
    assertStringArrayEquals(enums[@"regionKinds"],
        @[@"condition", @"do-while", @"goto", @"if", @"infinite-loop", @"multi-goto",
          @"root", @"sequence", @"switch", @"while"]);
    assertStringArrayEquals(enums[@"tokenKinds"],
        @[@"comment", @"identifier", @"keyword", @"literal", @"operation", @"punctuation",
          @"type", @"whitespace"]);
    assertStringArrayEquals(enums[@"diagnosticSeverities"], @[@"error", @"information", @"warning"]);
    assertStringArrayEquals(enums[@"confidences"], @[@"asserted", @"high", @"medium", @"low", @"unknown"]);
    assertStringArrayEquals(enums[@"failureCodes"], @[
        @"malformed-request", @"invalid-request", @"native-failure", @"package-verification-failed",
        @"busy", @"cancelled", @"timed-out", @"unavailable", @"unsupported-schema-version",
        @"request-id-mismatch", @"unsupported-compiler", @"request-too-large", @"response-too-large",
    ]);
    assertStringArrayEquals(root[@"tokenEntityKinds"],
        @[@"block", @"call", @"instruction", @"operation", @"region", @"type", @"variable", @"varnode"]);

    NSArray<NSString *> *optionalFields = @[
        @"types.byteSize", @"types.isSigned", @"types.pointeeTypeID", @"types.returnTypeID",
        @"varnodes.typeID", @"varnodes.registerName", @"operations.outputVarnodeID",
        @"operations.directTargetAddress", @"edges.targetBlockID", @"edges.operationID",
        @"ssaValues.definingOperationID", @"ssaValues.definingPhiID", @"ssaBindings.outputSSAValueID",
        @"phis.incoming.sourceBlockID", @"phis.incoming.edgeID",
        @"memoryVersions.definingOperationID", @"memoryVersions.definingMemoryPhiID",
        @"memoryPhis.incoming.sourceBlockID", @"memoryPhis.incoming.edgeID",
        @"memoryEffects.inputMemoryVersionID", @"memoryEffects.outputMemoryVersionID",
        @"variables.typeID", @"calls.targetAddress", @"calls.targetSymbol", @"calls.prototypeTypeID",
        @"calls.resultVariableID", @"regions.parentRegionID", @"regions.conditionOperationID",
    ];
    NSDictionary *optionals = root[@"optionals"];
    assert(optionals.count == optionalFields.count);
    for (NSString *field in optionalFields) {
        NSDictionary *expected = @{@"present": @YES, @"absent": @YES};
        assert([optionals[field] isEqual:expected]);
    }
}

void emitFullFamilyCrossLanguageFixture(
    const char *requestPath,
    const char *replyPath,
    const char *mappingPath
) {
    NSData *requestPayload = binaryPlist(fullFamilyRequestObject());
    DecodedRequest decoded = decodeRequest(requestPayload, kFullRequestID);
    StructuredResult resultValue = fullFamilyResult(decoded.request);
    NSData *replyPayload = encodeSuccessReply(
        kFullRequestID, decoded.request, fullAvailability(), resultValue
    );
    NSError *requestError = nil;
    NSError *replyError = nil;
    NSError *mappingError = nil;
    NSData *mappingPayload = encodeMappingCoverageFixtureForTesting();
    BOOL wroteRequest = [requestPayload writeToFile:[NSString stringWithUTF8String:requestPath]
                                            options:NSDataWritingAtomic
                                              error:&requestError];
    BOOL wroteReply = [replyPayload writeToFile:[NSString stringWithUTF8String:replyPath]
                                        options:NSDataWritingAtomic
                                          error:&replyError];
    BOOL wroteMapping = [mappingPayload writeToFile:[NSString stringWithUTF8String:mappingPath]
                                            options:NSDataWritingAtomic
                                              error:&mappingError];
    assert(wroteRequest && requestError == nil);
    assert(wroteReply && replyError == nil);
    assert(wroteMapping && mappingError == nil);
}

void assertNoPrivatePathStrings(id value) {
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = value;
        assert([string rangeOfString:@"/private/"].location == NSNotFound);
        assert([string rangeOfString:@"/Users/"].location == NSNotFound);
        assert([string rangeOfString:@"NativeDecompilerPackage"].location == NSNotFound);
        assert([string rangeOfString:@"file:" options:NSCaseInsensitiveSearch].location == NSNotFound);
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) assertNoPrivatePathStrings(item);
    } else if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in (NSDictionary *)value) {
            assertNoPrivatePathStrings(key);
            assertNoPrivatePathStrings(((NSDictionary *)value)[key]);
        }
    }
}

void runPackageBackedBridgeFixture(const char *requestPath, const char *replyPath) {
    assert([NSBundle.mainBundle.bundlePath.pathExtension isEqual:@"app"]);
    MSNativeDecompilerObjCBridge *first = [[MSNativeDecompilerObjCBridge alloc] init];
    MSNativeDecompilerObjCBridge *second = [[MSNativeDecompilerObjCBridge alloc] init];
    assert([first prepare]);
    assert([first prepare]);
    assert([second prepare]);
    assert([first preparationAttemptCountForTesting] == 1U);
    assert([second preparationAttemptCountForTesting] == 1U);

    NSMutableDictionary *requestObject = packageBackedRequestObject();
    NSData *request = binaryPlist(requestObject);
    MSNativeDecompilerCancellationHandle *cancellation =
        [[MSNativeDecompilerCancellationHandle alloc] init];
    NSData *firstReply = [first decompileRequestID:kPackageRequestID
                                           payload:request
                                      cancellation:cancellation];
    NSData *secondReply = [second decompileRequestID:kPackageRequestID
                                             payload:request
                                        cancellation:cancellation];
    assert([firstReply isEqualToData:secondReply]);
    assert([first preparationAttemptCountForTesting] == 1U);
    assert([second preparationAttemptCountForTesting] == 1U);
    validateBinaryPropertyListKeysForTesting(firstReply);

    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:firstReply
                                                                    options:0
                                                                     format:nil
                                                                      error:nil];
    if (![root[@"outcome"] isEqual:@"success"]) {
        fprintf(stderr, "package-backed bridge failure: %s\n", root.description.UTF8String);
    }
    assert([root[@"outcome"] isEqual:@"success"]);
    assert(root[@"failure"] == nil);
    NSDictionary *success = root[@"success"];
    assert([success[@"availability"][@"available"] isEqual:@YES]);
    NSDictionary *result = success[@"result"];
    assert([result[@"requestID"] isEqual:kPackageRequestID.UUIDString]);
    assert([result[@"requestSHA256"] isEqual:requestObject[@"body"][@"requestSHA256"]]);
    assert([result[@"image"][@"imageID"] isEqual:@"image.package-backed"]);
    assert([result[@"function"][@"functionID"] isEqual:@"function.package-backed.mov42"]);
    assert([result[@"instructions"] count] == 2U);
    assert([result[@"operations"] count] > 0U);
    assert([result[@"blocks"] count] > 0U);
    assert([result[@"ssaBindings"] count] == [result[@"operations"] count]);

    NSMutableData *instructionBytes = [NSMutableData data];
    for (NSDictionary *instruction in result[@"instructions"]) {
        [instructionBytes appendData:instruction[@"bytes"]];
    }
    static constexpr std::uint8_t expectedBytes[] = {
        0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6,
    };
    assert([instructionBytes isEqualToData:
        [NSData dataWithBytes:expectedBytes length:sizeof(expectedBytes)]]);
    assertNoPrivatePathStrings(root);

    NSError *requestError = nil;
    NSError *replyError = nil;
    assert([request writeToFile:[NSString stringWithUTF8String:requestPath]
                        options:NSDataWritingAtomic
                          error:&requestError]);
    assert(requestError == nil);
    assert([firstReply writeToFile:[NSString stringWithUTF8String:replyPath]
                           options:NSDataWritingAtomic
                             error:&replyError]);
    assert(replyError == nil);
}

NSString *failureCode(NSData *reply) {
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:reply
                                                                    options:0
                                                                     format:nil
                                                                      error:nil];
    return root[@"failure"][@"code"];
}

void testPreparationIsEagerAndFailureIsProcessLatched() {
    MSNativeDecompilerObjCBridge *first = [[MSNativeDecompilerObjCBridge alloc] init];
    MSNativeDecompilerObjCBridge *second = [[MSNativeDecompilerObjCBridge alloc] init];
    MSNativeDecompilerCancellationHandle *cancellation =
        [[MSNativeDecompilerCancellationHandle alloc] init];
    NSData *request = binaryPlist(validRequestObject());

    NSData *beforePrepare = [first decompileRequestID:kRequestID
                                              payload:request
                                         cancellation:cancellation];
    assert([failureCode(beforePrepare) isEqual:@"unavailable"]);
    assert([first preparationAttemptCountForTesting] == 0U);

    assert(![first prepare]);
    assert(![first prepare]);
    assert(![second prepare]);
    assert([first preparationAttemptCountForTesting] == 1U);
    assert([second preparationAttemptCountForTesting] == 1U);

    NSData *afterFailedPrepare = [second decompileRequestID:kRequestID
                                                    payload:request
                                               cancellation:cancellation];
    assert([failureCode(afterFailedPrepare) isEqual:@"package-verification-failed"]);
    assert([first preparationAttemptCountForTesting] == 1U);
    assert([second preparationAttemptCountForTesting] == 1U);
}

// Export All rows name the provider's MacScope-shaped reason; the reply
// encoder must keep such a code verbatim.
void testProviderReasonCodeSurvivesFailureReply() {
    NSData *reply = encodeFailureReply(
        kRequestID, WireFailureCode::nativeFailure, "native-provider-native-error"
    );
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:reply
                                                                    options:0
                                                                     format:nil
                                                                      error:nil];
    assert([root[@"failure"][@"detail"] isEqualToString:@"native-provider-native-error"]);
    NSData *wire = encodeFailureReply(
        kRequestID, WireFailureCode::nativeFailure,
        "native opcode is not representable in the current wire schema"
    );
    NSDictionary *wireRoot = [NSPropertyListSerialization propertyListWithData:wire
                                                                        options:0
                                                                         format:nil
                                                                          error:nil];
    assert([wireRoot[@"failure"][@"detail"]
        isEqualToString:@"native opcode is not representable in the current wire schema"]);
}

void testCancellationHandleIsBoundedAndFailureDetailIsSanitized() {
    MSNativeDecompilerCancellationHandle *handle =
        [[MSNativeDecompilerCancellationHandle alloc] init];
    assert(!cancellationWasRequested(handle));
    [handle cancel];
    assert(cancellationWasRequested(handle));

    NSData *reply = encodeFailureReply(
        kRequestID, WireFailureCode::nativeFailure,
        "unsafe /Users/person 0xabcdef native detail\n"
    );
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:reply
                                                                    options:0
                                                                     format:nil
                                                                      error:nil];
    NSString *detail = root[@"failure"][@"detail"];
    assert(detail.length <= 1024);
    assert([detail rangeOfString:@"/"].location == NSNotFound);
    assert([detail rangeOfString:@"0x"].location == NSNotFound);
    assert([detail rangeOfString:@"\n"].location == NSNotFound);
}

void runWireBoundaryTests() {
    testRequestUsesEffectiveBytesAndPreservesRawBytes();
    testDecodesSwiftWireCodecBinaryGolden();
    testClosedShapeAndCompilerAndRequestIDRejection();
    testCanonicalRequestDigestRejectsSemanticMutation();
    testSharedPlistRegionExpansionIsRejectedBeforeNativeCopies();
    testDuplicateBinaryPropertyListKeysAreRejectedBeforeFoundationCollapsesThem();
    testSchemaV3RejectsTypeHintAliasAndAcceptsAuthoredRoot();
    testCalleeSignatureStorageRegisterDecodesAndPreservesCanonicalBytes();
    testCalleeSignatureStorageRegisterRejectsInvalidWireValues();
    testReachableDictionaryBudgetAcceptsValidAggregateAboveOldCeiling();
    testValidatedResultMappingIsCanonicalAndDeterministic();
    testRuntimeProfileAndOutputBudgetFailClosedBeforeSerialization();
    testFullFamilyResultMappingIsCompleteAndDeterministic();
    testProductionNativeTypeKindsAreRepresentableOnWireV3();
    testMappingCoverageFixtureIsExhaustiveAndDeterministic();
    testCancellationHandleIsBoundedAndFailureDetailIsSanitized();
}

void runAllTests() {
    runWireBoundaryTests();
    testBudgetProfileV2DecodesAndMismatchedLimitsReject();
    testDocumentOperationDecodes();
    testProviderReasonCodeSurvivesFailureReply();
    testPreparationIsEagerAndFailureIsProcessLatched();
}

} // namespace

#if defined(MACSCOPE_NATIVE_BRIDGE_STANDALONE_TEST)
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && std::string(argv[1]) == "--emit-cp4-fixtures") {
            testCP4ProductionBoundaryAndEmitFixtures(argv[2]);
            return 0;
        }
#if defined(MACSCOPE_NATIVE_BRIDGE_WIRE_ONLY_TEST)
        if (argc == 5 && std::string(argv[1]) == "--emit-cross-language-fixture") {
            runWireBoundaryTests();
            emitFullFamilyCrossLanguageFixture(argv[2], argv[3], argv[4]);
        } else {
            assert(argc == 1);
            runWireBoundaryTests();
        }
#else
        if (argc == 4 && std::string(argv[1]) == "--package-backed-decompile") {
            runPackageBackedBridgeFixture(argv[2], argv[3]);
        } else {
            runAllTests();
        }
        if (argc == 5 && std::string(argv[1]) == "--emit-cross-language-fixture") {
            emitFullFamilyCrossLanguageFixture(argv[2], argv[3], argv[4]);
        } else if (!(argc == 4 && std::string(argv[1]) == "--package-backed-decompile")) {
            assert(argc == 1);
        }
#endif
    }
    return 0;
}
#else
#import <XCTest/XCTest.h>

@interface NativeDecompilerObjCBridgeTests : XCTestCase
@end

@implementation NativeDecompilerObjCBridgeTests
- (void)testObjectiveCBridgeContract {
    runAllTests();
}
@end
#endif
