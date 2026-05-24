//
//  ContextCompressor.swift
//  Sidekick
//
//  Created by John Bean on 10/9/25.
//

import Foundation
import OSLog

/// Utility responsible for summarising and trimming tool call outputs when context limits are exceeded.
enum ContextCompressor {
    
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Sidekick",
        category: "ContextCompressor"
    )
    
    /// Compresses tool call results whose token counts exceed the specified threshold.
    /// - Parameters:
    ///   - results: The tool call results captured so far in the agent loop.
    ///   - threshold: Maximum number of tokens allowed before compression.
    /// - Returns: A new array of tool call results, where oversized entries are summarised.
    static func compressFunctionResults(
        _ results: [FunctionCallResult],
        threshold: Int
    ) async throws -> [FunctionCallResult] {
        guard !results.isEmpty else { return results }
        
        var compressedResults: [FunctionCallResult] = []
        
        for result in results {
            guard let text = result.result else {
                compressedResults.append(result)
                continue
            }
            let tokenCount = text.estimatedTokenCount
            if tokenCount <= threshold {
                compressedResults.append(result)
                continue
            }
            
            logger.info("Compressing tool result '\(result.call)' with ~\(tokenCount) tokens")
            
            let summary = try await summarizeToolResult(
                call: result.call,
                result: text,
                threshold: threshold
            )
            
            var updatedResult = result
            updatedResult.result = summary
            compressedResults.append(updatedResult)
        }
        
        return compressedResults
    }
    
    // MARK: - Private helpers
    
    /// Summarises a single tool result using the main model. Ensures the final summary stays under the token threshold.
    ///
    /// Compression deliberately runs on the **main** model rather than
    /// the worker: tool outputs can be many thousands of tokens long
    /// (e.g. fetched web pages), and the worker server is pinned to a
    /// 4K context for memory efficiency. Routing through the main
    /// model guarantees we have enough headroom to fit the raw output,
    /// the compression prompt, and the produced summary in one go.
    private static func summarizeToolResult(
        call: String,
        result: String,
        threshold: Int
    ) async throws -> String {
        let prompt = """
You are Sidekick's compression worker. Summarise the tool result below preserving every critical fact, figure, and citation.

Tool call schema:
\(call)

Raw tool output:
\(result)

Requirements:
1. Retain the essential facts, figures, URLs, commands, and conclusions.
2. Replace verbose prose with compact bullet points when possible.
3. Remove duplicated sentences or boilerplate.
4. Target 20-30% of the original length, but never exceed \(threshold) tokens.
5. Output plain text only—no additional commentary.
"""
        
        let message = Message(
            text: prompt,
            sender: .user
        )
        
        let canReachRemoteServer = await Model.shared.remoteServerIsReachable()
        let usingRemoteModel = canReachRemoteServer && InferenceSettings.useServer
        let messageSubset = await Message.MessageSubset(
            usingRemoteModel: usingRemoteModel,
            message: message
        )
        
        var summaryResponse = try await Model.shared.mainModelServer.getChatCompletion(
            mode: .default,
            canReachRemoteServer: canReachRemoteServer,
            messages: [messageSubset]
        ).text
        
        summaryResponse = summaryResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If summary still exceeds threshold, truncate conservatively.
        if summaryResponse.estimatedTokenCount > threshold {
            logger.warning("Summary still \(summaryResponse.estimatedTokenCount) tokens; trimming to \(threshold)")
            var trimmedSummary = summaryResponse
            trimmedSummary.trimmingSuffixToTokens(maxTokens: threshold)
            summaryResponse = trimmedSummary
        }
        
        return summaryResponse
    }
}

