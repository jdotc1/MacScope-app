#include "MacScopeNativeDecompiler/Backend.hpp"
#include "MacScopeNativeDecompiler/OutputModel.hpp"
#include "TestFixtures.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <exception>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>

using namespace macscope::native_decompiler;

namespace {

int failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

template <typename Function>
std::string contractErrorMessage(Function function, const char* message) {
    try {
        function();
        ++failures;
        std::cerr << "FAIL: expected ContractError: " << message << '\n';
    } catch (const ContractError& error) {
        return error.what();
    }
    return {};
}

class FixtureProvider final : public NativeStructuredProvider {
public:
    BackendAvailability availabilityValue = test_fixtures::fullAvailability();
    std::function<void(const AnalysisRequestView&)> inspectRequest;
    std::function<void(StructuredResult&)> mutateResult;
    bool reverseCollections = false;
    bool throwFromAvailability = false;
    bool throwFromProduce = false;
    std::string produceContractError;
    bool driftAfterProduce = false;
    std::chrono::milliseconds delay{0};
    std::atomic_bool* cancellationFlag = nullptr;
    mutable std::size_t availabilityCalls = 0;
    std::size_t produceCalls = 0;
    std::atomic_int activeProduceCalls{0};
    std::atomic_int maxConcurrentProduceCalls{0};
    bool produced = false;

    BackendAvailability availability() const override {
        ++availabilityCalls;
        if (throwFromAvailability) {
            throw std::runtime_error("private provider availability path: /tmp/secret");
        }
        auto result = availabilityValue;
        if (driftAfterProduce && produced) {
            result.identity.wrapperVersion = "0.1.1";
        }
        return result;
    }

    StructuredResult produce(
        const AnalysisRequestView& request,
        const CancellationToken& cancellation
    ) override {
        ++produceCalls;
        cancellation.throwIfCancelled();
        if (inspectRequest) inspectRequest(request);

        const auto active = activeProduceCalls.fetch_add(1, std::memory_order_acq_rel) + 1;
        auto maximum = maxConcurrentProduceCalls.load(std::memory_order_relaxed);
        while (active > maximum &&
               !maxConcurrentProduceCalls.compare_exchange_weak(
                   maximum,
                   active,
                   std::memory_order_release,
                   std::memory_order_relaxed
               )) {
        }
        struct ActiveProduceGuard final {
            std::atomic_int& count;
            ~ActiveProduceGuard() { count.fetch_sub(1, std::memory_order_acq_rel); }
        } activeGuard{activeProduceCalls};

        if (delay.count() > 0) std::this_thread::sleep_for(delay);
        if (throwFromProduce) {
            throw std::runtime_error("private provider analysis path: /tmp/secret");
        }
        if (!produceContractError.empty()) {
            throw ContractError(produceContractError);
        }
        auto result = test_fixtures::makeResult(request);
        if (mutateResult) mutateResult(result);
        if (reverseCollections) test_fixtures::reverseSetLikeCollections(result);
        if (cancellationFlag != nullptr) cancellationFlag->store(true, std::memory_order_relaxed);
        produced = true;
        return result;
    }
};

struct ProviderHarness final {
    FixtureProvider* provider = nullptr;
    std::unique_ptr<StructuredDecompilerBackend> backend;
};

ProviderHarness makeHarness(std::function<void(FixtureProvider&)> configure = {}) {
    auto provider = std::make_unique<FixtureProvider>();
    if (configure) configure(*provider);
    auto* providerView = provider.get();
    return ProviderHarness{providerView, makeValidatedProviderBackend(std::move(provider))};
}

void expectPacValidationFailure(
    std::function<void(StructuredResult&)> mutate,
    const char* message
) {
    const auto request = test_fixtures::makeRequest();
    auto result = test_fixtures::makeResult(request);
    mutate(result);
    (void)contractErrorMessage(
        [&] { validateStructuredResult(request, result); },
        message
    );
}

// Output-size model v3 charge for distinct ASCII text seen for the first
// time: occurrence 8 + object 16 + one byte per UTF-8 byte.
[[nodiscard]] std::size_t textCharge(std::string_view value) {
    return 24U + value.size();
}

} // namespace

