//
//  ExpertFunctions.swift
//  Sidekick
//
//  Created by John Bean on 5/14/25.
//

import Foundation
import SimilaritySearchKit

public class ExpertFunctions {
    
    static var functions: [AnyFunctionBox] = [
        ExpertFunctions.queryVectorDatabase
    ]
    
    /// A function to query a expert vector database
    static let queryVectorDatabase = Function<QueryVectorDatabaseParams, String>(
        name: "query_database",
        description: {
            let expertNames: String = ExpertManager.shared.experts.map { expert in
                return expert.name
            }.joined(separator: "\n")
            return """
"Query a vector database. The databases available are listed below:"

\(expertNames)
"""
        }(),
        allowsParallelExecution: true,
        params: [
            FunctionParameter(
                label: "database",
                description: "The database to search within.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "query",
                description: """
The query to look up in the specified database.

This query will be used with a RAG system, not Google Search. RAG systems use semantic search, meaning search queries work best when semantically similar to the search results.

Example:
Google Search query: "apple average weight"
RAG query: "the average apple weighs 100 grams"
""",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "max_results",
                description: "The maximum number of search results (optional, default: 5)",
                datatype: .integer,
                isRequired: false
            )
        ],
        run: { params in
            // Get expert
            let experts: [Expert] = ExpertManager.shared.experts
            guard let expert: Expert = experts.filter(
                { $0.name.lowercased() == params.database.lowercased()
                }).first else {
                throw QueryVectorDatabaseError.databaseNotFound(params.database)
            }
            // Query database
            let index: SimilarityIndex = await expert.resources.loadIndex()
            let resultsMultiplier: Int = RetrievalSettings.searchResultsMultiplier * 2
            let maxResults: Int = min(
                params.max_results ?? 5,
                resultsMultiplier
            )
            let resourcesSearchResults: [SearchResult] = await index.search(
                query: params.query,
                maxResults: resultsMultiplier
            )
            
            // Use graph-enhanced retrieval if enabled
            var sources: [Source]
            if expert.useGraphRAG, let graph = await expert.resources.loadGraphIndex() {
                // Use GraphRetriever for enhanced results
                let enhancedResults = await GraphRetriever.retrieve(
                    query: params.query,
                    vectorResults: resourcesSearchResults,
                    graph: graph,
                    maxResults: maxResults
                )
                
                // Convert enhanced results to sources
                sources = enhancedResults.map { result in
                    var text = result.text
                    
                    // Add entity context if available
                    if !result.entityContext.isEmpty {
                        text += "\n\nRelated entities: " + result.entityContext.joined(separator: ", ")
                    }
                    
                    // Add community summary if available
                    if let summary = result.communitySummary {
                        text += "\n\nContext: \(summary)"
                    }
                    
                    return Source(
                        text: text,
                        source: result.source
                    )
                }
            } else {
                // Use standard retrieval
                sources = resourcesSearchResults.map { result in
                    // If search result context is not being used, skip
                    if !RetrievalSettings.useWebSearchResultContext {
                        return Source(
                            text: result.text,
                            source: result.sourceUrlText!
                        )
                    }
                    // Get item index and source url
                    guard let itemIndex: Int = result.itemIndex,
                          let sourceUrl: String = result.sourceUrlText else {
                        return Source(
                            text: result.text,
                            source: result.sourceUrlText!
                        )
                    }
                    // Get items in the same file
                    return Source.appendSourceContext(
                        index: itemIndex,
                        text: result.text,
                        sourceUrlText: sourceUrl,
                        similarityIndex: index
                    )
                }
            }
            // Convert to JSON
            let sourcesInfo: [Source.SourceInfo] = sources.map(keyPath: \.info)
            let jsonEncoder: JSONEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData: Data = try! jsonEncoder.encode(sourcesInfo)
            let resultsText: String = String(
                data: jsonData,
                encoding: .utf8
            )!
            // Return
            return """
Below are the documents and corresponding content returned from your `query_databases` query.

\(resultsText)
"""
            enum QueryVectorDatabaseError: LocalizedError {
                case databaseNotFound(String)
                case noResults
                var errorDescription: String? {
                    switch self {
                        case .databaseNotFound(let name):
                            return "No database with the name `\(name)` exists."
                        case .noResults:
                            return "No related results were found."
                    }
                }
            }
        }
    )
    struct QueryVectorDatabaseParams: FunctionParams {
        let database: String
        let query: String
        let max_results: Int?
    }
    
}
