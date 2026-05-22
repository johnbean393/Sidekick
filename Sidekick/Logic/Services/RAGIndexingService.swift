//
//  RAGIndexingService.swift
//  Sidekick
//
//  Phase 3 of the SwiftData migration extracts the long-running
//  RAG indexing and Graph-RAG building pipelines out of the
//  ``Resources`` value type. The service is `@Observable`, holds no
//  global state of its own, and is intended to be created on demand
//  by callers (``Expert+RAG``, ``ExpertEditorView``, etc.) for the
//  duration of a single indexing run.
//
//  ``Resources`` keeps the lightweight read-side helpers
//  (`loadIndex`, `loadGraphIndex`, `addResource`, ...) so the bulk
//  of the call sites stay untouched. Only the heavy lifting has
//  moved into this file.
//

import Foundation
import Observation
import OSLog
import SimilaritySearchKit
import SimilaritySearchKitDistilbert
import SwiftUI

@MainActor
@Observable
public final class RAGIndexingService {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "RAGIndexingService"
    )

    /// Live indexing progress for the in-flight run (Graph RAG only).
    public private(set) var progress: Resources.GraphProgress?

    /// Whether the service is currently busy indexing.
    public private(set) var isIndexing: Bool = false

    public init() {}

    /// Re-indexes every resource in the supplied ``Resources`` bundle
    /// and returns the updated bundle. Mirrors the previous
    /// `Resources.updateResourcesIndex(expertName:)` API.
    @discardableResult
    public func updateResourcesIndex(
        in resources: Resources,
        expertName: String,
        progressUpdate: (@Sendable (Resources.GraphProgress) -> Void)? = nil
    ) async -> Resources {
        var resources = resources
        let taskId: UUID = UUID()
        let taskName: String = String(localized: "Updating resource index for expert \"\(expertName)\"")
        withAnimation(.linear(duration: 0.3)) {
            LengthyTasksController.shared.addTask(id: taskId, task: taskName)
        }
        self.isIndexing = true
        resources.status = .indexing
        if resources.useGraphRAG {
            let initialProgress = Resources.GraphProgress(
                percentComplete: 0.0,
                stagePercentComplete: 0.0,
                stage: String(localized: "Preparing resources"),
                stageIdentifier: String(localized: "Preparing resources")
            )
            resources.graphStatus = .building
            resources.graphProgress = initialProgress
            self.progress = initialProgress
            progressUpdate?(initialProgress)
        } else {
            resources.graphProgress = nil
            self.progress = nil
        }
        let useGraphRAG: Bool = resources.useGraphRAG
        Self.logger.notice(
            "Updating resource index for expert \"\(expertName, privacy: .public)\" (Graph RAG: \(useGraphRAG ? "Enabled" : "Disabled"))"
        )

        var resourceList: [Resource] = resources.resources
        let indexUrl: URL = resources.indexUrl
        var totalEntities: Int = 0
        var allGraphsSucceeded = true

        let totalResourceCount = max(resourceList.count, 1)
        var resourceWorkUnits: [Int] = []
        for index in resourceList.indices {
            var resource = resourceList[index]
            let units = resource.workloadEstimate(useGraphRAG: useGraphRAG)
            resourceWorkUnits.append(units)
            resourceList[index] = resource
        }
        let totalWorkUnits = max(resourceWorkUnits.reduce(0, +), 1)
        var completedWorkUnits: Double = 0
        var latestProgress: Resources.GraphProgress? = resources.graphProgress

        for index in resourceList.indices {
            let resourceUnits = Double(resourceWorkUnits[index])
            if useGraphRAG {
                let stageDescription = String(
                    localized: "Processing resource \(index + 1) of \(totalResourceCount)"
                )
                let stageIdentifier = String(localized: "Preparing resource")
                    .graphStageIdentifier(fallback: "preparing resource")
                let overallProgress = completedWorkUnits / Double(totalWorkUnits)
                let progressValue = Resources.GraphProgress(
                    percentComplete: overallProgress,
                    stagePercentComplete: 0.0,
                    stage: stageDescription,
                    stageIdentifier: stageIdentifier
                )
                resources.graphStatus = .building
                resources.graphProgress = progressValue
                self.progress = progressValue
                progressUpdate?(progressValue)
                latestProgress = progressValue
            }

            let success = await resourceList[index].updateIndex(
                resourcesDirUrl: indexUrl,
                useGraphRAG: useGraphRAG,
                progressCallback: { update in
                    totalEntities = update.entities
                    guard useGraphRAG else { return }

                    let resourceFraction = max(0.0, min(update.fractionComplete, 1.0))
                    let overallProgress = (
                        completedWorkUnits + (resourceUnits * resourceFraction)
                    ) / Double(totalWorkUnits)
                    let clampedOverall = max(0.0, min(overallProgress, 1.0))

                    let stageDescription = update.stage.isEmpty ? String(
                        localized: "Processing resource \(index + 1) of \(totalResourceCount)"
                    ) : update.stage
                    let stageIdentifier = stageDescription.graphStageIdentifier(
                        fallback: String(localized: "Processing resource")
                    )

                    let stageProgressRaw = update.total > 0
                        ? Double(update.current) / Double(update.total)
                        : resourceFraction
                    let stageProgress = max(0.0, min(stageProgressRaw, 1.0))
                    let progressValue = Resources.GraphProgress(
                        percentComplete: clampedOverall,
                        stagePercentComplete: stageProgress,
                        stage: stageDescription,
                        stageIdentifier: stageIdentifier
                    )
                    latestProgress = progressValue
                    progressUpdate?(progressValue)
                }
            )

            if useGraphRAG && !success {
                allGraphsSucceeded = false
                Self.logger.error("Graph building failed for resource at index \(index)")
            }

            if useGraphRAG {
                completedWorkUnits += resourceUnits
            }

            if useGraphRAG, let latest = latestProgress {
                resources.graphProgress = latest
                self.progress = latest
            }
        }

        await MainActor.run {
            resources.resources = resourceList
            if resources.useGraphRAG {
                resources.graphStatus = allGraphsSucceeded ? .ready : .error
                if allGraphsSucceeded {
                    completedWorkUnits = Double(totalWorkUnits)
                    let finalProgress = Resources.GraphProgress(
                        percentComplete: 1.0,
                        stagePercentComplete: 1.0,
                        stage: String(localized: "Completed"),
                        stageIdentifier: String(localized: "Completed")
                    )
                    resources.graphProgress = finalProgress
                    self.progress = finalProgress
                    progressUpdate?(finalProgress)
                }
            } else {
                resources.graphStatus = .ready
                resources.graphProgress = nil
                self.progress = nil
            }
        }

        Self.logger.notice(
            "Updated index for resources in expert \"\(expertName, privacy: .public)\""
        )
        if resources.useGraphRAG {
            if allGraphsSucceeded {
                Self.logger.notice(
                    "Built knowledge graph with \(totalEntities) entities"
                )
            } else {
                Self.logger.error("Some knowledge graphs failed to build")
            }
            resources.graphProgress = nil
            self.progress = nil
        }

        let removedResources: [Resource] = resources.resources.filter {
            !(!$0.wasMoved || $0.isWebResource)
        }
        let removedResourcesDescription: String = removedResources.map {
            "\"\($0.name)\""
        }.joined(separator: ", ")
        if !removedResources.isEmpty {
            Task { @MainActor in
                Dialogs.showAlert(
                    title: String(localized: "Remove Resources"),
                    message: String(localized: "The resources \(removedResourcesDescription) were removed because they could not be located.")
                )
            }
        }
        await MainActor.run {
            resources.resources = resources.resources.filter { !$0.wasMoved || $0.isWebResource }
        }
        await MainActor.run {
            withAnimation(.linear(duration: 0.3)) {
                LengthyTasksController.shared.finishTask(taskId: taskId)
            }
        }
        Self.logger.notice(
            "Finished updating resource index for expert \"\(expertName, privacy: .public)\""
        )
        resources.status = .ready
        if resources.useGraphRAG {
            resources.graphStatus = .ready
        }
        self.isIndexing = false
        return resources
    }

    /// Migrates a ``Resources`` bundle to Graph RAG by enabling the
    /// flag and triggering a fresh index pass.
    @discardableResult
    public func migrateToGraphRAG(
        in resources: Resources,
        expertName: String,
        progressUpdate: (@Sendable (Resources.GraphProgress) -> Void)? = nil
    ) async -> Resources {
        var resources = resources
        resources.useGraphRAG = true
        resources.graphStatus = .building

        Self.logger.notice("Migrating expert \"\(expertName)\" to Graph RAG")
        resources = await updateResourcesIndex(
            in: resources,
            expertName: expertName,
            progressUpdate: progressUpdate
        )
        Self.logger.notice("Completed migration to Graph RAG for expert \"\(expertName)\"")
        return resources
    }
}

// MARK: - Graph Progress Helpers

extension String {

    func graphStageIdentifier(fallback: String) -> String {
        let sanitized = self.sanitizedStageIdentifier()
        if sanitized.isEmpty {
            let fallbackSanitized = fallback.sanitizedStageIdentifier()
            return fallbackSanitized.isEmpty ? fallback.lowercased() : fallbackSanitized
        }
        return sanitized
    }

    fileprivate func sanitizedStageIdentifier() -> String {
        var base = self
        let patterns = [
            "\\([^)]*\\)",
            "\\b\\d+\\/\\d+\\b",
            "\\b\\d+%\\b",
            "\\b\\d+\\b"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(base.startIndex..., in: base)
                base = regex.stringByReplacingMatches(in: base, options: [], range: range, withTemplate: "")
            }
        }
        if let whitespaceRegex = try? NSRegularExpression(pattern: "\\s+", options: []) {
            let range = NSRange(base.startIndex..., in: base)
            base = whitespaceRegex.stringByReplacingMatches(in: base, options: [], range: range, withTemplate: " ")
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return base
    }
}
