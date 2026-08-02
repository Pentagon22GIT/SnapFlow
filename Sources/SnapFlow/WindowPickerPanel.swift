import AppKit
import CoreGraphics

private final class PreviewImageLoader {
    private static let maximumPreviewPixelSize = CGSize(width: 680, height: 420)
    private let provider: (CGWindowID?) -> CGImage?
    private let queue = DispatchQueue(label: "dev.pent.SnapFlow.preview-loader", qos: .userInitiated)
    private var cache: [String: NSImage] = [:]
    private var completed: Set<String> = []
    private var pending: [String: [(NSImage?) -> Void]] = [:]

    init(provider: @escaping (CGWindowID?) -> CGImage?) {
        self.provider = provider
    }

    func request(_ window: ManagedWindow, completion: @escaping (NSImage?) -> Void) {
        let key = window.stableIdentity
        if completed.contains(key) {
            completion(cache[key])
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }

        pending[key] = [completion]
        let provider = self.provider
        let windowID = window.cgWindowID
        queue.async { [weak self] in
            guard self != nil else { return }
            let imageRef = provider(windowID).flatMap { source in
                Self.makePreviewImage(from: source)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let image = imageRef.map { NSImage(cgImage: $0, size: .zero) }
                if let image { self.cache[key] = image }
                self.completed.insert(key)
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }

    private static func makePreviewImage(from source: CGImage) -> CGImage? {
        let sourceSize = CGSize(
            width: CGFloat(source.width),
            height: CGFloat(source.height)
        )
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = min(min(
            maximumPreviewPixelSize.width / sourceSize.width,
            maximumPreviewPixelSize.height / sourceSize.height
        ), 1)
        guard scale < 1 else { return source }

        let width = max(Int((sourceSize.width * scale).rounded()), 1)
        let height = max(Int((sourceSize.height * scale).rounded()), 1)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

final class WindowPickerPanel: NSObject {
    private var panels: [NSPanel] = []
    private var onSelect: ((ManagedWindow, SnapZone) -> Void)?
    private var onCancel: (() -> Void)?
    private var previewLoader: PreviewImageLoader?

    var isVisible: Bool { !panels.isEmpty }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        panels.contains { NSMouseInRect(point, $0.frame, false) }
    }

    func show(
        windows: [ManagedWindow],
        zones: [SnapZone],
        screen: NSScreen,
        previewProvider: @escaping (CGWindowID?) -> CGImage?,
        onCancel: @escaping () -> Void,
        onSelect: @escaping (ManagedWindow, SnapZone) -> Void
    ) {
        hide(notifyCancel: false)
        guard !windows.isEmpty, !zones.isEmpty else { return }
        self.onSelect = onSelect
        self.onCancel = onCancel
        let previewLoader = PreviewImageLoader(provider: previewProvider)
        self.previewLoader = previewLoader

        for zone in zones {
            let panel = makePanel(frame: zone.frame(in: screen))
            let content = PickerZoneView(
                windows: windows,
                zone: zone,
                previewLoader: previewLoader,
                selection: { [weak self] window, selectedZone in
                    self?.onSelect?(window, selectedZone)
                    self?.hide(notifyCancel: false)
                },
                onCancel: { [weak self] in
                    self?.hide(notifyCancel: true)
                }
            )
            panel.contentView = content
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func hide(notifyCancel: Bool = false) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        let cancel = onCancel
        onSelect = nil
        onCancel = nil
        previewLoader = nil
        if notifyCancel { cancel?() }
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        return panel
    }
}

private final class PickerZoneView: NSView {
    private let previewLoader: PreviewImageLoader
    private let onCancel: () -> Void
    private let effectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let canvas = CenteredCardCanvas()
    private var scrollObserver: NSObjectProtocol?
    private var lastPreviewScrollOrigin = CGPoint.zero

    init(
        windows: [ManagedWindow],
        zone: SnapZone,
        previewLoader: PreviewImageLoader,
        selection: @escaping (ManagedWindow, SnapZone) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.previewLoader = previewLoader
        self.onCancel = onCancel
        super.init(frame: .zero)
        build(windows: windows, zone: zone, selection: selection)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        scrollView.frame = bounds
        canvas.viewportSize = bounds.size
        canvas.frame.size.width = bounds.width
        canvas.relayout()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !containsCard(at: point) else { return }
        onCancel()
    }

    private func containsCard(at point: CGPoint) -> Bool {
        guard let hit = hitTest(point) else { return false }
        var current: NSView? = hit
        while let view = current {
            if view is WindowCardButton { return true }
            current = view.superview
        }
        return false
    }

    private func build(
        windows: [ManagedWindow],
        zone: SnapZone,
        selection: @escaping (ManagedWindow, SnapZone) -> Void
    ) {
        wantsLayer = true

        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        addSubview(effectView)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvas
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handlePreviewScroll()
        }

        canvas.onBackgroundClick = { [weak self] in self?.onCancel() }
        for window in windows {
            let card = WindowCardButton(window: window, zone: zone, actionHandler: selection)
            canvas.addCard(card)
        }
        canvas.loadInitialPreviews(count: 12, using: previewLoader)
    }

    private func handlePreviewScroll() {
        let origin = scrollView.contentView.bounds.origin
        guard origin != lastPreviewScrollOrigin else { return }
        lastPreviewScrollOrigin = origin
        canvas.loadPreviews(
            near: scrollView.contentView.bounds,
            prefetchCount: 6,
            using: previewLoader
        )
    }
}

private final class CenteredCardCanvas: NSView {
    var viewportSize: CGSize = .zero
    var onBackgroundClick: (() -> Void)?
    private var cards: [WindowCardButton] = []
    private let horizontalPadding: CGFloat = 34
    private let verticalPadding: CGFloat = 34
    private let spacingX: CGFloat = 22
    private let spacingY: CGFloat = 26

    override var isFlipped: Bool { true }

    func addCard(_ card: WindowCardButton) {
        cards.append(card)
        addSubview(card)
    }

    func loadInitialPreviews(count: Int, using loader: PreviewImageLoader) {
        cards.prefix(max(count, 0)).forEach { $0.loadPreview(using: loader) }
    }

    func loadPreviews(near visibleRect: CGRect, prefetchCount: Int, using loader: PreviewImageLoader) {
        let visibleIndices = cards.indices.filter { cards[$0].frame.intersects(visibleRect) }
        guard let first = visibleIndices.first, let last = visibleIndices.last else { return }
        let start = max(first - max(prefetchCount, 0), 0)
        let end = min(last + max(prefetchCount, 0), cards.count - 1)
        guard start <= end else { return }
        for index in start...end {
            cards[index].loadPreview(using: loader)
        }
    }

    func relayout() {
        guard viewportSize.width > 0 else { return }

        let available = max(viewportSize.width - horizontalPadding * 2, 220)
        let preferredWidth = min(max(available * 0.34, 250), 340)
        let columns = max(1, Int((available + spacingX) / (preferredWidth + spacingX)))
        let cardWidth = min(340, max(235, (available - CGFloat(max(columns - 1, 0)) * spacingX) / CGFloat(columns)))
        let previewHeight = cardWidth * 0.60
        let cardHeight = previewHeight + 34
        let rows = max(1, Int(ceil(Double(cards.count) / Double(columns))))
        let contentHeight = CGFloat(rows) * cardHeight + CGFloat(max(rows - 1, 0)) * spacingY
        let canvasHeight = max(viewportSize.height, contentHeight + verticalPadding * 2)
        frame.size = CGSize(width: viewportSize.width, height: canvasHeight)

        let totalWidth = CGFloat(columns) * cardWidth + CGFloat(max(columns - 1, 0)) * spacingX
        let startX = max((viewportSize.width - totalWidth) / 2, horizontalPadding)
        let startY = max((canvasHeight - contentHeight) / 2, verticalPadding)

        for (index, card) in cards.enumerated() {
            let row = index / columns
            let column = index % columns
            let x = startX + CGFloat(column) * (cardWidth + spacingX)
            let y = startY + CGFloat(row) * (cardHeight + spacingY)
            card.frame = CGRect(x: x, y: y, width: cardWidth, height: cardHeight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard cards.allSatisfy({ !$0.frame.contains(point) }) else { return }
        onBackgroundClick?()
    }
}

private final class WindowCardButton: NSButton {
    private let managedWindow: ManagedWindow
    private let zone: SnapZone
    private let actionHandler: (ManagedWindow, SnapZone) -> Void
    private let previewView = NSImageView()
    private let placeholderIconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var didRequestPreview = false

    init(window: ManagedWindow, zone: SnapZone, actionHandler: @escaping (ManagedWindow, SnapZone) -> Void) {
        self.managedWindow = window
        self.zone = zone
        self.actionHandler = actionHandler
        super.init(frame: .zero)
        target = self
        action = #selector(selectWindow)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        build(window)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let titleHeight: CGFloat = 24
        previewView.frame = CGRect(x: 0, y: titleHeight + 8, width: bounds.width, height: max(bounds.height - titleHeight - 8, 0))
        placeholderIconView.frame = CGRect(
            x: previewView.frame.midX - 32,
            y: previewView.frame.midY - 32,
            width: 64,
            height: 64
        )
        titleField.frame = CGRect(x: 2, y: 0, width: max(bounds.width - 4, 0), height: titleHeight)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private func build(_ window: ManagedWindow) {
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 6
        previewView.layer?.masksToBounds = true
        previewView.layer?.borderWidth = 0
        previewView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        previewView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor

        placeholderIconView.image = window.appIcon
        placeholderIconView.imageScaling = .scaleProportionallyDown

        titleField.stringValue = window.title
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.alignment = .left
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.textColor = .labelColor

        addSubview(previewView)
        addSubview(placeholderIconView)
        addSubview(titleField)
    }

    func loadPreview(using loader: PreviewImageLoader) {
        guard !didRequestPreview else { return }
        didRequestPreview = true
        loader.request(managedWindow) { [weak self] image in
            guard let self, let image else { return }
            self.previewView.image = image
            self.placeholderIconView.isHidden = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        previewView.layer?.borderWidth = 3
    }

    override func mouseExited(with event: NSEvent) {
        previewView.layer?.borderWidth = 0
    }

    @objc private func selectWindow() {
        actionHandler(managedWindow, zone)
    }
}
