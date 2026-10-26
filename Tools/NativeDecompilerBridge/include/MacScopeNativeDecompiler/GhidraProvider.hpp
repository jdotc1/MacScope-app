#pragma once

#include "MacScopeNativeDecompiler/Backend.hpp"

#include <memory>
#include <string>

namespace macscope::native_decompiler {

/// Construct the untrusted package-backed native producer. Callers must pass
/// the returned provider directly to `makeValidatedProviderBackend`; native
/// objects and raw provider output are never an accepted publication surface.
[[nodiscard]] std::unique_ptr<NativeStructuredProvider> makeGhidraProvider(
    GhidraBackendConfiguration configuration
);

/// Construct the only supported package-backed configuration from an explicit
/// materialization root and the compiled, attested relative layout. This does
/// not acquire package content; `makeGhidraProvider` performs complete runtime
/// attestation before native global state is initialized.
[[nodiscard]] GhidraBackendConfiguration
makeGhidraBackendConfigurationForMaterialization(
    std::string materializationRoot,
    std::string languageId,
    std::string compilerSpecId
);

} // namespace macscope::native_decompiler
