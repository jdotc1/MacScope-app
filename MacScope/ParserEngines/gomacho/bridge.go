// Package main is MacScope's go-macho engine bridge (RX-03), built with
// `go build -buildmode=c-archive` into a static library linked by the
// analysis worker. It parses in-memory bytes only and returns the same raw
// Mach-O fact schema as the LIEF adapter. Any panic inside go-macho is
// recovered and reported as a rejected parse; it can never cross into Swift.
package main

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static char *macscope_copy_json(const void *bytes, size_t length) {
 char *out = (char *)malloc(length + 1);
 if (!out) return NULL;
 memcpy(out, bytes, length); out[length] = 0; return out;
}
*/
import "C"

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"time"
	"unsafe"

	"github.com/blacktop/go-macho"
	"github.com/blacktop/go-macho/types"
)

const maximumInputBytes = 1<<31 - 1 // C.GoBytes takes a C int

type sectionFacts struct {
	Name    string `json:"name"`
	Segment string `json:"segment"`
	Addr    uint64 `json:"addr"`
	Size    uint64 `json:"size"`
	Offset  uint64 `json:"offset"`
}

type segmentFacts struct {
	Name     string         `json:"name"`
	Vmaddr   uint64         `json:"vmaddr"`
	Vmsize   uint64         `json:"vmsize"`
	Fileoff  uint64         `json:"fileoff"`
	Filesize uint64         `json:"filesize"`
	Maxprot  uint32         `json:"maxprot"`
	Initprot uint32         `json:"initprot"`
	Sections []sectionFacts `json:"sections"`
}

type buildFacts struct {
	Platform uint32    `json:"platform"`
	Minos    [3]uint32 `json:"minos"`
	Sdk      [3]uint32 `json:"sdk"`
}

type sliceFacts struct {
	Cputype      uint32         `json:"cputype"`
	Cpusubtype   uint32         `json:"cpusubtype"`
	Filetype     uint32         `json:"filetype"`
	Ncmds        uint32         `json:"ncmds"`
	Sizeofcmds   uint32         `json:"sizeofcmds"`
	Flags        uint32         `json:"flags"`
	FatOffset    uint64         `json:"fat_offset"`
	Commands     []uint32       `json:"commands"`
	Segments     []segmentFacts `json:"segments"`
	UUID         *string        `json:"uuid"`
	Dylibs       []string       `json:"dylibs"`
	IDDylib      *string        `json:"id_dylib"`
	EntryOffset  *uint64        `json:"entry_offset"`
	BuildVersion *buildFacts    `json:"build_version"`
}

type document struct {
	Status string       `json:"status"`
	Error  string       `json:"error,omitempty"`
	Slices []sliceFacts `json:"slices,omitempty"`
}

func version(v types.Version) [3]uint32 {
	raw := uint32(v)
	return [3]uint32{raw >> 16, (raw >> 8) & 0xff, raw & 0xff}
}

func slice(f *macho.File, fatOffset uint64) sliceFacts {
	facts := sliceFacts{
		Cputype:    uint32(f.FileHeader.CPU),
		Cpusubtype: uint32(f.FileHeader.SubCPU),
		Filetype:   uint32(f.FileHeader.Type),
		Ncmds:      f.FileHeader.NCommands,
		Sizeofcmds: f.FileHeader.SizeCommands,
		Flags:      uint32(f.FileHeader.Flags),
		FatOffset:  fatOffset,
		Commands:   []uint32{},
		Segments:   []segmentFacts{},
		Dylibs:     []string{},
	}
	for _, load := range f.Loads {
		facts.Commands = append(facts.Commands, uint32(load.Command()))
		switch value := load.(type) {
		case *macho.Segment:
			segment := segmentFacts{
				Name: value.Name, Vmaddr: value.Addr, Vmsize: value.Memsz, Fileoff: value.Offset,
				Filesize: value.Filesz, Maxprot: uint32(value.Maxprot), Initprot: uint32(value.Prot),
				Sections: []sectionFacts{},
			}
			for _, section := range f.Sections {
				if section.Seg == value.Name {
					segment.Sections = append(segment.Sections, sectionFacts{
						Name: section.Name, Segment: section.Seg, Addr: section.Addr, Size: section.Size,
						Offset: uint64(section.Offset),
					})
				}
			}
			facts.Segments = append(facts.Segments, segment)
		case *macho.UUID:
			text := hex.EncodeToString(value.UUID[:])
			facts.UUID = &text
		case *macho.IDDylib:
			name := value.Name
			facts.IDDylib = &name
		case *macho.LoadDylib:
			facts.Dylibs = append(facts.Dylibs, value.Name)
		case *macho.WeakDylib:
			facts.Dylibs = append(facts.Dylibs, value.Name)
		case *macho.ReExportDylib:
			facts.Dylibs = append(facts.Dylibs, value.Name)
		case *macho.EntryPoint:
			offset := value.EntryOffset
			facts.EntryOffset = &offset
		case *macho.BuildVersion:
			if facts.BuildVersion == nil {
				facts.BuildVersion = &buildFacts{Platform: uint32(value.Platform), Minos: version(value.Minos), Sdk: version(value.Sdk)}
			}
		}
	}
	return facts
}

