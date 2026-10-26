import Foundation

/// Recovers `_objc_msgSend$<selector>` names for the entries of an arm64/arm64e `__objc_stubs`
/// section.
///
/// Since Xcode 14 (`-fobjc-msgsend-selector-stubs`, default for macOS 13+ deployment targets),
/// `[receiver selector]` compiles to `bl <stub>` where each stub loads its selector and tail-calls
/// `objc_msgSend`. The linker names the stubs `_objc_msgSend$<selector>`, but those are local
/// symbols that `strip` removes, and the stubs have no indirect-symbol-table rows, so a stripped
/// app shows every message send as `bl 0x100000a40`.
///
/// Every stub variant ld64 emits begins with the same selector load:
///
///     adrp x1, selref@PAGE
///     ldr  x1, [x1, selref@PAGEOFF]
///
/// followed by a complete 12-byte (`b _objc_msgSend`) or 32-byte (`adrp x16/x17 … br/braa`)
/// dispatch. Both selector and dispatch linkage must be positively resolved from the current
/// loaded image; a selector load alone never establishes a message send.
///
/// Pure, bounded by the section size, and `Sendable`.
enum ObjCStubSelectorRecovery {
    static let symbolPrefix = "_objc_msgSend$"

    /// - Parameters:
    ///   - stubBytes: the file-backed bytes of `__objc_stubs`.
    ///   - sectionAddress: the section's virtual address.
    ///   - selectorBySelrefAddress: selref slot VA → selector name.
    /// - Returns: stub entry VA → `_objc_msgSend$<selector>`.
    static func names(
        stubBytes: Data,
        sectionAddress: UInt64,
        selectorBySelrefAddress: [UInt64: String],
        messageSendTargets: Set<UInt64> = [],
        messageSendPointerSlots: Set<UInt64> = []
    ) -> [UInt64: String] {
        guard !selectorBySelrefAddress.isEmpty, stubBytes.count >= 8 else { return [:] }
        let words: [UInt32] = stubBytes.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 3, by: 4).map { raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self).littleEndian }
        }
        var result: [UInt64: String] = [:]
        var index = 0
        while index + 1 < words.count {
            let (pc, overflow) = sectionAddress.addingReportingOverflow(UInt64(index) * 4)
            guard !overflow else { break }
            if let page = adrpPage(words[index], pc: pc, destination: 1),
               let pageOffset = ldr64UnsignedOffset(words[index + 1], destination: 1, base: 1) {
                let (selref, selrefOverflow) = page.addingReportingOverflow(pageOffset)
                if !selrefOverflow, let selector = selectorBySelrefAddress[selref], !selector.isEmpty,
                   let length = dispatchLength(words, index: index, pc: pc,
                       targets: messageSendTargets, slots: messageSendPointerSlots) {
                    result[pc] = symbolPrefix + selector
                    index += length
                    continue
                }
            }
            index += 1
        }
        return result
    }

    private static func dispatchLength(_ words: [UInt32], index: Int, pc: UInt64,
                                       targets: Set<UInt64>, slots: Set<UInt64>) -> Int? {
        guard index + 2 < words.count else { return nil }
        let tail = words[index + 2]
        // Compact direct tail: B (not BL) to positively identified msgSend linkage.
        if tail & 0xFC00_0000 == 0x1400_0000 {
            let immediate = Int64(Int32(bitPattern: (tail & 0x03FF_FFFF) << 6) >> 6) * 4
            let (branchPC, overflow) = pc.addingReportingOverflow(8)
            guard !overflow else { return nil }
            let target: UInt64?
            if immediate >= 0 {
                let sum = branchPC.addingReportingOverflow(UInt64(immediate))
                target = sum.overflow ? nil : sum.partialValue
            } else { target = branchPC >= UInt64(-immediate) ? branchPC - UInt64(-immediate) : nil }
            return target.map { targets.contains($0) ? 3 : nil } ?? nil
        }
        guard index + 7 < words.count else { return nil }
        let (tailPC, overflow) = pc.addingReportingOverflow(8)
        guard !overflow else { return nil }
        func padded(from offset: Int) -> Bool {
            (offset ..< 8).allSatisfy { words[index + $0] == 0xD420_0020 }
        }
        // Ordinary 32-byte linker stub: ADRP x16; LDR x16; BR x16; BRK padding.
        if let page = adrpPage(tail, pc: tailPC, destination: 16),
           let offset = ldr64UnsignedOffset(words[index + 3], destination: 16, base: 16),
           words[index + 4] == 0xD61F_0200, padded(from: 5) {
            let slot = page.addingReportingOverflow(offset)
            return !slot.overflow && slots.contains(slot.partialValue) ? 8 : nil
        }
        // Authenticated linker stub: x17 carries the slot/discriminator; BRAA x16,x17.
        if let page = adrpPage(tail, pc: tailPC, destination: 17),
           words[index + 3] & 0xFFC0_03FF == 0x9100_0231,
           words[index + 4] == 0xF940_0230,
           words[index + 5] == 0xD71F_0A11, padded(from: 6) {
            let offset = UInt64((words[index + 3] >> 10) & 0xFFF)
            let slot = page.addingReportingOverflow(offset)
            return !slot.overflow && slots.contains(slot.partialValue) ? 8 : nil
        }
        return nil
    }

    /// `ADRP Xd, label` → the 4 KiB page address it materialises, when `Rd == destination`.
    static func adrpPage(_ word: UInt32, pc: UInt64, destination: UInt32) -> UInt64? {
        guard word & 0x9F00_0000 == 0x9000_0000, word & 0x1F == destination else { return nil }
        let immlo = UInt64((word >> 29) & 0x3)
        let immhi = UInt64((word >> 5) & 0x7_FFFF)
        let raw = (immhi << 2) | immlo
        let signed = raw & (1 << 20) == 0 ? Int64(raw) : Int64(raw) - (1 << 21)
        let delta = signed * 4_096
        let page = pc & ~UInt64(0xFFF)
        if delta < 0 { return page >= UInt64(-delta) ? page - UInt64(-delta) : nil }
        let sum = page.addingReportingOverflow(UInt64(delta))
        return sum.overflow ? nil : sum.partialValue
    }

    /// `LDR Xt, [Xn, #imm]` (64-bit, unsigned offset) → the byte offset, when `Rt`/`Rn` match.
    static func ldr64UnsignedOffset(_ word: UInt32, destination: UInt32, base: UInt32) -> UInt64? {
        guard word & 0xFFC0_0000 == 0xF940_0000,
              word & 0x1F == destination,
              (word >> 5) & 0x1F == base else { return nil }
        return UInt64((word >> 10) & 0xFFF) * 8
    }
}
