import AppKit
import ServiceManagement

struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayText: String {
        var text = ""
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += keyName(for: UInt16(keyCode))
        return text
    }

    private func keyName(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let name = names[code] { return name }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        ) else { return "Key \(code)" }
        let value = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return value.isEmpty ? "Key \(code)" : value
    }
}

enum ShortcutAction: String, CaseIterable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, restoreLast

    var title: String {
        if self == .restoreLast { return "直前の配置を戻す" }
        return SnapZone(rawValue: rawValue)?.displayName ?? rawValue
    }

    var zone: SnapZone? { SnapZone(rawValue: rawValue) }
}

enum LinkedResizeDisplayMode: String, CaseIterable, Codable {
    case lightweight
    case mainOnly
    case allWindows

    var resizesMainWindowLive: Bool {
        self != .lightweight
    }

    var resizesLinkedWindowsLive: Bool {
        self == .allWindows
    }
}

final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("SnapFlowSettingsDidChange")

    private let defaults = UserDefaults.standard
    private let shortcutsKey = "shortcutBindings"
    private let edgeThresholdKey = "snapEdgeThreshold"
    private let cornerBandKey = "snapCornerBand"
    private let restoreSizeOnMoveKey = "restoreSnappedWindowSizeOnMove"
    private let linkedResizeEnabledKey = "linkedResizeEnabled"
    private let linkedResizeDisplayModeKey = "linkedResizeDisplayMode"
    private let sideDwellExpansionEnabledKey = "sideDwellExpansionEnabled"
    private let sideDwellDurationKey = "sideDwellDuration"
    private let windowPreviewsEnabledKey = "windowPreviewsEnabled"
    private let layoutIntrusionToleranceKey = "layoutIntrusionTolerance"
    private let legacySplitDetachmentThresholdKey = "splitDetachmentThreshold"

    static let defaultEdgeThreshold: Double = 26
    static let defaultCornerBand: Double = 120
    static let defaultSideDwellDuration: Double = 2
    static let defaultLayoutIntrusionTolerance: Double = 0.5
    static let edgeThresholdRange: ClosedRange<Double> = 8...80
    static let cornerBandRange: ClosedRange<Double> = 60...300
    static let sideDwellDurationRange: ClosedRange<Double> = 0.5...5
    static let layoutIntrusionToleranceRange: ClosedRange<Double> = 0.1...0.9

    var layoutIntrusionTolerance: Double {
        get {
            if defaults.object(forKey: layoutIntrusionToleranceKey) != nil {
                return Self.layoutIntrusionToleranceRange.clamped(
                    defaults.double(forKey: layoutIntrusionToleranceKey)
                )
            }
            if defaults.object(forKey: legacySplitDetachmentThresholdKey) != nil {
                return Self.layoutIntrusionToleranceRange.clamped(
                    defaults.double(forKey: legacySplitDetachmentThresholdKey)
                )
            }
            return Self.defaultLayoutIntrusionTolerance
        }
        set {
            defaults.set(
                Self.layoutIntrusionToleranceRange.clamped(newValue),
                forKey: layoutIntrusionToleranceKey
            )
            defaults.removeObject(forKey: legacySplitDetachmentThresholdKey)
            notify()
        }
    }

    var windowPreviewsEnabled: Bool {
        get {
            guard defaults.object(forKey: windowPreviewsEnabledKey) != nil else {
                return false
            }
            return defaults.bool(forKey: windowPreviewsEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: windowPreviewsEnabledKey)
            notify()
        }
    }

    var restoreSnappedWindowSizeOnMove: Bool {
        get {
            guard defaults.object(forKey: restoreSizeOnMoveKey) != nil else {
                return true
            }
            return defaults.bool(forKey: restoreSizeOnMoveKey)
        }
        set {
            defaults.set(newValue, forKey: restoreSizeOnMoveKey)
            notify()
        }
    }

    var linkedResizeEnabled: Bool {
        get {
            guard defaults.object(forKey: linkedResizeEnabledKey) != nil else {
                return true
            }
            return defaults.bool(forKey: linkedResizeEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: linkedResizeEnabledKey)
            notify()
        }
    }

    var linkedResizeDisplayMode: LinkedResizeDisplayMode {
        get {
            guard let rawValue = defaults.string(forKey: linkedResizeDisplayModeKey),
                  let mode = LinkedResizeDisplayMode(rawValue: rawValue) else {
                return .mainOnly
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: linkedResizeDisplayModeKey)
            notify()
        }
    }

    var sideDwellExpansionEnabled: Bool {
        get {
            guard defaults.object(forKey: sideDwellExpansionEnabledKey) != nil else {
                return true
            }
            return defaults.bool(forKey: sideDwellExpansionEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: sideDwellExpansionEnabledKey)
            notify()
        }
    }

    var sideDwellDuration: Double {
        get {
            guard defaults.object(forKey: sideDwellDurationKey) != nil else {
                return Self.defaultSideDwellDuration
            }
            return Self.sideDwellDurationRange.clamped(defaults.double(forKey: sideDwellDurationKey))
        }
        set {
            defaults.set(Self.sideDwellDurationRange.clamped(newValue), forKey: sideDwellDurationKey)
            notify()
        }
    }

    var shortcuts: [ShortcutAction: ShortcutBinding] {
        get {
            guard let data = defaults.data(forKey: shortcutsKey),
                  let decoded = try? JSONDecoder().decode([ShortcutAction: ShortcutBinding].self, from: data) else { return [:] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: shortcutsKey) }
            notify()
        }
    }


    var edgeThreshold: Double {
        get {
            guard defaults.object(forKey: edgeThresholdKey) != nil else {
                return Self.defaultEdgeThreshold
            }
            return Self.edgeThresholdRange.clamped(defaults.double(forKey: edgeThresholdKey))
        }
        set {
            defaults.set(Self.edgeThresholdRange.clamped(newValue), forKey: edgeThresholdKey)
            notify()
        }
    }

    var cornerBand: Double {
        get {
            guard defaults.object(forKey: cornerBandKey) != nil else {
                return Self.defaultCornerBand
            }
            return Self.cornerBandRange.clamped(defaults.double(forKey: cornerBandKey))
        }
        set {
            defaults.set(Self.cornerBandRange.clamped(newValue), forKey: cornerBandKey)
            notify()
        }
    }

    func resetDragDetectionSettings() {
        defaults.removeObject(forKey: edgeThresholdKey)
        defaults.removeObject(forKey: cornerBandKey)
        defaults.removeObject(forKey: sideDwellExpansionEnabledKey)
        defaults.removeObject(forKey: sideDwellDurationKey)
        notify()
    }

    var launchAtLogin: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}


private extension ClosedRange where Bound == Double {
    func clamped(_ value: Double) -> Double {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
