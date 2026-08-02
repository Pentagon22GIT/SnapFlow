import AppKit
import QuartzCore

final class OverlayPanel {
    static let sideExpansionPulseDuration: TimeInterval = 0.72

    private let panel: NSPanel
    private var isShowing = false
    private let zoneColor = NSColor(
        srgbRed: CGFloat(0x50) / 255,
        green: CGFloat(0x8D) / 255,
        blue: CGFloat(0xE5) / 255,
        alpha: 1
    )

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = zoneColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = zoneColor.withAlphaComponent(0.9).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 12
        panel.contentView = view
    }

    func show(frame: CGRect, from anchor: CGPoint) {
        let targetFrame = frame.insetBy(dx: 6, dy: 6)
        let wasShowing = isShowing
        isShowing = true

        if !wasShowing {
            let initialSize: CGFloat = 28
            let initialFrame = CGRect(
                x: anchor.x - initialSize / 2,
                y: anchor.y - initialSize / 2,
                width: initialSize,
                height: initialSize
            )
            panel.alphaValue = 0.35
            panel.setFrame(initialFrame, display: true)
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasShowing ? 0.10 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func pulse(
        times: Int = 3,
        duration: TimeInterval = OverlayPanel.sideExpansionPulseDuration
    ) {
        guard isShowing,
              times > 0,
              let layer = panel.contentView?.layer else { return }

        var values: [NSNumber] = [1]
        for _ in 0..<times {
            values.append(0.48)
            values.append(1)
        }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        layer.removeAnimation(forKey: "snap-zone-pulse")
        layer.add(animation, forKey: "snap-zone-pulse")
    }

    func finishPulse() {
        panel.contentView?.layer?.removeAnimation(forKey: "snap-zone-pulse")
    }

    func hide() {
        isShowing = false
        panel.contentView?.layer?.removeAllAnimations()
        panel.alphaValue = 1
        panel.orderOut(nil)
    }
}
