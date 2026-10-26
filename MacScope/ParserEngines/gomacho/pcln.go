// Adapted from reviewed I3 drafts; kept behind the existing worker ABI.
package main

import (
	"bytes"
	"debug/buildinfo"
	"debug/gosym"
	"encoding/binary"
	"time"
)

const pclnSchema = "macscope.pcln.v1"

type goFunction struct {
	Entry uint64 `json:"entry"`
	End   uint64 `json:"end"`
	Name  string `json:"name"`
	File  string `json:"file,omitempty"`
	Line  int    `json:"line,omitempty"`
}
type pclnDocument struct {
	TextBaseProvenance string       `json:"text_base_provenance,omitempty"`
	GoVersion          string       `json:"go_version,omitempty"`
	Schema             string       `json:"schema"`
	Format             string       `json:"format"`
	TextBase           uint64       `json:"text_base"`
	Functions          []goFunction `json:"functions"`
}
type pclnHeader struct {
	zeroHeader                                       bool
	goVersion                                        string
	nameEnd, cuBase, fileBase, fileEnd, pcEnd, files uint64
	format                                           string
	count, ftab, field, funcBase, nameBase, pcBase   uint64
	modern                                           bool
}

func pclnJSON(data []byte) []byte {
	return guardedJSON(pclnSchema, func() (any, error) { return pclnInventory(data) })
}
func pclnInventory(data []byte) (any, error) {
	sections, err := thinSections(data)
	if err != nil {
		return nil, err
	}
	var text, pcln *rawSection
	for i := range sections {
		s := &sections[i]
		if s.name == "__text" {
			if text != nil {
				return nil, reject("malformed", "duplicate __text")
			}
			text = s
		}
		if s.name == "__gopclntab" {
			if pcln != nil {
				return nil, reject("malformed", "duplicate __gopclntab")
			}
			pcln = s
		}
	}
	if text == nil || pcln == nil {
		return nil, reject("missing_section", "requires __text and __gopclntab")
	}
	if text.segment != "__TEXT" || text.size == 0 || pcln.size == 0 {
		return nil, reject("malformed", "invalid code or pcln section")
	}
	if uint64(pcln.offset) > uint64(len(data)) || pcln.size > uint64(len(data))-uint64(pcln.offset) {
		return nil, reject("malformed", "pcln section outside file")
	}
	table := data[uint64(pcln.offset) : uint64(pcln.offset)+pcln.size]
	version := ""
	if len(table) >= 32 && binary.LittleEndian.Uint32(table) == 0xfffffff1 && binary.LittleEndian.Uint64(table[24:32]) == 0 {
		// The magic is shared with older Go versions. Require embedded build-info
		// authority, never infer the linker version from magic or zero alone.
		info, e := buildinfo.Read(bytes.NewReader(data))
		if e == nil {
			version = info.GoVersion
		}
	}
	return parsePCLN(table, text.addr, text.addr+text.size, time.Now().Add(inventoryDeadline), version)
}

