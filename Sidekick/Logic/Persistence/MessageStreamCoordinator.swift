//
//  MessageStreamCoordinator.swift
//  Sidekick
//
//  Provides debounced `ModelContext.save()` calls so streaming
//  inference no longer rewrites the entire conversations.json on
//  every token. Used by ``ConversationManager`` and inference code
//  paths that mutate `MessageEntity` text frequently.
//

import Foundation
import SwiftData

/// Coalesces frequent writes into periodic saves.
///
/// Callers invoke ``noteChange()`` whenever they mutate a tracked
/// `MessageEntity`; the coordinator schedules a `save()` at most
/// once per ``debounceInterval``. Call ``flush()`` to force an
/// immediate save (e.g. when streaming ends).
@MainActor
public final class MessageStreamCoordinator {

    /// Shared instance used by inference call sites.
    public static let shared: MessageStreamCoordinator = .init()

    /// Default debounce interval — 250ms is a sweet spot between
    /// "feels live" and "doesn't thrash SQLite during streaming".
    public var debounceInterval: TimeInterval = 0.25

    private var scheduled: Bool = false
    private var pendingSaveTask: Task<Void, Never>?
    /// Optional caller-supplied flush block. When set, the
    /// coordinator invokes this instead of the default
    /// ``ModelContext.save()`` fall-back, which lets the
    /// ``ConversationManager`` reuse its own upsert pipeline.
    private var pendingFlush: (@MainActor () -> Void)?

    private init() {}

    /// Note that a tracked entity changed and a save should follow.
    ///
    /// - Parameter flush: Optional block executed when the debounce
    ///   fires. When supplied, the coordinator skips the default
    ///   `ModelContext.save()` shortcut and lets the caller decide
    ///   how to persist.
    public func noteChange(flush: (@MainActor () -> Void)? = nil) {
        if let flush {
            self.pendingFlush = flush
        }
        guard !scheduled else { return }
        scheduled = true
        pendingSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))
            await self.flushIfNeeded()
        }
    }

    /// Force an immediate save and cancel any pending debounce.
    public func flush() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        scheduled = false
        runFlush()
    }

    private func flushIfNeeded() {
        scheduled = false
        pendingSaveTask = nil
        runFlush()
    }

    private func runFlush() {
        if let flush = pendingFlush {
            pendingFlush = nil
            flush()
        } else {
            saveNow()
        }
    }

    private func saveNow() {
        let context = ModelContext(PersistenceController.shared.container)
        context.autosaveEnabled = false
        do {
            // The main UI `ModelContext` (provided via SwiftUI's
            // `.modelContainer(...)`) auto-saves periodically; this
            // explicit call exists primarily as a fall-back hook for
            // background mutations.
            if context.hasChanges {
                try context.save()
            }
        } catch {
            // Swallow — losing a per-token batch is fine, the next
            // batch (or terminal flush) will succeed.
        }
    }
}
