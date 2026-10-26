#include "DefinitionIdentity.hpp"
#include "MacScopeNativeDecompiler/OutputModel.hpp"
#include "TestFixtures.hpp"

#include <cstdlib>
#include <functional>
#include <iostream>
#include <set>
#include <string>

using namespace macscope::native_decompiler;
namespace {
int failures = 0;
void check(bool value, const char* message) {
    if (!value) { ++failures; std::cerr << "FAIL: " << message << '\n'; }
}
void rejects(const std::function<void()>& action, const char* message) {
    try { action(); check(false, message); } catch (const ContractError&) {}
}
}

int main() {
    // Adjacent definitions, reused instruction addresses, wide sequence times
    // and delimiter-like suffixes must retain distinct identities. No digest
    // collision assumption or storage offset is used to distinguish outputs.
    std::set<std::string> identities;
    const std::string prefixes[] = {
        "op:0000000000001000:", "op:ffffffffffffffff:",
        "op:0000000000001001:", "op:0000000000001000:entry:"
    };
    for (const auto& prefix : prefixes) {
        for (unsigned time = 0; time < 256; ++time) {
            const auto op = prefix + std::to_string(time);
            check(identities.insert(detail::definedVarnodeIdentity(op)).second, "varnode identity injectivity");
            check(identities.insert(detail::definedSsaIdentity(op)).second, "SSA identity injectivity");
            check(identities.insert(detail::definedPhiIdentity(op)).second, "phi identity injectivity/domain separation");
        }
    }
    // Multiple definitions of the same register storage still get distinct
    // SSA identities; the location itself is not copied into those identities.
    check(detail::definedSsaIdentity("op.0") != detail::definedSsaIdentity("op.1"), "redefined storage has distinct SSA values");
    check(!identities.contains("ssa:varnode:register:0000000000005000:32:register:entry"), "entry identities stay separate");

    auto request = test_fixtures::makeRequest();
    auto result = test_fixtures::makeResult(request);
    const auto vn = detail::definedVarnodeIdentity("op.0");
    const auto ssa = detail::definedSsaIdentity("op.0");
    result.varnodes[1].id = vn;
    result.operations[0].outputVarnodeId = vn;
    result.operations[1].inputVarnodeIds[0] = vn;
    result.variables[0].storageVarnodeIds[0] = vn;
    result.ssaValues[1].id = ssa;
    result.ssaValues[1].varnodeId = vn;
    result.ssaBindings[0].outputSsaValueId = ssa;
    result.ssaBindings[1].inputSsaValueIds[0] = ssa;
    // All storage, type, operation definition, source and presentation fields
    // survive the rename; validate the actual contract graph, not just strings.
    try { validateStructuredResult(request, result); }
    catch (const ContractError& error) { check(false, error.what()); }
    auto bad = result;
    bad.ssaBindings[1].inputSsaValueIds[0] = detail::definedSsaIdentity("op.missing");
    rejects([&] { validateStructuredResult(request, bad); }, "dangling compact SSA reference rejected");
    bad = result;
    bad.ssaValues[1].definingOperationId = "op.1";
    rejects([&] { validateStructuredResult(request, bad); }, "compact ID cannot hide wrong explicit definition");
    bad = result;
    bad.varnodes.push_back(bad.varnodes[1]);
    bad.varnodes.back().offset += 8;
    rejects([&] { validateStructuredResult(request, bad); }, "colliding compact location records rejected");
    bad = result;
    bad.ssaValues.push_back(bad.ssaValues[1]);
    bad.ssaValues.back().varnodeId = "vn.constant.0";
    rejects([&] { validateStructuredResult(request, bad); }, "colliding compact SSA records rejected");
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
