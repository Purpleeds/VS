#if canImport(SwiftUI)
import SwiftUI
import UIKit

/// Per-screen orientation control. Info.plist allows portrait + both landscapes; the game screen
/// narrows this to landscape while it is visible.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        AppLog.info("Orientation mask -> \(newMask.rawValue)", category: "ui")
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { error in
            AppLog.warning("Orientation update failed: \(error.localizedDescription)", category: "ui")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

private struct OrientationLockModifier: ViewModifier {
    let mask: UIInterfaceOrientationMask

    func body(content: Content) -> some View {
        content
            .onAppear { OrientationLock.apply(mask) }
            .onDisappear { OrientationLock.apply(.allButUpsideDown) }
    }
}

extension View {
    /// Restrict orientation while this view is on screen; restores portrait + landscape on exit.
    func lockOrientation(_ mask: UIInterfaceOrientationMask) -> some View {
        modifier(OrientationLockModifier(mask: mask))
    }
}
#endif
