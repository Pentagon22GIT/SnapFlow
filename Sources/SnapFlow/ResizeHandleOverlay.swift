import AppKit
import CoreGraphics

struct ResizeHandleDescriptor: Equatable {
    let id: String
    let displayID: CGDirectDisplayID
    let axis: SplitAxis
    let coordinate: CGFloat
    let span: ClosedRange<CGFloat>
    let screenFrame: CGRect
    let participantIDs: Set<String>
}

final class ResizeHandleOverlay {
    var onBegin: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onChange: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onEnd: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onCancel: ((ResizeHandleDescriptor) -> Void)?

    private var panels: [String: ResizeHandlePanel] = [:]
    private var activeHandleID: String?

    func update(_ descriptors: [ResizeHandleDescriptor]) {
        let visibleIDs = Set(descriptors.map(\.id))
        let staleIDs = panels.keys.filter {
            !visibleIDs.contains($0) && $0 != activeHandleID
        }
        for id in staleIDs {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }

        for descriptor in descriptors {
            let panel = panels[descriptor.id] ?? makePanel(for: descriptor)
            panels[descriptor.id] = panel
            panel.update(descriptor: descriptor)
            if activeHandleID == nil || activeHandleID == descriptor.id {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
        }
    }

    func beginInteraction(with handleID: String) {
        activeHandleID = handleID
        for (id, panel) in panels {
            panel.setInteractionActive(id == handleID)
            if id != handleID {
                panel.orderOut(nil)
            }
        }
    }

    func endInteraction() {
        activeHandleID = nil
        panels.values.forEach {
            $0.setInteractionActive(false)
            $0.cancelInteraction()
        }
    }

    func hideAll() {
        activeHandleID = nil
        panels.values.forEach {
            $0.cancelInteraction()
            $0.orderOut(nil)
        }
        panels.removeAll()
    }

    func owns(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return panels.values.contains { $0 === window }
    }

    private func makePanel(for descriptor: ResizeHandleDescriptor) -> ResizeHandlePanel {
        let panel = ResizeHandlePanel(descriptor: descriptor)
        panel.handleView.onBegin = { [weak self] descriptor, point in
            self?.onBegin?(descriptor, point)
        }
        panel.handleView.onChange = { [weak self] descriptor, point in
            self?.onChange?(descriptor, point)
        }
        panel.handleView.onEnd = { [weak self] descriptor, point in
            self?.onEnd?(descriptor, point)
        }
        panel.handleView.onCancel = { [weak self] descriptor in
            self?.onCancel?(descriptor)
        }
        return panel
    }
}

private final class ResizeHandlePanel: NSPanel {
    let handleView: ResizeHandleView

    init(descriptor: ResizeHandleDescriptor) {
        handleView = ResizeHandleView(descriptor: descriptor)
        super.init(
            contentRect: Self.panelFrame(for: descriptor),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        contentView = handleView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(descriptor: ResizeHandleDescriptor) {
        handleView.descriptor = descriptor
        setFrame(Self.panelFrame(for: descriptor), display: true)
    }

    func setInteractionActive(_ isActive: Bool) {
        level = isActive
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : .floating
    }

    func cancelInteraction() {
        handleView.cancelInteraction()
    }

    private static func panelFrame(for descriptor: ResizeHandleDescriptor) -> CGRect {
        let spanLength = max(descriptor.span.upperBound - descriptor.span.lowerBound, 1)
        let longSide = min(max(spanLength - 8, 36), 64)
        let hitThickness: CGFloat = 24
        let center = (descriptor.span.lowerBound + descriptor.span.upperBound) / 2
        switch descriptor.axis {
        case .horizontal:
            return CGRect(
                x: descriptor.coordinate - hitThickness / 2,
                y: center - longSide / 2,
                width: hitThickness,
                height: longSide
            )
        case .vertical:
            return CGRect(
                x: center - longSide / 2,
                y: descriptor.coordinate - hitThickness / 2,
                width: longSide,
                height: hitThickness
            )
        }
    }
}

private final class ResizeHandleView: NSView {
    var descriptor: ResizeHandleDescriptor {
        didSet {
            updatePillFrame()
            discardCursorRects()
        }
    }
    var onBegin: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onChange: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onEnd: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onCancel: ((ResizeHandleDescriptor) -> Void)?

    private let pillLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isDragging = false

    init(descriptor: ResizeHandleDescriptor) {
        self.descriptor = descriptor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        pillLayer.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        pillLayer.borderColor = NSColor.black.withAlphaComponent(0.28).cgColor
        pillLayer.borderWidth = 0.5
        pillLayer.shadowColor = NSColor.black.cgColor
        pillLayer.shadowOpacity = 0.24
        pillLayer.shadowRadius = 3
        pillLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(pillLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updatePillFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        let cursor: NSCursor = descriptor.axis == .horizontal
            ? .resizeLeftRight
            : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updatePillAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        isHovering = false
        updatePillAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        isDragging = true
        updatePillAppearance()
        onBegin?(descriptor, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onChange?(descriptor, NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        updatePillAppearance()
        onEnd?(descriptor, NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, isDragging else {
            super.keyDown(with: event)
            return
        }
        isDragging = false
        updatePillAppearance()
        onCancel?(descriptor)
    }

    func cancelInteraction() {
        guard isDragging else { return }
        isDragging = false
        updatePillAppearance()
    }

    private func updatePillFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let thickness: CGFloat = isHovering || isDragging ? 7 : 5
        let length: CGFloat = isHovering || isDragging ? 42 : 36
        switch descriptor.axis {
        case .horizontal:
            pillLayer.frame = CGRect(
                x: bounds.midX - thickness / 2,
                y: bounds.midY - length / 2,
                width: thickness,
                height: length
            )
        case .vertical:
            pillLayer.frame = CGRect(
                x: bounds.midX - length / 2,
                y: bounds.midY - thickness / 2,
                width: length,
                height: thickness
            )
        }
        pillLayer.cornerRadius = thickness / 2
        CATransaction.commit()
    }

    private func updatePillAppearance() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.10)
        pillLayer.backgroundColor = isDragging
            ? NSColor.controlAccentColor.cgColor
            : NSColor.white.withAlphaComponent(isHovering ? 1 : 0.88).cgColor
        CATransaction.commit()
        updatePillFrame()
    }
}
