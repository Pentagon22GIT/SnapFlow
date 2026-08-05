import AppKit
import QuartzCore

struct VirtualResizeItem {
    let stableIdentity: String
    let originalFrame: CGRect
    let targetFrame: CGRect
    let appIcon: NSImage?
}

final class VirtualResizeOverlay {
    private var canvas: VirtualResizeCanvas?

    func prepare(items: [VirtualResizeItem], screenFrame: CGRect) {
        guard !items.isEmpty else { return }
        let canvas = canvas(for: screenFrame)
        canvas.prepare(items: items, screenFrame: screenFrame)
    }

    func update(
        items: [VirtualResizeItem],
        driverFrame: CGRect,
        screenFrame: CGRect
    ) {
        guard !items.isEmpty else {
            canvas?.hideContent()
            return
        }
        let canvas = canvas(for: screenFrame)
        canvas.update(
            items: items,
            driverFrame: driverFrame,
            screenFrame: screenFrame
        )
    }

    func hideAll() {
        canvas?.hide()
        canvas = nil
    }

    private func canvas(for screenFrame: CGRect) -> VirtualResizeCanvas {
        if let canvas {
            return canvas
        }
        let created = VirtualResizeCanvas(screenFrame: screenFrame)
        canvas = created
        return created
    }
}

private final class VirtualResizeCanvas {
    private let panel: NSPanel
    private let rootView: NSView
    private let concealContainer = NSView()
    private let targetContainer = NSView()
    private let iconContainer = NSView()
    private var followers: [String: VirtualFollowerViews] = [:]
    private var isShowing = false

    init(screenFrame: CGRect) {
        panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        rootView = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        rootView.wantsLayer = true
        panel.contentView = rootView

        for container in [concealContainer, targetContainer, iconContainer] {
            container.frame = rootView.bounds
            container.autoresizingMask = [.width, .height]
            container.wantsLayer = true
            rootView.addSubview(container)
        }
    }

    func prepare(items: [VirtualResizeItem], screenFrame: CGRect) {
        updateScreenFrame(screenFrame)
        for item in items.sorted(by: { $0.stableIdentity < $1.stableIdentity }) {
            _ = follower(for: item)
        }
        rootView.layoutSubtreeIfNeeded()
        rootView.displayIfNeeded()
    }

    func update(
        items: [VirtualResizeItem],
        driverFrame: CGRect,
        screenFrame: CGRect
    ) {
        updateScreenFrame(screenFrame)
        let visibleIdentities = Set(items.map(\.stableIdentity))
        for (identity, follower) in followers where !visibleIdentities.contains(identity) {
            follower.setHidden(true)
        }

        let localDriver = localFrame(driverFrame, in: screenFrame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in items.sorted(by: { $0.stableIdentity < $1.stableIdentity }) {
            follower(for: item).update(
                originalFrame: localFrame(item.originalFrame, in: screenFrame),
                targetFrame: localFrame(item.targetFrame, in: screenFrame),
                driverFrame: localDriver,
                appIcon: item.appIcon,
                rootView: rootView
            )
        }
        CATransaction.commit()

        if !isShowing {
            panel.orderFrontRegardless()
            isShowing = true
        }
    }

    func hideContent() {
        followers.values.forEach { $0.setHidden(true) }
        if isShowing {
            panel.orderOut(nil)
            isShowing = false
        }
    }

    func hide() {
        hideContent()
        followers.values.forEach { $0.removeFromSuperview() }
        followers.removeAll()
        panel.orderOut(nil)
    }

    private func follower(for item: VirtualResizeItem) -> VirtualFollowerViews {
        if let existing = followers[item.stableIdentity] {
            existing.updateAppIcon(item.appIcon)
            return existing
        }
        let created = VirtualFollowerViews(
            appIcon: item.appIcon,
            concealContainer: concealContainer,
            targetContainer: targetContainer,
            iconContainer: iconContainer
        )
        followers[item.stableIdentity] = created
        return created
    }

    private func updateScreenFrame(_ screenFrame: CGRect) {
        guard panel.frame != screenFrame else { return }
        panel.setFrame(screenFrame, display: false)
        rootView.frame = CGRect(origin: .zero, size: screenFrame.size)
    }

    private func localFrame(_ frame: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - screenFrame.minX,
            y: frame.minY - screenFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }
}

private final class VirtualFollowerViews {
    private let concealView = NSVisualEffectView()
    private let targetView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let concealMask = CAShapeLayer()
    private let targetMask = CAShapeLayer()
    private let guideColor = NSColor(
        srgbRed: CGFloat(0x50) / 255,
        green: CGFloat(0x8D) / 255,
        blue: CGFloat(0xE5) / 255,
        alpha: 1
    )

