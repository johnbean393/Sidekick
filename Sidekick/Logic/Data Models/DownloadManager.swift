//
//  DownloadManager.swift
//  Sidekick
//
//  Created by Bean John on 9/22/24.
//

import DefaultModels
import Foundation
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
/// Controls the download of LLMs. ``@Observable`` thin service —
/// the plan kept managers like this one (inference, downloads)
/// rather than turning them into static enums because their state
/// is genuinely transient and view-bindable.
public final class DownloadManager: NSObject {

    /// A `Logger` object for the `PromptInputField` object
    @ObservationIgnored
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: DownloadManager.self)
    )

	/// Global instance of `DownloadManager`
	static var shared: DownloadManager = DownloadManager()

	/// Property for currently downloading URL session
	@ObservationIgnored
	private var urlSession: URLSession!
	/// A `Bool` representing whether the model should be added to the model manager
	@ObservationIgnored
	private var shouldAddModel: Bool = true
	/// Observable property for download progress
	var tasks: [URLSessionTask] = []
	/// Observable property for last update
	var lastUpdatedAt = Date()
	/// Observable property for whether the model was downloaded
	var didFinishDownloadingModel: Bool = false
	/// The recommended default model for the current device. Surfaces
	/// model details (name, parameter count, family) to the setup UI so
	/// users can see what "Download Default Model" actually refers to
	/// *before* they commit to the download.
	var recommendedModel: HuggingFaceModel?
	/// The on-disk download size of ``recommendedModel`` in bytes, when
	/// known. Resolved by a lightweight `HEAD` request and used purely
	/// for display.
	var recommendedModelDownloadSize: Int64?
	/// `true` while the recommended model is being resolved (network
	/// fetch for the live catalog plus an optional `HEAD` for the file
	/// size). Lets the UI show a loading state instead of a stale or
	/// empty preview.
	var isResolvingRecommendedModel: Bool = false
	/// The most recent download failure, if any. Cleared at the start
	/// of each new download attempt so retrying hides the error.
	var downloadError: String?
	/// Mirrors whether the active download tasks have been suspended.
	/// `URLSessionTask.state` isn't observable through Swift's
	/// `@Observable` macro, so we track the user-initiated pause
	/// state ourselves to drive the play/pause toggle in the UI.
	var isPaused: Bool = false
	/// Live byte counter for the active download. Driven by
	/// ``URLSessionDownloadDelegate``'s `didWriteData` so the UI can
	/// render text like `"1.2 GB of 4.7 GB"` without needing to KVO
	/// into ``URLSessionTask.progress`` from SwiftUI.
	var bytesWritten: Int64 = 0
	/// Expected total bytes for the active download. `0` while
	/// unknown (e.g. before the server reports `Content-Length`).
	var bytesExpected: Int64 = 0
	
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
		// Reset transient state so the UI can react to a fresh attempt
		// (e.g. clearing a previous error, allowing the completion sheet
		// to fire again on subsequent successes).
		self.downloadError = nil
		self.didFinishDownloadingModel = false
		self.bytesWritten = 0
		self.bytesExpected = 0
		self.isPaused = false
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
		// Resolve the recommended model up front so we surface the same
		// thing in the preview and in the actual download. Falls back to
		// the cached preview if the live catalog can't be re-fetched.
		let model: HuggingFaceModel
		if let cached = self.recommendedModel {
			model = cached
		} else {
			model = await DefaultModels.recommendedModel
			self.recommendedModel = model
		}
		Self.logger.info("Trying to download \(model.name, privacy: .public)")
		// Download model
		await self.downloadModel(model: model)
	}

	/// Resolve the default-model recommendation for the current device
	/// and probe its download size, populating ``recommendedModel`` and
	/// ``recommendedModelDownloadSize``. Safe to call repeatedly; while
	/// in flight, ``isResolvingRecommendedModel`` is `true`.
	///
	/// Intended for the setup screen so the user sees *which* model the
	/// "Download Default Model" button refers to before they click it.
	@MainActor
	public func prepareRecommendedModel() async {
		if self.isResolvingRecommendedModel { return }
		self.isResolvingRecommendedModel = true
		defer { self.isResolvingRecommendedModel = false }
		let model: HuggingFaceModel = await DefaultModels.recommendedModel
		self.recommendedModel = model
		self.recommendedModelDownloadSize = await Self.fetchDownloadSize(for: model.url)
	}

	/// Issues a `HEAD` request against the model's download URL to
	/// recover the `Content-Length`. Returns `nil` if the host cannot
	/// be reached or the header is absent so the UI can degrade
	/// gracefully (e.g. omit the size from the button label).
	private static func fetchDownloadSize(for url: URL) async -> Int64? {
		var request: URLRequest = URLRequest(url: url, timeoutInterval: 5)
		request.httpMethod = "HEAD"
		let configuration: URLSessionConfiguration = .default
		configuration.timeoutIntervalForRequest = 5
		configuration.timeoutIntervalForResource = 5
		let session: URLSession = URLSession(configuration: configuration)
		do {
			let (_, response) = try await session.data(for: request)
			if let httpResponse = response as? HTTPURLResponse,
			   let lengthString = httpResponse.value(forHTTPHeaderField: "Content-Length"),
			   let length = Int64(lengthString),
			   length > 0 {
				return length
			}
			return nil
		} catch {
			return nil
		}
	}
	
	/// Suspends every active download. Background-session tasks
	/// support `suspend()`, so this keeps the partial data on disk and
	/// resumes from the same byte offset when ``resumeAllDownloads()``
	/// is called.
	@MainActor
	public func pauseAllDownloads() {
		guard !self.tasks.isEmpty else { return }
		for task in self.tasks where task.state == .running {
			task.suspend()
		}
		self.isPaused = true
	}

	/// Resumes every suspended download. Counterpart to
	/// ``pauseAllDownloads()``.
	@MainActor
	public func resumeAllDownloads() {
		guard !self.tasks.isEmpty else { return }
		for task in self.tasks where task.state == .suspended {
			task.resume()
		}
		self.isPaused = false
	}

	/// Cancels every active download. Tasks fire
	/// `didCompleteWithError` with `NSURLErrorCancelled`, which the
	/// delegate explicitly treats as a clean stop (no error surfaced
	/// to the UI). Returns `true` if any task was actually cancelled.
	@discardableResult
	@MainActor
	public func cancelAllDownloads() -> Bool {
		guard !self.tasks.isEmpty else { return false }
		for task in self.tasks {
			task.cancel()
		}
		// Optimistically clear local state so the UI flips back to
		// the picker immediately, rather than waiting for the
		// delegate callback to fire.
		self.tasks = []
		self.isPaused = false
		self.bytesWritten = 0
		self.bytesExpected = 0
		self.didFinishDownloadingModel = false
		self.downloadError = nil
		return true
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
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		DispatchQueue.main.async {
			// Coalesce updates to ~10/s so we don't churn observers
			// during high-throughput chunks. (The original check had
			// the operands reversed and effectively never fired.)
			// `URLSession` reports `NSURLSessionTransferSizeUnknown`
			// (-1) when no `Content-Length` is available; clamp to 0
			// so the UI can treat it as "indeterminate".
			let now: Date = Date()
			let isComplete: Bool = totalBytesExpectedToWrite > 0
				&& totalBytesWritten >= totalBytesExpectedToWrite
			if isComplete || now.timeIntervalSince(self.lastUpdatedAt) > 0.1 {
				self.bytesWritten = totalBytesWritten
				self.bytesExpected = max(0, totalBytesExpectedToWrite)
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
		let fileName: String = task.originalRequest?.url?.lastPathComponent ?? ""
		// Treat user-initiated cancellation as a normal stop, not a
		// failure to surface. Without this guard, hitting Cancel would
		// flash a "Download failed: cancelled" message.
		let wasCancelled: Bool = {
			guard let nsError = error as NSError? else { return false }
			return nsError.domain == NSURLErrorDomain
				&& nsError.code == NSURLErrorCancelled
		}()
		let errorDescription: String? = wasCancelled ? nil : error?.localizedDescription
		DispatchQueue.main.async {
			self.tasks.removeAll(where: { $0.taskIdentifier == taskId })
			// Surface failures to the UI so the setup screen can show
			// an error + retry affordance rather than appearing to hang.
			if let errorDescription {
				self.downloadError = errorDescription
				self.didFinishDownloadingModel = false
			}
			// Reset transient progress + pause state once nothing is
			// in flight, so a fresh attempt starts from a clean slate.
			if self.tasks.isEmpty {
				self.bytesWritten = 0
				self.bytesExpected = 0
				self.isPaused = false
			}
			// Clear the matching lengthy-task entry when a download
			// stops for any reason (success is handled in
			// `didFinishDownloadingTo`, but failure/cancellation needs
			// to be cleaned up here too).
			if !fileName.isEmpty {
				let pending = LengthyTasksController.shared.tasks.contains {
					$0.name == "Downloading model \(fileName)"
				}
				if pending {
					LengthyTasksController.shared.tasks = LengthyTasksController.shared.tasks.filter {
						$0.name != "Downloading model \(fileName)"
					}
				}
			}
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
					ModelManager.add(destinationURL)
				}
				self.didFinishDownloadingModel = true
			}
		} catch {
			os_log("FileManager copy error at %@ to %@ error: %@", type: .error, location.absoluteString, destinationURL.absoluteString, error.localizedDescription)
			let errorDescription: String = error.localizedDescription
			Task { @MainActor in
				self.downloadError = errorDescription
				self.didFinishDownloadingModel = false
			}
			return
		}
		// Remove lengthy task
		Task { @MainActor in
			LengthyTasksController.shared.tasks = LengthyTasksController.shared.tasks.filter {
				$0.name != "Downloading model \(fileName)"
			}
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
