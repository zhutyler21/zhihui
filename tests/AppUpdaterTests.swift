import Foundation
import AppKit
import Sparkle

@main struct AppUpdaterTests {
    @MainActor static func main() throws {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let driver = controller.updater
        let updater = AppUpdater(isAvailable: true)
        precondition(updater.responds(to: NSSelectorFromString("updater:didFinishUpdateCycleForUpdateCheck:error:")))
        precondition(updater.responds(to: NSSelectorFromString("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")))
        var busy = true
        updater.interruptionReason = { busy ? "合成录音尚未保存" : nil }
        do {
            try updater.updater(driver, mayPerform: .updates)
            fatalError("Busy update check accepted")
        } catch { precondition(error.localizedDescription == "合成录音尚未保存") }
        busy = false
        try updater.updater(driver, mayPerform: .updates)
        // Synthetic metadata only; no update installation or meeting access.
        let item = SUAppcastItem(dictionary: ["title": "Synthetic", "sparkle:version": "22",
            "enclosure": ["url": "https://example.invalid/update.zip", "sparkle:version": "22"]])!
        var installs = 0
        precondition(!updater.updater(driver, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installs += 1 }))
        busy = true
        precondition(updater.updater(driver, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installs += 1 }))
        precondition(updater.deferredInstallation)
        updater.installDeferredUpdate()
        precondition(installs == 0 && updater.deferredInstallation)
        busy = false
        updater.installDeferredUpdate()
        precondition(installs == 1 && !updater.deferredInstallation)
        updater.installDeferredUpdate()
        precondition(installs == 1)
        updater.updater(driver, didFinishUpdateCycleFor: .updates,
                        error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        precondition(updater.status == "当前已是最新版本。")
        updater.updater(driver, didFinishUpdateCycleFor: .updates,
                        error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        precondition(updater.status.contains("重试"))
        busy = true
        precondition(updater.updater(driver, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { installs += 1 }))
        updater.updater(driver, didFinishUpdateCycleFor: .updates,
                        error: NSError(domain: SUSparkleErrorDomain, code: 4005))
        precondition(!updater.deferredInstallation && !updater.showsDeferredNotice)
        busy = false
        updater.installDeferredUpdate()
        precondition(installs == 1)
        let development = AppUpdater(isAvailable: false)
        development.start()
        development.setAutomaticallyChecks(true)
        development.checkForUpdates()
        precondition(!development.canCheckForUpdates && !development.automaticallyChecks)
        print("PASS update busy-check, download/recording race, deferred install, repeat install, no-update, network error, development opt-out")
    }
}
