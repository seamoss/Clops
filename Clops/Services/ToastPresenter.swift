import AppKit
import Foundation

@MainActor
final class ToastPresenter {
    private var panel: NSPanel?
    private var dismissalTask: Task<Void, Never>?

    func show(_ message: String) {
        dismissalTask?.cancel()
        panel?.close()

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -10)
        ])

        let fittingSize = effectView.fittingSize
        let width = max(fittingSize.width, 130)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: fittingSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = effectView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            let x = min(max(mouse.x - width / 2, visibleFrame.minX + 12), visibleFrame.maxX - width - 12)
            let y = min(max(mouse.y - 70, visibleFrame.minY + 12), visibleFrame.maxY - fittingSize.height - 12)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}
