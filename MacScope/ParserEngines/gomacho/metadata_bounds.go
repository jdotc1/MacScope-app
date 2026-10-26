// Adapted from reviewed I3 drafts; shared bounded metadata readers.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	inventoryInputLimit   = 64 << 20
	inventoryOutputLimit  = 16 << 20
	inventorySectionLimit = 16 << 20
	inventoryRecordLimit  = 50000
	inventoryStringLimit  = 4096
	inventoryDeadline     = 2 * time.Second
	metadataSchema        = "macscope.metadata.v1"
)

type refusal struct {
	Kind   string `json:"kind"`
	Detail string `json:"detail"`
}

func (r *refusal) Error() string       { return r.Kind + ": " + r.Detail }
func reject(kind, detail string) error { return &refusal{kind, detail} }

type errorEnvelope struct {
	Schema string   `json:"schema"`
	Error  *refusal `json:"error"`
}

func errorJSON(schema string, err error) []byte {
	r := &refusal{"malformed", "metadata reader rejected input"}
	if err != nil && len(err.Error()) <= inventoryStringLimit {
		r.Detail = err.Error()
	}
	var typed *refusal
	if errors.As(err, &typed) {
		r = typed
	}
	b, _ := json.Marshal(errorEnvelope{schema, r})
	return b
}

// A deadline is cooperative, not a substitute for the host worker watchdog.
func guardedJSON(schema string, f func() (any, error)) (out []byte) {
	defer func() {
		if recover() != nil {
			out = errorJSON(schema, reject("panic", "metadata reader panicked"))
		}
	}()
	value, err := f()
	if err != nil {
		return errorJSON(schema, err)
	}
	// Conservatively charge every possible JSON escape before encoding, so
	// the encoder cannot allocate an arbitrarily larger transient document.
	remaining := int64(inventoryOutputLimit)
	if !chargeJSON(reflect.ValueOf(value), &remaining, 0) {
		return errorJSON(schema, reject("output_limit", "conservative encoded-size budget exceeds 16 MiB"))
	}
	out, err = json.Marshal(value)
	if err != nil {
		return errorJSON(schema, reject("encoding", "JSON encoding failed"))
	}
	if len(out) > inventoryOutputLimit {
		return errorJSON(schema, reject("output_limit", "JSON exceeds 16 MiB"))
	}
	return out
}
func chargeJSON(v reflect.Value, left *int64, depth int) bool {
	if depth > 32 {
		return false
	}
	charge := func(n int64) bool { *left -= n; return *left >= 0 }
	if !v.IsValid() {
		return charge(4)
	}
	switch v.Kind() {
	case reflect.Interface, reflect.Pointer:
		if v.IsNil() {
			return charge(4)
		}
		return chargeJSON(v.Elem(), left, depth+1)
	case reflect.String:
		return chargeJSONString(v.String(), left)
	case reflect.Bool:
		return charge(5)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return charge(21)
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return charge(20)
	case reflect.Slice, reflect.Array:
		if !charge(2) {
			return false
		}
		for i := 0; i < v.Len(); i++ {
			if !charge(1) || !chargeJSON(v.Index(i), left, depth+1) {
				return false
			}
		}
		return true
	case reflect.Map:
		if !charge(2) {
			return false
		}
		for _, key := range v.MapKeys() {
			if !charge(2) || !chargeJSON(key, left, depth+1) || !chargeJSON(v.MapIndex(key), left, depth+1) {
				return false
			}
		}
		return true
	case reflect.Struct:
		if !charge(2) {
			return false
		}
		t := v.Type()
		for i := 0; i < v.NumField(); i++ {
			field := t.Field(i)
			if field.PkgPath != "" {
				continue
			}
			tag := strings.Split(field.Tag.Get("json"), ",")[0]
			if tag == "-" {
				continue
			}
			if tag == "" {
				tag = field.Name
			}
			if !charge(2) || !chargeJSONString(tag, left) || !chargeJSON(v.Field(i), left, depth+1) {
				return false
			}
		}
		return true
	default:
		return false
	}
}

// Go1.27 encodes replacement runes literally; older encoding/json escaped
// them. Learn this single fixed encoding from the linked standard library,
// rather than guess from a runtime version or change a test expectation.
var jsonReplacementWidth = func() int64 { b, _ := json.Marshal(string([]byte{0xff})); return int64(len(b) - 2) }()

// Charge the exact string escaping used by encoding/json (including HTML
// escaping), without allocating a temporary encoded string.
func chargeJSONString(s string, left *int64) bool {
	*left -= 2
	for len(s) > 0 {
		r, width := utf8.DecodeRuneInString(s)
		s = s[width:]
		n := int64(width)
		switch r {
		case '"', '\\', '\b', '\f', '\n', '\r', '\t':
			n = 2
		case '<', '>', '&', '\u2028', '\u2029':
			n = 6
		default:
			if r < 32 {
				n = 6
			} else if r == utf8.RuneError && width == 1 {
				n = jsonReplacementWidth
			}
		}
		*left -= n
		if *left < 0 {
			return false
		}
	}
	return *left >= 0
}

