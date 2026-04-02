//
//  DownloadManager.swift
//  Sidekick
//
//  Created by Bean John on 9/22/24.
//

import DefaultModels
import Foundation
import OSLog
import SwiftUI

@MainActor
/// Controls the download of LLMs
public class DownloadManager: NSObject, ObservableObject {
	
    /// A `Logger` object for the `PromptInputField` object
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: DownloadManager.self)
    )
    
	/// Global instance of `DownloadManager`
	static var shared: DownloadManager = DownloadManager()
	
	/// Property for currently downloading URL session
	private var urlSession: URLSession!
	/// A `Bool` representing whether the model should be added to the model manager
	private var shouldAddModel: Bool = true
	/// Published property for download progress
	@Published var tasks: [URLSessionTask] = []
	/// Published property for last update
	@Published var lastUpdatedAt = Date()
	/// Published property for whether the model was downloaded
	@Published var didFinishDownloadingModel: Bool = false
	
	override private init() {
		super.init()
		let config: URLSessionConfiguration = URLSessionConfiguration.background(
			withIdentifier: "com.pattonium.Sidekick.DownloadManager"
		)
		config.isDiscretionary = false
		
		// Warning: Make sure that the URLSession is created only once (if an URLSession still
		// exists from a previous download, it doesn't create a new URLSession object but returns
		// the existing one with the old delegate object attached)
		self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
		// Update lists of tasks for UI
		self.updateTasks()
	}
	
	/// Function to download an LLM
	@MainActor
	public func downloadModel(
		model: HuggingFaceModel
	) async {
		await downloadModel(url: model.url)
	}
	
	/// Function to download an LLM
	@MainActor
	public func downloadModel(
		url: URL
	) async {
		// Check if accessible
		URL.verifyURL(
			url: url
		) { isValid in
			if isValid {
				// If accessible
				self.startDownload(
					url: url
				)
			} else {
				// If not accessible
				let mirrorUrlString: String = url.absoluteString.replacingOccurrences(
					of: "huggingface.co",
					with: "hf-mirror.com"
				)
				self.startDownload(
					url: URL(string: mirrorUrlString)!
				)
			}
		}
		// Add lengthy task
		LengthyTasksController.shared.addTask(
			id: UUID(),
			task: String(
				localized: "Downloading model \(url.lastPathComponent)"
			)
		)
	}
	
	/// Function to download the default large language model
	@MainActor
	public func downloadDefaultModel() async {
		// Set to add model
		self.shouldAddModel = true
		// Get default model
		let model: HuggingFaceModel = await DefaultModels.recommendedModel
        Self.logger.info("Trying to download \(model.name, privacy: .public)")
		// Download model
		await self.downloadModel(model: model)
	}
	
	/// Function to download the default completions model
	@MainActor
    public func downloadDefaultCompletionsModel() async {
        // Set to not add model
        self.shouldAddModel = false
        // Get default model
        let modelUrl: URL = URL(string: "https://huggingface.co/mradermacher/Qwen3-1.7B-Base-GGUF/resolve/main/Qwen3-1.7B-Base.Q4_K_M.gguf")!
        Self.logger.info("Trying to download \(modelUrl.deletingLastPathComponent().lastPathComponent, privacy: .public)")
        // Download model
        await self.downloadModel(url: modelUrl)
        // Add download location to settings
        let fileName: String = modelUrl.lastPathComponent
        let destinationUrl: URL = Settings.dirUrl.appendingPathComponent(
            fileName
        )
        InferenceSettings.completionsModelUrl = destinationUrl
    }
	
	private func startDownload(
        url: URL
    ) {
        Self.logger.info("Starting download for resource \"\(url, privacy: .public)\"")
		// Ignore download if it's already in progress
		if self.tasks.contains(where: {
			$0.originalRequest?.url == url
		}) {
			return
		}
		let task: URLSessionTask = urlSession.downloadTask(with: url)
		DispatchQueue.main.async {
			self.tasks.append(task)
		}
		task.resume()
	}
	
	@MainActor
	private func updateTasks() {
		self.urlSession.getAllTasks { tasks in
			DispatchQueue.main.async {
				self.tasks = tasks
				self.lastUpdatedAt = Date()
			}
		}
	}
}

extension DownloadManager: URLSessionDelegate, URLSessionDownloadDelegate {
	
	nonisolated public func urlSession(
		_: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData _: Int64,
		totalBytesWritten _: Int64,
		totalBytesExpectedToWrite _: Int64
	) {
		DispatchQueue.main.async {
			let now: Date = Date()
			if self.lastUpdatedAt.timeIntervalSince(now) > 10 {
				self.lastUpdatedAt = now
			}
		}
	}
	
	nonisolated public func urlSession(
		_: URLSession,
		task: URLSessionTask,
		didCompleteWithError error: Error?
	) {
		if let error = error {
			os_log("Download error: %@", type: .error, String(describing: error))
		} else {
			os_log("Task finished: %@", type: .info, task)
		}
		
		let taskId = task.taskIdentifier
		DispatchQueue.main.async {
			self.tasks.removeAll(where: { $0.taskIdentifier == taskId })
		}
	}
	
	nonisolated public func urlSession(
		_: URLSession,
		downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		// Move file to app resources
		let fileName = downloadTask.originalRequest?.url?.lastPathComponent ?? "defaultModel.gguf"
		let destinationURL = Settings.dirUrl.appending(
			path: fileName
		)
		// Remove if exists
		let fileManager = FileManager.default
		try? fileManager.removeItem(at: destinationURL)
		do {
			// Check if dir exists
			let folderExists: Bool = (
				try? Settings.dirUrl.checkResourceIsReachable()
			) ?? false
			// If not, fix
			if !folderExists {
				try fileManager.createDirectory(
					at: Settings.dirUrl,
					withIntermediateDirectories: false
				)
			}
			// Move the model to the directory
			try fileManager.moveItem(at: location, to: destinationURL)
			// Point to the model if needed
			Task { @MainActor in
				if self.shouldAddModel {
					if Settings.modelUrl == nil {
						Settings.selectMainLocalModel(destinationURL)
					}
					ModelManager.shared.add(destinationURL)
				}
				self.didFinishDownloadingModel = true
			}
		} catch {
			os_log("FileManager copy error at %@ to %@ error: %@", type: .error, location.absoluteString, destinationURL.absoluteString, error.localizedDescription)
			return
		}
		// Remove lengthy task
		LengthyTasksController.shared.tasks = LengthyTasksController.shared.tasks.filter {
			$0.name != "Downloading model \(fileName)"
		}
	}
	
	/// A `View` that shows download progess
	public var progressView: some View {
		Group {
			ForEach(
				self.tasks,
				id: \.self
			) { task in
				ProgressView(task.progress)
					.progressViewStyle(.linear)
			}
		}
		.padding(.top)
	}
		
}
