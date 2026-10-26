#include <ghidra/funcdata.hh>
#include <ghidra/heritage.hh>
#include <ghidra/libdecomp.hh>
#include <ghidra/loadimage.hh>
#include <ghidra/printc.hh>
#include <ghidra/sleigh_arch.hh>

#include <filesystem>
#include <iostream>
#include <type_traits>

static_assert(std::is_polymorphic_v<ghidra::LoadImage>);
static_assert(std::is_polymorphic_v<ghidra::SleighArchitecture>);

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "expected one compiled processor-specification root\n";
        return 2;
    }
    const std::filesystem::path specificationRoot(argv[1]);
    if (!std::filesystem::is_directory(specificationRoot)) {
        std::cerr << "compiled processor-specification root is unavailable\n";
        return 3;
    }

    try {
        ghidra::startDecompilerLibrary(specificationRoot.string().c_str());
        ghidra::shutdownDecompilerLibrary();
    } catch (...) {
        std::cerr << "native Ghidra decompiler initialization failed\n";
        return 4;
    }
    return 0;
}
