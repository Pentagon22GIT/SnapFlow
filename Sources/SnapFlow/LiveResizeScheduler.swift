import ApplicationServices
import Foundation

struct LiveResizeRequest {
    let stableIdentity: String
    let element: AXUIElement
    let targetFrame: CGRect
    let primaryScreenTop: CGFloat
}

final class LiveResizeScheduler {
    private let windowService: AXWindowService
    private let workerQueue = DispatchQueue(
        label: "com.snapflow.live-resize",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private var generation = 0
    private var pending: [String: LiveResizeRequest] = [:]
    private var isWorkerRunning = false
    private var stopCompletions: [() -> Void] = []

    init(windowService: AXWindowService) {
        self.windowService = windowService
    }

    func begin() -> Int {
        lock.lock()
        generation &+= 1
        pending.removeAll()
        let current = generation
        lock.unlock()
        return current
    }

    func submit(_ requests: [LiveResizeRequest], generation expectedGeneration: Int) {
        guard !requests.isEmpty else { return }
        lock.lock()
        guard generation == expectedGeneration else {
            lock.unlock()
            return
        }
        for request in requests {
            pending[request.stableIdentity] = request
        }
        let shouldStartWorker = !isWorkerRunning
        if shouldStartWorker {
            isWorkerRunning = true
        }
        lock.unlock()

        if shouldStartWorker {
            workerQueue.async { [weak self] in
                self?.drain(generation: expectedGeneration)
            }
        }
    }

    func stop(generation expectedGeneration: Int, completion: @escaping () -> Void) {
        lock.lock()
        if generation == expectedGeneration {
            generation &+= 1
            pending.removeAll()
        }
        if isWorkerRunning {
            stopCompletions.append(completion)
            lock.unlock()
            return
        }
        lock.unlock()
        DispatchQueue.main.async(execute: completion)
    }

    func cancelAll() {
        lock.lock()
        generation &+= 1
        pending.removeAll()
        lock.unlock()
    }

    private func drain(generation workerGeneration: Int) {
        while true {
            lock.lock()
            guard generation == workerGeneration else {
                finishWorkerLocked()
                return
            }
            let batch = pending.values.sorted {
                $0.stableIdentity < $1.stableIdentity
            }
            pending.removeAll()
            guard !batch.isEmpty else {
                finishWorkerLocked()
                return
            }
            lock.unlock()

            for request in batch {
                lock.lock()
                let isCurrent = generation == workerGeneration
                lock.unlock()
                guard isCurrent else { break }
                _ = windowService.setFrameLightweight(
                    request.targetFrame,
                    primaryScreenTop: request.primaryScreenTop,
                    for: request.element
                )
            }
        }
    }

    private func finishWorkerLocked() {
        let completions = stopCompletions
        stopCompletions.removeAll()
        let restartGeneration = pending.isEmpty ? nil : generation
        isWorkerRunning = restartGeneration != nil
        lock.unlock()
        if !completions.isEmpty {
            DispatchQueue.main.async {
                completions.forEach { $0() }
            }
        }
        if let restartGeneration {
            workerQueue.async { [weak self] in
                self?.drain(generation: restartGeneration)
            }
        }
    }
}
