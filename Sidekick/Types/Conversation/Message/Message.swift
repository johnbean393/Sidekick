//
//  Message.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import AppKit
import Foundation
import SimilaritySearchKit
import SwiftUI

public struct Message: Identifiable, Codable, Hashable {
	
	init(
		text: String,
		sender: Sender,
		model: String? = nil,
        referencedURLs: [URL] = [],
        functionCallRecords: [FunctionCallRecord]? = nil,
		expertId: UUID? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.sender = sender
        self.referencedURLs = referencedURLs.map { url in
            return ReferencedURL(url: url)
        }
        self.startTime = .now
        self.lastUpdated = .now
        self.outputEnded = false
        let modelName: String = model ?? String(
            localized: "Unknown"
        )
        self.model = modelName
        self.functionCallRecords = functionCallRecords
        self.expertId = expertId
    }
	
	init(
		imageUrl: URL,
		prompt: String,
		expertId: UUID? = nil
	) {
		self.id = UUID()
		self.text = "Generated an image with the prompt \"\(prompt)\"."
		self.sender = .system
		self.startTime = .now
		self.lastUpdated = .now
		self.outputEnded = true
		self.model = "Image Playground Model"
		self.imageUrl = imageUrl
		self.expertId = expertId
	}
	
	/// A `UUID` for `Identifiable` conformance
	public var id: UUID = UUID()
	
	/// A `ContentType` for the message
	public var contentType: Self.ContentType {
		if self.imageUrl != nil {
			return .image
		}
		return .text
	}
	
	/// Stored property for the message text
	public var text: String
	
	/// Computed property returning the response text
	public var responseText: String {
		return self.text.reasoningRemoved
	}
	
	/// A `String` containing the message's reasoning process
	public var reasoningText: String? {
		// Return nil if sender is not assistant
		if self.sender != .assistant { return nil }
		// List special reasoning tokens
        let specialTokenSets: [[String]] = String.specialReasoningTokens
		// Extract text between tokens
		// For each set of tokens
		for specialTokenSet in specialTokenSets {
			// Get range of start token
			if let startRange = self.text.range(
				of: specialTokenSet.first!
			) {
				// Get range of end token
				if let endRange = self.text.range(
					of: specialTokenSet.last!,
					range: startRange.upperBound..<text.endIndex
				) {
					// Return text
					return String(
						self.text[startRange.upperBound..<endRange.lowerBound]
					).trimmingCharacters(in: .whitespacesAndNewlines)
				} else if !self.outputEnded {
					// If still outputting, show unfinished reasoning text
					return String(
						self.text[startRange.upperBound..<text.endIndex]
					).trimmingCharacters(in: .whitespacesAndNewlines)
				}
			}
		}
		// If failed to locate reasoning text, return nil
		return nil
	}
	
	/// A `Bool` representing if the message is contains a reasoning process
	public var hasReasoning: Bool {
		// Return true if...
		// a.) There are reasoning tokens
        // b.) The reasoning process is not nil
		// c.) The message does come from a model
        guard let reasoningText = self.reasoningText else { return false }
        return (!reasoningText.isEmpty) && (self.sender == .assistant)
	}
	
