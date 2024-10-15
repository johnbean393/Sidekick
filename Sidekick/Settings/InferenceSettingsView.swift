//
//  InferenceSettingsView.swift
//  Sidekick
//
//  Created by Bean John on 10/14/24.
//

import FSKit_macOS
import SwiftUI
import UniformTypeIdentifiers

struct InferenceSettingsView: View {
	
	@State private var isEditingSystemPrompt: Bool = false
	
	@State private var temperature: Double = InferenceSettings.temperature
	@State private var contextLength: Int = InferenceSettings.contextLength
	
    var body: some View {
		Form {
			Section {
				model
			} header: {
				Text("Model")
			}
			Section {
				parameters
			} header: {
				Text("Parameters")
			}
		}
		.formStyle(.grouped)
		.sheet(isPresented: $isEditingSystemPrompt) {
			SystemPromptEditor(
				isEditingSystemPrompt: $isEditingSystemPrompt
			)
		}
    }
	
	var model: some View {
		HStack(alignment: .top) {
			VStack(alignment: .leading) {
				Text("Model")
					.font(.title3)
					.bold()
				Text("This will be the default LLM used.")
					.font(.caption)
			}
			Spacer()
			Button {
				let _ = Settings.selectModel()
			} label: {
				Text("Select")
			}
		}
	}
	
	var parameters: some View {
		Group {
			systemPromptEditor
			contextLengthEditor
			temperatureEditor
		}
	}
		
	var systemPromptEditor: some View {
		HStack(alignment: .top) {
			VStack(alignment: .leading) {
				Text("System Prompt")
					.font(.title3)
					.bold()
			}
			Spacer()
			Button {
				self.isEditingSystemPrompt.toggle()
			} label: {
				Text("Customise")
			}
		}
	}
	
	var contextLengthEditor: some View {
		HStack(alignment: .top) {
			VStack(alignment: .leading) {
				Text("Model")
					.font(.title3)
					.bold()
				Text("Context length is the maximum amount of information it can take as input for a query. A larger context length allows an LLM to recall more information, at the cost of slower output and more memory usage.")
					.font(.caption)
			}
			Spacer()
			TextField(
				"",
				value: $contextLength,
				formatter: NumberFormatter()
			)
			.textFieldStyle(.plain)
		}
		.onChange(of: contextLength) {
			InferenceSettings.contextLength = self.contextLength
		}
	}
	
	var temperatureEditor: some View {
		HStack(alignment: .top) {
			VStack(alignment: .leading) {
				Text("Temperature")
					.font(.title3)
					.bold()
				Text("Temperature is a parameter that influences LLM output, determining whether it is more random and creative or more predictable.")
					.font(.caption)
			}
			.frame(width: 250)
			Spacer()
			Slider(
				value: $temperature,
				in: 0...2,
				step: 0.1
			)
			.frame(minWidth: 275)
			.overlay(alignment: .leading) {
				Text(String(format: "%g", self.temperature))
					.font(.body)
					.foregroundStyle(.secondary)
					.padding(.leading, 100)
			}
		}
		.onChange(of: temperature) {
			InferenceSettings.temperature = self.temperature
		}
	}
	
}

#Preview {
    InferenceSettingsView()
}