/// Original COFF section coordinates paired with the versioned synthetic analysis layout.
/// The section-table ordinal, rather than its possibly repeated name, identifies a section.
struct COFFSectionCoordinate: Codable, Hashable, Sendable {
    var sectionOrdinal: Int
    var originalRVA: UInt32
    var layoutVersion: Int = 1
}