	/// Function returning the message text that is submitted to the LLM
	public func textWithSources(
		similarityIndex: SimilarityIndex?,
		useWebSearch: Bool,
		temporaryResources: [TemporaryResource]
	) async -> (
		text: String,
		sources: Int
	) {
		// If assistant or system, no sources needed
		if self.sender != .user {
			return (self.text, 0)
		}
		// Search in expert resources
		// If no resources, return blank array
		let hasResources: Bool = similarityIndex != nil && !(similarityIndex?.indexItems.isEmpty ?? true)
		let searchResultsMultiplier: Int = RetrievalSettings.searchResultsMultiplier * 2
		let resourcesSearchResults: [SearchResult] = await similarityIndex?.search(
			query: text,
			maxResults: searchResultsMultiplier
		) ?? []
        let resourcesResults: [Source] = resourcesSearchResults.map { result in
            // If search result context is not being used, skip
            if !RetrievalSettings.useWebSearchResultContext {
                return Source(
                    text: result.text,
                    source: result.sourceUrlText!
                )
            }
            // Get item index and source url
            guard let index: Int = result.itemIndex,
                  let sourceUrl: String = result.sourceUrlText,
                  let similarityIndex: SimilarityIndex = similarityIndex else {
                return Source(
                    text: result.text,
                    source: result.sourceUrlText!
                )
            }
            // Get items in the same file
            return Source.appendSourceContext(
                index: index,
                text: result.text,
                sourceUrlText: sourceUrl,
                similarityIndex: similarityIndex
            )
        }
		// Search Tavily
		var resultCount: Int = (hasResources && !resourcesResults.isEmpty) ? 1 : 2
		resultCount = resultCount * searchResultsMultiplier
		var searchResults: [Source]? = []
		if useWebSearch {
            searchResults = try? await WebSearch.search(
                query: text,
                resultCount: resultCount
            )
		}
		// Get temporary resources as sources
		let temporaryResourcesSources: [Source] = temporaryResources.map(
			\.source
		).compactMap({ $0 })
		// Combine
		let results: [Source] = resourcesResults + (
            searchResults ?? []
		) + temporaryResourcesSources
		// Save sources
		let sources: Sources = Sources(
			messageId: self.id,
			sources: results
		)
		await MainActor.run { SourcesStore.add(sources) }
		// Skip if no results
		if results.isEmpty {
			return (self.text, 0)
		}
        // Convert to JSON
        let sourcesInfo: [Source.SourceInfo] = results.map(\.info)
        let jsonEncoder: JSONEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted]
        let jsonData: Data = try! jsonEncoder.encode(sourcesInfo)
        let resultsText: String = String(
            data: jsonData,
            encoding: .utf8
        )!
		let messageText: String = """
\(self.text)

Below is information that may or may not be relevant to my request in JSON format. 

When multiple sources provide correct, but conflicting information (e.g. different definitions), ALWAYS use sources from files, not websites. 

If your response uses information from one or more provided sources I provided, your response MUST be directly followed with a single exaustive LIST OF FILEPATHS AND URLS of ALL referenced sources, in the format [{"url": "/path/to/referenced/file.pdf"}, {"url": "/path/to/another/referenced/file.docx"}, {"url": "https://referencedwebsite.com"}, "https://anotherreferencedwebsite.com"}]

This list should be the only place where references and sources are addressed, and MUST not be preceded by a header or a divider.

If I did not provide sources, YOU MUST NOT end your response with a list of filepaths and URLs. If no sources were provided, DO NOT mention the lack of sources.

If you did not use the information I provided, YOU MUST NOT end your response with a list of filepaths and URLs. 

DO NOT reference sources outside of those provided below. If you did not reference provided sources, do not mention sources in your response.

\(resultsText)
"""
		return (messageText, results.count)
	}
	
	/// A `Double` representing the number of tokens outputted per second
	public var tokensPerSecond: Double?
	
	/// The model's name, of type `String`
	public let model: String
	
	/// The ``Sender`` of the message (`user`, `system` or `assistant`)
	private var sender: Sender
	
	/// The `UUID` of the expert used
	public var expertId: UUID?
	
	/// A `URL` for an image generated, if any
	public var imageUrl: URL?
    
    /// An array of ``FunctionCallRecord`` used in the response.
    ///
    /// Holds the flat union of every tool call across every iteration
    /// of the agent loop. Kept for backward compatibility with code
    /// (and persisted messages) written before ``steps`` existed —
    /// when ``steps`` is non-empty the per-step records are the
    /// canonical source for rendering.
    public var functionCallRecords: [FunctionCallRecord]? = nil
	/// A `Bool` representing whether the message did execute function calls
    public var hasFunctionCallRecords: Bool {
        guard let functionCallRecords else { return false }
        return !functionCallRecords.isEmpty
    }
    
    /// Per-iteration breakdown of the assistant's tool-calling loop.
    ///
    /// One entry per iteration that ended in tool calls; the final
    /// iteration (the answer the user sees) lives in ``text`` and
    /// its derived properties. Empty for messages that didn't go
    /// through the agent loop or were persisted before this field
    /// existed.
    public var steps: [MessageStep] = []
    /// `true` when this message has captured per-step reasoning /
    /// explainer / tool call history.
    public var hasSteps: Bool { !self.steps.isEmpty }
    
	/// An array for `URL` of sources referenced in a response
	public var referencedURLs: [ReferencedURL] = []
	
	/// Function to get the sender
	public func getSender() -> Sender {
		return self.sender
	}
	
	/// Stored property for the start time of interaction
	public var startTime: Date
	/// Stored property for the most recent update time
	public var lastUpdated: Date
	/// Stored property for the moment the assistant's reasoning phase
	/// ended — i.e. when `responseText` first became non-empty.
	///
	/// Captured during streaming so the "Thought for …" duration shown
	/// in the UI freezes the instant the model finishes thinking,
	/// rather than continuing to climb while the final answer streams.
	public var reasoningEndTime: Date?
	
	/// Stored property for the time taken for a response to start
	public var responseStartSeconds: Double?
	
	/// Stored property for whether the output has finished
	public var outputEnded: Bool
	
	/// A ``Snapshot`` of canvas content
	public var snapshot: Snapshot? = nil
	
	/// `true` once the assistant has emitted a closing reasoning
	/// token (`</think>` / `</thought>`), regardless of whether any
	/// post-reasoning text follows.
	///
	/// Distinct from ``hasReasoning``, which becomes `true` the
	/// instant the opening token appears. Used to stamp
	/// ``reasoningEndTime`` even for tool-calling iterations where
	/// the model emits a thought and then jumps straight into a
	/// native tool call with no narration text in between.
	public var isReasoningClosed: Bool {
		guard self.sender == .assistant else { return false }
		for tokenSet in String.specialReasoningTokens {
			let openToken: String = tokenSet.first!
			let closeToken: String = tokenSet.last!
			if self.text.contains(openToken) && self.text.contains(closeToken) {
				return true
			}
		}
		return false
	}

	/// Stamp ``reasoningEndTime`` the first time the assistant has
	/// closed its chain-of-thought block.
	///
	/// Safe to call repeatedly — subsequent calls are no-ops once the
	/// timestamp has been recorded. Call from streaming code paths
	/// every time the message's `text` changes so the duration shown
	/// in the reasoning banner reflects only the reasoning phase.
	public mutating func markReasoningEndIfNeeded(at date: Date = .now) {
		guard self.reasoningEndTime == nil else { return }
		guard self.sender == .assistant else { return }
		// Stamp as soon as the reasoning block is closed. Earlier
		// versions also required `!responseText.isEmpty`, but that
		// missed iterations where the model emits a thought followed
		// directly by a native tool call (no user-facing text), which
		// left the per-step "Thought for …" pill stuck without a
		// duration in the persisted history.
		guard self.hasReasoning, self.isReasoningClosed else { return }
		self.reasoningEndTime = date
	}
	
	/// Function to update message
	@MainActor
	public mutating func update(
		response: LlamaServer.CompleteResponse,
		includeReferences: Bool
	) {
		// Set variables
		self.tokensPerSecond = response.predictedPerSecond
		self.responseStartSeconds = response.responseStartSeconds
		self.lastUpdated = .now
        // Decode text for extract text and references
        let text: String = response.text.dropSuffixIfPresent("[]")
		let delimiters: [String] = ["\n[", " ["]
		// Set text as default if reference extraction fails
		self.text = text
		// For each delimiter
		for delimiter in delimiters {
			let messageText: String = text.dropFollowingSubstring(
				delimiter,
				options: .backwards
			)
                .trimmingCharacters(in: .whitespacesAndNewlines)
				.dropSuffixIfPresent(
					"Sources"
				).dropSuffixIfPresent(
					"References"
				)
				.dropSuffixIfPresent(
					"**Sources**"
				).dropSuffixIfPresent(
					"**References**"
				)
				.dropSuffixIfPresent(
					"Sources:"
				).dropSuffixIfPresent(
					"References:"
				).dropSuffixIfPresent(
					"**Sources:**"
				).dropSuffixIfPresent(
					"**References:**"
				).dropSuffixIfPresent(
					"**Sources**:"
				).dropSuffixIfPresent(
					"**References**:"
				).dropSuffixIfPresent(
					"List of Filepaths and URLs:"
				)
                .trimmingCharacters(in: .whitespacesAndNewlines)
			let jsonText: String = text.dropPrecedingSubstring(
				delimiter,
				options: .backwards,
				includeCharacter: true
			)
			// Decode references if needed
            if includeReferences, let data: Data = jsonText.data(
                using: .utf8
            ) {
				// Decode data
				if let references = ReferencedURL.fromData(
					data: data
				) {
					self.referencedURLs = references
					self.text = messageText
				}
			}
		}
		// Try to extract snapshot
		self.updateSnapshot()
		// Safety net: if streaming didn't get a chance to stamp the
		// reasoning end time (e.g. non-streaming code paths), fall
		// back to "now" so the duration shown isn't `lastUpdated -
		// startTime` (which would include response generation time).
		self.markReasoningEndIfNeeded()
	}
	
	/// Function to extract snapshots if available
	private mutating func updateSnapshot() {
		// Try to extract site
		if let site = Snapshot.Site.extractSite(
			from: self.responseText
		) {
			self.snapshot = Snapshot(site: site)
			self.snapshot?.site?.saveToCache()
		}
	}
		
	
	/// Function to end a message
	public mutating func end(at date: Date = .now) {
		self.lastUpdated = date
		self.outputEnded = true
	}
	
    public struct MessageSubset: Codable {
        
        private enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }
        
        init(
            modelType: ModelType = .regular,
            usingRemoteModel: Bool,
            message: Message,
            similarityIndex: SimilarityIndex? = nil,
            temporaryResources: [TemporaryResource] = [],
            shouldAddSources: Bool = false,
            useVisionContent: Bool = false,
            useWebSearch: Bool = false,
            useCanvas: Bool = false,
            canvasSelection: String? = nil
        ) async {
            self.role = message.sender
            self.toolCallID = nil
            self.toolCalls = nil
            // Set up mutable message
            var message: Message = message
            // Apply changes for Canvas
            if useCanvas, let canvasSelection = canvasSelection, !canvasSelection.isEmpty {
                message.text = """
\(message.text)

I have selected the range "\(canvasSelection)". Output the full text again with the changes applied. Keep as much of the previous text as available. 
"""
            } else if useCanvas {
                message.text = """
\(message.text)

Output the full text again with the changes applied. Keep as much of the previous text as available.
"""
            }
            // Apply Canvas changes if needed
            if let snapshot = message.snapshot,
               snapshot.type == .text,
               let ogText: String = snapshot.originalText {
                message.text = message.text.replacingOccurrences(
                    of: ogText,
                    with: snapshot.text
                )
            }
            // Add sources if needed
            if shouldAddSources {
                // Initialize the content based on the useVisionContent flag.
                if useVisionContent {
                    var contentArr: [Content] = []
                    // Add text content, stripping images
                    let textContentStr: String = await message.textWithSources(
                        similarityIndex: similarityIndex,
                        useWebSearch: useWebSearch,
                        temporaryResources: temporaryResources.filter({ !$0.isImage })
                    ).text
                    let textContentItem: Content = .text(textContentStr)
                    contentArr.append(textContentItem)
                    // Add image content
                    let maxEdge: CGFloat = 900 / 2
                    let imageUrls: [URL] = temporaryResources.filter({ $0.isImage }).map(\.url)
                    let encodedImages: [String] = imageUrls.compactMap { url in
                        guard let image = NSImage(contentsOf: url) else {
                            return nil // Return nil if file can't be read as image
                        }
                        let originalSize = image.size
                        let maxOriginalEdge = max(originalSize.width, originalSize.height)
                        var resizedImage = image
                        // Only resize if one of the dimensions is larger than maxEdge
                        if maxOriginalEdge > maxEdge {
                            let scale = maxEdge / maxOriginalEdge
                            let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
                            let newImage = NSImage(size: newSize)
                            newImage.lockFocus()
                            // Set high interpolation quality to ensure sharp resized image
                            NSGraphicsContext.current?.imageInterpolation = .default
                            image.draw(
                                in: NSRect(origin: .zero, size: newSize),
                                from: NSRect(origin: .zero, size: originalSize),
                                operation: .copy,
                                fraction: 1.0
                            )
                            newImage.unlockFocus()
                            resizedImage = newImage
                        }
                        guard let tiffData = resizedImage.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiffData),
                              let pngData = bitmap.representation(
                                using: .png,
                                properties: [.compressionFactor: 0.95]
                              ) else {
                            return nil // Return nil if image can't be encoded
                        }
                        let encoding: String = pngData.base64EncodedString()
                        return "data:image/png;base64,\(encoding)"
                    }
                    let imageContentItems: [Content] = encodedImages.map { encodedImage in
                        return .imageURL(ImageURL(url: encodedImage))
                    }
                    contentArr += imageContentItems
                    self.content = .multimodal(contentArr)
                } else {
                    // Else, initialize text content
                    let textContentStr: String = await message.textWithSources(
                        similarityIndex: similarityIndex,
                        useWebSearch: useWebSearch,
                        temporaryResources: temporaryResources
                    ).text
                    self.content = .textOnly(textContentStr)
                }
            } else {
                // Else, just use message text
                let plainText: String = message.text
                self.content = .textOnly(plainText)
            }
        }
        
        init(
            role: Sender,
            content: ContentValue,
            toolCallID: String? = nil,
            toolCalls: [ToolCall]? = nil
        ) {
            self.role = role
            self.content = content
            self.toolCallID = toolCallID
            self.toolCalls = toolCalls
        }
        
        /// A ``Sender`` object representing the sender
        var role: Sender
        /// The message's content
        var content: ContentValue
        /// The tool call ID for tool role messages
        var toolCallID: String?
        /// The tool calls emitted by an assistant message
        var toolCalls: [ToolCall]?
        
        static func assistantToolCalls(
            functionCalls: [any DecodableFunctionCall]
        ) -> MessageSubset {
            let toolCalls: [ToolCall] = functionCalls.map { functionCall in
                return ToolCall(functionCall: functionCall)
            }
            return MessageSubset(
                role: .assistant,
                content: .textOnly(""),
                toolCalls: toolCalls
            )
        }
        
        static func toolResult(
            toolCallID: String,
            content: String
        ) -> MessageSubset {
            return MessageSubset(
                role: .tool,
                content: .textOnly(content),
                toolCallID: toolCallID
            )
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.role = try container.decode(Sender.self, forKey: .role)
            self.content = try container.decode(ContentValue.self, forKey: .content)
            self.toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
            self.toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
            if let toolCalls, !toolCalls.isEmpty {
                try container.encode(toolCalls, forKey: .toolCalls)
            }
            if let toolCallID, !toolCallID.isEmpty {
                try container.encode(toolCallID, forKey: .toolCallID)
            }
        }
        
        public struct ToolCall: Codable {
            
            let id: String
            let type: String
            let function: ToolCallFunction
            
            init(functionCall: any DecodableFunctionCall) {
                self.id = functionCall.toolCallID ?? UUID().uuidString
                self.type = "function"
                self.function = ToolCallFunction(
                    name: functionCall.name,
                    arguments: functionCall.getArgumentsJSONString()
                )
            }
        }
        
        public struct ToolCallFunction: Codable {
            
            let name: String
            let arguments: String
        }
        
        public enum Content: Codable {
            
            case text(String)
            case imageURL(ImageURL)
            
            private enum CodingKeys: String, CodingKey {
                case type
                case text
                case imageURL = "image_url"
            }
            
            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                
                switch type {
                    case "text":
                        let text = try container.decode(String.self, forKey: .text)
                        self = .text(text)
                    case "image_url":
                        let imageUrl = try container.decode(ImageURL.self, forKey: .imageURL)
                        self = .imageURL(imageUrl)
                    default:
                        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid content type")
                }
            }
            
            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                    case .text(let text):
                        try container.encode("text", forKey: .type)
                        try container.encode(text, forKey: .text)
                    case .imageURL(let url):
                        try container.encode("image_url", forKey: .type)
                        try container.encode(url, forKey: .imageURL)
                }
            }
        }
        
        public struct ImageURL: Codable {
            let url: String
        }
        
        public enum ContentValue: Codable {
            
            case textOnly(String)
            case multimodal([Content])
            
            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                // Try decoding as a String (single mode)
                if let stringValue = try? container.decode(String.self) {
                    self = .textOnly(stringValue)
                    return
                }
                // Then try decoding as a [Content] array (multimodal mode)
                if let arrayValue = try? container.decode([Content].self) {
                    self = .multimodal(arrayValue)
                    return
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unable to decode ContentValue as either a String or an array of Content"
                )
            }
            
            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                    case .textOnly(let str):
                        try container.encode(str)
                    case .multimodal(let contents):
                        try container.encode(contents)
                }
            }
        }
           
    }
	
	public enum ContentType: String, CaseIterable {
		case text
		case image
	}
	
}

