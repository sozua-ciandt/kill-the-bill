import XCTest
@testable import KillTheBill

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testShowReusesWindowRestoresItAndAlwaysBringsItForward() {
        let application = SpySettingsApplication()
        let window = SpySettingsWindow(isMiniaturized: true)
        let refocusScheduler = ManualSettingsRefocusScheduler()
        var factoryCallCount = 0
        var willShowCallCount = 0
        let title = SpySettingsTitle("Settings")

        let controller = SettingsWindowController(
            application: application,
            titleProvider: { title.value },
            onWillShow: { willShowCallCount += 1 },
            refocusScheduler: refocusScheduler,
            windowFactory: {
                factoryCallCount += 1
                return window
            }
        )

        controller.show()

        XCTAssertEqual(window.makeKeyAndOrderFrontCallCount, 1)
        XCTAssertEqual(window.orderFrontRegardlessCallCount, 1)
        refocusScheduler.runPending()
        XCTAssertEqual(window.makeKeyAndOrderFrontCallCount, 2)
        XCTAssertEqual(window.orderFrontRegardlessCallCount, 2)

        title.value = "Configurações"
        controller.show()
        refocusScheduler.runPending()

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(willShowCallCount, 2)
        XCTAssertEqual(application.showInDockCallCount, 2)
        XCTAssertEqual(application.hideFromDockCallCount, 0)
        XCTAssertEqual(window.title, "Configurações")
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertEqual(window.deminiaturizeCallCount, 1)
        XCTAssertEqual(application.unhideCallCount, 4)
        XCTAssertEqual(application.activateCallCount, 4)
        XCTAssertEqual(window.makeKeyAndOrderFrontCallCount, 4)
        XCTAssertEqual(window.orderFrontRegardlessCallCount, 4)
    }

    func testCloseRestoresMenuBarOnlyModeCancelsRefocusAndReusesWindow() {
        let application = SpySettingsApplication()
        let window = SpySettingsWindow(isMiniaturized: false)
        let refocusScheduler = ManualSettingsRefocusScheduler()
        var factoryCallCount = 0

        let controller = SettingsWindowController(
            application: application,
            titleProvider: { "Settings" },
            refocusScheduler: refocusScheduler,
            windowFactory: {
                factoryCallCount += 1
                return window
            }
        )

        controller.show()
        XCTAssertEqual(window.makeKeyAndOrderFrontCallCount, 1)

        window.simulateClose()
        refocusScheduler.runPending()

        XCTAssertEqual(application.showInDockCallCount, 1)
        XCTAssertEqual(application.hideFromDockCallCount, 1)
        XCTAssertEqual(window.makeKeyAndOrderFrontCallCount, 1)

        controller.show()

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(application.showInDockCallCount, 2)
        XCTAssertEqual(window.makeKeyAndOrderFrontCallCount, 2)
    }
}

@MainActor
private final class ManualSettingsRefocusCancellation: SettingsRefocusCancellation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class ManualSettingsRefocusScheduler: SettingsRefocusScheduling {
    private var pending: (
        cancellation: ManualSettingsRefocusCancellation,
        action: @MainActor () -> Void
    )?

    func schedule(
        _ action: @escaping @MainActor () -> Void
    ) -> any SettingsRefocusCancellation {
        let cancellation = ManualSettingsRefocusCancellation()
        pending = (cancellation, action)
        return cancellation
    }

    func runPending() {
        guard let pending else { return }
        self.pending = nil
        guard !pending.cancellation.isCancelled else { return }
        pending.action()
    }
}

@MainActor
private final class SpySettingsTitle {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

@MainActor
private final class SpySettingsApplication: SettingsApplicationActivating {
    private(set) var unhideCallCount = 0
    private(set) var activateCallCount = 0
    private(set) var showInDockCallCount = 0
    private(set) var hideFromDockCallCount = 0

    func unhide() {
        unhideCallCount += 1
    }

    func activate() {
        activateCallCount += 1
    }

    func showInDock() {
        showInDockCallCount += 1
    }

    func hideFromDock() {
        hideFromDockCallCount += 1
    }
}

@MainActor
private final class SpySettingsWindow: SettingsWindowPresenting {
    var isMiniaturized: Bool
    var isVisible = false
    var title = ""
    private(set) var deminiaturizeCallCount = 0
    private(set) var makeKeyAndOrderFrontCallCount = 0
    private(set) var orderFrontRegardlessCallCount = 0
    private var closeHandler: (@MainActor () -> Void)?

    init(isMiniaturized: Bool) {
        self.isMiniaturized = isMiniaturized
    }

    func deminiaturize() {
        deminiaturizeCallCount += 1
        isMiniaturized = false
    }

    func makeKeyAndOrderFront() {
        makeKeyAndOrderFrontCallCount += 1
        isVisible = true
    }

    func orderFrontRegardless() {
        orderFrontRegardlessCallCount += 1
    }

    func setCloseHandler(_ handler: @escaping @MainActor () -> Void) {
        closeHandler = handler
    }

    func simulateClose() {
        isVisible = false
        closeHandler?()
    }
}
