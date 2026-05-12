import Cocoa
import Sparkle

@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    let updaterController: SPUStandardUpdaterController

    private override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
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
