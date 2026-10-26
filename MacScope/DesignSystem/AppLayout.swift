import AppKit

enum AppLayout {
    /// Existing authored-finding review geometry, shared by its sheet and lists.
    static let analystFindingEditorMinimumHeight: CGFloat = 180
    static let analystFindingDecisionMaximumWidth: CGFloat = 300
    static let analystFindingReviewMinimumWidth: CGFloat = 600
    static let analystFindingReviewIdealWidth: CGFloat = 760
    static let analystFindingReviewMinimumHeight: CGFloat = 520
    static let analystFindingReviewIdealHeight: CGFloat = 720
    static let analystFindingListMaximumHeight: CGFloat = 220
    /// Bounds for the existing native-value relationship control.
    static let nativeValueRelationshipMaximumWidth: CGFloat = 240
    /// Dense detail rows inside an individual source-correlation candidate.
    static let sourceCandidateDetailSpacing: CGFloat = 3

    /// Minimum width of the crash report viewer.
    static let crashReportMinimumWidth: CGFloat = 640
    /// Minimum height of the crash report viewer.
    static let crashReportMinimumHeight: CGFloat = 380
    /// Width of the crash report frame-number column.
    static let crashReportFrameNumberWidth: CGFloat = 32
    /// Width of the hardware watchpoint editor sheet.
    static let watchpointEditorWidth: CGFloat = 450
    /// Minimum width of the graph zoom percentage label.
    static let graphZoomLabelMinimumWidth: CGFloat = 48
    /// Height of the loader architecture slice list.
    static let loaderArchitectureListHeight: CGFloat = 180
    /// Height of the loader ELF archive member list.
    static let loaderArchiveListHeight: CGFloat = 220
    /// Width of the loader sheet when choosing a shared-cache image.
    static let loaderCacheSheetWidth: CGFloat = 560
    /// Width of the loader sheet for other binary formats.
    static let loaderOptionsSheetWidth: CGFloat = 460
    /// Height of the loader shared-cache image list.
    static let loaderCacheImageListHeight: CGFloat = 300

    static let minimumSupportedWindowWidth: CGFloat = 1080
    static let sidebarMinWidth: CGFloat = 328
    static let sidebarIdealWidth: CGFloat = 352
    static let sidebarMaxWidth: CGFloat = 384
    static let editorMinimumReadableWidth: CGFloat = 560
    static let minimumBalancedWindowWidth: CGFloat = sidebarMinWidth + editorMinimumReadableWidth
    static let maximumSidebarWindowShare: CGFloat = 0.34
    static let maximumInspectorWindowShare: CGFloat = 0.27
    static let maximumSupportingPaneWindowShare: CGFloat = 0.56
    static let inspectorMinWidth: CGFloat = 260
    static let inspectorIdealWidth: CGFloat = 300
    static let inspectorMaxWidth: CGFloat = 340
    static let inspectorPresentationMinWindowWidth: CGFloat = 1220
    static let compactInspectorThreshold: CGFloat = 1400
    static let compactInspectorMinWidth: CGFloat = 248
    static let compactInspectorIdealWidth: CGFloat = 276
    static let compactInspectorMaxWidth: CGFloat = 312

    static func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        min(sidebarMaxWidth, max(sidebarMinWidth, windowWidth * 0.28))
    }

    static func allowsInspector(for windowWidth: CGFloat) -> Bool {
        windowWidth >= inspectorPresentationMinWindowWidth
    }

    static func inspectorMinimumWidth(for windowWidth: CGFloat) -> CGFloat {
        windowWidth < compactInspectorThreshold ? compactInspectorMinWidth : inspectorMinWidth
    }

    static func inspectorIdealWidth(for windowWidth: CGFloat) -> CGFloat {
        windowWidth < compactInspectorThreshold ? compactInspectorIdealWidth : inspectorIdealWidth
    }

    static func inspectorMaximumWidth(for windowWidth: CGFloat) -> CGFloat {
        windowWidth < compactInspectorThreshold ? compactInspectorMaxWidth : inspectorMaxWidth
    }

    static func workspacePaneMetrics(for windowWidth: CGFloat) -> WorkspacePaneMetrics {
        WorkspacePaneMetrics(windowWidth: windowWidth)
    }
}

struct WorkspacePaneMetrics {
    let windowWidth: CGFloat

    var sidebarWidth: CGFloat {
        AppLayout.sidebarWidth(for: windowWidth)
    }

    var allowsInspector: Bool {
        AppLayout.allowsInspector(for: windowWidth)
    }

    var inspectorMinWidth: CGFloat {
        AppLayout.inspectorMinimumWidth(for: windowWidth)
    }

    var inspectorIdealWidth: CGFloat {
        AppLayout.inspectorIdealWidth(for: windowWidth)
    }

    var inspectorMaxWidth: CGFloat {
        AppLayout.inspectorMaximumWidth(for: windowWidth)
    }

    var inspectorReservedWidth: CGFloat {
        allowsInspector ? inspectorMaxWidth : 0
    }

    var sidebarWindowShare: CGFloat {
        guard windowWidth > 0 else { return 1 }
        return sidebarWidth / windowWidth
    }

    var inspectorWindowShare: CGFloat {
        guard windowWidth > 0 else { return 1 }
        return inspectorReservedWidth / windowWidth
    }

    var supportingPaneWindowShare: CGFloat {
        guard windowWidth > 0 else { return 1 }
        return (sidebarWidth + inspectorReservedWidth) / windowWidth
    }

    var editorFrameMinimumWidth: CGFloat {
        min(AppLayout.editorMinimumReadableWidth, max(0, windowWidth - sidebarWidth))
    }

    var editorReadableWidth: CGFloat {
        max(0, windowWidth - sidebarWidth - inspectorReservedWidth)
    }

    var editorReadableWidthAtInspectorMaximum: CGFloat {
        editorReadableWidth
    }

    var minimumBalancedWidth: CGFloat {
        sidebarWidth + AppLayout.editorMinimumReadableWidth + inspectorReservedWidth
    }

    var preservesReadableEditor: Bool {
        editorReadableWidth >= AppLayout.editorMinimumReadableWidth
    }

    var preservesReadableEditorAtInspectorMaximum: Bool {
        editorReadableWidthAtInspectorMaximum >= AppLayout.editorMinimumReadableWidth
    }

    var respectsPaneBudget: Bool {
        sidebarWindowShare <= AppLayout.maximumSidebarWindowShare
            && inspectorWindowShare <= AppLayout.maximumInspectorWindowShare
            && supportingPaneWindowShare <= AppLayout.maximumSupportingPaneWindowShare
            && preservesReadableEditor
            && preservesReadableEditorAtInspectorMaximum
    }
}
