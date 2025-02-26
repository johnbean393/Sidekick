//
//  ChatStyle.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import SwiftUI

struct ChatStyle: TextFieldStyle {
	
	@Environment(\.colorScheme) var colorScheme
	
	@FocusState var isFocused: Bool
	@Binding var isRecording: Bool
	
	var isChatPromptBar: Bool = true
	
	let cornerRadius = 16.0
	var rect: RoundedRectangle {
		RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
	}
	
	var outlineColor: Color {
		if isRecording {
			return .red
		} else if isFocused {
			return .accentColor
		}
		return .primary
	}
	
	func _body(configuration: TextField<Self._Label>) -> some View {
		configuration
			.textFieldStyle(.plain)
			.frame(maxWidth: .infinity)
			.if(isChatPromptBar) { view in
				view
					.padding(.leading, 24)
					.padding(.trailing, 21)
			}
			.if(!isChatPromptBar) { view in
				view
					.padding(.horizontal, 4)
			}
			.padding(8)
			.cornerRadius(cornerRadius)
			.background(
				LinearGradient(
					colors: [
						Color.textBackground,
						Color.textBackground.opacity(0.5)
					],
					startPoint: .leading,
					endPoint: .trailing
				)
			)
			.mask(rect)
			.overlay(
				rect
					.stroke(style: StrokeStyle(lineWidth: 1))
					.foregroundStyle(outlineColor)
			)
			.animation(isFocused ? .easeIn(duration: 0.2) : .easeOut(duration: 0.0), value: isFocused)
	}
	
}

struct ChatButtonStyle: ButtonStyle {
	
	let cornerRadius = 30.0
	var rect: RoundedRectangle {
		RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
	}
	
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.bold()
			.cornerRadius(cornerRadius)
			.background(
				LinearGradient(
					colors: [
						Color.textBackground,
						Color.textBackground.opacity(0.5)
					],
					startPoint: .leading,
					endPoint: .trailing
				)
			)
			.mask(rect)
			.overlay(
				rect
					.stroke(style: StrokeStyle(lineWidth: 1))
					.foregroundStyle(Color.primary)
			)
	}
	
}
