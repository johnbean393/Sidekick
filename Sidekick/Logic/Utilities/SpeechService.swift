//
//  SpeechService.swift
//  Sidekick
//
//  Created by John Bean on 3/22/25.
//

import AVFoundation
import Foundation
import OSLog
import SwiftUI

class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
	
	var onSpeechFinished: (() -> Void)?
	var onSpeechStart: (() -> Void)?
	
	func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
		onSpeechFinished?()
	}
	
	func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
		onSpeechStart?()
	}
	
	func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didReceiveError error: Error, for utterance: AVSpeechUtterance, at characterIndex: UInt) {
		print("Speech synthesis error: \(error)")
	}
}

@MainActor
final class SpeechSynthesizer: NSObject, ObservableObject {
	
	/// A `Logger` object for the ``SpeechSynthesizer`` object
	private static let logger: Logger = .init(
		subsystem: Bundle.main.bundleIdentifier!,
		category: String(describing: SpeechSynthesizer.self)
	)
	
	/// Static global singleton instance of ``SpeechSynthesizer``
	static let shared = SpeechSynthesizer()
	/// The system speech synthesizer
	private let synthesizer = AVSpeechSynthesizer()
	/// The delegate to handle TTS requests
	private let delegate = SpeechSynthesizerDelegate()
	
	@Published var isSpeaking = false
	@Published var voices: [AVSpeechSynthesisVoice] = []
	
	override init() {
		super.init()
		self.synthesizer.delegate = self.delegate
		self.fetchVoices()
	}
	
	/// Function to get the ID of the currently selected voice
	private func getVoiceIdentifier() -> String? {
		let voiceIdentifier = UserDefaults.standard.string(forKey: "voiceId")
		if let voice = voices.first(where: {$0.identifier == voiceIdentifier}) {
			return voice.identifier
		}
		
		return voices.first?.identifier
	}
	
	var lastCancelation: (() -> Void)? = {}
	
	/// Function to perform TTS on a `String`
	public func speak(
		text: String,
		onFinished: @escaping () -> Void = {}
	) async {
		// Get voice
		guard let voiceIdentifier: String = getVoiceIdentifier() else {
			Self.logger.error("Could not find selected voice identifier")
			return
		}
		lastCancelation = onFinished
		delegate.onSpeechFinished = {
			withAnimation {
				self.isSpeaking = false
			}
			onFinished()
		}
		delegate.onSpeechStart = {
			withAnimation(.linear) {
				self.isSpeaking = true
			}
		}
		let utterance = AVSpeechUtterance(string: text)
		utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
		utterance.rate = 0.52 // Slightly faster than medium speed
		synthesizer.speak(utterance)
	}
	
	/// Function to stop current TTS task
	public func stopSpeaking() async {
		withAnimation(.linear) {
			self.isSpeaking = false
		}
		lastCancelation?()
		synthesizer.stopSpeaking(at: .immediate)
	}
	
	/// Shared start/stop entry point used by message views. When the
	/// synthesizer is already speaking the call stops playback;
	/// otherwise it begins reading `text`. Decouples callers from
	/// the synthesizer's mutable state so a chip and a menu item can
	/// drive the same backend without re-implementing the toggle
	/// each time.
	public func toggleReading(
		text: String,
		onFinished: @escaping () -> Void = {}
	) {
		Task { @MainActor in
			if self.isSpeaking {
				await self.stopSpeaking()
			} else {
				await self.speak(text: text, onFinished: onFinished)
			}
		}
	}
	
	/// Function to fetch list of all available voices
	public func fetchVoices() {
		let voices = AVSpeechSynthesisVoice.speechVoices().sorted { (firstVoice: AVSpeechSynthesisVoice, secondVoice: AVSpeechSynthesisVoice) -> Bool in
			return firstVoice.quality.rawValue > secondVoice.quality.rawValue
		}
		// Prevent state refresh if there are no new elements
		let diff = self.voices.elementsEqual(voices, by: { $0.identifier == $1.identifier })
		if diff {
			return
		}
		DispatchQueue.main.async {
			self.voices = voices
		}
	}
	
}
