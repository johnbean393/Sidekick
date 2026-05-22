//
//  SlideStudioViewController.swift
//  Sidekick
//
//  Created by John Bean on 2/26/25.
//

import Foundation
import SimilaritySearchKit
import SwiftUI
import WebViewKit
import WebKit

public class SlideStudioViewController: ObservableObject, DropDelegate {
	
	/// The current step in the slide generation process, of type `SlideStudioStep`
	@Published public var currentStep: SlideStudioStep = .prompt
	
	/// A `Bool` indicating whether the content of the presentation should be informed by content from the web
	@Published public var useWebSearch: Bool = false
	
	/// The ID of the selected expert, of type `UUID`
	@Published public var selectedExpertId: UUID?
	
	/// A list of `TemporaryResource` used to inform the presentation's content
	@Published public var tempResources: [TemporaryResource] = []
	
	/// The current selected expert, of type `Expert`
	public var selectedExpert: Expert? {
		guard let id = self.selectedExpertId else { return nil }
		return ExpertManager.getExpert(id: id)
	}
	
	/// The prompt given by the user, of type `String`
	@Published public var prompt: String = ""
	
	/// The number of pages in the finished powerpoint, of type `Int`
	@Published public var pageCount: Int = 10
	
	/// The markdown generated, of type `String`
	@Published public var markdown: String = ""
	
	/// The user's prompt rephrased to generate text content, of type `String`
	private var rephrasedPrompt: String = ""
	
	/// The `marp` child process to serve the preview
	public var marpPreviewProcess: Process = Process()
	
	/// The `marp` child process to export the slides
	public var marpExportProcess: Process = Process()
	
	/// The URL pointing to the Markdown file
	private var markdownPreviewFileUrl: URL {
		return Settings
			.cacheUrl
			.appendingPathComponent("slideStudioPreview.md")
	}
	
	/// The URL pointing to the HTML file
	private var markdownPreviewUrl: URL {
		return Settings
			.cacheUrl
			.appendingPathComponent("slideStudioPreview.html")
	}
	
	/// A view showing a preview of the slides
	public var preview: some View {
		WebView(
			url: self.markdownPreviewUrl
		)
	}
	
	/// Function to start presentation generation
	public func startGeneration() async {
		// Handle errors
		do {
			// Check prompt
			guard !self.prompt.isEmpty else {
				throw GenerationError.noPrompt
			}
			// Rephrase prompt
			try await self.rephrasePrompt()
			// Generate base content
			let contentMessages: [Message] = try await self.generateContent()
			// Generate image titles
			let imageTitles: [String] = try await self.listImagesNeeded(
				contentMessages: contentMessages
			)
			// Retrieve relavant images
			let searchResults: [ImageSearchResult] = await self.findImages(
				imageTitles: imageTitles
			)
			// Generate presentation markdown
			self.markdown = try await self.generateMarkdown(
				contentMessages: contentMessages,
				searchResults: searchResults
			)
			// Prepare editor + preview
			self.startPreview()
			// Switch to editor + preview
			self.currentStep = .previewEditor
		} catch {
			// Show error
			Dialogs.showAlert(
				title: String(localized: "Error"),
				message: String(localized: "Error generating presentation: \(error.localizedDescription)")
			)
		}
	}
	
	/// Function to rephrase prompt for generating foundation knowledge answer
	private func rephrasePrompt() async throws {
		// Set step to rephrasing prompt
		self.currentStep = .rephrasingPrompt
		// Formulate messages
		let systemPrompt: String = InferenceSettings.systemPrompt
		let rephrasePrompt: String = """
Rephrase this prompt to not mention the need for generating a presentation. Respond with the rephrased prompt ONLY.

"\(prompt)"
"""
		let messages: [Message] = [
			Message(text: systemPrompt, sender: .system),
			Message(text: rephrasePrompt, sender: .user)
		]
		// Submit for completion
		do {
			let response: LlamaServer.CompleteResponse = try await Model
				.shared
				.listenThinkRespond(
                    messages: messages,
                    modelType: .regular,
					mode: .default
				)
			// Set rephrased prompt
			self.rephrasedPrompt = response.text.reasoningRemoved
		} catch {
			throw GenerationError.rephrasingPromptFailed
		}
	}
	
