import Foundation

/// One reply shared by audio readiness, timeout and cancellation. No audio I/O
/// under the lock. Cancellation may win before continuation installation.
final class AudioPreparationReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: DispatchWorkItem?

    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }

    @discardableResult
    func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock(); continuation.resume(returning: result); return false
        }
        precondition(self.continuation == nil)
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func arm(_ work: DispatchWorkItem) {
        lock.lock()
        if result == nil { timeout = work; lock.unlock() }
        else { lock.unlock(); work.cancel() }
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let reply = continuation; continuation = nil
        let timer = timeout; timeout = nil
        lock.unlock()
        timer?.cancel()
        reply?.resume(returning: value)
    }
}
