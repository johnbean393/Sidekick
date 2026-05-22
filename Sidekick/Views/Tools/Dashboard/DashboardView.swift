//
//  DashboardView.swift
//  Sidekick
//
//  Created by John Bean on 5/20/25.
//

import Charts
import SwiftData
import SwiftUI

struct DashboardView: View {

    @Query(sort: \InferenceRecordEntity.startTime, order: .reverse)
    private var recordRows: [InferenceRecordEntity]

    @State private var state: InferenceRecordsState = .init()

    private static let dateFormatter: Date.FormatStyle = .dateTime

    private var records: [InferenceRecord] {
        recordRows.map { InferenceRecord(entity: $0) }
    }

    private var filteredRecords: [InferenceRecord] {
        InferenceRecords.filtered(records: records, state: state)
    }

    private var displayedRecords: [InferenceRecord] {
        InferenceRecords.displayed(records: records, state: state)
    }

    private var availableModels: [String] {
        InferenceRecords.models(records: records, state: state)
    }

    private var intervalUsage: [InferenceRecords.IntervalUse] {
        InferenceRecords.intervalUsage(records: records, state: state)
    }

    private var modelUsage: [InferenceRecords.ModelUse] {
        InferenceRecords.modelUsage(records: records, state: state)
    }

    var totalTokens: Int {
        filteredRecords.reduce(0) { $0 + $1.totalTokens }
    }

    var totalInputTokens: Int {
        filteredRecords.reduce(0) { $0 + $1.inputTokens }
    }

    var totalOutputTokens: Int {
        filteredRecords.reduce(0) { $0 + $1.outputTokens }
    }

    var totalUsage: Int {
        filteredRecords.count
    }

    var timeframeDescription: String {
        if state.selections.isEmpty {
            return " " + state.selectedTimeframe.description.lowercased()
        } else {
            return ""
        }
    }