	/// Function to generate the base content
	private func generateContent() async throws -> [Message] {
		// Set step to generating content
		self.currentStep = .generatingContent
		// Load index if needed
		let similarityIndex: SimilarityIndex? = await selectedExpert?
			.resources
			.loadIndex()
		// Formulate messages
		let systemPrompt: String = InferenceSettings.systemPrompt
		var messages: [Message] = [
			Message(text: systemPrompt, sender: .system),
			Message(text: self.rephrasedPrompt, sender: .user)
		]
		// Submit for completion
		do {
			let response: LlamaServer.CompleteResponse = try await Model
				.shared
				.listenThinkRespond(
                    messages: messages,
                    modelType: .regular,
					mode: .chat,
					similarityIndex: similarityIndex,
					useWebSearch: self.useWebSearch,
					temporaryResources: self.tempResources
				)
			// Return messages
			let responseMessage: Message = Message(
				text: response.text.reasoningRemoved,
				sender: .assistant
			)
			messages.append(
				responseMessage
			)
			return messages
		} catch {
			throw GenerationError.generatingContentFailed
		}
	}
	
	/// Function to list required images
	private func listImagesNeeded(
		contentMessages: [Message]
	) async throws -> [String] {
		// Set step to listing images
		self.currentStep = .listingImagesNeeded
		// Formulate messages
		let imageTitlePrompt: String = """
You are about to create a presentation about the content above. List 1-2 word titles of images you might need, each on a new line. List the titles ONLY.
"""
		let imageTitleMessage: Message = Message(
			text: imageTitlePrompt,
			sender: .user
		)
		let messages: [Message] = contentMessages + [imageTitleMessage]
		// Submit for completion
		do {
			let response: LlamaServer.CompleteResponse = try await Model
				.shared
				.listenThinkRespond(
					messages: messages,
                    modelType: .regular,
					mode: .default
				)
			// Extract titles
			let imageTitles: [String] = response
				.text
				.reasoningRemoved
				.split(
					separator: "\n"
				).map { title in
					if title.isEmpty {
						return nil
					}
					return String(title)
				}
				.compactMap({ $0 })
			return imageTitles
		} catch {
			throw GenerationError.listingImagesNeededFailed
		}
	}
	
	/// Function to find images needed
	private func findImages(
		imageTitles: [String]
	) async -> [ImageSearchResult] {
		// Set step to finding images
		self.currentStep = .findingImages
		// For each image title
		let searchResults: [ImageSearchResult] = await withTaskGroup(
			of: (
				title: String,
				image: [ImageSearch.CommonsImage]
			)?.self,
			returning: [ImageSearchResult].self
		) { taskGroup in
			// Start tasks to search for images in parallel
			for title in imageTitles {
				taskGroup.addTask {
					do {
						let commonsImages: [ImageSearch.CommonsImage].SubSequence = try await ImageSearch
							.searchCommonsImages(
								searchTerm: title.lowercased(),
								count: 10
							)
							.filter { image in
								let allowedExtensions: Set<String> = [
									".jpg",
									".jpeg",
									".png",
									".svg",
									".webp",
									".heic"
								]
								return allowedExtensions.map { `extension` in
									return image.urlString.contains(`extension`)
								}.contains(true)
							}
							.prefix(2)
						return (title, Array(commonsImages))
					} catch {
						return nil
					}
				}
			}
			// Collect task group results
			var searchResults: [ImageSearchResult] = []
			for await result in taskGroup {
				guard let result = result else { continue }
				let searchResult: ImageSearchResult = ImageSearchResult(
					description: result.title,
					imageUrls: result.image.map(\.url)
				)
				searchResults.append(searchResult)
			}
			return searchResults
		}
		// Return search results
		return searchResults
	}
	
	/// Function to generate Markdown for slides
	private func generateMarkdown(
		contentMessages: [Message],
		searchResults: [ImageSearchResult]
	) async throws -> String {
		// Set step to generating final slides
		self.currentStep = .generatingSlides
		// Get cheatsheet text
		guard let cheatsheetUrl: URL = Bundle.main.url(
			forResource: "marpCheatsheet",
			withExtension: "md"
		) else {
			throw GenerationError.generatingContentFailed
		}
		let cheatsheetText: String = try! String(
			contentsOf: cheatsheetUrl,
            encoding: .utf8
		)
		// Formulate prompt
		do {
			let searchResultsTemp: String = searchResults.map { result in
				let urls: [String] = result.imageUrls.map { url in
					return """
			{
				"url": "\(url.absoluteString)"
			}
"""
				}
				return """
	{
		"description": "\(result.description)",
		"imageUrls": [
\(urls.joined(separator: ",\n"))
		]
	}
"""
			}.joined(separator: ",\n")
			let searchResultsString: String = "[\n\(searchResultsTemp)\n]"
			let markdownGenerationPrompt: String = """
Generate a detailed, \(self.pageCount) page PowerPoint style presentation ABOUT THE CONTENT ABOVE. The presentation should NOT be about Marp. Each page MUST NOT have more than 9 lines.

The format is as follows:

\(cheatsheetText)

Below are links to images that could be used in the presentation. Note that not all images need to be used, and not all slides need to have images. Do not use unrelated images.

\(searchResultsString)

Respond with the Markdown ONLY. Do not include comments.
"""
			// Formulate messages
			let markdownGenerationMessage: Message = Message(
				text: markdownGenerationPrompt,
				sender: .user
			)
			let messages: [Message] = contentMessages + [markdownGenerationMessage]
			// Submit for completion
			let response: LlamaServer.CompleteResponse = try await Model
				.shared
				.listenThinkRespond(
					messages: messages,
                    modelType: .regular,
					mode: .default
				)
			// Strip code tags, thinking process & return
			return response.text.reasoningRemoved.replacingOccurrences(
				of: "```Markdown",
				with: ""
			).replacingOccurrences(
				of: "```markdown",
				with: ""
			).replacingOccurrences(
				of: "```",
				with: ""
			).replacingOccurrences(
				of: "# ",
				with: "## "
			).trimmingCharacters(in: .whitespacesAndNewlines)
		} catch {
			throw GenerationError.generatingContentFailed
		}
	}
	
