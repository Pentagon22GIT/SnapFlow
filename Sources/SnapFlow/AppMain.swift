import AppKit
import ApplicationServices

@main
final class SnapFlowApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = SnapController()
    private let shortcutManager = GlobalShortcutManager()
    private lazy var settingsWindow = SettingsWindowController()
    private var settingsObserver: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = SnapFlowApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains { $0.processIdentifier != currentPID }
            if alreadyRunning {
                NSApplication.shared.terminate(nil)
                return
            }
        }

        configureStatusItem()
        configureShortcuts()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.configureShortcuts() }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        controller.stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "SnapFlow")

        let menu = NSMenu()
        menu.addItem(withTitle: "機能を一時停止", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "左半分", action: #selector(snapLeft), keyEquivalent: "")
        menu.addItem(withTitle: "右半分", action: #selector(snapRight), keyEquivalent: "")
        menu.addItem(withTitle: "上半分", action: #selector(snapTop), keyEquivalent: "")
        menu.addItem(withTitle: "下半分", action: #selector(snapBottom), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "左上", action: #selector(snapTopLeft), keyEquivalent: "")
        menu.addItem(withTitle: "右上", action: #selector(snapTopRight), keyEquivalent: "")
        menu.addItem(withTitle: "左下", action: #selector(snapBottomLeft), keyEquivalent: "")
        menu.addItem(withTitle: "右下", action: #selector(snapBottomRight), keyEquivalent: "")
        menu.addItem(withTitle: "最大化", action: #selector(maximize), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "直前の配置を戻す", action: #selector(restoreLast), keyEquivalent: "")
        menu.addItem(withTitle: "固定状態を解除", action: #selector(clearLocks), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "更新を確認…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "アクセシビリティ設定を開く", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(withTitle: "状態をリセット", action: #selector(resetSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "SnapFlowを終了", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func configureShortcuts() {
        shortcutManager.register(bindings: AppSettings.shared.shortcuts) { [weak self] action in
            guard let self else { return }
            if action == .restoreLast {
                self.controller.restoreLast()
            } else if let zone = action.zone {
                self.controller.snapFocusedWindow(to: zone)
            }
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        controller.isEnabled.toggle()
        sender.title = controller.isEnabled ? "機能を一時停止" : "機能を再開"
    }

    @objc private func snapLeft() { controller.snapFocusedWindow(to: .leftHalf) }
    @objc private func snapRight() { controller.snapFocusedWindow(to: .rightHalf) }
    @objc private func snapTop() { controller.snapFocusedWindow(to: .topHalf) }
    @objc private func snapBottom() { controller.snapFocusedWindow(to: .bottomHalf) }
    @objc private func snapTopLeft() { controller.snapFocusedWindow(to: .topLeft) }
    @objc private func snapTopRight() { controller.snapFocusedWindow(to: .topRight) }
    @objc private func snapBottomLeft() { controller.snapFocusedWindow(to: .bottomLeft) }
    @objc private func snapBottomRight() { controller.snapFocusedWindow(to: .bottomRight) }
    @objc private func maximize() { controller.snapFocusedWindow(to: .maximize) }
    @objc private func restoreLast() { controller.restoreLast() }
    @objc private func clearLocks() { controller.clearLocks() }
    @objc private func openSettings() { settingsWindow.show() }

    @objc private func checkForUpdates() {
        guard let url = URL(string: "https://github.com/Pentagon22GIT/SnapFlow/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func resetSettings() {
        controller.reset()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