    private var appIcon: NSImage?

    init(
        appIcon: NSImage?,
        concealContainer: NSView,
        targetContainer: NSView,
        iconContainer: NSView
    ) {
        self.appIcon = appIcon
        configure(effectView: concealView, borderWidth: 0)
        configure(effectView: targetView, borderWidth: 2)
        concealView.isHidden = true
        targetView.isHidden = true
        iconView.isHidden = true
        iconView.image = appIcon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        concealContainer.addSubview(concealView)
        targetContainer.addSubview(targetView)
        iconContainer.addSubview(iconView)
    }

    func update(
        originalFrame: CGRect,
        targetFrame: CGRect,
        driverFrame: CGRect,
        appIcon: NSImage?,
        rootView: NSView
    ) {
        updateAppIcon(appIcon)
        let concealFrame = originalFrame.insetBy(dx: 1, dy: 1)
        let guideFrame = targetFrame.insetBy(dx: 6, dy: 6)

        concealView.isHidden = false
        targetView.isHidden = false
        concealView.frame = concealFrame
        targetView.frame = guideFrame
        applyDriverCutout(
            to: concealView,
            mask: concealMask,
            driverFrame: driverFrame,
            rootView: rootView
        )
        applyDriverCutout(
            to: targetView,
            mask: targetMask,
            driverFrame: driverFrame,
            rootView: rootView
        )
        layoutIcon(in: guideFrame)
    }

    func updateAppIcon(_ newIcon: NSImage?) {
        guard appIcon !== newIcon else { return }
        appIcon = newIcon
        iconView.image = newIcon
    }

    func removeFromSuperview() {
        concealView.layer?.removeAllAnimations()
        targetView.layer?.removeAllAnimations()
        iconView.layer?.removeAllAnimations()
        concealView.removeFromSuperview()
        targetView.removeFromSuperview()
        iconView.removeFromSuperview()
    }

    func setHidden(_ hidden: Bool) {
        concealView.isHidden = hidden
        targetView.isHidden = hidden
        iconView.isHidden = hidden || targetView.frame.width < 72 || targetView.frame.height < 72
    }

    private func configure(effectView: NSVisualEffectView, borderWidth: CGFloat) {
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = guideColor.withAlphaComponent(0.20).cgColor
        effectView.layer?.borderColor = guideColor.withAlphaComponent(0.92).cgColor
        effectView.layer?.borderWidth = borderWidth
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
    }

    private func applyDriverCutout(
        to view: NSView,
        mask: CAShapeLayer,
        driverFrame: CGRect,
        rootView: NSView
    ) {
        guard let layer = view.layer else { return }
        let driverInView = view.convert(driverFrame, from: rootView)
        let overlap = view.bounds.intersection(driverInView)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
            layer.mask = nil
            return
        }

        let path = CGMutablePath()
        path.addRect(view.bounds)
        path.addRect(overlap)
        mask.frame = view.bounds
        mask.path = path
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        layer.mask = mask
    }

    private func layoutIcon(in targetFrame: CGRect) {
        let side = min(max(min(targetFrame.width, targetFrame.height) * 0.22, 36), 80)
        iconView.isHidden = targetFrame.width < 72 || targetFrame.height < 72
        iconView.frame = CGRect(
            x: targetFrame.midX - side / 2,
            y: targetFrame.midY - side / 2,
            width: side,
            height: side
        )
    }
}
