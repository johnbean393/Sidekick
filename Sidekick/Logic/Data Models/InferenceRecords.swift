//
//  InferenceRecords.swift
//  Sidekick
//
//  Created by John Bean on 5/20/25.
//
//  Persistence façade for inference usage records. Records live in
//  SwiftData (see ``InferenceRecordEntity``); this file exposes the
//  small `record(_:)` helper used by the inference path to append a
//  row, along with the value-type bridging extension.
//

import Foundation
import OSLog
import SwiftData

/// Namespace for the static helpers used by the inference path to
/// persist usage records.
@MainActor
public enum InferenceRecords {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "InferenceRecords"
    )

    /// Persists a single inference record into SwiftData. Hops to
    /// the main actor (where the shared container lives) before
    /// inserting; the write is local to this single row so the cost
    /// is negligible.
    public static func record(_ record: InferenceRecord) {
        let context = ModelContext(PersistenceController.shared.container)
        context.insert(
            InferenceRecordEntity(
                id: record.id,
                name: record.name,
                startTime: record.startTime,
                endTime: record.endTime,
                typeRaw: record.type.rawValue,
                endpointString: record.endpoint?.absoluteString,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                tokensPerSecond: record.tokensPerSecond
            )
        )
        do {
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to persist inference record: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

// MARK: - Bridging `InferenceRecordEntity` <-> `InferenceRecord`

extension InferenceRecord {
    /// Hydrate a value-type ``InferenceRecord`` from a SwiftData row.
    init(entity: InferenceRecordEntity) {
        self.init(
            id: entity.id,
            name: entity.name,
            startTime: entity.startTime,
            endTime: entity.endTime,
            type: InferenceRecord.UsageType(rawValue: entity.typeRaw) ?? .chatCompletions,
            endpoint: entity.endpointString.flatMap(URL.init(string:)),
            inputTokens: entity.inputTokens,
            outputTokens: entity.outputTokens,
            tokensPerSecond: entity.tokensPerSecond
        )
    }
}
