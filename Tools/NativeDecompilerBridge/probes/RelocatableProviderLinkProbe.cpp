#include "MacScopeNativeDecompiler/GhidraProvider.hpp"

#include <exception>
#include <iostream>
#include <string>
#include <utility>

int main(int argumentCount, char* arguments[]) {
    using namespace macscope::native_decompiler;
    if (argumentCount != 2) {
        std::cerr << "relocatable-provider-link-probe-usage-invalid\n";
        return 2;
    }

    try {
        auto configuration = makeGhidraBackendConfigurationForMaterialization(
            std::string(arguments[1]),
            "AARCH64:LE:64:AppleSilicon",
            "default"
        );
        const auto provider = makeGhidraProvider(std::move(configuration));
        const auto availability = provider->availability();
        if (!availability.available ||
            availability.identity.backendId != "ghidra-native-decompiler" ||
            availability.identity.ghidraVersion != "12.1.2" ||
            availability.identity.wrapperVersion != "dcp05c-v1" ||
            !availability.runtimeIdentity) {
            std::cerr << "relocatable-provider-link-probe-identity-invalid\n";
            return 1;
        }
        const auto& runtimeIdentity = *availability.runtimeIdentity;
        const auto wrapperRevisionIsCanonical =
            (runtimeIdentity.wrapperRevision.size() == 40U ||
             runtimeIdentity.wrapperRevision.size() == 64U) &&
            runtimeIdentity.wrapperRevision.find_first_not_of("0123456789abcdef") ==
                std::string::npos;
        if (runtimeIdentity.backendId != "ghidra-native-decompiler" ||
            runtimeIdentity.engineVersion != "12.1.2" ||
            runtimeIdentity.engineRevision !=
                "c0f584bf229fffba61b36431f3ce30c0c3e4e682" ||
            runtimeIdentity.wrapperVersion != "dcp05c-v1" ||
            !wrapperRevisionIsCanonical ||
            runtimeIdentity.wrapperRevision != availability.identity.wrapperGitRevision ||
            runtimeIdentity.packageManifestSha256.size() != 64U ||
            runtimeIdentity.packageTreeSha256.size() != 64U ||
            runtimeIdentity.languageId != "AARCH64:LE:64:AppleSilicon" ||
            runtimeIdentity.compilerSpecId != "default" ||
            runtimeIdentity.targetProfileId !=
                "apple-aarch64-pac-visible-clobber-v1" ||
            runtimeIdentity.contextProfileSha256 !=
                "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5") {
            std::cerr << "relocatable-provider-link-probe-identity-invalid\n";
            return 1;
        }
    } catch (const ContractError& error) {
        std::cerr << error.what() << '\n';
        return 1;
    } catch (const std::exception&) {
        std::cerr << "relocatable-provider-link-probe-failed\n";
        return 1;
    } catch (...) {
        std::cerr << "relocatable-provider-link-probe-failed\n";
        return 1;
    }

    std::cout << "Relocatable provider link probe passed\n";
    return 0;
}
