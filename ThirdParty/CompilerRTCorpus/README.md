# compiler-rt signature-corpus dependency record

The governing upstream license is stored at
`Scripts/function-signatures/LICENSE.compiler-rt.txt`. Source-oracle fixtures,
manifest data, rejection records, and the standard-library-only generator live
under `Scripts/function-signatures/`; the generated runtime predicates live in
`MacScope/Services/FunctionSignatures/FunctionSignatureCorpus.swift`.

The Xcode archive used to generate the corpus is not committed. Its exact
SHA-256 and selected arm64 slice SHA-256 are recorded in
`Scripts/function-signatures/compiler_rt_signatures_manifest.json`.
