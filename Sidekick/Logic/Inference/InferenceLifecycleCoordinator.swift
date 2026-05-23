//
//  InferenceLifecycleCoordinator.swift
//  Sidekick
//
//  Centralizes shutdown of every memory-intensive inference child process
//  (llama-server, llama-perplexity, watchdog) so that on quit / kill /
//  unexpected termination no orphaned process is left running.
//

import AppKit
import Darwin
import Foundation
import OSLog

/// Coordinates the lifecycle of every inference-related child process spawned
/// by Sidekick. Owners of such processes (``LlamaServer``,
/// ``CompletionsController``, ``DetectorViewController``, ...) must
/// register their PID through this coordinator. On normal quit the
/// coordinator runs an awaited graceful shutdown; on `SIGTERM`/`SIGINT`/
/// `SIGHUP` (e.g. `kill <pid>` or shell-initiated termination) it falls back
/// to a best-effort synchronous cleanup before the app exits.
public final class InferenceLifecycleCoordinator: @unchecked Sendable {
    
    // MARK: - Logging
    
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier ?? "Sidekick",
        category: String(describing: InferenceLifecycleCoordinator.self)
    )
    
    // MARK: - Shared Instance
    
    public static let shared: InferenceLifecycleCoordinator = .init()
    
    // MARK: - State
    
    /// Tracked child process identifiers. Protected by `lock`.
    private var trackedPIDs: Set<pid_t> = []
    private let lock: NSLock = .init()
    
    /// Hooks supplied by owners that perform an awaitable graceful shutdown.
    /// Identified by a string so they can be replaced without leaking.
    private var asyncShutdownHooks: [String: @Sendable () async -> Void] = [:]
    
    /// Dispatch sources that translate UNIX signals into Swift callbacks.
    private var signalSources: [DispatchSourceSignal] = []
    
    /// Set to `true` once a coordinated shutdown is underway so callers can
    /// avoid restarting servers or scheduling new work during teardown.
    public private(set) var isShuttingDown: Bool = false
    
    // MARK: - Init
    
    private init() {}
    
    // MARK: - PID Registry
    
    /// Register a freshly-spawned inference child process so the coordinator
    /// can terminate it on shutdown. Safe to call from any thread.
    public func register(pid: pid_t) {
        guard pid > 0 else { return }
        self.lock.lock()
        self.trackedPIDs.insert(pid)
        self.lock.unlock()
    }
    
    /// Remove a PID from the registry after it has been intentionally stopped.
    public func unregister(pid: pid_t) {
        guard pid > 0 else { return }
        self.lock.lock()
        self.trackedPIDs.remove(pid)
        self.lock.unlock()
    }
    
    /// Snapshot the currently tracked PIDs.
    public func currentPIDs() -> [pid_t] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Array(self.trackedPIDs)
    }
    
    // MARK: - Shutdown Hooks
    
    /// Register an async shutdown hook keyed by ``identifier``. Replacing a
    /// previously-registered hook with the same identifier removes the old
    /// one.
    public func registerShutdownHook(
        identifier: String,
        _ hook: @escaping @Sendable () async -> Void
    ) {
        self.lock.lock()
        self.asyncShutdownHooks[identifier] = hook
        self.lock.unlock()
    }
    
    public func unregisterShutdownHook(identifier: String) {
        self.lock.lock()
        self.asyncShutdownHooks.removeValue(forKey: identifier)
        self.lock.unlock()
    }
    
    private func currentHooks() -> [(String, @Sendable () async -> Void)] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.asyncShutdownHooks.map { ($0.key, $0.value) }
    }
    
    // MARK: - Signal Handling
    
    /// Install signal handlers that intercept `SIGTERM`, `SIGINT`, and
    /// `SIGHUP` and trigger a synchronous best-effort cleanup so that
    /// `kill <pid>`, `pkill`, terminal `Ctrl-C`, or session shutdown never
    /// leaves an orphaned `llama-server` alive.
    ///
    /// `SIGKILL` cannot be intercepted; the bundled `llama-server-watchdog`
    /// is the safety net for that case.
    public func installSignalHandlers() {
        let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
        for signo in signals {
            // Ignore the default disposition so the signal is delivered to
            // the dispatch source instead of killing the process outright.
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signo,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                Self.logger.notice(
                    "Received signal \(signo, privacy: .public); tearing down inference processes"
                )
                self?.handleTerminationSignal(signo: signo)
            }
            source.resume()
            self.signalSources.append(source)
        }
    }
    
    /// Synchronous fallback used by signal handlers. Best-effort: terminates
    /// every tracked PID with `SIGTERM`, waits briefly, then escalates to
    /// `SIGKILL`, before letting the process exit normally.
    private func handleTerminationSignal(signo: Int32) {
        self.isShuttingDown = true
        self.killAllRegisteredProcesses(gracePeriodSeconds: 2.0)
        // Re-raise with default disposition so the OS records the signal
        // exit status correctly.
        signal(signo, SIG_DFL)
        raise(signo)
    }
    
    /// Synchronously terminate every registered PID. Sends `SIGTERM`, then
    /// `SIGKILL` to anything still alive after ``gracePeriodSeconds``.
    public func killAllRegisteredProcesses(
        gracePeriodSeconds: TimeInterval = 1.5
    ) {
        let pids = self.currentPIDs()
        guard !pids.isEmpty else { return }
        for pid in pids {
            // `kill(pid, 0)` returns 0 iff the process exists; this avoids
            // spamming logs for processes that already exited.
            if kill(pid, 0) == 0 {
                _ = kill(pid, SIGTERM)
            }
        }
        let deadline = Date().addingTimeInterval(gracePeriodSeconds)
        while Date() < deadline {
            let stillAlive = pids.contains { kill($0, 0) == 0 }
            if !stillAlive { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for pid in pids where kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
        }
        self.lock.lock()
        self.trackedPIDs.removeAll()
        self.lock.unlock()
    }
    
    // MARK: - Coordinated Async Shutdown
    
    /// Run every registered async shutdown hook concurrently with a hard
    /// timeout, then sweep any process that survived. Safe to call from the
    /// main actor (``AppDelegate.applicationShouldTerminate``).
    public func shutdownAll(
        timeout: TimeInterval = 4.0
    ) async {
        self.isShuttingDown = true
        let hooks = self.currentHooks()
        Self.logger.notice(
            "Coordinated inference shutdown started (hooks: \(hooks.count, privacy: .public), tracked PIDs: \(self.currentPIDs().count, privacy: .public))"
        )
        await withTaskGroup(of: Void.self) { group in
            for (identifier, hook) in hooks {
                group.addTask {
                    await hook()
                    Self.logger.info(
                        "Shutdown hook completed: \(identifier, privacy: .public)"
                    )
                }
            }
            // Watchdog timer so a stuck hook never blocks app exit.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
            await group.waitForAll()
        }
        // Belt-and-braces: kill anything that survived the graceful pass.
        self.killAllRegisteredProcesses(gracePeriodSeconds: 1.0)
        Self.logger.notice("Coordinated inference shutdown complete")
    }
    
}
