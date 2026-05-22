//
//  InferenceRecords.swift
//  Sidekick
//
//  Created by John Bean on 5/20/25.
//
//  Phase 2 of the SwiftData migration replaces the previous
//  ``InferenceRecords`` `ObservableObject` singleton with this
//  much smaller façade. Records now live entirely in SwiftData
//  (see ``InferenceRecordEntity``); this file exposes:
//    * `InferenceRecordsState` – an `@Observable` UI state holder
//      that lives in ``DashboardView``.
//    * `InferenceRecords.record(_:)` – a static helper used by the
//      inference path to append a row.
//    * The aggregation/formatting helpers (`Timeframe`, `ModelUse`,
//      `IntervalUse`, etc.) that the dashboard view consumes.
//

import Charts
import Foundation
import OSLog
import Observation
import SwiftData
import SwiftUI

/// UI-only state for the inference dashboard. Holds picker state
/// (timeframe, type, model) and the row-selection set. The view
/// owns this directly with `@State`; SwiftData rows are pulled via
/// `@Query` inside ``DashboardView`` itself.
@MainActor
@Observable
public final class InferenceRecordsState {

    /// The selected record type filter.
    public var selectedType: InferenceRecord.UsageType = .chatCompletions

    /// Selected row IDs in the dashboard table.
    public var selections = Set<InferenceRecord.ID>()

    /// The currently selected model filter (`nil` means "all").
    public var selectedModel: String? = nil

    /// The currently selected timeframe.
    public var selectedTimeframe: InferenceRecords.Timeframe = .today

    public init() {}
}

