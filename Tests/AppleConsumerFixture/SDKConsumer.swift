import Foundation
import RGBSDK
import UIKit

/// An independent application target: only the public product is a dependency.
/// No gateway is contacted and no private key or wallet identifier is logged.
@main
final class SDKConsumer: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            let rate = try FeeRate(satsPerVByte: 2)
            precondition(rate.milliSatsPerVByte == 2_000)
            let seed = try SecretSeed(copying: Array(repeating: UInt8(7), count: 64))
            defer { seed.close() }
            let keys = try deriveKeysFromSeed(network: .regtest, seed: seed)
            defer { keys.close() }
            precondition(!keys.accountXpubVanilla.isEmpty)
        } catch {
            preconditionFailure("SDK consumer native boundary check failed")
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .systemBackground
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