// MARK: - SwiftData hydration

extension Message {
    /// Convenience initialiser used when restoring a ``Message``
    /// from a ``MessageEntity`` row. All fields are explicit so the
    /// memberwise/auto-generated initialisers remain untouched.
    init(
        id: UUID,
        text: String,
        sender: Sender,
        model: String,
        expertId: UUID?,
        imageUrl: URL?,
        startTime: Date,
        lastUpdated: Date,
        reasoningEndTime: Date?,
        responseStartSeconds: Double?,
        tokensPerSecond: Double?,
        outputEnded: Bool,
        functionCallRecords: [FunctionCallRecord]?,
        steps: [MessageStep],
        referencedURLs: [ReferencedURL],
        snapshot: Snapshot?
    ) {
        self.id = id
        self.text = text
        self.sender = sender
        self.model = model
        self.expertId = expertId
        self.imageUrl = imageUrl
        self.startTime = startTime
        self.lastUpdated = lastUpdated
        self.reasoningEndTime = reasoningEndTime
        self.responseStartSeconds = responseStartSeconds
        self.tokensPerSecond = tokensPerSecond
        self.outputEnded = outputEnded
        self.functionCallRecords = functionCallRecords
        self.steps = steps
        self.referencedURLs = referencedURLs
        self.snapshot = snapshot
    }
}
