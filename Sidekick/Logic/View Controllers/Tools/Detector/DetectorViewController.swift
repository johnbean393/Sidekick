//
//  DetectorViewController.swift
//  Sidekick
//
//  Created by John Bean on 2/23/25.
//

import Accelerate
import Foundation
import FSKit_macOS
import SwiftUI

public class DetectorViewController: ObservableObject {
	
	/// The state of the detector, of type ``DetectorState``
	@Published public var state: DetectorState = .input {
		didSet {
			// Toggle inspector state
			switch self.state {
				case .input:
					self.showInspector = false
				default:
					self.showInspector = true
			}
		}
	}
	
	/// The text being evaluated, of type `String`
	@Published public var text: String = ""
	
	/// A `Bool` representing whether the inspector is shown
	@Published public var showInspector: Bool = false
	
	/// The evaluation details of the text
	public var evaluationDetails: EvaluationDetails?
	
	/// An `Int` value indicating the AI percentage content of the text
	public var aiScore: Int? {
		// Return nil if the text is empty
		if self.text.isEmpty {
			return nil
		}
		// Calculate score
		if let perplexity = self.perplexity,
			let burstiness = self.burstiness {
			// Normalize scores
			let normalizedPerplexity: Double = 1 - (
				1 / (1 + exp(-0.5 * (perplexity - 9)))
			)
			let normalizedBurstiness: Double = 1 - (
				1 / (1 + exp(-0.35 * (burstiness - 32)))
			)
			// Apply weighting
			let perplexityWeight: Double = 0.66
			let weightedPerplexity: Double = normalizedPerplexity * perplexityWeight
			let weightedBurstiness: Double = normalizedBurstiness * (1.0 - perplexityWeight)
			// Combine
			return Int(round((weightedPerplexity + weightedBurstiness) * 100))
		} else {
			return nil
		}
	}
	
	/// The perplexity score of the text, of type `Double`
	private var perplexity: Double?
	
	/// The burstiness score of the text, of type `Double`
	private var burstiness: Double?
	
	/// The `llama-perplexity` child process to serve the preview
	var perplexityProcess: Process = Process()
	
	/// The`URL` of the text file where the text to evaluate is cached
	private let textFileUrl: URL = Settings
		.cacheUrl
		.appendingPathComponent("textToEvaluate.txt")
	
	/// Function to check the AI percentage of the text
	@MainActor
	public func evaluateText() async {
		// Set state to evaluation
		self.state = .evaluating
		// Save text to file
		try? self.text.write(
			to: self.textFileUrl,
			atomically: true,
			encoding: .utf8
		)
		// Get number of tokens in text
		let tokenNum: Int = await Model.shared.countTokens(in: self.text) ?? 256
		// Return error if insufficient tokens
		if tokenNum <= 256 {
			self.error(
				message: String(
					localized: "Text is not long enough to evaluate."
				)
			)
			return
		}
		// Start `llama-perplexity` process
		self.perplexityProcess = Process()
		self.perplexityProcess.executableURL = Bundle
			.main
			.privateFrameworksURL?
			.appendingPathComponent("llama-perplexity")
		// Formulate arguments
		guard let modelPath: String = Settings.modelUrl?.posixPath else {
			self.error(
				message: String(
					localized: "Could not locate model."
				)
			)
			return
		}
		let arguments: [String] = [
			"--model",
			modelPath,
			"--temp",
			"0",
			"--file",
			self.textFileUrl.posixPath,
			"--ctx-size",
			"128",
			"--ppl-output-type",
			"0"
		]
		self.perplexityProcess.arguments = arguments
		// Capture output data
		let outputPipe: Pipe = Pipe()
		self.perplexityProcess.standardOutput = outputPipe
		// Run process
		do {
			try self.perplexityProcess.run()
		} catch {
			self.error(
				message: String(
					localized: "Could not obtain perplexity score."
				)
			)
			return
		}
		// Get data
		// First, extract text output
		let data: Data = outputPipe.fileHandleForReading.readDataToEndOfFile()
		let perplexityOutput: String = String(
			decoding: data,
			as: UTF8.self
		)
		// Narrow down to line
		let line: String = perplexityOutput
			.split(separator: "\n")
			.map({ String($0) })
			.last ?? ""
		let scores: [Double] = line
			.split(separator: ",")
			.filter({ !$0.isEmpty })
			.map { scoreStr in
				Double(String(scoreStr).dropPrecedingSubstring("]")) ?? nil
			}
			.compactMap({ $0 })
		// Get scores
		let perplexityScore: Double = scores.last ?? 0.0
		let burstinessScore: Double = self.calculateBurstiness(
			self.text
		) ?? 0.0
		// Save scores
		self.perplexity = perplexityScore
		self.burstiness = burstinessScore
		// Get un-deviating sentences
		self.getDeviantSentences()
		// Move to next stage
		self.state = .result
	}
	
