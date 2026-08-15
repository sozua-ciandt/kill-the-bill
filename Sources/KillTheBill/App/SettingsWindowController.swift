import AppKit
import SwiftUI

@MainActor
protocol SettingsWindowPresenting: AnyObject {
    var isMiniaturized: Bool { get }
    var isVisible: Bool { get }
    var title: String { get set }

    func deminiaturize()
    func makeKeyAndOrderFront()
    func orderFrontRegardless()
    func setCloseHandler(_ handler: @escaping @MainActor () -> Void)
}

@MainActor
protocol SettingsApplicationActivating: AnyObject {
    func unhide()
    func activate()
    func showInDock()
    func hideFromDock()
}

@MainActor
protocol SettingsRefocusCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol SettingsRefocusScheduling: AnyObject {
    func schedule(
        _ action: @escaping @MainActor () -> Void
    ) -> any SettingsRefocusCancellation
}

@MainActor
private final class SystemSettingsApplicationActivator: SettingsApplicationActivating {
    func unhide() {
        NSApplication.shared.unhide(nil)
    }

    func activate() {
        // KillTheBill is an LSUIElement app. Explicit activation is required so
        // a regular window does not remain behind the previously active app.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showInDock() {
        guard NSApplication.shared.activationPolicy() != .regular else { return }
        _ = NSApplication.shared.setActivationPolicy(.regular)
    }

    func hideFromDock() {
        guard NSApplication.shared.activationPolicy() != .accessory else { return }
        _ = NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@MainActor
private final class TaskSettingsRefocusCancellation: SettingsRefocusCancellation {
    private var task: Task<Void, Never>?

    init(action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
private final class SystemSettingsRefocusScheduler: SettingsRefocusScheduling {
    func schedule(
        _ action: @escaping @MainActor () -> Void
    ) -> any SettingsRefocusCancellation {
        TaskSettingsRefocusCancellation(action: action)
    }
}

@MainActor
private final class AppKitSettingsWindow: NSObject, SettingsWindowPresenting, NSWindowDelegate {
    private let window: NSWindow
    private var closeHandler: (@MainActor () -> Void)?

    init<Content: View>(rootView: Content) {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.identifier = NSUserInterfaceItemIdentifier(
            "dev.sozua-ciandt.kill-the-bill.settings"
        )
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)

        let frameName = "KillTheBill.SettingsWindow"
        if !window.setFrameUsingName(frameName) {
            window.center()
        }
        window.setFrameAutosaveName(frameName)

        self.window = window
        super.init()
        window.delegate = self
    }

    var isMiniaturized: Bool { window.isMiniaturized }
    var isVisible: Bool { window.isVisible }

    var title: String {
        get { window.title }
        set { window.title = newValue }
    }

    func deminiaturize() {
        window.deminiaturize(nil)
    }

    func makeKeyAndOrderFront() {
        window.makeKeyAndOrderFront(nil)
    }

    func orderFrontRegardless() {
        window.orderFrontRegardless()
    }

    func setCloseHandler(_ handler: @escaping @MainActor () -> Void) {
        closeHandler = handler
    }

    func windowWillClose(_ notification: Notification) {
        closeHandler?()
    }
}

/// Owns the single Settings window for the lifetime of the menu-bar app.
///
/// A dedicated AppKit window avoids relying on a secondary SwiftUI `Settings`
/// scene from `MenuBarExtra(content:label:)`. It also lets an LSUIElement app
/// explicitly activate and focus the window after the menu popover closes.
@MainActor
final class SettingsWindowController {
    typealias WindowFactory = @MainActor () -> any SettingsWindowPresenting

    private let application: any SettingsApplicationActivating
    private let titleProvider: @MainActor () -> String
    private let onWillShow: @MainActor () -> Void
    private let windowFactory: WindowFactory
    private let refocusScheduler: any SettingsRefocusScheduling
    private var presentedWindow: (any SettingsWindowPresenting)?
    private var refocusTask: (any SettingsRefocusCancellation)?

    convenience init(
        settings: AppSettings,
        store: UsageStore,
        updater: UpdateManager,
        launchAtLoginManager: LaunchAtLoginManager
    ) {
        self.init(
            application: SystemSettingsApplicationActivator(),
            titleProvider: {
                AppLocalizer(language: settings.language).text("settings.title")
            },
            onWillShow: {
                launchAtLoginManager.refreshStatus()
            },
            windowFactory: {
                AppKitSettingsWindow(
                    rootView: SettingsView(
                        settings: settings,
                        store: store,
                        updater: updater,
                        launchAtLoginManager: launchAtLoginManager
                    )
                    .environment(\.locale, settings.language.locale)
                )
            }
        )
    }

    init(
        application: any SettingsApplicationActivating,
        titleProvider: @escaping @MainActor () -> String,
        onWillShow: @escaping @MainActor () -> Void = {},
        refocusScheduler: (any SettingsRefocusScheduling)? = nil,
        windowFactory: @escaping WindowFactory
    ) {
        self.application = application
        self.titleProvider = titleProvider
        self.onWillShow = onWillShow
        self.refocusScheduler = refocusScheduler ?? SystemSettingsRefocusScheduler()
        self.windowFactory = windowFactory
    }

    func show() {
        onWillShow()
        application.showInDock()

        let window: any SettingsWindowPresenting
        if let presentedWindow {
            window = presentedWindow
        } else {
            let createdWindow = windowFactory()
            createdWindow.setCloseHandler { [weak self] in
                self?.settingsWindowDidClose()
            }
            presentedWindow = createdWindow
            window = createdWindow
        }

        window.title = titleProvider()
        bringToFront(window)

        // MenuBarExtra closes its popover during the same mouse event. Repeat
        // focus just after that animation so its close cannot steal key state
        // from the newly presented Settings window.
        refocusTask?.cancel()
        refocusTask = refocusScheduler.schedule { [weak self] in
            guard let self,
                  let window = self.presentedWindow,
                  window.isVisible else { return }
            self.bringToFront(window)
        }
    }

    private func bringToFront(_ window: any SettingsWindowPresenting) {
        application.unhide()
        application.activate()
        if window.isMiniaturized {
            window.deminiaturize()
        }
        window.makeKeyAndOrderFront()
        window.orderFrontRegardless()
    }

    private func settingsWindowDidClose() {
        refocusTask?.cancel()
        refocusTask = nil
        application.hideFromDock()
    }
}
