package main

import "encoding/binary"

func fileExtent(data []byte, offset, size uint64) bool {
	return offset <= uint64(len(data)) && size <= uint64(len(data))-offset
}

// Only commands in inventory.go's LoadIncluding list are consumed by go-macho.
// Unrelated signatures/notes/hints are intentionally not parsed by this oracle.
func preflightCommand(file, cmd []byte, kind uint32) error {
	bo := binary.LittleEndian
	pair := func(at int, scale uint64) error {
		if at+8 > len(cmd) {
			return reject("malformed", "truncated load command")
		}
		off, n := uint64(bo.Uint32(cmd[at:])), uint64(bo.Uint32(cmd[at+4:]))
		if n*scale > inventorySectionLimit || !fileExtent(file, off, n*scale) {
			return reject("malformed", "load-command data exceeds bounded file extent")
		}
		return nil
	}
	switch kind {
	case 2: // LC_SYMTAB
		if len(cmd) < 24 {
			return reject("malformed", "truncated symbol command")
		}
		if bo.Uint32(cmd[12:]) > inventoryRecordLimit {
			return reject("record_limit", "symbol count exceeds 50000")
		}
		if e := pair(8, 16); e != nil {
			return e
		}
		return pair(16, 1)
	case 0xb: // LC_DYSYMTAB (only indirect symbols are loaded eagerly)
		if len(cmd) < 80 {
			return reject("malformed", "truncated dynamic symbol command")
		}
		if bo.Uint32(cmd[60:]) > inventoryRecordLimit {
			return reject("record_limit", "indirect symbol count exceeds 50000")
		}
		return pair(56, 4)
	case 0x22, 0x80000022: // dyld info, each offset/size pair
		if len(cmd) < 48 {
			return reject("malformed", "truncated dyld info")
		}
		for p := 8; p < 48; p += 8 {
			if e := pair(p, 1); e != nil {
				return e
			}
		}
	case 0x80000033, 0x80000034:
		return pair(8, 1)
	case 0xc, 0xd, 0x80000018, 0x8000001f, 0x20, 0x80000023:
		if len(cmd) < 24 {
			return reject("malformed", "truncated dylib command")
		}
		off := uint64(bo.Uint32(cmd[8:]))
		if off >= uint64(len(cmd)) {
			return reject("malformed", "dylib name offset outside command")
		}
	}
	return nil
}
