//
//  MessageReadAloudButton.swift
//  Sidekick
//
//  Created by John Bean on 3/22/25.
//

import SwiftUI

struct MessageReadAloudButton: View {
	
	@StateObject private var speechSynthesizer: SpeechSynthesizer = .shared
	
	var message: Message
	
	private var isGenerating: Bool {
		return !message.outputEnded && message.getSender() == .assistant
	}
	
	private var isReading: Bool {
		self.speechSynthesizer.isSpeaking
	}
	
	var imageName: String {
		return !self.isReading ? "speaker.wave.3" : "speaker.slash.fill"
	}
	
    var body: some View {
		Button {
			self.speechSynthesizer.toggleReading(
				text: self.message.readableText
			)
		} label: {
			Image(systemName: self.imageName)
				.foregroundStyle(.secondary)
		}
		.buttonStyle(.plain)
		.disabled(self.isGenerating)
    }
	
}

extension Message {
	/// Text to feed into TTS. Strips reasoning chatter so playback
	/// starts at the assistant's actual answer.
	var readableText: String {
		return self.hasReasoning ? self.responseText : self.text
	}
}
