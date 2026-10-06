import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var status = "Updates are checked securely through GitHub."
    var correctionIsRunning: (() -> Bool)?
    private var updaterController: SPUStandardUpdaterController!
    private var pendingInstallation: (() -> Void)?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else {
            status = "Open the installed LocalWrite app to check for updates."
            return
        }
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).assign(to: &$canCheckForUpdates)
        updaterController.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main).assign(to: &$automaticallyChecksForUpdates)
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    func correctionDidFinish() {
        guard let install = pendingInstallation else { return }
        pendingInstallation = nil
        install()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard correctionIsRunning?() == true else { return false }
        pendingInstallation = installHandler
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "Version \(item.displayVersionString) is available."
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError? {
            status = error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)
                ? "You’re up to date." : "Couldn’t check for updates. Try again later."
        } else {
            status = "Updates are checked securely through GitHub."
        }
    }
}
