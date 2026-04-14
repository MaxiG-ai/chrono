import Foundation
import SwiftUI

/// Observable clock that ticks once per second. Views that display the running
/// timer observe this and the `TimelineView` API to get a refresh every second
/// without each view owning its own timer.
@Observable
@MainActor
final class LiveClock {
    private(set) var now: Date = Date()
    private var timer: Timer?

    init() {}

    func start() {
        guard timer == nil else { return }
        // Fire on the main run loop so view updates happen on the main thread.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