	/// Function to calculate burstiness of text
	private func calculateBurstiness(_ text: String) -> Double? {
		var lens: [(Int, Int)] = []
		let sentences: [Substring] = text.split(separator: ". ")
		// Get words and sentence lengths
		for sentence in sentences {
			let chars: Int = sentence.count
			if chars < 1 {
				continue
			}
			let words: Int = sentence.split(separator: " ").count
			lens.append((chars, words))
		}
		let charLengths: [Double] = lens.map { Double($0.0) }
		let wordLengths: [Double] = lens.map { Double($0.1) }
		// Calculate standard deviation
		if let charStd: Double = charLengths.standardDeviation(),
		   let wordStd: Double = wordLengths.standardDeviation() {
			return (charStd + wordStd) / 2
		}
		return nil
	}
	
	/// Function to get sentences that deviate from the median
	private func getDeviantSentences() {
		// Separate into sentences
		let sentences: [String] = self.text.split(separator: ". ").map { String($0) }
		guard !sentences.isEmpty else { return }
		// Create result object
		var evaluationDetails: EvaluationDetails = .init(
			chunks: sentences.map { sentence in
				EvaluationDetails.Chunk(
					text: sentence + ". ",
					state: .normal
				)
			}
		)
		// Get sentence lengths
		let lengths: [Int] = sentences.map { $0.count }
		// Find the median length
		let sortedLengths: [Int] = lengths.sorted()
		let midIndex: Int = sortedLengths.count / 2
		let medianLength: Double
		if sortedLengths.count % 2 == 0 {
			medianLength = Double(sortedLengths[midIndex - 1] + sortedLengths[midIndex]) / 2.0
		} else {
			medianLength = Double(sortedLengths[midIndex])
		}
		// Calculate absolute deviations from the median
		let deviations = sentences.map { abs(Double($0.count) - medianLength) }
		// Find the threshold for the bottom 10% deviating sentences
		let sortedDeviations: [Double] = deviations.sorted(by: <)
		let thresholdIndex: Int = Int(Double(sortedDeviations.count) * 0.1)
		let deviationThreshold: Double = sortedDeviations[thresholdIndex]
		// Find the threshold for the top 10% deviating sentences
		let topThresholdIndex: Int = sortedDeviations.count - thresholdIndex - 1
		let topDeviationThreshold: Double = sortedDeviations[topThresholdIndex]
		// Update evaluationDetails with deviated sentences
		for (index, deviation) in deviations.enumerated() {
			if deviation <= deviationThreshold {
				evaluationDetails.chunks[index].state = .drivingAiProb
			} else if deviation >= topDeviationThreshold {
				evaluationDetails.chunks[index].state = .drivingHumanProb
			}
		}
		self.evaluationDetails = evaluationDetails
	}

	
	/// Function to display error and cancel task
	@MainActor
	private func error(
		message: String
	) {
		Dialogs.showAlert(
			title: String(localized: "Error"),
			message: message
		)
		self.reset()
	}
	
	/// Function to reset the detector
	public func reset(
		resetInput: Bool = true
	) {
		withAnimation(.linear) {
			// Reset inputs
			if resetInput {
				self.text = ""
			}
			self.state = .input
			// Reset analysis results
			self.perplexity = nil
			self.burstiness = nil
			// Terminate process if running
			if self.perplexityProcess.isRunning {
				self.perplexityProcess.terminate()
			}
		}
	}
	
	/// An enum representing the current state of the AI detector
	public enum DetectorState: CaseIterable {
		
		/// The user is currently inputting or editing the text
		case input
		/// Sidekick is evaluating the text for AI use
		case evaluating
		/// Sidekick's evaluation results are displayed to the user
		case result
		
	}
	
}