func validatePCLN(data []byte, start, end uint64, authority ...string) (pclnHeader, error) {
	h := pclnHeader{}
	if len(data) > inventorySectionLimit {
		return h, reject("input_limit", "pcln exceeds 16 MiB")
	}
	if len(data) < 16 {
		return h, reject("malformed", "truncated pcln header")
	}
	if data[4] != 0 || data[5] != 0 || (data[6] != 1 && data[6] != 2 && data[6] != 4) || data[7] != 8 {
		return h, reject("unsupported", "requires 64-bit little-endian Go pcln profile")
	}
	if start == 0 || end <= start {
		return h, reject("malformed", "invalid text range")
	}
	bo := binary.LittleEndian
	h.count = bo.Uint64(data[8:16])
	h.field = 8
	if h.count == 0 {
		return h, reject("malformed", "empty function table")
	}
	if h.count > inventoryRecordLimit {
		return h, reject("record_limit", "pcln exceeds 50000 functions")
	}
	magic := bo.Uint32(data[:4])
	switch magic {
	case 0xfffffffb:
		h.format = "go12"
		h.ftab = 16
	case 0xfffffffa:
		h.format = "go116"
	case 0xfffffff0:
		h.format = "go118"
		h.modern = true
		h.field = 4
	case 0xfffffff1:
		h.format = "go120"
		h.modern = true
		h.field = 4
	default:
		return h, reject("unsupported", "unknown pcln magic")
	}
	if h.format != "go12" {
		words := uint64(7)
		first := uint64(2)
		if h.modern {
			words = 8
			first = 3
		}
		min := 8 + 8*words
		if uint64(len(data)) < min {
			return h, reject("malformed", "truncated pcln header words")
		}
		word := func(i uint64) uint64 { return bo.Uint64(data[8+8*i : 16+8*i]) }
		if word(1) > inventoryRecordLimit {
			return h, reject("record_limit", "pcln exceeds 50000 files")
		}
		if h.modern && word(2) != start {
			// The audited Go1.27.1 and installed Go1.27.2 linkers explicitly leaves this historical
			// word unused/zero. No nonzero disagreement or older-version zero
			// is accepted, even though Go1.20+ shares the same table magic.
			if h.format == "go120" && word(2) == 0 && len(authority) == 1 && (authority[0] == "go1.27.1" || authority[0] == "go1.27.2") {
				h.zeroHeader = true
				h.goVersion = authority[0]
			} else {
				return h, reject("text_base_mismatch", "pcln header textStart differs from __text (no audited zero-header version authority)")
			}
		}
		previous := min
		for i := first; i < words; i++ {
			off := word(i)
			if off < previous || off >= uint64(len(data)) {
				return h, reject("malformed", "invalid pcln subtable offset")
			}
			previous = off
		}
		h.nameBase = word(first)
		h.nameEnd = word(first + 1)
		h.cuBase = word(first + 1)
		h.fileBase = word(first + 2)
		h.fileEnd = word(first + 3)
		h.files = word(1)
		h.pcBase = word(first + 3)
		h.ftab = word(words - 1)
		h.funcBase = h.ftab
		h.pcEnd = h.ftab
	}
	extent := (h.count*2 + 1) * h.field
	if h.ftab > uint64(len(data)) || extent > uint64(len(data))-h.ftab {
		return h, reject("malformed", "function table outside pcln")
	}
	field := func(off uint64) uint64 {
		if h.field == 4 {
			return uint64(bo.Uint32(data[off : off+4]))
		}
		return bo.Uint64(data[off : off+8])
	}
	if !h.modern && field(h.ftab) != start {
		return h, reject("text_base_mismatch", "first absolute function entry differs from __text")
	}
	if h.format == "go12" {
		tail := h.ftab + extent
		if tail+4 > uint64(len(data)) {
			return h, reject("malformed", "missing Go1.2 file table offset")
		}
		off := uint64(bo.Uint32(data[tail : tail+4]))
		if off+4 > uint64(len(data)) {
			return h, reject("malformed", "invalid Go1.2 file table")
		}
		files := uint64(bo.Uint32(data[off : off+4]))
		h.files = files
		h.fileBase = off
		h.fileEnd = off + 4*files
		h.nameEnd = uint64(len(data))
		h.pcEnd = uint64(len(data))
		if files > inventoryRecordLimit {
			return h, reject("record_limit", "file table exceeds 50000")
		}
		if files*4 > uint64(len(data))-off {
			return h, reject("malformed", "truncated file table")
		}
	}
	var previous uint64
	for i := uint64(0); i <= h.count; i++ {
		pc := field(h.ftab + 2*i*h.field)
		if h.modern {
			if pc > end-start {
				return h, reject("malformed", "function PC outside text")
			}
			pc += start
		}
		if pc < start || pc > end || (i > 0 && pc <= previous) {
			return h, reject("malformed", "unordered or out-of-text function interval")
		}
		previous = pc
		if i == h.count {
			break
		}
		off := field(h.ftab + (2*i+1)*h.field)
		if off > uint64(len(data))-h.funcBase {
			return h, reject("malformed", "function descriptor offset outside pcln")
		}
		off += h.funcBase
		first := uint64(8)
		if h.modern {
			first = 4
		}
		// Fields through cuOffset used by PCToLine must exist.
		if off > uint64(len(data)) || first+32 > uint64(len(data))-off {
			return h, reject("malformed", "truncated function descriptor")
		}
		descriptorPC := field(off)
		if h.modern {
			descriptorPC += start
		}
		if descriptorPC != pc {
			return h, reject("malformed", "function descriptor entry differs from function table")
		}
		name := uint64(bo.Uint32(data[off+first : off+first+4]))
		if name >= h.nameEnd-h.nameBase {
			return h, reject("malformed", "function name offset outside pcln")
		}
		name += h.nameBase
		limit := name + inventoryStringLimit + 1
		if limit > h.nameEnd {
			limit = h.nameEnd
		}
		found := false
		for p := name; p < limit; p++ {
			if data[p] == 0 {
				found = true
				break
			}
		}
		if !found {
			return h, reject("string_limit", "unterminated or oversized function name")
		}
	}
	return h, nil
}

func parsePCLN(data []byte, start, end uint64, deadline time.Time, authority ...string) (any, error) {
	if time.Now().After(deadline) {
		return nil, reject("deadline", "cooperative parse deadline exceeded")
	}
	h, err := validatePCLN(data, start, end, authority...)
	if err != nil {
		return nil, err
	}
	if time.Now().After(deadline) {
		return nil, reject("deadline", "cooperative parse deadline exceeded")
	}
	sources, err := validateSources(data, h, deadline)
	if err != nil {
		return nil, err
	}
	table, err := gosym.NewTable(nil, gosym.NewLineTable(data, start))
	if err != nil || table == nil || uint64(len(table.Funcs)) != h.count {
		return nil, reject("malformed", "debug/gosym rejected function table")
	}
	out := pclnDocument{Schema: pclnSchema, Format: h.format, TextBase: start, Functions: make([]goFunction, 0, len(table.Funcs))}
	if h.zeroHeader {
		out.TextBaseProvenance = "text-base from __text (header field zero)"
		out.GoVersion = h.goVersion
	}
	for index, f := range table.Funcs {
		if time.Now().After(deadline) {
			return nil, reject("deadline", "cooperative parse deadline exceeded")
		}
		if f.Sym == nil || f.Name == "" || f.Entry < start || f.End > end || f.End <= f.Entry {
			return nil, reject("malformed", "invalid function record")
		}
		if err := checkedString(f.Name); err != nil {
			return nil, err
		}
		row := goFunction{Entry: f.Entry, End: f.End, Name: f.Name}
		file, line := sources[index].file, sources[index].line
		if file != "" && line > 0 {
			gotFile, gotLine, _ := table.PCToLine(f.Entry)
			if gotFile != file || gotLine != line {
				return nil, reject("malformed", "gosym source mapping disagrees with validated entry mapping")
			}
			if err := checkedString(file); err != nil {
				return nil, err
			}
			row.File = file
			row.Line = line
		}
		out.Functions = append(out.Functions, row)
	}
	if time.Now().After(deadline) {
		return nil, reject("deadline", "cooperative parse deadline exceeded")
	}
	return out, nil
}
