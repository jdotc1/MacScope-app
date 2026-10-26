// Adapted from reviewed I3 drafts; kept behind the existing worker ABI.
package main

import (
	"bytes"
	"encoding/binary"
	"time"
)

type sourceFact struct {
	file string
	line int
}

func boundedCString(data []byte, offset, end uint64) (string, error) {
	if offset >= end || end > uint64(len(data)) {
		return "", reject("malformed", "string outside its subtable")
	}
	limit := offset + inventoryStringLimit + 1
	if limit > end {
		limit = end
	}
	n := bytes.IndexByte(data[offset:limit], 0)
	if n < 0 {
		return "", reject("string_limit", "unterminated or oversized string")
	}
	s := string(data[offset : offset+uint64(n)])
	if e := checkedString(s); e != nil {
		return "", e
	}
	return s, nil
}

// Validate source tables BEFORE NewTable, which initializes its own file map and
// otherwise silently recovers malformed mapping reads as missing source data.
func validateSources(data []byte, h pclnHeader, deadline time.Time) ([]sourceFact, error) {
	bo := binary.LittleEndian
	fileNames := map[uint64]string{}
	if h.format == "go12" {
		for i := uint64(1); i < h.files; i++ {
			off := uint64(bo.Uint32(data[h.fileBase+4*i:]))
			s, e := boundedCString(data, off, uint64(len(data)))
			if e != nil {
				return nil, e
			}
			fileNames[i] = s
		}
	} else {
		pos := h.fileBase
		for i := uint64(0); i < h.files; i++ {
			s, e := boundedCString(data, pos, h.fileEnd)
			if e != nil {
				return nil, e
			}
			fileNames[pos-h.fileBase] = s
			pos += uint64(len(s)) + 1
		}
	}
	type pcResult struct{ first int32 }
	cache := map[uint32]pcResult{}
	operations := 0
	pcValue := func(offset uint32) (int32, error) { return 0, nil }
	pcValue = func(offset uint32) (int32, error) {
		if offset == 0 {
			return -1, nil
		}
		if v, ok := cache[offset]; ok {
			return v.first, nil
		}
		p := h.pcBase + uint64(offset)
		if p >= h.pcEnd {
			return 0, reject("malformed", "PC-value offset outside subtable")
		}
		read := func() (uint32, error) {
			var v uint32
			for shift := uint(0); shift < 35; shift += 7 {
				operations++
				if operations > 32<<20 {
					return 0, reject("read_limit", "PC-value decoding budget exceeded")
				}
				if operations%1024 == 0 && time.Now().After(deadline) {
					return 0, reject("deadline", "source validation deadline exceeded")
				}
				if p >= h.pcEnd {
					return 0, reject("malformed", "truncated PC-value varint")
				}
				b := data[p]
				p++
				if shift == 28 && b > 15 {
					return 0, reject("malformed", "PC-value varint overflow")
				}
				v |= uint32(b&127) << shift
				if b&128 == 0 {
					return v, nil
				}
			}
			return 0, reject("malformed", "overlong PC-value varint")
		}
		val := int64(-1)
		first := true
		entryValue := int32(-1)
		pc := uint64(0)
		for {
			uv, e := read()
			if e != nil {
				return 0, e
			}
			if uv == 0 && !first {
				break
			}
			delta := int64(uv >> 1)
			if uv&1 != 0 {
				delta = -delta - 1
			}
			val += delta
			if val < -2147483648 || val > 2147483647 {
				return 0, reject("malformed", "PC-value signed overflow")
			}
			advance, e := read()
			if e != nil {
				return 0, e
			}
			if advance == 0 {
				return 0, reject("unsupported", "zero-progress PC-value stream")
			}
			step := uint64(advance) * uint64(data[6])
			if step > 0xffffffff || pc+step < pc {
				return 0, reject("malformed", "PC-value address overflow")
			}
			pc += step
			if first {
				entryValue = int32(val)
				first = false
			}
		}
		cache[offset] = pcResult{entryValue}
		return entryValue, nil
	}
	field := func(off uint64) uint64 {
		if h.field == 4 {
			return uint64(bo.Uint32(data[off:]))
		}
		return bo.Uint64(data[off:])
	}
	out := make([]sourceFact, h.count)
	for i := uint64(0); i < h.count; i++ {
		if time.Now().After(deadline) {
			return nil, reject("deadline", "source validation deadline exceeded")
		}
		off := h.funcBase + field(h.ftab+(2*i+1)*h.field)
		first := uint64(8)
		if h.modern {
			first = 4
		}
		fileValue, e := pcValue(bo.Uint32(data[off+first+16:]))
		if e != nil {
			return nil, e
		}
		line, e := pcValue(bo.Uint32(data[off+first+20:]))
		if e != nil {
			return nil, e
		}
		if fileValue < 0 || line <= 0 {
			continue
		}
		var name string
		if h.format == "go12" {
			if fileValue == 0 {
				continue
			}
			var ok bool
			name, ok = fileNames[uint64(fileValue)]
			if !ok {
				return nil, reject("malformed", "Go1.2 file index outside file map")
			}
		} else {
			cu := uint64(bo.Uint32(data[off+first+28:]))
			idx := cu + uint64(fileValue)
			if idx > 0xffffffff || idx*4+4 > h.fileBase-h.cuBase {
				return nil, reject("malformed", "compilation-unit file index outside subtable")
			}
			fileOff := bo.Uint32(data[h.cuBase+idx*4:])
			if fileOff == 0xffffffff {
				continue
			}
			var ok bool
			name, ok = fileNames[uint64(fileOff)]
			if !ok {
				return nil, reject("malformed", "file name offset is not an advertised file")
			}
		}
		out[i] = sourceFact{name, int(line)}
	}
	return out, nil
}
