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
    let occlusionParticipants: [WindowOcclusionParticipant]
    let showsPill: Bool

    init(
        id: String,
        displayID: CGDirectDisplayID,
        axis: SplitAxis,
        coordinate: CGFloat,
        span: ClosedRange<CGFloat>,
        screenFrame: CGRect,
        participantIDs: Set<String>,
        occlusionParticipants: [WindowOcclusionParticipant] = [],
        showsPill: Bool = true
    ) {
        self.id = id
        self.displayID = displayID
        self.axis = axis
        self.coordinate = coordinate
        self.span = span
        self.screenFrame = screenFrame
        self.participantIDs = participantIDs
        self.occlusionParticipants = occlusionParticipants
        self.showsPill = showsPill
    }

    func interactionFrame(thickness: CGFloat = 16) -> CGRect {
        let spanLength = max(span.upperBound - span.lowerBound, 1)
        switch axis {
        case .horizontal:
            return CGRect(
                x: coordinate - thickness / 2,
                y: span.lowerBound,
                width: thickness,
                height: spanLength
            )
        case .vertical:
            return CGRect(
                x: span.lowerBound,
                y: coordinate - thickness / 2,
                width: spanLength,
                height: thickness
            )
        }
    }

    func isOccluded(by frames: [CGRect]) -> Bool {
        let handleFrame = interactionFrame()
        return frames.contains { frame in
            let intersection = handleFrame.intersection(frame)
            return !intersection.isNull
                && intersection.width > 1
                && intersection.height > 1
        }
    }
}


private struct ResizeHandlePresentationSignature: Equatable {
    let id: String
    let axis: SplitAxis
    let coordinate: CGFloat
    let lowerBound: CGFloat
    let upperBound: CGFloat
    let showsPill: Bool

    init(_ descriptor: ResizeHandleDescriptor) {
        id = descriptor.id
        axis = descriptor.axis
        coordinate = descriptor.coordinate
        lowerBound = descriptor.span.lowerBound
        upperBound = descriptor.span.upperBound
        showsPill = descriptor.showsPill
    }
}

private struct ResizeHandleJunctionDescriptor {
    let id: String
    let first: ResizeHandleDescriptor
    let second: ResizeHandleDescriptor
    let frame: CGRect
}

final class ResizeHandleOverlay {
    var onBegin: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onChange: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onEnd: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onCancel: ((ResizeHandleDescriptor) -> Void)?

    private var panels: [String: ResizeHandlePanel] = [:]
    private var junctionPanels: [String: ResizeHandleJunctionPanel] = [:]
    private var activeHandleID: String?
    private var activeJunctionID: String?
    private var isInputSuspended = false
    private var presentedSignatures: [ResizeHandlePresentationSignature] = []

    var hasPresentedHandles: Bool {
        !panels.isEmpty || !junctionPanels.isEmpty
    }

