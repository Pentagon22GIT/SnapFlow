import AppKit
import ApplicationServices

private func activeWindowObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let owner = Unmanaged<ActiveWindowObserver>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    owner.receive(notification: notification as String)
}

final class ActiveWindowObserver {
    var onFocusedWindowChange: ((pid_t) -> Void)?

    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var observedPID: pid_t?
    private var registeredNotifications: [CFString] = []

    deinit {
        stop()
    }

    func observeFrontmostApplication() {
        observe(NSWorkspace.shared.frontmostApplication)
    }

    func observe(_ application: NSRunningApplication?) {
        guard AXIsProcessTrusted(),
              let application,
              !application.isTerminated,
              application.activationPolicy == .regular,
              application.processIdentifier
                != ProcessInfo.processInfo.processIdentifier else {
            stop()
            return
        }

        let pid = application.processIdentifier
        guard observedPID != pid else { return }
        stop()

        var createdObserver: AXObserver?
        guard AXObserverCreate(
            pid,
            activeWindowObserverCallback,
            &createdObserver
        ) == .success,
              let createdObserver else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let notifications: [CFString] = [
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var successfulNotifications: [CFString] = []

        for notification in notifications {
            let result = AXObserverAddNotification(
                createdObserver,
                appElement,
                notification,
                refcon
            )
            if result == .success || result == .notificationAlreadyRegistered {
                successfulNotifications.append(notification)
            }
        }

        guard !successfulNotifications.isEmpty else { return }
        observer = createdObserver
        applicationElement = appElement
        observedPID = pid
        registeredNotifications = successfulNotifications
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )
    }

    func stop() {
        if let observer,
           let applicationElement {
            for notification in registeredNotifications {
                AXObserverRemoveNotification(
                    observer,
                    applicationElement,
                    notification
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        applicationElement = nil
        observedPID = nil
        registeredNotifications.removeAll()
    }

    fileprivate func receive(notification: String) {
        guard notification == kAXFocusedWindowChangedNotification
                || notification == kAXMainWindowChangedNotification,
              let observedPID else { return }
        onFocusedWindowChange?(observedPID)
    }
}
