//
//  Resources.swift
//  Sidekick
//
//  Created by Bean John on 10/6/24.
//

import Foundation
import FSKit_macOS
import OSLog
import SimilaritySearchKit
import SimilaritySearchKitDistilbert
import SwiftUI

/// An object that manages a expert's resources
public struct Resources: Identifiable, Codable, Hashable, Sendable {
    
    /// A `Logger` object for ``Resources`` objects
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Resources.self)
    )
    
    /// Stored property for `Identifiable` conformance
    public var id: UUID = UUID()
    
    /// An array of all resources associated with this expert of type  ``Resource``
    public var resources: [Resource] = []
    
    /// A URL of the expert's index directory of type `URL`
    public var indexUrl: URL {
        return Settings
            .containerUrl
            .appendingPathComponent("Resources")
            .appendingPathComponent(self.id.uuidString)
    }
    
    /// The ``Status`` of the resource
    public var status: Status? = nil
    
    public enum Status: CaseIterable, Codable, Sendable {
        case indexing
        case ready
    }
    
    /// Whether Graph RAG is enabled for this expert's resources
    public var useGraphRAG: Bool = false
    
    /// The status of graph indexing
    public var graphStatus: GraphStatus? = nil
    
    /// Progress information for graph indexing
    public var graphProgress: GraphProgress? = nil
    
    public enum GraphStatus: CaseIterable, Codable, Sendable {
        case building
        case ready
        case error
    }
    
    /// Represents progress when building graph indexes
    public struct GraphProgress: Codable, Hashable, Sendable {
        public var percentComplete: Double
        public var stagePercentComplete: Double?
        public var stage: String?
        public var stageIdentifier: String?
        
        public init(
            percentComplete: Double,
            stagePercentComplete: Double? = nil,
            stage: String? = nil,
            stageIdentifier: String? = nil
        ) {
            self.percentComplete = percentComplete
            self.stagePercentComplete = stagePercentComplete
            self.stage = stage
            self.stageIdentifier = stageIdentifier
        }
        
        enum CodingKeys: String, CodingKey {
            case percentComplete
            case stagePercentComplete
            case stage
            case stageIdentifier
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.percentComplete = try container.decode(Double.self, forKey: .percentComplete)
            self.stagePercentComplete = try container.decodeIfPresent(Double.self, forKey: .stagePercentComplete)
            self.stage = try container.decodeIfPresent(String.self, forKey: .stage)
            self.stageIdentifier = try container.decodeIfPresent(String.self, forKey: .stageIdentifier)
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(percentComplete, forKey: .percentComplete)
            try container.encodeIfPresent(stagePercentComplete, forKey: .stagePercentComplete)
            try container.encodeIfPresent(stage, forKey: .stage)
            try container.encodeIfPresent(stageIdentifier, forKey: .stageIdentifier)
        }
    }
    
    // MARK: - Initialization
    
    /// Default initializer
    public init() {}
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case id
        case resources
        case status
        case useGraphRAG
        case graphStatus
        case graphProgress
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        resources = try container.decode([Resource].self, forKey: .resources)
        status = try container.decodeIfPresent(Status.self, forKey: .status)
        
        // Provide default values for new properties to support existing saved data
        useGraphRAG = try container.decodeIfPresent(Bool.self, forKey: .useGraphRAG) ?? false
        graphStatus = try container.decodeIfPresent(GraphStatus.self, forKey: .graphStatus)
        graphProgress = try container.decodeIfPresent(GraphProgress.self, forKey: .graphProgress)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(resources, forKey: .resources)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(useGraphRAG, forKey: .useGraphRAG)
        try container.encodeIfPresent(graphStatus, forKey: .graphStatus)
        try container.encodeIfPresent(graphProgress, forKey: .graphProgress)
    }
    
    /// Function to load a similarity index of type `SimilarityIndex`, must cache after initial load to improve performance
    /// - Returns: Returns a similarity index of type `SimilarityIndex`
    public func loadIndex() async -> SimilarityIndex {
        let startTime: Date = .now
        // Init index
        let similarityIndex: SimilarityIndex = await SimilarityIndex(
            model: DistilbertEmbeddings(),
            metric: CosineSimilarity()
        )
        // Load items
        for resource in self.resources {
            let indexItems: [IndexItem] = await resource.getIndexItems(
                resourcesDirUrl: self.indexUrl
            )
            similarityIndex.indexItems += indexItems
        }
        print("Loaded index in \(Date.now.timeIntervalSince(startTime)) seconds.")
        // Return similarity index
        return similarityIndex
    }
    
    /// Function to update resources index.
    ///
    /// Phase 3 of the SwiftData migration moved the implementation
    /// into ``RAGIndexingService``; this wrapper preserves the
    /// previous call-site API by allocating a transient service
    /// instance.
    @MainActor
    public mutating func updateResourcesIndex(
        expertName: String,
        progressUpdate: (@Sendable (GraphProgress) -> Void)? = nil
    ) async {
        let service = RAGIndexingService()
        self = await service.updateResourcesIndex(
            in: self,
            expertName: expertName,
            progressUpdate: progressUpdate
        )
    }
    
    /// Function to load knowledge graph index
    /// - Returns: The merged knowledge graph for all resources
    public func loadGraphIndex() async -> KnowledgeGraph? {
        guard self.useGraphRAG else {
            return nil
        }
        
        let startTime: Date = .now
        let dbPath = self.indexUrl.appendingPathComponent("graph.sqlite").path
        
        do {
            let database = try GraphDatabase(dbPath: dbPath)
            
            // Create a merged graph
            let mergedGraph = KnowledgeGraph(resourceId: self.id)
            
            // Load graphs for each resource
            for resource in self.resources {
                do {
                    let graph = try database.loadGraph(resourceId: resource.id)
                    mergedGraph.merge(graph)
                } catch {
                    Self.logger.warning("Failed to load graph for resource \(resource.id): \(error.localizedDescription)")
                }
            }
            
            Self.logger.info("Loaded knowledge graph in \(Date.now.timeIntervalSince(startTime)) seconds")
            return mergedGraph
            
        } catch {
            Self.logger.error("Failed to load knowledge graph: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Function to migrate to Graph RAG. Delegates to
    /// ``RAGIndexingService``.
    @MainActor
    public mutating func migrateToGraphRAG(
        expertName: String,
        progressUpdate: (@Sendable (GraphProgress) -> Void)? = nil
    ) async {
        let service = RAGIndexingService()
        self = await service.migrateToGraphRAG(
            in: self,
            expertName: expertName,
            progressUpdate: progressUpdate
        )
    }
    
    /// Function to initialize directory for the resources's index
    public mutating func setup() async {
        // Make directory
        do {
            try FileManager.default.createDirectory(
                at: self.indexUrl,
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Failed to create directory for resources index: \(error, privacy: .public)")
        }
    }
    
    
    /// Function to add a resource without reindexing
    @MainActor
    public mutating func addResource(_ resource: Resource) {
        if self.resources.map(\.url).contains(resource.url) { return }
        Self.logger.notice("Adding resource \(resource.url, privacy: .public)")
        self.resources.append(resource)
    }
    
    /// Function to add multiple resources without reindexing
    @MainActor
    public mutating func addResources(_ resources: [Resource]) {
        for resource in resources {
            if self.resources.map(\.url).contains(resource.url) {
                continue
            }
            Self.logger.notice("Adding resource \(resource.url, privacy: .public)")
            self.resources.append(resource)
        }
    }
    
    /// Function to remove a resource without reindexing
    @MainActor
    public mutating func removeResource(_ resource: Resource) {
        for index in self.resources.indices  {
            if self.resources[index].id == resource.id {
                self.resources[index].deleteDirectory(
                    resourcesDirUrl: self.indexUrl
                )
                self.resources.remove(at: index)
                Self.logger.notice("Removing resource \(resource.url, privacy: .public)")
                break
            }
        }
    }
    
    /// Function to show the resources's index directory in Finder
    public func showIndexDirectory() async {
        await MainActor.run {
            FileManager.showItemInFinder(url: self.indexUrl)
        }
    }
    
}

// Graph stage identifier helpers now live in
// ``RAGIndexingService.swift`` since they are an implementation
// detail of the indexing pipeline.