func parse(data []byte) (result document) {
	defer func() {
		if recovered := recover(); recovered != nil {
			result = document{Status: "rejected", Error: "go-macho panicked"}
		}
	}()
	if len(data) >= 4 && binary.BigEndian.Uint32(data) == 0xcafebabe {
		fat, err := macho.NewFatFile(bytes.NewReader(data))
		if err != nil {
			return document{Status: "rejected", Error: err.Error()}
		}
		result = document{Status: "parsed"}
		for _, arch := range fat.Arches {
			result.Slices = append(result.Slices, slice(arch.File, uint64(arch.Offset)))
		}
		return result
	}
	f, err := macho.NewFile(bytes.NewReader(data))
	if err != nil {
		return document{Status: "rejected", Error: err.Error()}
	}
	return document{Status: "parsed", Slices: []sliceFacts{slice(f, 0)}}
}

//export macscope_gomacho_macho_facts
func macscope_gomacho_macho_facts(input *C.uint8_t, length C.size_t) *C.char {
	var result document
	if input == nil || length == 0 || uint64(length) > maximumInputBytes {
		result = document{Status: "rejected", Error: "input is empty or exceeds the bound"}
	} else {
		result = parse(C.GoBytes(unsafe.Pointer(input), C.int(length)))
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		encoded = []byte(fmt.Sprintf(`{"status":"rejected","error":%q}`, "encoding failed"))
	}
	return C.CString(string(encoded))
}

// Type inventory is a developer oracle only. Run it in the bounded parser-dump
// subprocess; it is deliberately not called during ordinary image analysis.
const maximumInventoryInput = 64 * 1024 * 1024
const maximumInventoryRows = 16384
const maximumInventoryJSON = 8 * 1024 * 1024

type inventoryRow struct {
	Name        string `json:"name"`
	Address     uint64 `json:"address,omitempty"`
	Kind        string `json:"kind,omitempty"`
	Superclass  string `json:"superclass,omitempty"`
	Class       string `json:"class,omitempty"`
	Protocol    string `json:"protocol,omitempty"`
	TypeAddress uint64 `json:"typeAddress,omitempty"`
}
type inventoryDocument struct {
	Status      string                    `json:"status"`
	Error       string                    `json:"error,omitempty"`
	Inventories map[string][]inventoryRow `json:"inventories,omitempty"`
	Errors      map[string]string         `json:"errors,omitempty"`
}

