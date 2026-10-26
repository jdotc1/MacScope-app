import Foundation
import XCTest

@testable import MacScope

final class InfoPlistDocumentTypeTests: XCTestCase {
    func testPlatformPolicyRequiresMacOS27WithoutChangingSwiftLanguageMode() throws {
        let info = try macScopeInfoDictionary()
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "27.0")

        let projectURL = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml", isDirectory: false)
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        let scalars = plainYAMLScalarMappings(in: project)

        let expectedGlobalDeployments = [
            "options.deploymentTarget.macOS": "27.0",
            "settings.base.MACOSX_DEPLOYMENT_TARGET": "27.0",
        ]
        let expectedProductDeployments = [
            "targets.SwiftAssemblyVendor.deploymentTarget": "27.0",
            "targets.MacScopeAnalysisCore.deploymentTarget": "27.0",
            "targets.MacScopeDebuggerCore.deploymentTarget": "27.0",
            "targets.MacScopeApp.deploymentTarget": "27.0",
            "targets.PluginXPCService.deploymentTarget": "27.0",
            "targets.AnalysisWorkerXPCService.deploymentTarget": "27.0",
            "targets.AIAgentWorkerXPCService.deploymentTarget": "27.0",
            "targets.NativeDecompilerXPCService.deploymentTarget": "27.0",
            "targets.ShellBrokerXPCService.deploymentTarget": "27.0",
            "targets.ShellBrokerLaunchAgent.deploymentTarget": "27.0",
            "targets.SourceExecutionRunner.deploymentTarget": "27.0",
            "targets.CoreTests.deploymentTarget": "27.0",
            "targets.Phase2Tests.deploymentTarget": "27.0",
            "targets.MacScopeInstalledAppUITests.deploymentTarget": "27.0",
        ]

