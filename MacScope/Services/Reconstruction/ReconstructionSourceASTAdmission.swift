import CryptoKit
import Foundation

/// Fixed-profile semantic gate over a full compiler translation unit, before linking or execution.
/// The caller owns the compiler receipt, input identity and immutable artifact capture. AST locations
/// never authorize omission: #line and macro locations are model-controlled presentation.
enum ReconstructionSourceASTAdmission {
    static let maximumBytes = 1_048_576
    static let maximumNodes = 8_192
    static let maximumDepth = 64
    static let profileID = ReconstructionSourceProfile.scalarU32V1.rawValue

    enum Failure: Error, Equatable {
        case invalidAuthority, malformedAST, bounds, invalidTranslationUnit
        case invalidFunction, forbiddenNode(String), invalidReference
    }

    struct Result: Equatable, Sendable {
        let sourceSHA256: String
        let profileID: String
        let astSHA256: String
        let functionName: String
        let nodeCount: Int
    }

    static func validate(json: Data, expectedSourceSHA256: String, profileID: String) throws -> Result {
        guard profileID == Self.profileID, expectedSourceSHA256.utf8.count == 64,
              expectedSourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidAuthority
        }
        guard !json.isEmpty, json.count <= maximumBytes else { throw Failure.bounds }
        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(json, limits: .init(maximumBytes: maximumBytes,
                maximumDepth: 160, maximumTokens: 131_072, maximumMembersAndElements: 131_072))
        } catch { throw Failure.malformedAST }
        guard let root = value.objectValue, root["kind"]?.stringValue == "TranslationUnitDecl" else {
            throw Failure.invalidTranslationUnit
        }
        var validator = Validator()
        let declarations = try validator.children(root)
        var function: Node?
        for declaration in declarations {
            let node = try validator.node(declaration, depth: 1)
            if node["kind"]?.stringValue == "FunctionDecl" {
                guard function == nil else { throw Failure.invalidFunction }
                function = node
            } else {
                try validator.validateTypeDeclaration(node, depth: 1)
            }
        }
        guard let function else { throw Failure.invalidFunction }
        try validator.validateFunction(function)
        return Result(sourceSHA256: expectedSourceSHA256, profileID: profileID,
            astSHA256: SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined(),
            functionName: "reconstructed", nodeCount: validator.count)
    }

    private typealias Node = [String: Phase2ProductionJSONValue]
    private struct Validator {
        var count = 1
        var declarations: [String: String] = [:]
        var returns = 0
        var uint32TypeIsUnsigned = false

        mutating func node(_ value: Phase2ProductionJSONValue, depth: Int) throws -> Node {
            count += 1
            guard count <= maximumNodes, depth <= maximumDepth else { throw Failure.bounds }
            guard let node = value.objectValue, let kind = node["kind"]?.stringValue, !kind.isEmpty else {
                throw Failure.malformedAST
            }
            guard !kind.hasSuffix("Attr") else { throw Failure.forbiddenNode(kind) }
            return node
        }
        func children(_ node: Node) throws -> [Phase2ProductionJSONValue] {
            guard let inner = node["inner"] else { return [] }
            guard let values = inner.arrayValue else { throw Failure.malformedAST }
            return values
        }
        mutating func validateTypeDeclaration(_ node: Node, depth: Int) throws {
            let allowed: Set<String> = ["TypedefDecl", "BuiltinType", "VectorType", "ElaboratedType",
                "TypedefType", "RecordType", "PointerType", "ConstantArrayType", "RecordDecl", "FieldDecl"]
            guard let kind = node["kind"]?.stringValue, allowed.contains(kind) else {
                throw Failure.forbiddenNode(node["kind"]?.stringValue ?? "missing")
            }
            if kind == "TypedefDecl", node["name"]?.stringValue == "uint32_t" {
                guard !uint32TypeIsUnsigned, scalarType(node, unsignedOnly: true) else { throw Failure.invalidFunction }
                uint32TypeIsUnsigned = true
            }
            // Header types have no executable authority. In particular a FieldDecl initializer,
            // embedded function, VarDecl or attribute cannot hide behind a harmless typedef.
            for child in try children(node) {
                try validateTypeDeclaration(try self.node(child, depth: depth + 1), depth: depth + 1)
            }
        }
        mutating func validateFunction(_ node: Node) throws {
            let signature = node["type"]?.objectValue?["qualType"]?.stringValue
            let signatures: Set<String> = ["uint32_t (uint32_t)", "unsigned int (unsigned int)",
                "uint32_t (unsigned int)", "unsigned int (uint32_t)"]
            guard node["name"]?.stringValue == "reconstructed",
                  node["mangledName"]?.stringValue == "_reconstructed",
                  signature.map(signatures.contains) == true,
                  signature?.contains("uint32_t") != true || uint32TypeIsUnsigned,
                  node["storageClass"] == nil, node["variadic"]?.boolValue != true,
                  node["inline"]?.boolValue != true else { throw Failure.invalidFunction }
            let values = try children(node)
            guard values.count == 2 else { throw Failure.invalidFunction }
            let parameter = try self.node(values[0], depth: 2)
            guard parameter["kind"]?.stringValue == "ParmVarDecl", try children(parameter).isEmpty else {
                throw Failure.invalidFunction
            }
            try register(parameter, kind: "ParmVarDecl")
            let body = try self.node(values[1], depth: 2)
            guard body["kind"]?.stringValue == "CompoundStmt" else { throw Failure.invalidFunction }
            try executable(body, depth: 2)
            guard returns > 0 else { throw Failure.invalidFunction }
        }
        func scalarType(_ node: Node, unsignedOnly: Bool = false) -> Bool {
            guard let type = node["type"]?.objectValue,
                  let spelling = (type["desugaredQualType"] ?? type["qualType"])?.stringValue else { return false }
            return spelling == "unsigned int" || (!unsignedOnly && spelling == "int")
        }
        mutating func register(_ node: Node, kind: String) throws {
            guard scalarType(node, unsignedOnly: true), let id = node["id"]?.stringValue, !id.isEmpty,
                  declarations[id] == nil, node["storageClass"] == nil,
                  node["tls"] == nil else { throw Failure.invalidFunction }
            declarations[id] = kind
        }
        mutating func executable(_ node: Node, depth: Int) throws {
            guard let kind = node["kind"]?.stringValue else { throw Failure.malformedAST }
            let values = try children(node)
            switch kind {
            case "CompoundStmt": break
            case "ReturnStmt":
                guard values.count == 1 else { throw Failure.invalidFunction }
                returns += 1
            case "IfStmt":
                guard values.count == 2 || values.count == 3,
                      node["hasInit"]?.boolValue != true, node["hasVar"]?.boolValue != true else {
                    throw Failure.invalidFunction
                }
            case "DeclStmt":
                guard !values.isEmpty else { throw Failure.invalidFunction }
                for value in values {
                    guard value.objectValue?["kind"]?.stringValue == "VarDecl" else { throw Failure.invalidFunction }
                }
            case "VarDecl":
                try register(node, kind: "VarDecl")
                guard values.count == 1, node["init"]?.stringValue == "c" else { throw Failure.invalidFunction }
            case "IntegerLiteral":
                guard scalarType(node), values.isEmpty, let literal = node["value"]?.stringValue,
                      UInt32(literal) != nil else { throw Failure.invalidFunction }
            case "DeclRefExpr":
                guard scalarType(node, unsignedOnly: true), values.isEmpty,
                      let reference = node["referencedDecl"]?.objectValue,
                      let id = reference["id"]?.stringValue,
                      declarations[id] == reference["kind"]?.stringValue else { throw Failure.invalidReference }
            case "ImplicitCastExpr", "CStyleCastExpr":
                guard scalarType(node), values.count == 1,
                      ["LValueToRValue", "IntegralCast", "NoOp"].contains(node["castKind"]?.stringValue ?? "") else {
                    throw Failure.invalidFunction
                }
            case "ParenExpr":
                guard scalarType(node), values.count == 1 else { throw Failure.invalidFunction }
            case "ConditionalOperator":
                guard scalarType(node), values.count == 3 else { throw Failure.invalidFunction }
            case "BinaryOperator":
                guard scalarType(node), values.count == 2,
                      ["+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^", "==", "!=", "<", ">", "<=", ">=", "&&", "||", "="].contains(node["opcode"]?.stringValue ?? "") else {
                    throw Failure.invalidFunction
                }
                if node["opcode"]?.stringValue == "=" {
                    guard values[0].objectValue?["kind"]?.stringValue == "DeclRefExpr" else { throw Failure.invalidFunction }
                }
            case "CompoundAssignOperator":
                guard scalarType(node, unsignedOnly: true), values.count == 2,
                      values[0].objectValue?["kind"]?.stringValue == "DeclRefExpr",
                      ["+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^="].contains(node["opcode"]?.stringValue ?? "") else {
                    throw Failure.invalidFunction
                }
            case "UnaryOperator":
                guard scalarType(node), values.count == 1,
                      ["+", "-", "!", "~", "++", "--"].contains(node["opcode"]?.stringValue ?? "") else { throw Failure.invalidFunction }
                if ["++", "--"].contains(node["opcode"]?.stringValue ?? "") {
                    guard scalarType(node, unsignedOnly: true),
                          values[0].objectValue?["kind"]?.stringValue == "DeclRefExpr" else { throw Failure.invalidFunction }
                }
            case "NullStmt":
                guard values.isEmpty else { throw Failure.invalidFunction }
            default: throw Failure.forbiddenNode(kind)
            }
            for child in values {
                try executable(try self.node(child, depth: depth + 1), depth: depth + 1)
            }
        }
    }
}