func checkedString(s string) error {
	if len(s) > inventoryStringLimit {
		return reject("string_limit", "name or path exceeds 4096 bytes")
	}
	if !utf8.ValidString(s) {
		return reject("malformed", "name or path is not UTF-8")
	}
	return nil
}
func nullable(s string) *string {
	if s == "" || s == "<ROOT>" || s == "<META>" || s == "<stripped>" {
		return nil
	}
	return &s
}

func nullableAddress(address uint64) *uint64 {
	if address == 0 {
		return nil
	}
	return &address
}

type budgetReader struct {
	data     *bytes.Reader
	deadline time.Time
	reads    int
	bytes    int64
}

func (r *budgetReader) ReadAt(p []byte, off int64) (int, error) {
	if time.Now().After(r.deadline) {
		return 0, reject("deadline", "cooperative parse deadline exceeded")
	}
	r.reads++
	r.bytes += int64(len(p))
	if r.reads > 2000000 || r.bytes > 512<<20 {
		return 0, reject("read_limit", "metadata read budget exceeded")
	}
	return r.data.ReadAt(p, off)
}

type rawSection struct {
	segment, name string
	addr, size    uint64
	offset        uint32
}

// Validate allocation-bearing load-command and section extents before go-macho.
func thinSections(data []byte) ([]rawSection, error) {
	if len(data) == 0 {
		return nil, reject("invalid_input", "empty input")
	}
	if len(data) > inventoryInputLimit {
		return nil, reject("input_limit", "input exceeds 64 MiB")
	}
	if len(data) < 32 {
		return nil, reject("malformed", "truncated Mach-O header")
	}
	bo := binary.LittleEndian
	if bo.Uint32(data) != 0xfeedfacf {
		return nil, reject("unsupported", "requires little-endian thin 64-bit Mach-O")
	}
	n, size := uint64(bo.Uint32(data[16:20])), uint64(bo.Uint32(data[20:24]))
	if size > uint64(len(data)-32) || n > 4096 || n > size/8 {
		return nil, reject("malformed", "invalid load-command extent")
	}
	p, end := uint64(32), uint64(32)+size
	sections := []rawSection{}
	for i := uint64(0); i < n; i++ {
		if p+8 > end {
			return nil, reject("malformed", "truncated load command")
		}
		cmd, sz := bo.Uint32(data[p:p+4]), uint64(bo.Uint32(data[p+4:p+8]))
		if sz < 8 || sz > end-p {
			return nil, reject("malformed", "invalid load-command size")
		}
		if err := preflightCommand(data, data[p:p+sz], cmd); err != nil {
			return nil, err
		}
		if cmd == 0x19 {
			if sz < 72 {
				return nil, reject("malformed", "truncated segment")
			}
			ns := uint64(bo.Uint32(data[p+64 : p+68]))
			if ns > (sz-72)/80 || len(sections)+int(ns) > 4096 {
				return nil, reject("malformed", "invalid section count")
			}
			for j := uint64(0); j < ns; j++ {
				s := data[p+72+j*80 : p+72+(j+1)*80]
				row := rawSection{string(bytes.TrimRight(s[16:32], "\x00")), string(bytes.TrimRight(s[0:16], "\x00")), bo.Uint64(s[32:40]), bo.Uint64(s[40:48]), bo.Uint32(s[48:52])}
				typ := bo.Uint32(s[64:68]) & 0xff
				relocOff, relocCount := uint64(bo.Uint32(s[56:60])), uint64(bo.Uint32(s[60:64]))
				if relocCount > inventoryRecordLimit || !fileExtent(data, relocOff, relocCount*8) {
					return nil, reject("malformed", "section relocation extent exceeds bound")
				}
				if row.addr+row.size < row.addr {
					return nil, reject("malformed", "section address overflow")
				}
				if typ != 1 && typ != 0xc && typ != 0x12 {
					if uint64(row.offset) > uint64(len(data)) || row.size > uint64(len(data))-uint64(row.offset) {
						return nil, reject("malformed", "section outside file")
					}
					// Text may exceed the metadata limit; it is not copied by the projection.
					if row.name != "__text" && row.size > inventorySectionLimit {
						return nil, reject("input_limit", "section exceeds 16 MiB")
					}
				}
				sections = append(sections, row)
			}
		}
		p += sz
	}
	if p != end {
		return nil, reject("malformed", "load-command size sum mismatch")
	}
	return sections, nil
}