    var body: some View {
        @Bindable var state = self.state
        VStack {
            stats
                .frame(minHeight: 320)
            table
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                self.typePicker
            }
            ToolbarItemGroup(placement: .primaryAction) {
                self.modelPicker
                self.timeframePicker
            }
        }
        .navigationTitle(Text("Dashboard"))
    }

    var stats: some View {
        ScrollView(.horizontal) {
            HStack {
                self.tokenUsage
                self.tokenChart
                    .frame(minWidth: 400)
                self.requestChart
                    .frame(minWidth: 400)
                self.modelChart
                    .frame(minWidth: 400)
            }
            .padding([.vertical, .leading], 10)
        }
        .scrollIndicators(.never)
    }

    var tokenUsage: some View {
        VStack {
            Text(String(self.totalTokens))
                .font(.system(size: 60))
                .fontDesign(.serif)
                .fontWeight(.heavy)
                .contentTransition(.numericText(value: Double(self.totalTokens)))
            Text("tokens used\(self.timeframeDescription)")
                .font(.body)
                .contentTransition(.numericText())
            VStack {
                HStack {
                    Text("\(self.totalInputTokens) input")
                        .contentTransition(.numericText(value: Double(self.totalInputTokens)))
                    Text("\(self.totalOutputTokens) output")
                        .contentTransition(.numericText(value: Double(self.totalOutputTokens)))
                }
                Text("\(self.totalUsage) uses")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
        }
        .padding(.horizontal, 30)
        .background {
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.groupBoxBackground)
                .frame(height: 300)
        }
    }

    var tokenChart: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Tokens")
                .font(.title2)
                .bold()
            Chart(self.intervalUsage) { usage in
                BarMark(
                    x: .value("Date", usage.description),
                    y: .value("Tokens", usage.tokens)
                )
                .foregroundStyle(by: .value("Type", usage.type.rawValue.capitalized))
            }
        }
        .frame(maxWidth: 300, maxHeight: 280)
        .padding(.horizontal, 30)
        .background {
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.groupBoxBackground)
                .frame(height: 300)
        }
    }

    var requestChart: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Usage")
                .font(.title2)
                .bold()
            Chart(self.intervalUsage) { usage in
                BarMark(
                    x: .value("Date", usage.description),
                    y: .value("Uses", usage.uses)
                )
            }
        }
        .frame(maxWidth: 300, maxHeight: 280)
        .padding(.horizontal, 30)
        .background {
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.groupBoxBackground)
                .frame(height: 300)
        }
    }

    var modelChart: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Models")
                .font(.title2)
                .bold()
            Chart(self.modelUsage) { usage in
                BarMark(
                    x: .value("Model", usage.model),
                    y: .value("Tokens", usage.tokens)
                )
                .foregroundStyle(by: .value("Type", usage.type.rawValue.capitalized))
            }
        }
        .frame(maxWidth: 300, maxHeight: 280)
        .padding(.horizontal, 30)
        .background {
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.groupBoxBackground)
                .frame(height: 300)
        }
    }

    var table: some View {
        @Bindable var state = self.state
        return Table(
            self.displayedRecords,
            selection: $state.selections
        ) {
            TableColumn("Start Time") { record in
                Text(record.startTime.formatted(Self.dateFormatter))
            }
            TableColumn("End Time") { record in
                Text(record.endTime.formatted(Self.dateFormatter))
            }
            TableColumn("Duration") { record in
                DurationCell(duration: Double(record.duration))
            }
            TableColumn("Model") { record in
                ModelCell(name: record.name, isRemote: record.usedRemoteServer)
            }
            TableColumn("Type") { record in
                Text(record.type.description)
            }
            TableColumn("Input Tokens") { record in
                Text(verbatim: String(record.inputTokens))
            }
            TableColumn("Output Tokens") { record in
                Text(verbatim: String(record.outputTokens))
            }
            TableColumn("Total Tokens") { record in
                Text(verbatim: String(record.totalTokens))
            }
            TableColumn("Speed (t/s)") { record in
                SpeedCell(speed: record.tokensPerSecond)
            }
        }
    }

    var typePicker: some View {
        @Bindable var state = self.state
        return Picker(selection: $state.selectedType.animation(.linear)) {
            ForEach(InferenceRecord.UsageType.allCases, id: \.self) { type in
                Text(type.description).tag(type)
            }
        }
        .pickerStyle(.segmented)
    }

    var modelPicker: some View {
        @Bindable var state = self.state
        return Picker(selection: $state.selectedModel.animation(.linear)) {
            Text("All Models").tag(String?(nil))
            ForEach(self.availableModels, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .pickerStyle(.menu)
    }

    var timeframePicker: some View {
        @Bindable var state = self.state
        return Picker(selection: $state.selectedTimeframe.animation(.linear)) {
            ForEach(InferenceRecords.Timeframe.allCases, id: \.self) { timeframe in
                Text(timeframe.description).tag(timeframe)
            }
        }
        .pickerStyle(.menu)
    }

}

// MARK: - Optimized Cell Views

private struct DurationCell: View, Equatable {
    let duration: Double

    var body: some View {
        Text(verbatim: String(format: "%.1f", duration) + " s")
    }
}

private struct SpeedCell: View, Equatable {
    let speed: Double

    var body: some View {
        Text(verbatim: String(format: "%.1f", speed) + " t/s")
    }
}

private struct ModelCell: View, Equatable {
    let name: String
    let isRemote: Bool

    private var indicatorColor: Color {
        isRemote ? .blue : .green
    }

    private var inferenceType: String {
        isRemote ? String(localized: "Remote Inference") : String(localized: "Local Inference")
    }

    var body: some View {
        HStack(spacing: 6) {
            PopoverButton {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 10, height: 10)
            } content: {
                Text(inferenceType)
                    .padding(7)
            }
            .buttonStyle(.plain)
            Text(name)
        }
    }
}

#Preview {
    DashboardView()
}