/// Namespace for the legacy `InferenceRecords` API plus the static
/// helpers used outside ``DashboardView``.
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

    // MARK: - Dashboard aggregation helpers

    /// Returns the subset of `records` matching the picker filters
    /// in ``InferenceRecordsState``, with timeframe and (optional)
    /// model restrictions applied. Selections override the broader
    /// filter when non-empty.
    public static func filtered(
        records: [InferenceRecord],
        state: InferenceRecordsState
    ) -> [InferenceRecord] {
        var pool = records.filter { $0.type == state.selectedType }
        if !state.selections.isEmpty {
            pool = pool.filter { state.selections.contains($0.id) }
        }
        let timely = pool.filter {
            state.selectedTimeframe.range.contains($0.startTime)
                || state.selectedTimeframe.range.contains($0.endTime)
        }
        if let model = state.selectedModel {
            return timely.filter { $0.name == model }
        }
        return timely
    }

    /// Returns the records that appear in the dashboard table
    /// (timeframe + model filter, ignoring the selection set).
    public static func displayed(
        records: [InferenceRecord],
        state: InferenceRecordsState
    ) -> [InferenceRecord] {
        let typeRecords = records.filter { $0.type == state.selectedType }
        let timely = typeRecords.filter {
            state.selectedTimeframe.range.contains($0.startTime)
                || state.selectedTimeframe.range.contains($0.endTime)
        }
        if let model = state.selectedModel {
            return timely.filter { $0.name == model }
        }
        return timely
    }

    /// All distinct model names present in the type-filtered set.
    public static func models(
        records: [InferenceRecord],
        state: InferenceRecordsState
    ) -> [String] {
        Set(records.filter { $0.type == state.selectedType }.map(\.name)).sorted()
    }

    /// Grouped token/usage stats keyed by the bucket granularity of
    /// the currently selected timeframe.
    public static func intervalUsage(
        records: [InferenceRecord],
        state: InferenceRecordsState
    ) -> [IntervalUse] {
        let calendar = Calendar.current
        let timeframe = state.selectedTimeframe
        let pool = filtered(records: records, state: state)
        let grouping: (Date) -> Date = { date in
            switch timeframe {
                case .today:
                    return calendar.dateInterval(of: .hour, for: date)!.start
                case .thisWeek, .thisMonth:
                    return calendar.startOfDay(for: date)
                case .thisYear:
                    let components = calendar.dateComponents([.year, .month], from: date)
                    return calendar.date(from: components)!
                case .allTime:
                    let components = calendar.dateComponents([.year], from: date)
                    return calendar.date(from: components)!
            }
        }
        let grouped = Dictionary(grouping: pool) { grouping($0.startTime) }
        let formatter = DateFormatter()
        switch timeframe {
            case .today:
                formatter.dateFormat = "ha"
            case .thisWeek, .thisMonth:
                formatter.dateFormat = "MMM d"
            case .thisYear:
                formatter.dateFormat = "MMMM"
            case .allTime:
                formatter.dateFormat = "yyyy"
        }
        let usageData = grouped.map { (groupDate, rows) -> [IntervalUse] in
            let uses = rows.count
            let inputTokens = rows.reduce(0) { $0 + $1.inputTokens }
            let outputTokens = rows.reduce(0) { $0 + $1.outputTokens }
            let description = formatter.string(from: groupDate)
            return [
                IntervalUse(
                    date: groupDate,
                    description: description,
                    uses: uses,
                    tokens: inputTokens,
                    type: .input
                ),
                IntervalUse(
                    date: groupDate,
                    description: description,
                    uses: uses,
                    tokens: outputTokens,
                    type: .output
                )
            ]
        }
        return usageData
            .flatMap { $0 }
            .sorted { lhs, rhs in
                let cal = Calendar.current
                let lhsValue = cal.component(timeframe.calendarComponent, from: lhs.date)
                let rhsValue = cal.component(timeframe.calendarComponent, from: rhs.date)
                return lhsValue < rhsValue
            }
    }

    /// Per-model totals used by the dashboard's stacked bar chart.
    public static func modelUsage(
        records: [InferenceRecord],
        state: InferenceRecordsState
    ) -> [ModelUse] {
        let availableModels = models(records: records, state: state)
        let pool = filtered(records: records, state: state)
        let perModel: [(totalTokens: Int, uses: [ModelUse])] = availableModels.map { model in
            let rows = pool.filter { $0.name == model }
            let inputs = rows.map(\.inputTokens).reduce(0, +)
            let outputs = rows.map(\.outputTokens).reduce(0, +)
            return (
                inputs + outputs,
                [
                    ModelUse(model: model, tokens: inputs, type: .input),
                    ModelUse(model: model, tokens: outputs, type: .output)
                ]
            )
        }
        return perModel
            .sorted(by: \.totalTokens)
            .flatMap { $0.uses }
            .filter { $0.tokens > 0 }
    }

    /// Removes the given record from the SwiftData store. Logs and
    /// swallows failures.
    public static func delete(_ record: InferenceRecord) {
        let targetId = record.id
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<InferenceRecordEntity>(
                predicate: #Predicate { $0.id == targetId }
            )
            if let row = try context.fetch(descriptor).first {
                context.delete(row)
                try context.save()
            }
        } catch {
            Self.logger.error(
                "Failed to delete inference record: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Public sub-types

    public enum Timeframe: CaseIterable {

        case today
        case thisWeek
        case thisMonth
        case thisYear
        case allTime

        var description: String {
            switch self {
                case .today:
                    return String(localized: "Today")
                case .thisWeek:
                    return String(localized: "This Week")
                case .thisMonth:
                    return String(localized: "This Month")
                case .thisYear:
                    return String(localized: "This Year")
                case .allTime:
                    return String(localized: "All Time")
            }
        }

        var calendarComponent: Calendar.Component {
            switch self {
                case .today:
                    return .hour
                case .thisWeek, .thisMonth:
                    return .day
                case .thisYear:
                    return .month
                case .allTime:
                    return .year
            }
        }

        private var startDate: Date {
            switch self {
                case .today:
                    return Date.now.oneDayAgo
                case .thisWeek:
                    return Date.now.oneWeekAgo
                case .thisMonth:
                    return Date.now.oneMonthAgo
                case .thisYear:
                    return Date.now.oneMonthAgo
                case .allTime:
                    return Date.distantPast
            }
        }

        var range: ClosedRange<Date> {
            return self.startDate...Date.now
        }
    }

    public struct IntervalUse: Identifiable {

        public var id: String { date.ISO8601Format() + "-" + type.rawValue }

        public var date: Date
        public var description: String

        public var uses: Int
        public var tokens: Int
        public var type: TokenType
    }

    public struct ModelUse: Identifiable {

        public var id: String { model + "-" + type.rawValue }

        public var model: String
        public var tokens: Int
        public var type: TokenType
    }

    public enum TokenType: String, CaseIterable, Plottable {
        case input, output
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
