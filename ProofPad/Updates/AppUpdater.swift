import Cocoa
import Sparkle

@MainActor
final class AppUpdater: NSObject {
    let updaterController: SPUStandardUpdaterController

    override init() {
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
}
