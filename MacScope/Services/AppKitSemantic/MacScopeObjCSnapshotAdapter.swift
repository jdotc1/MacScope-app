// INTEGRATION EXAMPLE ONLY — requires the private MacScope target's internal
// LoadedBinary / ObjCClass / ObjCCategory types plus AppKitFusionCore port.
// Insert into MacScopeAnalysisCore only after reading current AGENTS.md,
// obtaining the owner file lock and reviewing actual `LoadedBinary` identity.
// Deliberately does not open a Mach-O file or create a new image address space.

import Foundation

enum MacScopeAppKitObjCSnapshotAdapter {
    static func methods(in loaded: LoadedBinary, selectedImage: AppKitImageKey) -> [ObjCMethodFact] {
        var methods: [ObjCMethodFact] = []

        for cls in loaded.objcClasses {
            for method in cls.instanceMethods {
                methods.append(.init(image: selectedImage, ownerClass: cls.name,
                                     selector: method.selector, isClassMethod: false,
                                     ownerKind: .classDefinition,
                                     implementationVMAddress: method.implementation))
            }
            for method in cls.classMethods {
                methods.append(.init(image: selectedImage, ownerClass: cls.name,
                                     selector: method.selector, isClassMethod: true,
                                     ownerKind: .classDefinition,
                                     implementationVMAddress: method.implementation))
            }
        }

        // Preserve category facts independently. Dispatch order/replacement
        // is not proven by the presence of a category or a duplicate selector.
        for category in loaded.objcCategories {
            for method in category.instanceMethods {
                methods.append(.init(image: selectedImage, ownerClass: category.className,
                                     selector: method.selector, isClassMethod: false,
                                     ownerKind: .categoryDefinition,
                                     implementationVMAddress: method.implementation))
            }
            for method in category.classMethods {
                methods.append(.init(image: selectedImage, ownerClass: category.className,
                                     selector: method.selector, isClassMethod: true,
                                     ownerKind: .categoryDefinition,
                                     implementationVMAddress: method.implementation))
            }
        }

        return methods
    }
}

// Ownership proof obligation outside this method:
//   selectedImage.imageID          = current MacScope ImageSlot/selected-slice ID
//   selectedImage.imageGeneration  = captured analysis generation
//   selectedImage.bundleGeneration = exact owner-selected bundle generation
// Never construct these three identities from a file basename or nibkit label.
