package main

import (
	"encoding/binary"
	"encoding/json"
	"testing"
	"time"
)

func pclnEmptyMachO() []byte {
	b := make([]byte, 32)
	binary.LittleEndian.PutUint32(b, 0xfeedfacf)
	return b
}
func pclnErrorKind(t *testing.T, b []byte) string {
	t.Helper()
	var e errorEnvelope
	if err := json.Unmarshal(b, &e); err != nil {
		t.Fatal(err)
	}
	if e.Error == nil {
		t.Fatalf("expected refusal: %s", b)
	}
	return e.Error.Kind
}
func headerVector(magic uint32) []byte {
	b := make([]byte, 256)
	bo := binary.LittleEndian
	bo.PutUint32(b, magic)
	b[6] = 4
	b[7] = 8
	bo.PutUint64(b[8:], 1)
	if magic == 0xfffffffb {
		bo.PutUint64(b[16:], 0x1000)
		bo.PutUint64(b[24:], 80)
		bo.PutUint64(b[32:], 0x1010)
		bo.PutUint32(b[40:], 200)
		bo.PutUint32(b[200:], 1)
		bo.PutUint64(b[80:], 0x1000) // valid descriptor entry, independently agrees with ftab
		bo.PutUint32(b[88:], 160)
		copy(b[160:], "main.known\x00")
		return b
	}
	modern := magic != 0xfffffffa
	first, words, ft := 2, 7, 128
	if modern {
		first = 3
		words = 8
		bo.PutUint64(b[24:], 0x1000)
	}
	offsets := []uint64{80, 96, 104, 112, uint64(ft)}
	for i := first; i < words; i++ {
		bo.PutUint64(b[8+i*8:], offsets[i-first])
	}
	copy(b[80:], "main.known\x00")
	if modern {
		bo.PutUint32(b[ft:], 0)
		bo.PutUint32(b[ft+4:], 32)
		bo.PutUint32(b[ft+8:], 16)
		bo.PutUint32(b[160:], 0)
		bo.PutUint32(b[164:], 0)
	} else {
		bo.PutUint64(b[ft:], 0x1000)
		bo.PutUint64(b[ft+8:], 32)
		bo.PutUint64(b[ft+16:], 0x1010)
		bo.PutUint64(b[160:], 0x1000)
		bo.PutUint32(b[168:], 0)
	}
	return b
}
func TestPCLNHeaderFormats(t *testing.T) {
	for _, c := range []struct {
		magic  uint32
		format string
	}{{0xfffffffb, "go12"}, {0xfffffffa, "go116"}, {0xfffffff0, "go118"}, {0xfffffff1, "go120"}} {
		t.Run(c.format, func(t *testing.T) {
			h, e := validatePCLN(headerVector(c.magic), 0x1000, 0x1010)
			if e != nil || h.format != c.format || h.count != 1 {
				t.Fatalf("got %+v %v", h, e)
			}
		})
	}
}
func TestPCLNRefusals(t *testing.T) {
	cases := []struct {
		name   string
		mutate func([]byte) []byte
		kind   string
	}{
		{"short", func(b []byte) []byte { return b[:10] }, "malformed"},
		{"magic", func(b []byte) []byte { b[0] = 0; return b }, "unsupported"},
		{"ptr", func(b []byte) []byte { b[7] = 4; return b }, "unsupported"},
		{"base", func(b []byte) []byte { binary.LittleEndian.PutUint64(b[24:], 0x1004); return b }, "text_base_mismatch"},
		{"count", func(b []byte) []byte { binary.LittleEndian.PutUint64(b[8:], inventoryRecordLimit+1); return b }, "record_limit"},
		{"offset", func(b []byte) []byte { binary.LittleEndian.PutUint64(b[64:], 999); return b }, "malformed"},
		{"interval", func(b []byte) []byte { binary.LittleEndian.PutUint32(b[136:], 0); return b }, "malformed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, e := validatePCLN(c.mutate(headerVector(0xfffffff1)), 0x1000, 0x1010)
			if e == nil || e.(*refusal).Kind != c.kind {
				t.Fatalf("got %v want %s", e, c.kind)
			}
		})
	}
}
func TestPCLNDeadline(t *testing.T) {
	_, e := parsePCLN(headerVector(0xfffffff1), 0x1000, 0x1010, time.Now().Add(-time.Second))
	if e == nil || e.(*refusal).Kind != "deadline" {
		t.Fatal(e)
	}
}
func TestPCLNMissingSection(t *testing.T) {
	if got := pclnErrorKind(t, pclnJSON(pclnEmptyMachO())); got != "missing_section" {
		t.Fatal(got)
	}
}
func TestPCLNPanicBoundary(t *testing.T) {
	b := guardedJSON(pclnSchema, func() (any, error) { panic("test") })
	if got := pclnErrorKind(t, b); got != "panic" {
		t.Fatal(got)
	}
}
func TestPCLNDescriptorEntryMismatch(t *testing.T) {
	b := headerVector(0xfffffff1)
	binary.LittleEndian.PutUint32(b[160:], 4)
	if _, e := validatePCLN(b, 0x1000, 0x1010); e == nil || e.(*refusal).Kind != "malformed" {
		t.Fatalf("got %v", e)
	}
}
func TestPCLNSourceOffsetRefusal(t *testing.T) {
	b := headerVector(0xfffffff1)
	binary.LittleEndian.PutUint32(b[180:], 999)
	h, e := validatePCLN(b, 0x1000, 0x1010)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = validateSources(b, h, time.Now().Add(time.Second)); e == nil || e.(*refusal).Kind != "malformed" {
		t.Fatalf("got %v", e)
	}
}

func TestPCLNZeroHeaderAuthority(t *testing.T) {
	for _, c := range []struct {
		name, version string
		magic         uint32
		base          uint64
		accept        bool
	}{
		{"audited-go1271", "go1.27.1", 0xfffffff1, 0, true},
		{"audited-go1272", "go1.27.2", 0xfffffff1, 0, true},
		{"nonzero-mismatch-go1271", "go1.27.1", 0xfffffff1, 0x1004, false},
		{"older-same-magic", "go1.23.2", 0xfffffff1, 0, false},
		{"older-format", "go1.27.1", 0xfffffff0, 0, false},
		{"unknown-build-version", "", 0xfffffff1, 0, false},
		{"unaudited-future", "go1.28.0", 0xfffffff1, 0, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			b := headerVector(c.magic)
			binary.LittleEndian.PutUint64(b[24:], c.base)
			h, e := validatePCLN(b, 0x1000, 0x1010, c.version)
			if c.accept {
				if e != nil || !h.zeroHeader || h.goVersion != c.version {
					t.Fatalf("got %+v %v", h, e)
				}
			} else if e == nil || e.(*refusal).Kind != "text_base_mismatch" {
				t.Fatalf("got %+v %v", h, e)
			}
		})
	}
}
func TestPCLNZeroHeaderProvenance(t *testing.T) {
	b := headerVector(0xfffffff1)
	binary.LittleEndian.PutUint64(b[24:], 0)
	v, e := parsePCLN(b, 0x1000, 0x1010, time.Now().Add(time.Second), "go1.27.1")
	if e != nil {
		t.Fatal(e)
	}
	d := v.(pclnDocument)
	if d.TextBaseProvenance != "text-base from __text (header field zero)" || d.GoVersion != "go1.27.1" || len(d.Functions) != 1 || d.Functions[0].Name != "main.known" {
		t.Fatalf("got %+v", d)
	}
}
