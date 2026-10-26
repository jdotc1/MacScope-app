// Standalone focused probe. The retained fixture helpers are compiled, but their
// historical main and suites are not executed by this probe.
#define main retained_native_golden_main
#include "../../../MacScope/Tests/CoreTests/NativeDecompilerObjCBridgeTests.mm"
#undef main
#include <fstream>
#include <iostream>
#include <limits>
#include <set>

int main(int argc, const char* argv[]) {
    assert(argc == 2);
    @autoreleasepool {
        DecodedRequest decoded = decodeRequest(binaryPlist(fullFamilyRequestObject()), kFullRequestID);
        const auto prototype = fullFamilyResult(decoded.request).tokens.front();
        std::size_t cases = 0;
        for (const std::size_t count : {1U, 64U, 512U, 1024U}) {
            for (const bool unicode : {false, true}) {
                auto result = fullFamilyResult(decoded.request);
                auto floatingType = result.types.front();
                floatingType.id = "type.float";
                floatingType.kind = "floatingPoint";
                floatingType.name = "float";
                floatingType.byteSize = 4U;
                floatingType.isSigned = std::nullopt;
                floatingType.pointeeTypeId = std::nullopt;
                floatingType.returnTypeId = std::nullopt;
                floatingType.fields.clear();
                floatingType.parameterTypeIds.clear();
                result.types.push_back(std::move(floatingType));
                result.tokens.clear();
                for (std::size_t i = 0; i < count; ++i) {
                    auto token = prototype;
                    token.id = "size-token-" + std::to_string(i);
                    token.text = unicode ? "α≤变量" : "synthetic_value";
                    token.line = std::numeric_limits<std::uint32_t>::max();
                    token.column = 65535U;
                    result.tokens.push_back(std::move(token));
                }
                canonicalizeStructuredResult(result);
                validateStructuredResult(decoded.request, result);
                const auto bound = estimatedStructuredResultBytes(result);
                NSData* reply = encodeSuccessReply(kFullRequestID, decoded.request, fullAvailability(), result);
                assert(reply.length <= bound && bound <= decoded.request.budgets.maxOutputBytes);
                NSDictionary* object = [NSPropertyListSerialization propertyListWithData:reply options:0 format:nil error:nil];
                assert([object[@"success"][@"result"][@"tokens"] count] == count);
                for (NSDictionary* token in object[@"success"][@"result"][@"tokens"]) {
                    assert([token[@"line"] unsignedLongLongValue] == std::numeric_limits<std::uint32_t>::max());
                    assert([token[@"column"] unsignedLongLongValue] == 65535U);
                }
                const auto path = std::string(argv[1]) + "/case-" + std::to_string(cases);
                assert([reply writeToFile:[NSString stringWithUTF8String:(path + ".reply").c_str()] atomically:YES]);
                std::ofstream(path + ".bound") << bound << '\n';
                ++cases;
            }
        }
        assert([binaryPlist(fullFamilyRequestObject()) writeToFile:[NSString stringWithUTF8String:(std::string(argv[1])+"/request.bplist").c_str()] atomically:YES]);
        std::cout << "PASS: size model v3, eight focused actual binary replies with shared addresses/positions, Unicode and all record families\n";
    }
}