	/// Function to save markdown to file
	public func saveMarkdownToFile(
		_ markdownStr: String? = nil
	) {
		// Unwrap markdown
		let markdown: String = markdownStr ?? self.markdown
		// Save to file
		try? markdown.write(
			to: self.markdownPreviewFileUrl,
			atomically: true,
			encoding: .utf8
		)
	}
	
	/// Function to start `marp` preview server
	public func startPreview() {
		// Save the code
		self.saveMarkdownToFile()
		// Start the marp child process
		self.marpPreviewProcess = Process()
		self.marpPreviewProcess.executableURL = Bundle
			.main
			.resourceURL?
			.appendingPathComponent("marp")
		let arguments = [
			"--watch",
			self.markdownPreviewFileUrl.posixPath,
			"--output",
			self.markdownPreviewUrl.posixPath
		]
		self.marpPreviewProcess.arguments = arguments
		self.marpPreviewProcess.standardInput = FileHandle.nullDevice
		// To debug with server's output, comment these 2 lines to inherit stdout.
		self.marpPreviewProcess.standardOutput =  FileHandle.nullDevice
		self.marpPreviewProcess.standardError =  FileHandle.nullDevice
		// Run process
		do {
			try self.marpPreviewProcess.run()
		} catch {
			// Print error
			print("Error generating diagram: \(error)")
			// Return to first step
			Task.detached { @MainActor in
				Dialogs.showAlert(
					title: String(localized: "Error"),
					message: String(localized: "An error occurred while generating the slides.")
				)
				self.reset()
			}
		}
	}
	
	/// Function to stop `marp` preview server
	public func stopPreview() {
		// Terminate server process
		if self.marpPreviewProcess.isRunning {
			self.marpPreviewProcess.terminate()
			self.marpPreviewProcess = Process()
		}
	}
	
	/// Function to stop `marp` export process
	public func stopExport() {
		// Terminate export process
		if self.marpExportProcess.isRunning {
			self.marpExportProcess.terminate()
			self.marpExportProcess = Process()
		}
	}
	
	/// Function to reset Slide Studio
	public func reset() {
		// Stop the preview
		self.stopPreview()
		self.stopExport()
		// Reset variables
		self.markdown = ""
		self.prompt = ""
		self.pageCount = 10
		self.tempResources.removeAll()
		self.useWebSearch = false
		// Reset step
		self.currentStep = .prompt
	}
	
	/// Function to export slides from Slide Studio
	@MainActor
	public func exportSlides(
		config: SlideExportConfiguration = .default
	) {
		// Terminate export process if running
		self.stopExport()
		// Start the marp child process
		self.marpExportProcess = Process()
		self.marpExportProcess.executableURL = Bundle
			.main
			.resourceURL?
			.appendingPathComponent("marp")
		var arguments = [
			self.markdownPreviewFileUrl.posixPath
		]
		if config.format == .pptxEditable {
			arguments.append("--pptx")
			arguments.append("--pptx-editable")
		}
		arguments.append("--output")
		arguments.append(config.outputUrl.posixPath)
		self.marpExportProcess.arguments = arguments
		self.marpExportProcess.standardInput = FileHandle.nullDevice
		// To debug with server's output, comment these 2 lines to inherit stdout.
		self.marpExportProcess.standardOutput =  FileHandle.nullDevice
		self.marpExportProcess.standardError =  FileHandle.nullDevice
		// Run process
		do {
			try self.marpExportProcess.run()
		} catch {
			// Print error
			print("Error generating slides: \(error)")
			// Return to first step
			Task.detached { @MainActor in
				Dialogs.showAlert(
					title: String(localized: "Error"),
					message: String(localized: "An error occurred while exporting the slides.")
				)
				self.reset()
			}
		}
	}
	