        for (path, expected) in expectedGlobalDeployments {
            XCTAssertEqual(scalars[path], expected, "Unexpected deployment policy at \(path)")
        }
        XCTAssertEqual(scalars["options.minimumXcodeGenVersion"], "2.45.4")
        let explicitProductDeployments = scalars.filter { path, _ in
            let components = path.split(separator: ".")
            return components.count == 3 &&
                components[0] == "targets" &&
                components[2] == "deploymentTarget"
        }
        XCTAssertEqual(
            explicitProductDeployments,
            expectedProductDeployments,
            "Every explicit product deployment must be one of the governed targets at macOS 27.0"
        )
        XCTAssertEqual(scalars["settings.base.SWIFT_VERSION"], "6.0")
    }

    func testAIAgentWorkerInfoPlistIsAnApplicationXPCService() throws {
        let plistURL = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AIAgentWorkerService/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "XPC!")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)")
        let service = try XCTUnwrap(plist["XPCService"] as? [String: Any])
        XCTAssertEqual(service["ServiceType"] as? String, "Application")
    }

    func testInfoPlistRegistersReferenceAnalysisInputTypesAsViewers() throws {
        let info = try macScopeInfoDictionary()
        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])

        let appBundleType = try documentType(
            containing: "com.apple.application-bundle",
            in: documentTypes
        )
        XCTAssertEqual(appBundleType["CFBundleTypeName"] as? String, "macOS Application Bundle")
        XCTAssertEqual(appBundleType["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(appBundleType["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(appBundleType["LSTypeIsPackage"] as? Bool, true)

        let frameworkType = try documentType(
            containing: "com.apple.framework",
            in: documentTypes
        )
        XCTAssertEqual(frameworkType["CFBundleTypeName"] as? String, "macOS Framework Bundle")
        XCTAssertEqual(frameworkType["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(frameworkType["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(frameworkType["LSTypeIsPackage"] as? Bool, true)

        let binaryType = try documentType(
            containing: "com.apple.mach-o-binary",
            in: documentTypes
        )
        XCTAssertEqual(binaryType["CFBundleTypeName"] as? String, "Mach-O Binary Inputs")
        XCTAssertEqual(binaryType["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(binaryType["LSHandlerRank"] as? String, "Alternate")

        let binaryContentTypes = try XCTUnwrap(binaryType["LSItemContentTypes"] as? [String])
        XCTAssertTrue(binaryContentTypes.contains("com.apple.mach-o-dylib"))
        XCTAssertTrue(binaryContentTypes.contains("public.unix-executable"))
        XCTAssertTrue(binaryContentTypes.contains("public.object-code"))
        XCTAssertTrue(binaryContentTypes.contains("public.ar-archive"))

        let rawDataType = try documentType(containing: "public.data", in: documentTypes)
        XCTAssertEqual(rawDataType["CFBundleTypeName"] as? String, "Raw Binary Data Inputs")
        XCTAssertEqual(rawDataType["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(rawDataType["LSHandlerRank"] as? String, "Alternate")
    }

    func testInfoPlistRegistersMacScopePluginPackageTypesAsViewers() throws {
        let info = try macScopeInfoDictionary()
        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])

        let pluginTypes: [(identifier: String, name: String)] = [
            ("org.macscope.cpu-plugin-package", "MacScope CPU Plugin Package"),
            ("org.macscope.loader-plugin-package", "MacScope Loader Plugin Package"),
            ("org.macscope.tool-plugin-package", "MacScope Tool Plugin Package")
        ]

        for pluginType in pluginTypes {
            let documentType = try documentType(containing: pluginType.identifier, in: documentTypes)
            XCTAssertEqual(documentType["CFBundleTypeName"] as? String, pluginType.name)
            XCTAssertEqual(documentType["CFBundleTypeRole"] as? String, "Viewer")
            XCTAssertEqual(documentType["LSHandlerRank"] as? String, "Alternate")
            XCTAssertEqual(documentType["LSTypeIsPackage"] as? Bool, true)
        }
    }

    func testInfoPlistExportsMacScopePluginPackageUTIs() throws {
        let info = try macScopeInfoDictionary()
        let exportedTypes = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])

        let expectedTypes: [(identifier: String, extensionName: String)] = [
            ("org.macscope.cpu-plugin-package", "mscopecpu"),
            ("org.macscope.loader-plugin-package", "mscopeloader"),
            ("org.macscope.tool-plugin-package", "mscopetool")
        ]

        for expectedType in expectedTypes {
            let exportedType = try exportedTypeDeclaration(
                identifier: expectedType.identifier,
                in: exportedTypes
            )
            XCTAssertEqual(exportedType["UTTypeConformsTo"] as? [String], ["com.apple.package"])

            let tagSpecification = try XCTUnwrap(
                exportedType["UTTypeTagSpecification"] as? [String: Any]
            )
            XCTAssertEqual(
                tagSpecification["public.filename-extension"] as? [String],
                [expectedType.extensionName]
            )
        }
    }

    private func documentType(
        containing contentType: String,
        in documentTypes: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        try XCTUnwrap(
            documentTypes.first { item in
                (item["LSItemContentTypes"] as? [String])?.contains(contentType) == true
            },
            "Missing document type for \(contentType)",
            file: file,
            line: line
        )
    }

    private func plainYAMLScalarMappings(in yaml: String) -> [String: String] {
        var parents: [(indentation: Int, key: String)] = []
        var scalars: [String: String] = [:]

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let content = line.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty,
                  !content.hasPrefix("#"),
                  !content.hasPrefix("-")
            else {
                continue
            }
            guard let separator = content.firstIndex(of: ":") else {
                continue
            }

            let indentation = line.prefix(while: { $0 == " " }).count
            while let parent = parents.last, parent.indentation >= indentation {
                parents.removeLast()
            }

            let key = String(content[..<separator])
            var rawValue = String(content[content.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            let path = (parents.map(\.key) + [key]).joined(separator: ".")
            if rawValue.isEmpty {
                parents.append((indentation, key))
                continue
            }
            if let commentRange = rawValue.range(of: " #") {
                rawValue = String(rawValue[..<commentRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            if rawValue.count >= 2,
               let first = rawValue.first,
               let last = rawValue.last,
               first == last,
               first == "\"" || first == "'"
            {
                rawValue.removeFirst()
                rawValue.removeLast()
            }
            scalars[path] = rawValue
        }

        return scalars
    }

    private func exportedTypeDeclaration(
        identifier: String,
        in exportedTypes: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        try XCTUnwrap(
            exportedTypes.first { item in
                item["UTTypeIdentifier"] as? String == identifier
            },
            "Missing exported type for \(identifier)",
            file: file,
            line: line
        )
    }
}
