import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings = AppSettings.shared
    private let scrollView = NSScrollView()
    private var didPositionScrollView = false
    private var recordingAction: ShortcutAction?
    private var keyMonitor: Any?
    private var shortcutButtons: [ShortcutAction: NSButton] = [:]
    private var clearButtons: [ShortcutAction: NSButton] = [:]
    private var resizeModeButtons: [LinkedResizeDisplayMode: NSButton] = [:]
    private let launchCheckbox = NSButton(checkboxWithTitle: "ログイン時にSnapFlowを起動", target: nil, action: nil)
    private let windowPreviewsCheckbox = NSButton(
        checkboxWithTitle: "配置候補にウィンドウ画像を表示",
        target: nil,
        action: nil
    )
    private let restoreSizeOnMoveCheckbox = NSButton(
        checkboxWithTitle: "移動時にスナップ前のサイズへ戻す",
        target: nil,
        action: nil
    )
    private let linkedResizeCheckbox = NSButton(
        checkboxWithTitle: "分割ウィンドウを一緒にリサイズ",
        target: nil,
        action: nil
    )
    private let edgeThresholdSlider = NSSlider()
    private let edgeThresholdValue = NSTextField(labelWithString: "")
    private let cornerBandSlider = NSSlider()
    private let cornerBandValue = NSTextField(labelWithString: "")
    private let sideDwellExpansionCheckbox = NSButton(
        checkboxWithTitle: "左右端で待つと四分割を選びやすくする",
        target: nil,
        action: nil
    )
    private let sideDwellDurationSlider = NSSlider()
    private let sideDwellDurationValue = NSTextField(labelWithString: "")
    private let layoutIntrusionSlider = NSSlider()
    private let layoutIntrusionValue = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 580, height: 820),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        window.title = "SnapFlow \(version) 設定"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        finishRecording()
    }

    func show() {
        refresh()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        positionScrollViewAtTopIfNeeded()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let documentView = FlippedSettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -26)
        ])

        stack.addArrangedSubview(sectionTitle("一般"))
        launchCheckbox.target = self
        launchCheckbox.action = #selector(toggleLaunchAtLogin)
        stack.addArrangedSubview(launchCheckbox)

        windowPreviewsCheckbox.target = self
        windowPreviewsCheckbox.action = #selector(toggleWindowPreviews)
        stack.addArrangedSubview(windowPreviewsCheckbox)
        let previewNote = NSTextField(
            wrappingLabelWithString: "画面収録の許可が必要です。画像は保存・送信しません。"
        )
        previewNote.textColor = .secondaryLabelColor
        previewNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(previewNote)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("ウィンドウ移動"))
        restoreSizeOnMoveCheckbox.target = self
        restoreSizeOnMoveCheckbox.action = #selector(toggleRestoreSizeOnMove)
        stack.addArrangedSubview(restoreSizeOnMoveCheckbox)
        let restoreSizeNote = NSTextField(
            wrappingLabelWithString: "スナップしたウィンドウを動かすと、元の大きさに戻します。"
        )
        restoreSizeNote.textColor = .secondaryLabelColor
        restoreSizeNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(restoreSizeNote)

        linkedResizeCheckbox.target = self
        linkedResizeCheckbox.action = #selector(toggleLinkedResize)
        stack.addArrangedSubview(linkedResizeCheckbox)
        let linkedResizeNote = NSTextField(
            wrappingLabelWithString: "境目のつまみを動かすと、隣のウィンドウも一緒にサイズが変わります。"
        )
        linkedResizeNote.textColor = .secondaryLabelColor
        linkedResizeNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(linkedResizeNote)

        let displayModeTitle = NSTextField(labelWithString: "ドラッグ中の表示")
        displayModeTitle.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(displayModeTitle)

        let displayModeStack = NSStackView()
        displayModeStack.orientation = .vertical
        displayModeStack.alignment = .leading
        displayModeStack.spacing = 7
        displayModeStack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        let modeDescriptions: [(LinkedResizeDisplayMode, String, String)] = [
            (.lightweight, "軽量", "すべてアイコンで表示"),
            (.mainOnly, "標準", "操作中のウィンドウだけ内容を表示"),
            (.allWindows, "すべて表示", "すべてのウィンドウ内容を表示")
        ]
        for (mode, title, detail) in modeDescriptions {
            let button = NSButton(
                radioButtonWithTitle: "\(title) — \(detail)",
                target: self,
                action: #selector(changeLinkedResizeDisplayMode(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            resizeModeButtons[mode] = button
            displayModeStack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(displayModeStack)
        let displayModeNote = NSTextField(
            wrappingLabelWithString: "表示するウィンドウが多いほど、動作が重くなる場合があります。"
        )
        displayModeNote.textColor = .secondaryLabelColor
        displayModeNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(displayModeNote)

        configureSlider(
            layoutIntrusionSlider,
            range: AppSettings.layoutIntrusionToleranceRange,
            action: #selector(changeLayoutIntrusionTolerance(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: "ウィンドウを小さくする範囲",
            detail: "小さくすると、ウィンドウを大きめに保ちます。",
            slider: layoutIntrusionSlider,
            valueLabel: layoutIntrusionValue
        ))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("ドラッグ判定"))
        let detectionNote = NSTextField(wrappingLabelWithString: "画面の端や四隅が反応する範囲を調整します。")
        detectionNote.textColor = .secondaryLabelColor
        detectionNote.maximumNumberOfLines = 0
        stack.addArrangedSubview(detectionNote)

        sideDwellExpansionCheckbox.target = self
        sideDwellExpansionCheckbox.action = #selector(toggleSideDwellExpansion)
        stack.addArrangedSubview(sideDwellExpansionCheckbox)

        configureSlider(
            sideDwellDurationSlider,
            range: AppSettings.sideDwellDurationRange,
            action: #selector(changeSideDwellDuration(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: "四分割に切り替わるまで",
            detail: "左右端で待つ時間を設定します。",
            slider: sideDwellDurationSlider,
            valueLabel: sideDwellDurationValue
        ))

        configureSlider(
            edgeThresholdSlider,
            range: AppSettings.edgeThresholdRange,
            action: #selector(changeEdgeThreshold(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: "画面端の反応範囲",
            detail: "大きくすると、端から少し離れていても反応します。",
            slider: edgeThresholdSlider,
            valueLabel: edgeThresholdValue
        ))

        configureSlider(
            cornerBandSlider,
            range: AppSettings.cornerBandRange,
            action: #selector(changeCornerBand(_:))
        )
        stack.addArrangedSubview(settingRow(
            title: "四隅の反応範囲",
            detail: "大きくすると、左右分割より四分割を選びやすくなります。",
            slider: cornerBandSlider,
            valueLabel: cornerBandValue
        ))

        let resetDetectionButton = NSButton(title: "ドラッグ判定を標準に戻す", target: self, action: #selector(resetDetectionSettings))
        resetDetectionButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetDetectionButton)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("キーボードショートカット"))
        let note = NSTextField(wrappingLabelWithString: "ボタンを押してキーを入力します。Escでキャンセルできます。")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0
        stack.addArrangedSubview(note)

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            let button = NSButton(title: "未設定", target: self, action: #selector(recordShortcut(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            shortcutButtons[action] = button

            let clearButton = NSButton(title: "消去", target: self, action: #selector(clearShortcut(_:)))
            clearButton.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            clearButton.bezelStyle = .rounded
            clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
            clearButtons[action] = clearButton

            grid.addRow(with: [label, button, clearButton])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .fill
        stack.addArrangedSubview(grid)

        stack.addArrangedSubview(NSButton(title: "すべてのショートカットを消去", target: self, action: #selector(clearShortcuts)))
    }

    private func configureSlider(_ slider: NSSlider, range: ClosedRange<Double>, action: Selector) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = 0
        slider.isContinuous = false
        slider.target = self
        slider.action = action
        slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    private func settingRow(
        title: String,
        detail: String,
        slider: NSSlider,
        valueLabel: NSTextField
    ) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.textColor = .secondaryLabelColor
        detailField.font = .systemFont(ofSize: 11)
        detailField.maximumNumberOfLines = 0

        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true

        let sliderRow = NSStackView(views: [slider, valueLabel])
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 12

        let stack = NSStackView(views: [titleField, detailField, sliderRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 17, weight: .semibold)
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return box
    }

    private func refresh() {
        launchCheckbox.state = settings.launchAtLogin ? .on : .off
        windowPreviewsCheckbox.state = settings.windowPreviewsEnabled ? .on : .off
        restoreSizeOnMoveCheckbox.state = settings.restoreSnappedWindowSizeOnMove ? .on : .off
        linkedResizeCheckbox.state = settings.linkedResizeEnabled ? .on : .off
        for (mode, button) in resizeModeButtons {
            button.state = settings.linkedResizeDisplayMode == mode ? .on : .off
            button.isEnabled = settings.linkedResizeEnabled
        }
        sideDwellExpansionCheckbox.state = settings.sideDwellExpansionEnabled ? .on : .off
        sideDwellDurationSlider.isEnabled = settings.sideDwellExpansionEnabled
        sideDwellDurationValue.textColor = settings.sideDwellExpansionEnabled ? .labelColor : .tertiaryLabelColor
        sideDwellDurationSlider.doubleValue = settings.sideDwellDuration
        sideDwellDurationValue.stringValue = String(format: "%.1f 秒", settings.sideDwellDuration)
        edgeThresholdSlider.doubleValue = settings.edgeThreshold
        edgeThresholdValue.stringValue = "\(Int(settings.edgeThreshold.rounded())) pt"
        cornerBandSlider.doubleValue = settings.cornerBand
        cornerBandValue.stringValue = "\(Int(settings.cornerBand.rounded())) pt"
        layoutIntrusionSlider.doubleValue = settings.layoutIntrusionTolerance
        layoutIntrusionValue.stringValue = "\(Int((settings.layoutIntrusionTolerance * 100).rounded())) %"

        let values = settings.shortcuts
        for action in ShortcutAction.allCases {
            let binding = values[action]
            shortcutButtons[action]?.title = binding?.displayText ?? "未設定"
            clearButtons[action]?.isEnabled = binding != nil
        }
    }

    @objc private func changeEdgeThreshold(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        settings.edgeThreshold = value
        edgeThresholdValue.stringValue = "\(Int(value)) pt"
    }

    @objc private func changeCornerBand(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        settings.cornerBand = value
        cornerBandValue.stringValue = "\(Int(value)) pt"
    }

    @objc private func changeSideDwellDuration(_ sender: NSSlider) {
        let value = (sender.doubleValue * 10).rounded() / 10
        settings.sideDwellDuration = value
        sideDwellDurationValue.stringValue = String(format: "%.1f 秒", value)
    }

    @objc private func changeLayoutIntrusionTolerance(_ sender: NSSlider) {
        let value = (sender.doubleValue * 20).rounded() / 20
        settings.layoutIntrusionTolerance = value
        layoutIntrusionValue.stringValue = "\(Int((value * 100).rounded())) %"
    }

    @objc private func toggleSideDwellExpansion() {
        settings.sideDwellExpansionEnabled = sideDwellExpansionCheckbox.state == .on
        refresh()
    }

    @objc private func resetDetectionSettings() {
        settings.resetDragDetectionSettings()
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try settings.setLaunchAtLogin(launchCheckbox.state == .on)
        } catch {
            launchCheckbox.state = settings.launchAtLogin ? .on : .off
            let alert = NSAlert()
            alert.messageText = "ログイン項目を変更できませんでした"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleWindowPreviews() {
        settings.windowPreviewsEnabled = windowPreviewsCheckbox.state == .on
    }

    @objc private func toggleRestoreSizeOnMove() {
        settings.restoreSnappedWindowSizeOnMove = restoreSizeOnMoveCheckbox.state == .on
    }

    @objc private func toggleLinkedResize() {
        settings.linkedResizeEnabled = linkedResizeCheckbox.state == .on
        refresh()
    }

    @objc private func changeLinkedResizeDisplayMode(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let mode = LinkedResizeDisplayMode(rawValue: rawValue) else {
            refresh()
            return
        }
        settings.linkedResizeDisplayMode = mode
        refresh()
    }

    @objc private func clearShortcuts() {
        settings.shortcuts = [:]
        refresh()
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = ShortcutAction(rawValue: raw) else { return }
        var shortcuts = settings.shortcuts
        shortcuts.removeValue(forKey: action)
        settings.shortcuts = shortcuts
        refresh()
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = ShortcutAction(rawValue: raw) else { return }
        recordingAction = action
        sender.title = "キーを入力…"
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recordingAction else { return event }
            if event.keyCode == 53 {
                self.finishRecording()
                return nil
            }
            let allowed: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let modifiers = event.modifierFlags.intersection(allowed)
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }
            let binding = ShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers.rawValue))
            var shortcuts = self.settings.shortcuts
            for (otherAction, otherBinding) in shortcuts where otherBinding == binding && otherAction != action {
                shortcuts.removeValue(forKey: otherAction)
            }
            shortcuts[action] = binding
            self.settings.shortcuts = shortcuts
            self.finishRecording()
            return nil
        }
    }

    private func finishRecording() {
        recordingAction = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        refresh()
    }

    private func positionScrollViewAtTopIfNeeded() {
        guard !didPositionScrollView else { return }
        didPositionScrollView = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            self.scrollView.contentView.scroll(to: .zero)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }
}

private final class FlippedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
