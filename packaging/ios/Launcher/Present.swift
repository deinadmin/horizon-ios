import SwiftUI
import UIKit

/// The C entry point `horizon-ios-launcher` looks up: show the launcher over the game, which keeps running
/// under it at its title screen. Play dismisses it; the game's Quit Game asks for it again. `submit` is how the
/// launcher asks the game things (Bridge.swift). Called on the main thread; the presenting waits a turn of the
/// run loop, because at startup the game's view controller may not be on screen yet while its first frame is
/// being set up.
@_cdecl("horizon_launcher_present")
public func horizonLauncherPresent(_ submit: HorizonSubmit?) -> Bool {
    Bridge.submit = submit
    GameAudio.start()
    Theme.registerFonts()
    DispatchQueue.main.async { present(attempts: 20) }
    return true
}

private func present(attempts: Int) {
    guard let root = gameViewController(), root.view.window != nil else {
        // Not on screen yet: try again shortly, for a couple of seconds at most.
        if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { present(attempts: attempts - 1) }
        }
        return
    }
    // Already up: a second request (Quit Game pressed twice) changes nothing.
    if root is LauncherHostingController {
        return
    }
    let host = LauncherHostingController(rootView: AnyView(EmptyView()))
    host.rootView = AnyView(
        HomeView(onPlay: { [weak host] in
            guard let host else { return }
            let scene = host.view.window?.windowScene
            host.dismiss(animated: true) {
                // Back to the game's landscape (its own view controller allows nothing else).
                turn(scene, to: .landscape)
            }
        })
        .preferredColorScheme(.dark)
    )
    host.modalPresentationStyle = .fullScreen
    host.modalTransitionStyle = .crossDissolve
    root.present(host, animated: false) {
        turn(host.view.window?.windowScene, to: launcherOrientations)
    }
}

/// Ask the scene to turn to `orientations` now, rather than when the phone is next moved.
func turn(_ scene: UIWindowScene?, to orientations: UIInterfaceOrientationMask) {
    guard let scene else { return }
    for window in scene.windows {
        var top = window.rootViewController
        while let next = top?.presentedViewController {
            top = next
        }
        top?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
}

/// The view controller of winit's window: the one the launcher is presented from.
func gameViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
    let window = windows.first(where: \.isKeyWindow) ?? windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

/// Phones keep the compact portrait launcher; iPads follow the way the device is held.
var launcherOrientations: UIInterfaceOrientationMask {
    UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
}

func launcherPresentationOrientation() -> UIInterfaceOrientation {
    guard UIDevice.current.userInterfaceIdiom == .pad else { return .portrait }
    return gameViewController()?.view.window?.windowScene?.interfaceOrientation ?? .portrait
}
private final class LauncherHostingController: UIHostingController<AnyView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { launcherOrientations }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { launcherPresentationOrientation() }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}
