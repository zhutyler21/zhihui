import AppKit
import AVFoundation
import CoreGraphics

@MainActor struct SystemSetupPermissions: SetupPermissionService {
    func read() -> SetupPermissions {
        let microphone: SetupAuthorization
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .authorized
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        case .notDetermined: microphone = .needsApproval
        @unknown default: microphone = .needsApproval
        }
        return SetupPermissions(microphone: microphone,
                                systemAudio: CGPreflightScreenCaptureAccess() ? .authorized : .needsApproval)
    }
    func request(_ permission: SetupPermission) async {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .denied: _ = openSettings(permission)
            case .authorized, .restricted: break
            @unknown default: break
            }
        case .systemAudio:
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        }
    }
    func openSettings(_ permission: SetupPermission) -> Bool {
        let pane = permission == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return false }
        return NSWorkspace.shared.open(url)
    }
}
