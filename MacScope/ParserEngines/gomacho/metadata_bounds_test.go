package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

// Small authored byte records exercise admission before any vendor metadata read.
func boundsMachO(name string, size int) []byte {
	b := make([]byte, 32+72+80+size)
	bo := binary.LittleEndian
	bo.PutUint32(b, 0xfeedfacf)
	bo.PutUint32(b[4:], 0x100000c)
	bo.PutUint32(b[12:], 2)
	bo.PutUint32(b[16:], 1)
	bo.PutUint32(b[20:], 152)
	bo.PutUint32(b[32:], 0x19)
	bo.PutUint32(b[36:], 152)
	copy(b[40:], "__TEXT")
	bo.PutUint32(b[96:], 1)
	s := b[104:184]
	copy(s, name)
	copy(s[16:], "__TEXT")
	bo.PutUint64(s[32:], 0x100000000)
	bo.PutUint64(s[40:], uint64(size))
	bo.PutUint32(s[48:], 184)
	return b
}

func boundsErrorKind(t *testing.T, err error, want string) {
	t.Helper()
	var refusal *refusal
	if !errors.As(err, &refusal) || refusal.Kind != want {
		t.Fatalf("got error %v, want refusal %s", err, want)
	}
}

func TestMetadataThinSectionBounds(t *testing.T) {
	valid := boundsMachO("__swift5_types", 4)
	rows, err := thinSections(valid)
	if err != nil || len(rows) != 1 || rows[0].offset != 184 || rows[0].size != 4 {
		t.Fatalf("valid section: rows=%v error=%v", rows, err)
	}
	for _, tc := range []struct {
		name   string
		mutate func([]byte)
	}{
		{"command-extent", func(b []byte) { binary.LittleEndian.PutUint32(b[20:], uint32(len(b))) }},
		{"section-file-extent", func(b []byte) { binary.LittleEndian.PutUint32(b[152:], uint32(len(b))) }},
		{"section-address-overflow", func(b []byte) { binary.LittleEndian.PutUint64(b[136:], ^uint64(0)) }},
		{"relocation-extent", func(b []byte) {
			binary.LittleEndian.PutUint32(b[160:], uint32(len(b)))
			binary.LittleEndian.PutUint32(b[164:], 1)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b := append([]byte(nil), valid...)
			tc.mutate(b)
			_, err := thinSections(b)
			boundsErrorKind(t, err, "malformed")
		})
	}
}

func TestMetadataCommandPayloadBounds(t *testing.T) {
	for _, tc := range []struct {
		name     string
		kind     uint32
		size     int
		offsetAt int
	}{
		{"symbols", 2, 24, 8},
		{"indirect-symbols", 0xb, 80, 56},
		{"dyld-binding", 0x80000022, 48, 8},
		{"chained-fixups", 0x80000034, 16, 8},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := make([]byte, tc.size)
			binary.LittleEndian.PutUint32(cmd[tc.offsetAt:], 32)
			binary.LittleEndian.PutUint32(cmd[tc.offsetAt+4:], 1)
			boundsErrorKind(t, preflightCommand(make([]byte, 32), cmd, tc.kind), "malformed")
		})
	}
}

func TestMetadataRootListAdmission(t *testing.T) {
	for _, tc := range []struct {
		name    string
		section string
		size    int
		want    string
	}{
		{"objc-misaligned", "__objc_classlist", 7, "metadata list alignment"},
		{"swift-misaligned", "__swift5_types", 3, "metadata list alignment"},
		{"objc-count", "__objc_protolist", (maximumInventoryRows + 1) * 8, "metadata row budget"},
		{"swift-count", "__swift5_proto", (maximumInventoryRows + 1) * 4, "metadata row budget"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := typeInventory(boundsMachO(tc.section, tc.size))
			if got.Status != "rejected" || got.Error != tc.want || len(got.Inventories) != 0 {
				t.Fatalf("got %+v, want whole-document refusal %q", got, tc.want)
			}
		})
	}
}

