import AVKit
import UIKit

/// Lets the player screens rotate while the rest of the app stays in portrait.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { Self.orientationLock }
}

enum Orientation {
    static func allowRotation(_ allowed: Bool, preferLandscape: Bool = false) {
        AppDelegate.orientationLock = allowed ? .allButUpsideDown : .portrait
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        topController()?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let target: UIInterfaceOrientationMask = allowed ? (preferLandscape ? .landscapeRight : .allButUpsideDown) : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

enum AudioSession {
    static func activateForMovies() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

/// AVPlayerViewController presented modally, so it keeps its own Done button, AirPlay and
/// Picture in Picture. Reports progress while playing and when closed; while Picture in
/// Picture is showing it stays alive (in `current`) and can be restored full screen.
final class NativePlayerController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    private static var current: NativePlayerController?
    var onProgress: ((Double, Double) -> Void)?
    var onClose: (() -> Void)?
    private var observer: Any?
    private var pictureInPicture = false

    static func present(url: URL, title: String, start: Double, onProgress: @escaping (Double, Double) -> Void, onClose: @escaping () -> Void) {
        current?.finish()
        let item = AVPlayerItem(url: url)
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .commonIdentifierTitle; metadata.value = title as NSString
        item.externalMetadata = [metadata]
        let player = AVPlayer(playerItem: item)
        let controller = NativePlayerController()
        controller.player = player
        controller.onProgress = onProgress
        controller.onClose = onClose
        controller.delegate = controller
        controller.modalPresentationStyle = .fullScreen
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        current = controller
        AudioSession.activateForMovies()
        Orientation.allowRotation(true, preferLandscape: true)
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        Orientation.topController()?.present(controller, animated: true) { player.play() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in self?.report() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Orientation.allowRotation(false)
        // Going to Picture in Picture also dismisses the controller; keep playing then.
        guard !pictureInPicture, isBeingDismissed || presentingViewController == nil else { return }
        finish()
    }

    func finish() {
        guard onClose != nil else { return }
        report()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        onClose?(); onClose = nil
        if Self.current === self { Self.current = nil }
    }

    private func report() {
        guard let item = player?.currentItem else { return }
        let position = item.currentTime().seconds, duration = item.duration.seconds
        if position.isFinite, duration.isFinite, duration > 0 { onProgress?(position, duration) }
    }

    // MARK: Picture in Picture

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { pictureInPicture = true }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPicture = false
        // Closed from the floating window rather than expanded back: playback is over.
        if presentingViewController == nil { finish() }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard presentingViewController == nil, let top = Orientation.topController() else { completionHandler(true); return }
        Orientation.allowRotation(true, preferLandscape: true)
        top.present(self, animated: true) { completionHandler(true) }
    }
}
