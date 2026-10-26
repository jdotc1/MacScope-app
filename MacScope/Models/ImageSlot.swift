/// The durable identity of a binary image WITHIN a workspace. A small integer allocated
/// once when the image joins the workspace (slot 0 = the primary/legacy image) and never
/// re-minted afterward. `BinaryImage.id` identifies the exact current owner of that slot and is
/// preserved when a valid re-analysis result is adopted; a replacement import receives a new ID.
/// The slot survives re-analysis, save/reopen, and undo, so it remains the durable qualifier for
/// address-keyed user state. Two images may legitimately contain the
/// SAME virtual address (all arm64 executables prefer 0x100000000), so any workspace-level
/// address key must carry its slot. Content identity (LC_UUID, file hash) is deliberately
/// NOT used: two loaded copies of one dylib must keep distinct slots.
struct ImageSlot: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    let rawValue: Int

    /// The single-image/legacy slot. Every workspace created before image-aware
    /// addressing has all of its state in this slot.
    static let primary = ImageSlot(rawValue: 0)

    static func < (lhs: ImageSlot, rhs: ImageSlot) -> Bool { lhs.rawValue < rhs.rawValue }
}
