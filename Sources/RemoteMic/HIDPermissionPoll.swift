import Foundation

// Adapted from upstream ade2cef + a39c4b5. Evaluate permissions once per tick.
final class HIDPermissionPoll {
    final class Subscription {
        private let lock = NSLock()
        private var owner: HIDPermissionPoll?
        private var token: UUID?

        fileprivate init(owner: HIDPermissionPoll, token: UUID) {
            self.owner = owner
            self.token = token
        }

        func cancel() {
            lock.lock()
            let owner = self.owner
            let token = self.token
            self.owner = nil
            self.token = nil
            lock.unlock()
            if let owner, let token { owner.unsubscribe(token) }
        }

        deinit { cancel() }
    }

    static let shared = HIDPermissionPoll()
    private enum TaskState {
        case idle, starting
        case running(HIDRemoteScheduledTask)
    }
    private let scheduler: HIDRemoteScheduling
    private let permissionEvaluator: () -> Bool
    private let lock = NSLock()
    private var subscribers: [UUID: (Bool) -> Void] = [:]
    private var taskState: TaskState = .idle

    init(
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        permissionEvaluator: @escaping () -> Bool = {
            HIDRemoteMonitor.isInputMonitoringGranted && KeyboardInjector.isAccessibilityTrusted
        }
    ) {
        self.scheduler = scheduler
        self.permissionEvaluator = permissionEvaluator
    }

    func subscribe(_ handler: @escaping (Bool) -> Void) -> Subscription {
        let token = UUID()
        lock.lock()
        subscribers[token] = handler
        let shouldStart: Bool
        if case .idle = taskState {
            taskState = .starting
            shouldStart = true
        } else {
            shouldStart = false
        }
        lock.unlock()
        if shouldStart { startPolling() }
        return Subscription(owner: self, token: token)
    }

    private func unsubscribe(_ token: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: token)
        let task: HIDRemoteScheduledTask?
        if subscribers.isEmpty, case .running(let running) = taskState {
            taskState = .idle
            task = running
        } else {
            task = nil
        }
        lock.unlock()
        task?.cancel()
    }

    private func startPolling() {
        let task = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds,
            repeatingEveryMilliseconds: HIDRemoteTiming.permissionPollMilliseconds
        ) { [weak self] in self?.notifySubscribers() }
        lock.lock()
        let shouldCancel = subscribers.isEmpty
        taskState = shouldCancel ? .idle : .running(task)
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    private func notifySubscribers() {
        lock.lock()
        let handlers = Array(subscribers.values)
        lock.unlock()
        guard !handlers.isEmpty else { return }
        let granted = permissionEvaluator()
        handlers.forEach { $0(granted) }
    }
}