func typeInventory(data []byte) (out inventoryDocument) {
	defer func() {
		if recover() != nil {
			out = inventoryDocument{Status: "rejected", Error: "go-macho metadata panic"}
		}
	}()
	if len(data) == 0 || len(data) > maximumInventoryInput {
		return inventoryDocument{Status: "rejected", Error: "input budget"}
	}
	sections, err := thinSections(data)
	if err != nil {
		return inventoryDocument{Status: "rejected", Error: err.Error()}
	}
	count := uint64(0)
	for _, section := range sections {
		width := uint64(0)
		switch section.name {
		case "__objc_classlist", "__objc_catlist", "__objc_protolist":
			width = 8
		case "__swift5_types", "__swift5_types2", "__swift5_protos", "__swift5_proto":
			width = 4
		}
		if width != 0 {
			if section.size%width != 0 {
				return inventoryDocument{Status: "rejected", Error: "metadata list alignment"}
			}
			count += section.size / width
			if count > maximumInventoryRows {
				return inventoryDocument{Status: "rejected", Error: "metadata row budget"}
			}
		}
	}
	reader := &budgetReader{data: bytes.NewReader(data), deadline: time.Now().Add(inventoryDeadline)}
	f, err := macho.NewFile(reader, macho.FileConfig{LoadIncluding: []types.LoadCmd{
		types.LC_SEGMENT_64, types.LC_SYMTAB, types.LC_DYSYMTAB,
		types.LC_DYLD_INFO, types.LC_DYLD_INFO_ONLY, types.LC_DYLD_CHAINED_FIXUPS, types.LC_DYLD_EXPORTS_TRIE,
		types.LC_ID_DYLIB, types.LC_LOAD_DYLIB, types.LC_LOAD_WEAK_DYLIB,
		types.LC_REEXPORT_DYLIB, types.LC_LAZY_LOAD_DYLIB, types.LC_LOAD_UPWARD_DYLIB,
	}})
	if err != nil {
		return inventoryDocument{Status: "rejected", Error: err.Error()}
	}
	defer f.Close()
	// Bound declared backing ranges before the upstream readers allocate sections.
	for _, s := range f.Sections {
		if s.Size > maximumInventoryInput {
			return inventoryDocument{Status: "rejected", Error: "section budget"}
		}
		if (s.Name == "__objc_classlist" || s.Name == "__objc_catlist" || s.Name == "__objc_protolist" || s.Name == "__swift5_types" || s.Name == "__swift5_types2" || s.Name == "__swift5_protos" || s.Name == "__swift5_proto") && s.Size > maximumInventoryRows*4 {
			return inventoryDocument{Status: "rejected", Error: "metadata row budget"}
		}
	}
	out = inventoryDocument{Status: "parsed", Inventories: map[string][]inventoryRow{}, Errors: map[string]string{}}
	has := func(name string) bool {
		for _, s := range f.Sections {
			if s.Name == name {
				return true
			}
		}
		return false
	}
	// Each inventory has its own error: a reader limitation must not masquerade as
	// an empty successful inventory or erase independently readable metadata.
	collect := func(key string, read func() ([]inventoryRow, error)) {
		out.Inventories[key] = []inventoryRow{}
		defer func() {
			if recover() != nil {
				out.Errors[key] = "go-macho metadata panic"
				out.Status = "partial"
			}
		}()
		rows, e := read()
		if e != nil {
			out.Errors[key] = e.Error()
			out.Status = "partial"
			return
		}
		if len(rows) > maximumInventoryRows {
			out.Errors[key] = "row budget"
			out.Status = "partial"
			return
		}
		for i := range rows {
			r := &rows[i]
			for _, value := range []*string{&r.Name, &r.Superclass, &r.Class, &r.Protocol} {
				if nullable(*value) == nil {
					*value = ""
				}
				if err := checkedString(*value); err != nil {
					out.Errors[key] = err.Error()
					out.Status = "partial"
					return
				}
			}
		}
		for _, r := range rows {
			if len(r.Name)+len(r.Superclass)+len(r.Class)+len(r.Protocol) > 16384 {
				out.Errors[key] = "name budget"
				out.Status = "partial"
				return
			}
		}
		sort.Slice(rows, func(i, j int) bool {
			if rows[i].Address != rows[j].Address {
				return rows[i].Address < rows[j].Address
			}
			return rows[i].Name < rows[j].Name
		})
		out.Inventories[key] = append(out.Inventories[key], rows...)
	}
	collect("objcClasses", func() ([]inventoryRow, error) {
		if !has("__objc_classlist") {
			return nil, nil
		}
		values, e := f.GetObjCClasses()
		rows := []inventoryRow{}
		for _, v := range values {
			rows = append(rows, inventoryRow{Name: v.Name, Address: v.ClassPtr, Superclass: v.SuperClass})
		}
		return rows, e
	})
	collect("objcCategories", func() ([]inventoryRow, error) {
		if !has("__objc_catlist") {
			return nil, nil
		}
		values, e := f.GetObjCCategories()
		rows := []inventoryRow{}
		for _, v := range values {
			class := ""
			if v.Class != nil {
				class = v.Class.Name
			}
			rows = append(rows, inventoryRow{Name: v.Name, Address: v.VMAddr, Class: class})
		}
		return rows, e
	})
	collect("objcProtocols", func() ([]inventoryRow, error) {
		if !has("__objc_protolist") {
			return nil, nil
		}
		values, e := f.GetObjCProtocols()
		rows := []inventoryRow{}
		for _, v := range values {
			rows = append(rows, inventoryRow{Name: v.Name, Address: v.Ptr})
		}
		return rows, e
	})
	collect("swiftTypes", func() ([]inventoryRow, error) {
		if !has("__swift5_types") && !has("__swift5_types2") {
			return nil, nil
		}
		values, e := f.GetSwiftTypes()
		rows := []inventoryRow{}
		for _, v := range values {
			rows = append(rows, inventoryRow{Name: v.Name, Address: v.Address, Kind: v.Kind.String()})
		}
		return rows, e
	})
	collect("swiftProtocols", func() ([]inventoryRow, error) {
		if !has("__swift5_protos") {
			return nil, nil
		}
		values, e := f.GetSwiftProtocols()
		rows := []inventoryRow{}
		for _, v := range values {
			rows = append(rows, inventoryRow{Name: v.Name, Address: v.Address})
		}
		return rows, e
	})
	collect("swiftConformances", func() ([]inventoryRow, error) {
		if !has("__swift5_proto") {
			return nil, nil
		}
		values, e := f.GetSwiftProtocolConformances()
		rows := []inventoryRow{}
		for _, v := range values {
			r := inventoryRow{Address: v.Address, Protocol: v.Protocol}
			if v.TypeRef != nil {
				r.Name = v.TypeRef.Name
				r.TypeAddress = v.TypeRef.Address
			}
			rows = append(rows, r)
		}
		return rows, e
	})
	return out
}