    func update(_ descriptors: [ResizeHandleDescriptor]) {
        let signatures = descriptors.map(ResizeHandlePresentationSignature.init)
            .sorted { $0.id < $1.id }
        if signatures == presentedSignatures {
            return
        }
        presentedSignatures = signatures

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
            panel.setInputSuspended(isInputSuspended)
            if activeHandleID == nil || activeHandleID == descriptor.id {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
        }

        let junctions = makeJunctions(from: descriptors)
        let visibleJunctionIDs = Set(junctions.map(\.id))
        let staleJunctionIDs = junctionPanels.keys.filter {
            !visibleJunctionIDs.contains($0) && $0 != activeJunctionID
        }
        for id in staleJunctionIDs {
            junctionPanels.removeValue(forKey: id)?.orderOut(nil)
        }
        for junction in junctions {
            let panel = junctionPanels[junction.id] ?? makeJunctionPanel(for: junction)
            junctionPanels[junction.id] = panel
            panel.update(descriptor: junction)
            panel.ignoresMouseEvents = isInputSuspended
            if activeHandleID == nil || activeJunctionID == junction.id {
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
        for (id, panel) in junctionPanels {
            panel.setInteractionActive(id == activeJunctionID)
            if id != activeJunctionID {
                panel.orderOut(nil)
            }
        }
    }

    func endInteraction() {
        activeHandleID = nil
        activeJunctionID = nil
        panels.values.forEach {
            $0.setInteractionActive(false)
            $0.cancelInteraction()
            $0.orderFrontRegardless()
        }
        junctionPanels.values.forEach {
            $0.setInteractionActive(false)
            $0.cancelInteraction()
            $0.orderFrontRegardless()
        }
    }

    func setInputSuspended(_ isSuspended: Bool) {
        guard isInputSuspended != isSuspended else { return }
        isInputSuspended = isSuspended
        panels.values.forEach { $0.setInputSuspended(isSuspended) }
        junctionPanels.values.forEach { $0.ignoresMouseEvents = isSuspended }
    }

    func hideAll() {
        presentedSignatures = []
        activeHandleID = nil
        activeJunctionID = nil
        isInputSuspended = false
        panels.values.forEach {
            $0.cancelInteraction()
            $0.orderOut(nil)
        }
        panels.removeAll()
        junctionPanels.values.forEach {
            $0.cancelInteraction()
            $0.orderOut(nil)
        }
        junctionPanels.removeAll()
    }

    func owns(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return panels.values.contains { $0 === window }
            || junctionPanels.values.contains { $0 === window }
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

    private func makeJunctionPanel(
        for descriptor: ResizeHandleJunctionDescriptor
    ) -> ResizeHandleJunctionPanel {
        let panel = ResizeHandleJunctionPanel(descriptor: descriptor)
        panel.junctionView.onBegin = { [weak self] junctionID, selected, point in
            guard let self else { return }
            self.activeJunctionID = junctionID
            self.onBegin?(selected, point)
            if self.activeHandleID == nil {
                self.activeJunctionID = nil
            }
        }
        panel.junctionView.onChange = { [weak self] selected, point in
            self?.onChange?(selected, point)
        }
        panel.junctionView.onEnd = { [weak self] selected, point in
            self?.onEnd?(selected, point)
        }
        panel.junctionView.onCancel = { [weak self] selected in
            self?.onCancel?(selected)
        }
        return panel
    }

    private func makeJunctions(
        from descriptors: [ResizeHandleDescriptor]
    ) -> [ResizeHandleJunctionDescriptor] {
        let xBoundaries = descriptors.filter { $0.axis == .horizontal }
        let yBoundaries = descriptors.filter { $0.axis == .vertical }
        let radius: CGFloat = 12
        var result: [ResizeHandleJunctionDescriptor] = []

        for xBoundary in xBoundaries {
            for yBoundary in yBoundaries where
                yBoundary.displayID == xBoundary.displayID {
                let point = CGPoint(
                    x: xBoundary.coordinate,
                    y: yBoundary.coordinate
                )
                guard xBoundary.span.contains(point.y),
                      yBoundary.span.contains(point.x) else { continue }
                let minX = max(point.x - radius, yBoundary.span.lowerBound)
                let maxX = min(point.x + radius, yBoundary.span.upperBound)
                let minY = max(point.y - radius, xBoundary.span.lowerBound)
                let maxY = min(point.y + radius, xBoundary.span.upperBound)
                guard maxX - minX >= 8, maxY - minY >= 8 else { continue }
                let ids = [xBoundary.id, yBoundary.id].sorted()
                result.append(ResizeHandleJunctionDescriptor(
                    id: ids.joined(separator: "::"),
                    first: xBoundary,
                    second: yBoundary,
                    frame: CGRect(
                        x: minX,
                        y: minY,
                        width: maxX - minX,
                        height: maxY - minY
                    )
                ))
            }
        }
        return result
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

    func setInputSuspended(_ isSuspended: Bool) {
        ignoresMouseEvents = isSuspended
        handleView.setInputSuspended(isSuspended)
    }

    func cancelInteraction() {
        handleView.cancelInteraction()
    }

    private static func panelFrame(for descriptor: ResizeHandleDescriptor) -> CGRect {
        descriptor.interactionFrame()
    }
}

private final class ResizeHandleView: NSView {
    var descriptor: ResizeHandleDescriptor {
        didSet {
            updatePillFrame()
            updatePillAppearance(animated: false)
            discardCursorRects()
        }
    }
    var onBegin: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onChange: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onEnd: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onCancel: ((ResizeHandleDescriptor) -> Void)?

    private let guideLayer = CALayer()
    private let pillLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isDragging = false
    private var isInputSuspended = false

    init(descriptor: ResizeHandleDescriptor) {
        self.descriptor = descriptor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        guideLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor
        guideLayer.opacity = 0
        layer?.addSublayer(guideLayer)
        pillLayer.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        pillLayer.borderColor = NSColor.black.withAlphaComponent(0.28).cgColor
        pillLayer.borderWidth = 0.5
        pillLayer.shadowColor = NSColor.black.cgColor
        pillLayer.shadowOpacity = 0.24
        pillLayer.shadowRadius = 3
        pillLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(pillLayer)
        updatePillAppearance(animated: false)
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

    func setInputSuspended(_ isSuspended: Bool) {
        guard isInputSuspended != isSuspended else { return }
        isInputSuspended = isSuspended
        updatePillAppearance(animated: false)
    }

    private func updatePillFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let thickness: CGFloat = isHovering || isDragging ? 7 : 5
        let requestedLength: CGFloat = isHovering || isDragging ? 42 : 36
        switch descriptor.axis {
        case .horizontal:
            let length = min(requestedLength, max(bounds.height - 4, 1))
            guideLayer.frame = CGRect(
                x: bounds.midX - 1,
                y: 0,
                width: 2,
                height: bounds.height
            )
            pillLayer.frame = CGRect(
                x: bounds.midX - thickness / 2,
                y: bounds.midY - length / 2,
                width: thickness,
                height: length
            )
        case .vertical:
            let length = min(requestedLength, max(bounds.width - 4, 1))
            guideLayer.frame = CGRect(
                x: 0,
                y: bounds.midY - 1,
                width: bounds.width,
                height: 2
            )
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

    private func updatePillAppearance(animated: Bool = true) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.10)
        } else {
            CATransaction.setDisableActions(true)
        }
        let isInteractive = !isInputSuspended
        guideLayer.opacity = isInteractive && (isHovering || isDragging) ? 1 : 0
        if isInputSuspended {
            pillLayer.opacity = descriptor.showsPill ? 0.18 : 0
        } else if isDragging {
            pillLayer.opacity = 1
        } else if isHovering {
            pillLayer.opacity = 0.92
        } else {
            pillLayer.opacity = descriptor.showsPill ? 0.45 : 0
        }
        pillLayer.backgroundColor = isDragging
            ? NSColor.controlAccentColor.cgColor
            : NSColor.white.withAlphaComponent(isHovering ? 1 : 0.88).cgColor
        CATransaction.commit()
        updatePillFrame()
    }
}

private final class ResizeHandleJunctionPanel: NSPanel {
    let junctionView: ResizeHandleJunctionView

    init(descriptor: ResizeHandleJunctionDescriptor) {
        junctionView = ResizeHandleJunctionView(descriptor: descriptor)
        super.init(
            contentRect: descriptor.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
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
        contentView = junctionView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(descriptor: ResizeHandleJunctionDescriptor) {
        junctionView.descriptor = descriptor
        setFrame(descriptor.frame, display: true)
    }

    func setInteractionActive(_ isActive: Bool) {
        level = isActive
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            : NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    func cancelInteraction() {
        junctionView.cancelInteraction()
    }
}

private final class ResizeHandleJunctionView: NSView {
    var descriptor: ResizeHandleJunctionDescriptor
    var onBegin: ((String, ResizeHandleDescriptor, CGPoint) -> Void)?
    var onChange: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onEnd: ((ResizeHandleDescriptor, CGPoint) -> Void)?
    var onCancel: ((ResizeHandleDescriptor) -> Void)?

    private var startPoint: CGPoint?
    private var selectedDescriptor: ResizeHandleDescriptor?
    private let directionThreshold: CGFloat = 4

    init(descriptor: ResizeHandleJunctionDescriptor) {
        self.descriptor = descriptor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor.crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        startPoint = NSEvent.mouseLocation
        selectedDescriptor = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = NSEvent.mouseLocation
        if selectedDescriptor == nil {
            let deltaX = point.x - startPoint.x
            let deltaY = point.y - startPoint.y
            guard let desiredAxis = SplitLayoutGeometry.resizeAxis(
                forDragDelta: CGPoint(x: deltaX, y: deltaY),
                minimumDistance: directionThreshold
            ) else { return }
            let selected = descriptor.first.axis == desiredAxis
                ? descriptor.first
                : descriptor.second
            selectedDescriptor = selected
            onBegin?(descriptor.id, selected, point)
            return
        }
        if let selectedDescriptor {
            onChange?(selectedDescriptor, point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { resetInteraction() }
        guard let selectedDescriptor else { return }
        onEnd?(selectedDescriptor, NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, let selectedDescriptor else {
            super.keyDown(with: event)
            return
        }
        onCancel?(selectedDescriptor)
        resetInteraction()
    }

    func cancelInteraction() {
        resetInteraction()
    }

    private func resetInteraction() {
        startPoint = nil
        selectedDescriptor = nil
    }
}
