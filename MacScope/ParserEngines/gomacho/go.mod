module macscope.invalid/parserengines/gomacho

go 1.20

require (
	github.com/blacktop/go-dwarf v1.0.14
	github.com/blacktop/go-macho v1.1.283
)

// The engine is built only from the vendored, pinned sources in ThirdParty/GoMachO.
// The cached builder runs with GOFLAGS=-mod=mod, GOPROXY=off and GOTOOLCHAIN=local,
// so a missing or changed module can never be fetched.
replace github.com/blacktop/go-macho => ../../../ThirdParty/GoMachO/go-macho

replace github.com/blacktop/go-dwarf => ../../../ThirdParty/GoMachO/go-dwarf