	/// An enum representing steps in the slide generation process
	public enum SlideStudioStep: CaseIterable {
		
		case prompt
		case rephrasingPrompt
		case generatingContent
		case listingImagesNeeded
		case findingImages
		case generatingSlides
		case previewEditor
		
		/// Phrase displayed to the user to indicate progress
		public var stallingPhrase: String {
			switch self {
				case .rephrasingPrompt:
					return String(localized: "Enhancing your prompt...")
				case .generatingContent:
					return String(localized: "Retrieving knowledge...")
				case .listingImagesNeeded:
					return String(localized: "Configuring image layout...")
				case .findingImages:
					return String(localized: "Finding images online...")
				case .generatingSlides:
					return String(localized: "Generating slides...")
				default:
					return String(localized: "Generating presentation...")
			}
		}
		
	}
	
	/// A `Bool` representing whether resources will be passed to the chatbot
	public var hasResources: Bool {
		return !tempResources.isEmpty
	}
	
	/// Function to validate dropped item
	public func validateDrop(info: DropInfo) -> Bool {
		return info.hasItemsConforming(to: ["public.file-url"])
	}
	
	/// Function to handle drop
	public func performDrop(info: DropInfo) -> Bool {
		for itemProvider in info.itemProviders(for: ["public.file-url"]) {
			itemProvider.loadItem(
				forTypeIdentifier: "public.file-url",
				options: nil
			) { (item, error) in
				if let data = item as? Data {
					Task.detached { @MainActor in
						await self.addFile(data)
					}
				}
			}
		}
		return true
	}
	
	/// Function to add a file from decoded URL
	public func addFile(_ data: Data) async {
		if let url = URL(
			dataRepresentation: data,
			relativeTo: nil
		) {
			await self.addFile(url)
		}
	}
	
	/// Function to add a file from URL
	public func addFile(_ url: URL) async {
		// Add temp resource if needed
		if self.tempResources.map(
			\.url
		).contains(url) {
			return
		}
		withAnimation(.linear) {
			self.tempResources.append(
				TemporaryResource(
					url: url
				)
			)
		}
	}
	
	/// An enum showing errors possible during the generation process
	enum GenerationError: Error {
		
		case noPrompt
		case rephrasingPromptFailed
		case generatingContentFailed
		case listingImagesNeededFailed
		case findingImagesFailed
		case generatingSlidesFailed
		
	}
	
	/// An image search result
	public struct ImageSearchResult: Codable {
		
		var description: String
		var imageUrls: [URL]
		
	}
	
	/// A configuration to export the slides
	public struct SlideExportConfiguration {
		
		/// The name of the slides file
		public var name: String = "slides \(Date.now.dateString)"
		
		/// The format of the exported slides, of type `Format`
		public var format: Format
		/// The `URL` to the directory which contains the exported slides
		public var outputDirUrl: URL
		
		/// The `URL` to the exported slides
		public var outputUrl: URL {
			let filename: String = "\(self.name).\(self.format.fileExtension)"
			return self.outputDirUrl.appendingPathComponent(filename)
		}
		
		/// A `Bool` representing if the export configuration is valid
		public var isValid: Bool {
			let hasName: Bool = !self.name.isEmpty
			let hasValidFormat: Bool = self.format.isAvailable
			return hasName && hasValidFormat
		}
		
		/// The format of the exported Slides
		public enum Format: String, CaseIterable {
			
			case pdf
			case pptx
			case pptxEditable
			case html
			
			/// The file extension for the format, of type `String`
			public var fileExtension: String {
				switch self {
					case .pptxEditable:
						return "pptx"
					default:
						return self.rawValue
				}
			}
			
			/// The displayed name for the format, of type `String`
			public var displayName: String {
				switch self {
					case .pdf:
						return "PDF"
					case .pptx:
						return "PowerPoint"
					case .pptxEditable:
						return String(localized: "Editable ") + "PowerPoint" + String(
							localized: " (Experimental)"
						)
					case .html:
						return String(localized: "Website")
				}
			}
			
			/// A `Bool` indicating if the export format can be selected
			var isAvailable: Bool {
				// If not editable ppt, return true
				if self != .pptxEditable {
					return true
				} else {
					// Else, check for LibreOffice
					let url: URL? = NSWorkspace
						.shared
						.urlForApplication(
							withBundleIdentifier: "org.libreoffice.script"
						)
					return url != nil
				}
			}
			
		}
		
		/// The default export config
		static public let `default`: SlideExportConfiguration = .init(
			format: .pdf,
			outputDirUrl: URL.downloadsDirectory
		)
		
	}
	
}
