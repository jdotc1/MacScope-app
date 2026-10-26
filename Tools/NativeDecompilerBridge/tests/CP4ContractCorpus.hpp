// Included by GhidraProviderTests.cpp inside its fixture namespace. Test-only.
std::optional<std::string> cp4CorpusOutputPath;

void testCP4ContractCorpus(NativeStructuredProvider& provider) {
    using cp4_test_json::Writer;
    Writer corpus;
    corpus.output << "[";
    bool firstFixture = true;
    const auto profile = productAnalysisBudgetsV1();
    const auto emit = [&](std::string_view name, const AnalysisRequestView& request,
                          const StructuredResult& result, bool accepted) {
        std::string error;
        try { validateStructuredResult(request, result); }
        catch (const ContractError& failure) { error = failure.what(); }
        check(accepted == error.empty(), std::string(name) + " C++ accept/reject oracle: " + error);
        if (!std::exchange(firstFixture, false)) corpus.output << ',';
        corpus.output << '{'; bool first = true;
        corpus.field(first, "name", std::string(name));
        corpus.field(first, "accepted", accepted);
        corpus.field(first, "cppError", error);
        corpus.field(first, "requestID", request.requestId);
        corpus.field(first, "requestSHA256", request.requestSha256);
        corpus.field(first, "image", request.image);
        corpus.field(first, "function", request.function);
        corpus.field(first, "memoryRegions", request.bytes.regions());
        corpus.field(first, "symbols", request.symbols.symbols());
        corpus.field(first, "capabilities", provider.availability().capabilities);
        corpus.field(first, "runtimeIdentity", provider.availability().runtimeIdentity);
        corpus.field(first, "estimatedBytes", std::uint64_t(estimatedStructuredResultBytes(result)));
        corpus.field(first, "encodedSizeUpperBound", std::uint64_t(structuredResultEncodedSizeUpperBound(result)));
        corpus.field(first, "replyVersion", requiredWireReplySchemaVersion(result));
        corpus.field(first, "result", result);
        corpus.output << '}';
    };
    const auto prepare = [&](AnalysisRequestView request) {
        request.requestId = "00000000-0000-0000-0000-000000000042";
        request.budgets = profile.analysisLimits();
        std::uint64_t byteCount = 0;
        for (const auto& region : request.bytes.regions()) byteCount += region.effectiveBytes.size();
        const auto target = normalizeAppleMachOTarget(0x0100000c, 2, std::string(64, 'a'), byteCount);
        request.requestSha256 = canonicalRequestSha256V2({std::cref(target), std::cref(request.image),
            std::cref(request.function), std::cref(request.bytes), std::cref(request.symbols),
            std::cref(request.authoredInputs), std::cref(profile)});
        return request;
    };
    const auto exportTwice = [&](std::string_view name, const AnalysisRequestView& request) {
        const auto first = provider.produce(request, CancellationToken{});
        const auto second = provider.produce(request, CancellationToken{});
        Writer one, two; one.value(first); two.value(second);
        check(one.output.str() == two.output.str(), std::string(name) + " complete DTO export is byte-identical");
        check(first == second, std::string(name) + " complete typed DTO is identical");
        check(std::none_of(first.warnings.begin(), first.warnings.end(), [](const auto& warning) {
            return warning.code.find("fallback") != std::string::npos;
        }), std::string(name) + " has no reduced-action fallback marker");
        emit(name, request, first, true);
        std::cout << "cp4-determinism " << name << " complete-json-bytes=" << one.output.str().size()
                  << " reply=" << requiredWireReplySchemaVersion(first) << " match=1\n";
        return first;
    };
    for (const auto& body : ordinaryVimBodies()) {
        const auto request = prepare(makePacRequest(std::string(body.name), body.words));
        const auto result = exportTwice(body.name, request);
        if (body.name == "vim_100001f58" || body.name == "vim_100005694") {
            check(result.blockPartition && std::any_of(result.blockPartition->edges.begin(),
                result.blockPartition->edges.end(), [](const auto& edge) {
                    return edge.transferKind == "rewritten-intra-instruction";
                }), "optimized relative target is explicitly classified as rewritten");
        }
    }
    // Keep a known unchanged legacy result in the cross-language corpus.
    exportTwice("unchanged-straight-line", prepare(makePacRequest("cp4-straight", {0x52800540U,0xd65f03c0U})));
    const auto loopRequest = prepare(makeLoopRequest());
    const auto loop = exportTwice("zero-op-loop", loopRequest);
    const auto cselRequest = prepare(makePacRequest("cp4-csel", {0x7100001fU,0x1a820020U,0xd65f03c0U}));
    const auto csel = exportTwice("multi-owner-csel", cselRequest);
    const auto authRequest = prepare(makePacRequest("cp4-autibsp", {0xd50323ffU,0xd65f03c0U}));
    const auto auth = exportTwice("standalone-autibsp", authRequest);
    const auto mutate = [&](std::string_view name, const AnalysisRequestView& request,
                            const StructuredResult& source, auto change) {
        auto bad = source; change(bad); emit(name, request, bad, false);
    };
    const auto bad = [&](std::string_view name, auto change) { mutate(name, cselRequest, csel, change); };
    bad("unsupported-partition-version", [](auto& r) { r.blockPartition->version = 2; });
    bad("missing-block-descriptor", [](auto& r) { r.blockPartition->blocks.pop_back(); });
    bad("missing-instruction-ownership", [](auto& r) { r.blockPartition->instructions.pop_back(); });
    bad("missing-edge-metadata", [](auto& r) { r.blockPartition->edges.pop_back(); });
    bad("forged-entry", [](auto& r) { r.blockPartition->entryBlockId = r.blockPartition->blocks.back().blockId; });
    bad("noncanonical-ordinal", [](auto& r) { r.blockPartition->blocks.back().ordinal = 0; });
    bad("forged-source-envelope", [](auto& r) { ++r.blocks.front().endAddressExclusive; });
    bad("forged-source-image", [](auto& r) { r.blockPartition->blocks.front().sourceRanges.front().imageId = "foreign"; });
    bad("source-range-overflow", [](auto& r) { r.blockPartition->blocks.front().sourceRanges.front().endAddressExclusive = ~Address(0); });
    bad("span-offset-overflow", [](auto& r) { r.blockPartition->instructions[1].spans.front().firstOperationIndex = ~std::uint32_t(0); });
    bad("span-count-overflow", [](auto& r) { r.blockPartition->instructions[1].spans.front().operationCount = ~std::uint32_t(0); });
    bad("duplicate-span-owner", [](auto& r) { auto& x=r.blockPartition->instructions[1].spans; x.push_back(x.front()); });
    bad("eliminated-with-live-ops", [](auto& r) { r.blockPartition->instructions[1].disposition = "eliminated"; });
    bad("unknown-disposition", [](auto& r) { r.blockPartition->instructions[1].disposition = "approximate"; });
    bad("noncontiguous-operation-sequence", [](auto& r) { r.operations.front().sequence = 77; });
    bad("missing-live-operation", [](auto& r) { r.blocks.front().operationIds.pop_back(); });
    bad("legacy-downgrade", [](auto& r) { r.blockPartition.reset(); });
    bad("source-slot-overflow", [](auto& r) { r.blockPartition->edges.front().sourceSlot = ~std::uint32_t(0); });
    bad("target-slot-overflow", [](auto& r) { r.blockPartition->edges.front().targetSlot = ~std::uint32_t(0); });
    bad("unknown-transfer", [](auto& r) { r.blockPartition->edges.front().transferKind = "assumed"; });
    bad("false-relative-rewrite", [](auto& r) {
        for (auto& e : r.blockPartition->edges) if (e.transferKind == "intra-instruction") {
            e.transferKind = "rewritten-intra-instruction"; break;
        }
    });
    bad("relative-as-absolute", [](auto& r) {
        for (auto& e : r.blockPartition->edges) if (e.transferKind == "intra-instruction") { e.transferKind = "direct"; break; }
    });
    bad("phi-predecessor-slot-swap", [](auto& r) { std::swap(r.phis.front().incoming[0], r.phis.front().incoming[1]); });
    mutate("empty-conditional-forgery", loopRequest, loop, [](auto& r) {
        for (auto& b : r.blocks) if (b.operationIds.empty()) b.terminatorKind = "conditional";
    });
    mutate("splice-with-operation", loopRequest, loop, [](auto& r) {
        for (auto& e : r.edges) if (e.kind == "splice") e.operationId = r.operations.front().id;
    });
    mutate("auth-mnemonic-forgery", authRequest, auth, [](auto& r) { r.instructions.front().mnemonic = "nop"; });
    mutate("auth-userop-forgery", authRequest, auth, [](auto& r) {
        for (auto& o : r.operations) if (o.authenticationEffect.kind == AuthenticationEffectKind::standaloneAuthenticationWithoutTransformedOutput) o.userOperationName = "AuthIA";
    });
    mutate("auth-output-forgery", authRequest, auth, [](auto& r) {
        for (auto& o : r.operations) if (o.authenticationEffect.kind == AuthenticationEffectKind::standaloneAuthenticationWithoutTransformedOutput) o.authenticationEffect.outputSsaValueId = r.ssaValues.front().id;
    });
    corpus.output << "]\n";
    if (cp4CorpusOutputPath) {
        std::ofstream stream(*cp4CorpusOutputPath, std::ios::binary | std::ios::trunc);
        stream << corpus.output.str();
        check(stream.good(), "complete CP4 corpus written without truncation");
    }
}
