import Foundation

/// What `HeadphoneController` needs from the link to the headphones.
///
/// `RFCOMMTransport` is the only real one. Tests supply a fake, so the
/// controller's request and state logic can be exercised without Bluetooth.
protocol GaiaTransport: AnyObject {
    /// Called for every decoded frame, on the main thread.
    var onFrame: ((GaiaFrame) -> Void)? { get set }
    /// Called when the channel drops, on the main thread.
    var onDisconnect: (() -> Void)? { get set }
    var isOpen: Bool { get }
    var deviceName: String? { get }

    func connect(allowWake: Bool) async throws
    func send(_ frame: GaiaFrame) throws
    func disconnect()
    func releaseLink()
}

extension RFCOMMTransport: GaiaTransport {}