// copyJSON uses fallible C allocation. Ownership remains with the existing C free API.
func copyJSON(encoded []byte) *C.char {
	if len(encoded) == 0 {
		return nil
	}
	return C.macscope_copy_json(unsafe.Pointer(&encoded[0]), C.size_t(len(encoded)))
}

func boundedInventoryJSON(value any, limit int64) []byte {
	if !chargeJSON(reflect.ValueOf(value), &limit, 0) {
		return []byte(`{"status":"rejected","reason":"output-budget","error":"output budget"}`)
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return []byte(`{"status":"rejected","reason":"encoding","error":"encoding"}`)
	}
	return encoded
}

//export macscope_gomacho_type_inventory
func macscope_gomacho_type_inventory(input *C.uint8_t, length C.size_t) (result *C.char) {
	defer func() {
		if recover() != nil {
			result = copyJSON([]byte(`{"status":"rejected","error":"boundary panic"}`))
		}
	}()
	if input == nil || length == 0 || uint64(length) > maximumInventoryInput {
		return copyJSON([]byte(`{"status":"rejected","error":"input budget"}`))
	}
	return copyJSON(boundedInventoryJSON(typeInventory(C.GoBytes(unsafe.Pointer(input), C.int(length))), maximumInventoryJSON))
}

type Function struct {
	Name       string `json:"name"`
	Start      uint64 `json:"start"`
	End        uint64 `json:"end"`
	SourceFile string `json:"sourceFile,omitempty"`
	Line       int    `json:"line,omitempty"`
}
type goDocument struct {
	Status             string     `json:"status"`
	Reason             string     `json:"reason,omitempty"`
	TextBaseProvenance string     `json:"textBaseProvenance,omitempty"`
	GoVersion          string     `json:"goVersion,omitempty"`
	Functions          []Function `json:"functions,omitempty"`
}

func goFunctions(data []byte) (out goDocument) {
	defer func() {
		if recover() != nil {
			out = goDocument{Status: "rejected", Reason: "malformed"}
		}
	}()
	value, err := pclnInventory(data)
	if err != nil {
		reason := "malformed"
		if r, ok := err.(*refusal); ok {
			reason = r.Kind
		}
		return goDocument{Status: "rejected", Reason: reason}
	}
	parsed := value.(pclnDocument)
	out = goDocument{Status: "parsed", GoVersion: parsed.GoVersion, TextBaseProvenance: parsed.TextBaseProvenance,
		Functions: make([]Function, 0, len(parsed.Functions))}
	for _, f := range parsed.Functions {
		out.Functions = append(out.Functions, Function{Name: f.Name, Start: f.Entry, End: f.End, SourceFile: f.File, Line: f.Line})
	}
	return out
}

//export macscope_gomacho_go_functions
func macscope_gomacho_go_functions(input *C.uint8_t, length C.size_t) (result *C.char) {
	defer func() {
		if recover() != nil {
			result = copyJSON([]byte(`{"status":"rejected","reason":"boundary-panic"}`))
		}
	}()
	if input == nil || length == 0 || uint64(length) > maximumInventoryInput {
		return copyJSON([]byte(`{"status":"rejected","reason":"input-budget"}`))
	}
	return copyJSON(boundedInventoryJSON(goFunctions(C.GoBytes(unsafe.Pointer(input), C.int(length))), inventoryOutputLimit))
}

func main() {}
