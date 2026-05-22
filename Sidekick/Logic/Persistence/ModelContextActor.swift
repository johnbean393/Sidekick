//
//  ModelContextActor.swift
//  Sidekick
//
//  @ModelActor-backed actor used for off-main-thread bulk writes
//  against the SwiftData store. The two intended call sites are
//  the one-time legacy-JSON import (``JSONImporter``) and the
//  RAG indexing pipeline (``RAGIndexingService``), both of which
//  produce write bursts large enough that running them on the
//  ``@MainActor`` context would noticeably stall the UI.
//
//  The actor owns its own ``ModelContext``; callers send `perform`
//  closures that read/write through `self.modelContext` and the
//  framework serialises them. Saving is the caller's responsibility
//  so multiple changes can be batched into a single commit.
//

import Foundation
import SwiftData

/// Background ``ModelContext`` owner used for bulk reads/writes
/// that must not block the main thread.
@ModelActor
public actor ModelContextActor {

    /// Runs ``body`` on the actor with access to the underlying
    /// ``ModelContext``. Throws are propagated to the caller; saving
    /// is the caller's responsibility so multiple operations can be
    /// batched into a single commit.
    public func perform<Result: Sendable>(
        _ body: @Sendable (ModelContext) throws -> Result
    ) throws -> Result {
        try body(modelContext)
    }

    /// Convenience wrapper that calls ``perform`` and then saves the
    /// context if any change actually happened. Useful for one-shot
    /// bulk inserts (the JSON importer's path).
    public func performAndSave<Result: Sendable>(
        _ body: @Sendable (ModelContext) throws -> Result
    ) throws -> Result {
        let result = try body(modelContext)
        if modelContext.hasChanges {
            try modelContext.save()
        }
        return result
    }
}