func TestMetadataStringsAndMissingValues(t *testing.T) {
	if err := checkedString(strings.Repeat("x", inventoryStringLimit)); err != nil {
		t.Fatal(err)
	}
	boundsErrorKind(t, checkedString(strings.Repeat("x", inventoryStringLimit+1)), "string_limit")
	boundsErrorKind(t, checkedString(string([]byte{0xff})), "malformed")
	for _, s := range []string{"", "<ROOT>", "<META>", "<stripped>"} {
		if nullable(s) != nil {
			t.Fatalf("sentinel %q was retained as a name", s)
		}
	}
	if value := nullable("NSObject"); value == nil || *value != "NSObject" {
		t.Fatal("real name lost")
	}
	if nullableAddress(0) != nil {
		t.Fatal("unknown address must remain absent")
	}
	if value := nullableAddress(123); value == nil || *value != 123 {
		t.Fatal("known address lost")
	}
}

func TestMetadataReaderBudgets(t *testing.T) {
	for _, tc := range []struct {
		name    string
		reads   int
		count   int64
		expired bool
		want    string
	}{
		{"deadline", 0, 0, true, "deadline"},
		{"reads", 2000000, 0, false, "read_limit"},
		{"bytes", 0, 512 << 20, false, "read_limit"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			deadline := time.Now().Add(time.Hour)
			if tc.expired {
				deadline = time.Now().Add(-time.Hour)
			}
			r := budgetReader{data: bytes.NewReader([]byte{7}), deadline: deadline, reads: tc.reads, bytes: tc.count}
			n, err := r.ReadAt(make([]byte, 1), 0)
			if n != 0 {
				t.Fatalf("refused read returned %d bytes", n)
			}
			boundsErrorKind(t, err, tc.want)
		})
	}
	r := budgetReader{data: bytes.NewReader([]byte{7}), deadline: time.Now().Add(time.Hour)}
	b := make([]byte, 1)
	if n, err := r.ReadAt(b, 0); n != 1 || err != nil || b[0] != 7 {
		t.Fatalf("bounded valid read: %v %v %v", n, err, b)
	}
}

func TestMetadataJSONPrecharge(t *testing.T) {
	for _, s := range []string{"", "ordinary", "\"\\\b\f\n\r\t", "<>&\u2028\u2029\x01", "é🙂", string([]byte{0xff})} {
		encoded, err := json.Marshal(s)
		if err != nil {
			t.Fatal(err)
		}
		left := int64(len(encoded))
		if !chargeJSONString(s, &left) || left != 0 {
			t.Fatalf("escape charge differs from encoding/json for %q: remainder %d", s, left)
		}
		left = int64(len(encoded) - 1)
		if chargeJSONString(s, &left) {
			t.Fatalf("insufficient string budget accepted for %q", s)
		}
	}
	value := inventoryDocument{Status: "parsed", Inventories: map[string][]inventoryRow{"objcClasses": {{Name: "Widget", Address: 123}}}, Errors: map[string]string{}}
	left := int64(4096)
	if !chargeJSON(reflect.ValueOf(value), &left, 0) {
		t.Fatal("inventory map shape refused")
	}
	var accepted inventoryDocument
	if err := json.Unmarshal(boundedInventoryJSON(value, 4096), &accepted); err != nil || accepted.Status != "parsed" || len(accepted.Inventories["objcClasses"]) != 1 {
		t.Fatalf("map inventory not preserved: %+v %v", accepted, err)
	}
	var refused struct {
		Status string
		Reason string
	}
	if err := json.Unmarshal(boundedInventoryJSON(value, 1), &refused); err != nil || refused.Status != "rejected" || refused.Reason != "output-budget" {
		t.Fatalf("small output budget not refused: %+v %v", refused, err)
	}
}
