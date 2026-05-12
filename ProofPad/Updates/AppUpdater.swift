import Cocoa
import OSLog
import Sparkle

@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    let updaterController: SPUStandardUpdaterController
    private let delegate: SparkleUpdateDelegate

    private override init() {
        let delegate = SparkleUpdateDelegate()
        self.delegate = delegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
        super.init()
    }

    func start() {
        updaterController.startUpdater()
    }

    func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
}

private final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ken.proofpad",
                                category: "updates")

    func standardUserDriverAllowsMinimizableStatusWindow() -> Bool {
        false
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        logger.info("Sparkle will relaunch ProofPad after installing an update.")
    }

    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        logger.info("Sparkle scheduled an update for quit; installing it immediately.")
        DispatchQueue.main.async {
            immediateInstallHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        logger.error("Sparkle update aborted: \(error.localizedDescription, privacy: .public)")
    }
}