int main() {
    {
        bool inspectedAuthoredInputs = false;
        auto harness = makeHarness([&](FixtureProvider& provider) {
            provider.inspectRequest = [&](const AnalysisRequestView& request) {
                inspectedAuthoredInputs = true;
                check(request.authoredInputs.names.size() == 2,
                      "validated provider receives the authored-input root");
                check(request.authoredInputs.names[0].address == 0x1000 &&
                      request.authoredInputs.names[1].address == 0x2000,
                      "validated provider receives canonical authored root ordering");
            };
        });
        auto request = test_fixtures::makeRequest();
        AuthoredInputs authoredInputs;
        authoredInputs.names = {
            {0x2000, AuthoredNameSubjectKind::data, "second"},
            {0x1000, AuthoredNameSubjectKind::function, "first"},
        };
        request.authoredInputs = canonicalizedAuthoredInputs(std::move(authoredInputs));
        (void)harness.backend->decompile(request, CancellationToken{});
        check(inspectedAuthoredInputs, "validated provider inspects carried authored inputs");
    }

    {
        auto harness = makeHarness();
        const auto availability = harness.backend->availability();
        check(availability.available, "valid provider availability is published");
        const auto request = test_fixtures::makeRequest();
        const auto result = harness.backend->decompile(request, CancellationToken{});
        validateStructuredResult(request, result);
        check(harness.provider->produceCalls == 1, "successful backend calls the provider exactly once");
        check(harness.provider->availabilityCalls == 3,
              "successful backend checks availability directly and before and after analysis");
        check(result.instructions.front().id == "instruction.0", "instruction records are canonicalized");
        check(result.operations.front().id == "op.0", "operation records are canonicalized");
        check(result.blocks.front().operationIds == std::vector<std::string>({"op.0", "op.1"}),
              "semantic basic-block operation order is preserved");
    }

    {
        const AuthenticationEffect transformed{
            AuthenticationEffectKind::transformedOutput,
            "ssa.1",
        };
        check(transformed == AuthenticationEffect{
                  AuthenticationEffectKind::transformedOutput,
                  "ssa.1",
              },
              "authentication effects are value-equatable");
        check(transformed != AuthenticationEffect{},
              "different closed authentication effects compare unequal");

        const auto request = test_fixtures::makeRequest();
        auto result = test_fixtures::makeResult(request);
        result.operations[0].opcode = "CALLOTHER";
        result.operations[0].userOperationName = "pacia";
        result.operations[0].authenticationEffect = transformed;
        validateStructuredResult(request, result);

        result = test_fixtures::makeResult(request);
        result.operations[1].opcode = "CALLOTHER";
        result.operations[1].userOperationName = "AuthDA";
        result.operations[1].authenticationEffect = AuthenticationEffect{
            AuthenticationEffectKind::authenticatedMemoryAccessWithoutTransformedAddress,
            std::nullopt,
        };
        validateStructuredResult(request, result);
        check(true, "closed transformed and outputless PAC shapes validate");
    }

    expectPacValidationFailure(
        [](StructuredResult& result) { result.operations[0].opcode = "CALLOTHER"; },
        "CALLOTHER missing user-operation name"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) { result.operations[0].userOperationName = "pacia"; },
        "user-operation name on non-CALLOTHER"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) {
            result.operations[0].opcode = "CALLOTHER";
            result.operations[0].userOperationName = "";
        },
        "empty CALLOTHER user-operation name"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) {
            result.operations[0].opcode = "CALLOTHER";
            result.operations[0].userOperationName = "pacia";
            result.operations[0].authenticationEffect = AuthenticationEffect{
                AuthenticationEffectKind::transformedOutput,
                std::nullopt,
            };
        },
        "transformed PAC effect missing output SSA ID"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) {
            result.operations[0].opcode = "CALLOTHER";
            result.operations[0].userOperationName = "pacia";
            result.operations[0].authenticationEffect = AuthenticationEffect{
                AuthenticationEffectKind::transformedOutput,
                "ssa.0",
            };
        },
        "transformed PAC effect bound to an input SSA value"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) {
            result.operations[1].opcode = "CALLOTHER";
            result.operations[1].userOperationName = "AuthIA";
            result.operations[1].authenticationEffect = AuthenticationEffect{
                AuthenticationEffectKind::transformedOutput,
                "ssa.1",
            };
        },
        "transformed PAC effect on outputless operation"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) {
            result.operations[0].opcode = "CALLOTHER";
            result.operations[0].userOperationName = "AuthDA";
            result.operations[0].authenticationEffect = AuthenticationEffect{
                AuthenticationEffectKind::authenticatedMemoryAccessWithoutTransformedAddress,
                std::nullopt,
            };
        },
        "outputless memory authentication effect on output-bearing operation"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) {
            result.operations[1].opcode = "CALLOTHER";
            result.operations[1].userOperationName = "AuthIB";
            result.operations[1].authenticationEffect = AuthenticationEffect{
                AuthenticationEffectKind::authenticatedControlTransferWithoutTransformedTarget,
                "ssa.1",
            };
        },
        "outputless control authentication effect carrying an SSA ID"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) {
            result.operations[0].authenticationEffect = AuthenticationEffect{
                AuthenticationEffectKind::none,
                "ssa.1",
            };
        },
        "none authentication effect carrying an SSA ID"
    );
    expectPacValidationFailure(
        [](StructuredResult& result) {
            result.operations[0].authenticationEffect = AuthenticationEffect{
                static_cast<AuthenticationEffectKind>(255U),
                std::nullopt,
            };
        },
        "unknown authentication-effect kind"
    );

    {
        StructuredResult empty;
        const auto emptyBound = estimatedStructuredResultBytes(empty);
        StructuredResult withPacOperation;
        OperationRecord operation;
        operation.id = "o";
        operation.blockId = "b";
        operation.opcode = "CALLOTHER";
        operation.userOperationName = "pacia";
        operation.authenticationEffect = AuthenticationEffect{
            AuthenticationEffectKind::transformedOutput,
            "ssa.out",
        };
        withPacOperation.operations.push_back(operation);
        const auto expectedOperationCharge =
            48U + textCharge(operation.id) + textCharge(operation.blockId) + 32U +
            textCharge(operation.opcode) + 32U +
            32U + textCharge(*operation.userOperationName) +
            32U + 32U + textCharge(*operation.authenticationEffect.outputSsaValueId);
        check(estimatedStructuredResultBytes(withPacOperation) ==
                  emptyBound + expectedOperationCharge,
              "semantic estimator charges PAC name, effect kind, optional presence, and output SSA exactly once");

        auto withoutPacPayload = withPacOperation;
        withoutPacPayload.operations[0].userOperationName.reset();
        withoutPacPayload.operations[0].authenticationEffect = AuthenticationEffect{};
        const auto exactPayloadCharge = textCharge("pacia") + textCharge("ssa.out");
        check(estimatedStructuredResultBytes(withPacOperation) ==
                  estimatedStructuredResultBytes(withoutPacPayload) + exactPayloadCharge,
              "PAC optional payload text contributes its exact worst-case escaped bound");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.capabilities.tokenizedPseudocode = false;
            provider.mutateResult = [](StructuredResult& result) {
                result.tokens.clear();
                result.pseudocodeDocument = PseudocodeDocumentRecord{
                    "uint64_t fixture(void) {\n\treturn 1;\n}\n",
                    "c",
                    true,
                    false,
                };
            };
        });
        const auto request = test_fixtures::makeRequest();
        const auto result = harness.backend->decompile(request, CancellationToken{});
        check(result.pseudocodeDocument.has_value(),
              "validated backend publishes a presentation document without token capability");
        check(result.tokens.empty(),
              "presentation document does not fabricate token records");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.delay = std::chrono::milliseconds(25);
        });
        const auto request = test_fixtures::makeRequest(
            AnalysisBudgets{4096, 256, 4096, 1024 * 1024, 2000}
        );
        std::atomic_int ready = 0;
        std::atomic_bool start = false;
        std::exception_ptr firstError;
        std::exception_ptr secondError;
        StructuredResult firstResult;
        StructuredResult secondResult;

        const auto run = [&](StructuredResult& destination, std::exception_ptr& error) {
            ready.fetch_add(1, std::memory_order_release);
            while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
            try {
                destination = harness.backend->decompile(request, CancellationToken{});
            } catch (...) {
                error = std::current_exception();
            }
        };

        std::thread first(run, std::ref(firstResult), std::ref(firstError));
        std::thread second(run, std::ref(secondResult), std::ref(secondError));
        while (ready.load(std::memory_order_acquire) != 2) std::this_thread::yield();
        start.store(true, std::memory_order_release);
        first.join();
        second.join();

        check(firstError == nullptr && secondError == nullptr,
              "concurrent callers both receive validated results");
        check(firstResult == secondResult,
              "serialized provider calls publish identical canonical results");
        check(harness.provider->produceCalls == 2,
              "concurrent callers each invoke the provider exactly once");
        check(harness.provider->maxConcurrentProduceCalls.load(std::memory_order_acquire) == 1,
              "validated backend serializes access to an untrusted provider instance");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.delay = std::chrono::milliseconds(100);
        });
        const auto request = test_fixtures::makeRequest(
            AnalysisBudgets{4096, 256, 4096, 1024 * 1024, 2000}
        );
        std::exception_ptr analysisError;
        std::thread analysis([&] {
            try {
                (void)harness.backend->decompile(request, CancellationToken{});
            } catch (...) {
                analysisError = std::current_exception();
            }
        });
        while (harness.provider->activeProduceCalls.load(std::memory_order_acquire) == 0) {
            std::this_thread::yield();
        }

        const auto availability = harness.backend->availability();
        const bool providerWasStillActive =
            harness.provider->activeProduceCalls.load(std::memory_order_acquire) > 0;
        analysis.join();

        check(analysisError == nullptr, "analysis completes while availability reports provider busy");
        check(!availability.available && availability.reasonCode == "provider-busy",
              "availability reports a truthful transient provider-busy state");
        check(providerWasStillActive,
              "availability returns before an active untrusted provider execution completes");
    }

    {
        const auto request = test_fixtures::makeRequest();
        const auto expected = canonicalizedStructuredResult(test_fixtures::makeResult(request));
        const auto expectedSummary = test_fixtures::canonicalSummary(expected);
        const auto expectedBound = estimatedStructuredResultBytes(expected);

        auto harness = makeHarness([](FixtureProvider& provider) { provider.reverseCollections = true; });
        auto result = harness.backend->decompile(request, CancellationToken{});
        check(test_fixtures::canonicalSummary(result) == expectedSummary,
              "shuffled set-like provider collections normalize to the canonical result");
        check(estimatedStructuredResultBytes(result) == expectedBound,
              "encoded-size estimate is independent of provider insertion order");
        const auto once = result;
        result = canonicalizedStructuredResult(std::move(result));
        check(result == once, "canonicalization is idempotent");
    }

    contractErrorMessage([] { (void)makeValidatedProviderBackend(nullptr); }, "null provider");

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.available = false;
            provider.availabilityValue.reasonCode = "fixture-unavailable";
            provider.availabilityValue.identity = {};
            provider.availabilityValue.capabilities = {};
            provider.availabilityValue.runtimeIdentity.reset();
        });
        check(!harness.backend->availability().available, "valid unavailable provider remains unavailable");
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "unavailable provider cannot analyze"
        );
        check(harness.provider->produceCalls == 0, "unavailable provider is not invoked");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.identity.ghidraGitRevision = "not-a-revision";
        });
        const auto availability = harness.backend->availability();
        check(!availability.available && availability.reasonCode == "provider-availability-invalid",
              "malformed provider availability is sanitized");
        const auto request = test_fixtures::makeRequest();
        const auto message = contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "invalid provider availability"
        );
        check(message == "structured provider availability is invalid",
              "invalid provider availability does not expose provider fields");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.available = false;
            provider.availabilityValue.reasonCode = "fixture-unavailable";
            provider.availabilityValue.capabilities = {};
        });
        check(!harness.backend->availability().available,
              "unavailable provider with a versioned identity is sanitized");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) { provider.throwFromAvailability = true; });
        const auto availability = harness.backend->availability();
        check(!availability.available && availability.reasonCode == "provider-availability-invalid",
              "availability exceptions are sanitized");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) { provider.throwFromProduce = true; });
        const auto request = test_fixtures::makeRequest();
        const auto message = contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "provider exception"
        );
        check(message == "structured provider execution failed", "provider exception text is suppressed");
        check(message.find("secret") == std::string::npos && message.find("/tmp") == std::string::npos,
              "provider exception does not leak private paths");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.produceContractError = "native-provider-basic-block-count-invalid";
        });
        const auto request = test_fixtures::makeRequest();
        const auto message = contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "provider contract code"
        );
        check(message == "structured provider execution failed", "provider contract code stays suppressed in what()");
        check(lastSuppressedProviderFailureReason() == "native-provider-basic-block-count-invalid",
              "provider contract code is retained as the suppressed reason");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.produceContractError = "Secret /tmp path in Provider text";
        });
        const auto request = test_fixtures::makeRequest();
        (void)contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "provider free text"
        );
        // FNV-1a 64 of "Secret /tmp path in Provider text".
        const auto reason = lastSuppressedProviderFailureReason();
        check(reason.starts_with("provider-error-unclassified-") && reason.size() == 44U &&
                  reason.find("ecret") == std::string_view::npos,
              "non-code provider text is reduced to a fingerprint");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) { provider.throwFromProduce = true; });
        const auto request = test_fixtures::makeRequest();
        (void)contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "provider foreign exception"
        );
        check(lastSuppressedProviderFailureReason() == "provider-exception-unclassified",
              "foreign provider exceptions record only a fixed reason");
        auto clean = makeHarness([](FixtureProvider&) {});
        (void)clean.backend->decompile(request, CancellationToken{});
        check(lastSuppressedProviderFailureReason().empty(), "a later successful call clears the suppressed reason");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.produceContractError = "authoring-input-unsupported";
        });
        const auto request = test_fixtures::makeRequest();
        const auto message = contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "authored authority rejection"
        );
        check(message == "authoring-input-unsupported",
              "authored authority rejection uses only its stable public path");
        check(harness.provider->produceCalls == 1, "authored authority rejection returns no success result");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.produceContractError = "native-provider-operation-opcode-unavailable";
        });
        const auto request = test_fixtures::makeRequest();
        const auto message = contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "unrepresentable opcode"
        );
        check(message == "native-provider-operation-opcode-unavailable",
              "unrepresentable opcode remains a typed unavailable outcome");
        check(harness.provider->produceCalls == 1,
              "unrepresentable opcode publishes no fabricated structured result");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) { provider.driftAfterProduce = true; });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "identity drift during analysis"
        );
    }

    {
        auto harness = makeHarness();
        std::atomic_bool cancelled = true;
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken(&cancelled)); },
            "pre-entry cancellation"
        );
        check(harness.provider->produceCalls == 0, "pre-entry cancellation prevents provider invocation");
    }

    {
        std::atomic_bool cancelled = false;
        auto harness = makeHarness([&](FixtureProvider& provider) { provider.cancellationFlag = &cancelled; });
        const auto request = test_fixtures::makeRequest();
        const auto message = contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken(&cancelled)); },
            "post-provider cancellation"
        );
        check(message == "analysis was cancelled", "late cancellation rejects result publication");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.delay = std::chrono::milliseconds(75);
        });
        const auto request = test_fixtures::makeRequest(
            AnalysisBudgets{4096, 256, 4096, 1024 * 1024, 2000}
        );
        std::exception_ptr firstError;
        StructuredResult firstResult;
        std::thread first([&] {
            try {
                firstResult = harness.backend->decompile(request, CancellationToken{});
            } catch (...) {
                firstError = std::current_exception();
            }
        });
        while (harness.provider->activeProduceCalls.load(std::memory_order_acquire) != 1) {
            std::this_thread::yield();
        }

        std::atomic_bool cancelled = false;
        std::string queuedMessage;
        std::thread queued([&] {
            queuedMessage = contractErrorMessage(
                [&] { (void)harness.backend->decompile(request, CancellationToken(&cancelled)); },
                "queued cancellation"
            );
        });
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        cancelled.store(true, std::memory_order_release);
        queued.join();
        first.join();

        check(firstError == nullptr, "active provider call succeeds while queued caller is cancelled");
        check(!firstResult.instructions.empty(), "active provider call publishes its result");
        check(queuedMessage == "analysis was cancelled",
              "cancellation is observed while waiting for serialized provider access");
        check(harness.provider->produceCalls == 1,
              "cancelled queued caller never enters the untrusted provider");
    }

    {
        auto harness = makeHarness();
        const auto request = test_fixtures::makeRequest(AnalysisBudgets{4096, 1, 4096, 1024 * 1024, 1000});
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "instruction budget"
        );
    }

    {
        auto harness = makeHarness();
        const auto request = test_fixtures::makeRequest(AnalysisBudgets{4096, 256, 1, 1024 * 1024, 1000});
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "operation budget"
        );
    }

    {
        auto harness = makeHarness();
        const auto request = test_fixtures::makeRequest(AnalysisBudgets{4096, 256, 4096, 1024, 1000});
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "output size budget"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) { provider.delay = std::chrono::milliseconds(20); });
        const auto request = test_fixtures::makeRequest(AnalysisBudgets{4096, 256, 4096, 1024 * 1024, 1});
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "wall-time publication budget"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) { result.requestId = "request.forged"; };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "forged request binding"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) { result.blocks[0].operationIds.pop_back(); };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "forged operation ownership"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                std::reverse(result.blocks[0].operationIds.begin(), result.blocks[0].operationIds.end());
            };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "semantic operation order is rejected rather than normalized"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                result.edges = {
                    {"edge.0", "block.0", "block.0", 0x1000, "backedge", "op.1"},
                    {"edge.1", "block.0", "block.0", 0x1000, "backedge", "op.1"},
                };
                result.blocks[0].predecessorEdgeIds = {"edge.0", "edge.1"};
                result.blocks[0].successorEdgeIds = {"edge.0", "edge.1"};
                result.ssaValues.push_back(
                    {"ssa.entry-x0", "vn.x0", "functionEntry", std::nullopt, std::nullopt}
                );
                result.ssaValues.push_back(
                    {"ssa.phi-x0", "vn.x0", "phiResult", std::nullopt, "phi.0"}
                );
                result.phis = {
                    {"phi.0", "block.0", "vn.x0", "ssa.phi-x0",
                     {{std::nullopt, std::nullopt, "ssa.entry-x0"},
                      {"block.0", "edge.0", "ssa.1"}}},
                };
            };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "phi missing one predecessor path"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) { result.instructions[0].bytes[0] ^= 0xffU; };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); }, "forged effective bytes"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                result.instructions[0].sourceRanges.push_back(result.instructions[0].sourceRanges.front());
            };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "duplicate source range is rejected rather than normalized"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                result.variables[0].storageVarnodeIds.push_back(result.variables[0].storageVarnodeIds.front());
            };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "duplicate variable storage is rejected"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                result.tokens[0].entityReferences.push_back(result.tokens[0].entityReferences.front());
            };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "duplicate token reference is rejected"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                const DiagnosticRecord warning{
                    "fixture-warning",
                    "warning",
                    "duplicate warning",
                    {{result.image.imageId, result.function.entryAddress, result.function.endAddressExclusive}},
                };
                result.warnings = {warning, warning};
            };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "duplicate diagnostics are rejected"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                result.tokens[0].id = std::string("token.") + static_cast<char>(0x1b) + "forged";
            };
        });
        const auto request = test_fixtures::makeRequest();
        const auto message = contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "control text in semantic IDs"
        );
        check(message.find(static_cast<char>(0x1b)) == std::string::npos,
              "validation errors do not echo control-text provider identifiers");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                result.tokens[0].id = std::string("\xc3\x28", 2);
            };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "invalid UTF-8 in structured output"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.identity.backendId = std::string("\xf0\x28\x8c\xbc", 4);
        });
        const auto availability = harness.backend->availability();
        check(!availability.available && availability.reasonCode == "provider-availability-invalid",
              "invalid UTF-8 availability is sanitized");
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.capabilities.memorySsa = false;
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "MemorySSA capability contradiction"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.capabilities.recoveredVariables = false;
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "variable capability contradiction"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.capabilities.recoveredTypes = false;
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "type capability contradiction"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.capabilities.structuredControlFlow = false;
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "region capability contradiction"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.availabilityValue.capabilities.tokenizedPseudocode = false;
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "token capability contradiction"
        );
    }

    {
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& result) {
                result.ssaValues.clear();
                result.ssaBindings.clear();
            };
        });
        const auto request = test_fixtures::makeRequest();
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(request, CancellationToken{}); },
            "SSA capability contradiction"
        );
    }

    {
        auto invalid = test_fixtures::fullAvailability();
        invalid.available = false;
        invalid.reasonCode = "unavailable";
        contractErrorMessage(
            [&] { validateBackendAvailability(invalid); }, "unavailable backend claiming capabilities"
        );

        invalid = test_fixtures::fullAvailability();
        invalid.capabilities.nativeDecompilerHeritage = false;
        contractErrorMessage(
            [&] { validateBackendAvailability(invalid); }, "available backend missing native heritage"
        );
    }

    {
        const auto request = test_fixtures::makeRequest();
        const auto result = test_fixtures::makeResult(request);
        const auto upperBound = estimatedStructuredResultBytes(result);
        check(upperBound > 4096, "encoded-size estimate includes structured records");
        check(upperBound < request.budgets.maxOutputBytes,
              "fixture remains inside the normal publication budget");

        auto controlText = result;
        controlText.tokens[0].text.assign(1024, '\x01');
        check(estimatedStructuredResultBytes(controlText) >= upperBound + 1024U - 64U,
              "encoded-size estimate charges every byte of a new ASCII text");

        auto nonAsciiText = result;
        nonAsciiText.tokens[0].text.clear();
        for (std::size_t index = 0; index < 512U; ++index) nonAsciiText.tokens[0].text += "\xc3\xa9";
        check(estimatedStructuredResultBytes(nonAsciiText) >= upperBound + (1024U * 2U) - 64U,
              "encoded-size estimate reserves UTF-16 storage for non-ASCII text");

        auto repeated = result;
        repeated.tokens.push_back(repeated.tokens[0]);
        repeated.tokens.back().id = repeated.tokens[0].id + "-copy";
        repeated.tokens.back().text = repeated.tokens[0].text + std::string(4096, 'y');
        auto repeatedTwice = repeated;
        repeatedTwice.tokens.push_back(repeated.tokens.back());
        repeatedTwice.tokens.back().id = repeated.tokens[0].id + "-copy2";
        check(estimatedStructuredResultBytes(repeatedTwice) <
                  estimatedStructuredResultBytes(repeated) + 4096U,
              "a repeated text is charged as a reference, not a second copy");

        auto byteHeavy = result;
        const auto originalBytes = byteHeavy.instructions[0].bytes.size();
        byteHeavy.instructions[0].bytes.assign(1024, 0xffU);
        check(
            estimatedStructuredResultBytes(byteHeavy) >=
                upperBound + ((1024U - originalBytes) * 5U),
            "encoded-size estimate reserves decimal array expansion for instruction bytes"
        );

        auto withDocument = result;
        withDocument.pseudocodeDocument = PseudocodeDocumentRecord{
            std::string(4096, 'x'),
            "c",
            false,
            true,
        };
        const auto documentBound = estimatedStructuredResultBytes(withDocument);
        check(documentBound >= upperBound + 4096U,
              "encoded-size estimate charges every pseudocode presentation byte");

        const auto boundedRequest = test_fixtures::makeRequest(AnalysisBudgets{
            4096,
            256,
            4096,
            upperBound + 1024U,
            1000,
        });
        auto harness = makeHarness([](FixtureProvider& provider) {
            provider.mutateResult = [](StructuredResult& produced) {
                produced.pseudocodeDocument = PseudocodeDocumentRecord{
                    std::string(4096, 'x'),
                    "c",
                    false,
                    true,
                };
            };
        });
        contractErrorMessage(
            [&] { (void)harness.backend->decompile(boundedRequest, CancellationToken{}); },
            "pseudocode presentation exceeds the publication budget"
        );
    }

    if (failures != 0) {
        std::cerr << failures << " provider-backend test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "MacScope validated structured-provider tests passed\n";
    return EXIT_SUCCESS;
}
