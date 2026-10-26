import Foundation

struct REANativeSubject: Codable, Sendable { var name: String; var format: String }
struct REANativeComponent: Codable, Sendable {
    var path: String; var artifact_id: String; var sha256: String; var format: String
}
struct REANativeEntry: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case file, directory, symlink, slice }
    var path: String; var kind: Kind
    var component: REANativeComponent? = nil
    var target: String? = nil
}
struct REANativeDependency: Codable, Sendable {
    var command: String; var encoding: String; var install_name: String
    var weak: Bool; var upward: Bool; var reexport: Bool; var delayed_init: Bool
    var current_version: String; var compatibility_version: String
}
struct REANativeSlice: Encodable, Sendable {
    var architecture: String
    var slice_offset: UInt64; var slice_size: UInt64
    var cpu_type: UInt32; var cpu_subtype: UInt32
    var fat_cpu_type: UInt32?; var fat_cpu_subtype: UInt32?; var fat_alignment_exponent: UInt32?
    var file_type: String; var file_type_code: UInt32
    var platform: UInt32?; var platforms: [UInt32]; var install_name: String?
    var dependencies: [REANativeDependency]; var rpaths: [String]; var dyld_environment: [String]
    var code_signature_present: Bool
    enum CodingKeys: String, CodingKey {
        case architecture, slice_offset, slice_size, cpu_type, cpu_subtype, fat_cpu_type, fat_cpu_subtype
        case fat_alignment_exponent, file_type, file_type_code, platform, platforms, install_name
        case dependencies, rpaths, dyld_environment, code_signature_present
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(architecture, forKey: .architecture)
        try c.encode(slice_offset, forKey: .slice_offset); try c.encode(slice_size, forKey: .slice_size)
        try c.encode(cpu_type, forKey: .cpu_type); try c.encode(cpu_subtype, forKey: .cpu_subtype)
        try c.encode(fat_cpu_type, forKey: .fat_cpu_type); try c.encode(fat_cpu_subtype, forKey: .fat_cpu_subtype)
        try c.encode(fat_alignment_exponent, forKey: .fat_alignment_exponent)
        try c.encode(file_type, forKey: .file_type); try c.encode(file_type_code, forKey: .file_type_code)
        try c.encode(platform, forKey: .platform); try c.encode(platforms, forKey: .platforms)
        try c.encode(install_name, forKey: .install_name); try c.encode(dependencies, forKey: .dependencies)
        try c.encode(rpaths, forKey: .rpaths); try c.encode(dyld_environment, forKey: .dyld_environment)
        try c.encode(code_signature_present, forKey: .code_signature_present)
    }
}
enum REANativeImageFacts: Encodable, Sendable {
    case parsed([REANativeSlice]), malformed(String), unsupported(String), notMachO
    enum CodingKeys: String, CodingKey { case status, slices, reason }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .parsed(let slices): try c.encode("parsed", forKey: .status); try c.encode(slices, forKey: .slices)
        case .malformed(let reason): try c.encode("malformed", forKey: .status); try c.encode(reason, forKey: .reason)
        case .unsupported(let reason): try c.encode("unsupported", forKey: .status); try c.encode(reason, forKey: .reason)
        case .notMachO: try c.encode("not-mach-o", forKey: .status)
        }
    }
}
struct REANativeImage: Encodable, Sendable { var path: String; var facts: REANativeImageFacts }
struct REANativeApplicationInput: Encodable, Sendable {
    let inventoryComplete: Bool
    var subject: REANativeSubject; var entries: [REANativeEntry]; var images: [REANativeImage]
    var roots: [String]; var architecture: String?
}
