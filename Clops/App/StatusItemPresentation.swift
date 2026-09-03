import AppKit

@MainActor
enum StatusItemVisualState: Equatable {
    case idle
    case copyFeedback
    case paused

    init(paused: Bool, copyFeedback: Bool) {
        if paused {
            self = .paused
        } else if copyFeedback {
            self = .copyFeedback
        } else {
            self = .idle
        }
    }

    var assetName: NSImage.Name? {
        switch self {
        case .idle:
            StatusItemPresentation.idleAssetName
        case .copyFeedback:
            StatusItemPresentation.copyFeedbackAssetName
        case .paused:
            nil
        }
    }

    var fallbackSymbolName: String {
        switch self {
        case .idle:
            "clipboard"
        case .copyFeedback:
            "clipboard.fill"
        case .paused:
            "pause.circle.fill"
        }
    }

    var imageAccessibilityDescription: String {
        switch self {
        case .idle:
            "Clops clipboard history"
        case .copyFeedback:
            "Clops, copy captured"
        case .paused:
            "Clops, capture paused"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .idle:
            "Capture active"
        case .copyFeedback:
            "Copy captured"
        case .paused:
            "Capture paused"
        }
    }

    var shouldPulse: Bool {
        self == .copyFeedback
    }
}

@MainActor
struct StatusItemPresentation {
    typealias NamedImageLoader = (NSImage.Name) -> NSImage?
    typealias SymbolImageLoader = (_ name: String, _ description: String) -> NSImage?

    static let idleAssetName = NSImage.Name("ClopsMenuBarTemplate")
    static let copyFeedbackAssetName = NSImage.Name("ClopsMenuBarCapturedTemplate")
    static let imageSize = NSSize(width: 18, height: 18)

    let state: StatusItemVisualState
    let image: NSImage
    let toolTip: String
    let accessibilityLabel = "Clops"
    let accessibilityHelp = "Opens clipboard history."

    var accessibilityValue: String {
        state.accessibilityValue
    }

    var shouldPulse: Bool {
        state.shouldPulse
    }

    init(
        paused: Bool,
        copyFeedback: Bool,
        shortcutLabel: String?,
        namedImageLoader: NamedImageLoader = { NSImage(named: $0) },
        symbolImageLoader: SymbolImageLoader = {
            NSImage(systemSymbolName: $0, accessibilityDescription: $1)
        }
    ) {
        let state = StatusItemVisualState(paused: paused, copyFeedback: copyFeedback)
        self.state = state
        self.toolTip = Self.toolTip(for: state, shortcutLabel: shortcutLabel)

        let source = state.assetName.flatMap(namedImageLoader)
            ?? symbolImageLoader(
                state.fallbackSymbolName,
                state.imageAccessibilityDescription
            )
            ?? NSImage(size: Self.imageSize)
        let image = source.copy() as! NSImage
        image.size = Self.imageSize
        image.isTemplate = true
        image.accessibilityDescription = state.imageAccessibilityDescription
        self.image = image
    }

    static func copyPulsePeak(burstCount: Int) -> Double {
        1.14 + Double(min(max(burstCount - 1, 0), 3)) * 0.02
    }

    private static func toolTip(
        for state: StatusItemVisualState,
        shortcutLabel: String?
    ) -> String {
        switch state {
        case .paused:
            shortcutLabel.map { "Clops — Capture Paused (\($0))" }
                ?? "Clops — Capture Paused"
        case .idle, .copyFeedback:
            shortcutLabel.map { "Clops Clipboard History (\($0))" }
                ?? "Clops Clipboard History — Shortcut unavailable"
        }
    }
}
