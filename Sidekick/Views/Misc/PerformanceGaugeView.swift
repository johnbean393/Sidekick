//
//  PerformanceGaugeView.swift
//  Sidekick
//
//  Created by Bean John on 11/9/24.
//

import SwiftUI
import DefaultModels

struct PerformanceGaugeView: View {
	
	let gpu: GPUInfoDevice? = try? .init()
	
	var name: String {
		return self.gpu?.name ?? "Unknown GPU"
	}
	
	var performance: CGFloat {
		return (self.gpu?.flops ?? 0) / pow(10, 12)
	}

	var historicalGPUs: [GPU] {
		let lastIndexByName = Dictionary(
			GPU.all.enumerated().map { ($0.element.name, $0.offset) },
			uniquingKeysWith: { _, latest in latest }
		)
		
		return GPU.all.enumerated().compactMap { index, gpu in
			lastIndexByName[gpu.name] == index ? gpu : nil
		}
	}

	var matchedHistoricalGPU: GPU? {
		return historicalGPUs.first { $0.name == self.name }
	}

	var displayedHistoricalGPUs: [GPU] {
		guard let matchedHistoricalGPU else {
			return historicalGPUs
		}
		
		return historicalGPUs.filter { $0.id != matchedHistoricalGPU.id }
	}

	var currentDisplayPerformance: CGFloat {
		return matchedHistoricalGPU?.tflops ?? performance
	}
	
	var minTflops: CGFloat {
		let allValues = displayedHistoricalGPUs.map(\.tflops) + [currentDisplayPerformance]
		return allValues.sorted().first ?? 0
	}
	
	var maxTflops: CGFloat {
		let allValues = displayedHistoricalGPUs.map(\.tflops) + [currentDisplayPerformance]
		return allValues.sorted().last ?? 0
	}
	
	let colors: [Color] = [.red, .yellow, .green]
	
	var body: some View {
		VStack {
			HStack {
				Text("GPU poor")
				Spacer()
				Text("GPU rich")
			}
			guage
		}
	}
	
	var guage: some View {
		GeometryReader(
			alignment: .center
		) { proxy in
			scaleLine
				.clipShape(
					Capsule()
				)
					.overlay(alignment: .leading) {
						Group {
							ForEach(displayedHistoricalGPUs) { gpu in
								PerformancePointView(
									name: gpu.name,
									width: proxy.size.width,
									min: minTflops,
									max: maxTflops,
									value: gpu.tflops
								)
							}
							PerformancePointView(
								name: self.name,
								isCurrentDevice: true,
								width: proxy.size.width,
								min: minTflops,
								max: maxTflops,
								value: currentDisplayPerformance
							)
							.shadow(radius: 10)
						}
					}
		}
		.frame(maxHeight: 15)
	}
	
	var scaleLine: some View {
		LinearGradient(
			gradient: Gradient(
				colors: self.colors
			),
			startPoint: .leading,
			endPoint: .trailing
		)
		.frame(maxHeight: 10)
	}
	
	private struct PerformancePointView: View {
		
		var name: String
		var isCurrentDevice: Bool = false
		var width: CGFloat
		
		var pointScale: CGFloat {
			return isCurrentDevice ? 1.5 : 1.00
		}
		
		var min: CGFloat
		var max: CGFloat
		var value: CGFloat
		
		var valueDescription: String {
			let num: CGFloat = round(self.value * 100) / 100
			return "\(name): \(num) TFLOPS"
		}
		
		var percent: CGFloat {
			return (self.value - self.min) / (self.max - self.min)
		}
		
		var fillColor: Color {
			return .white
		}
		
		let diameter: CGFloat = 10
		
		var xOffset: CGFloat {
			return ((width - diameter) * percent) / pointScale
		}
		
		@State private var isHovering: Bool = false
		
		var body: some View {
			circle
				.popover(isPresented: $isHovering) {
					Text(valueDescription)
						.padding(7)
				}
				.onHover { hovering in
					withAnimation(.linear) {
						self.isHovering = hovering
					}
				}
				.offset(
					x: xOffset
				)
				.scaleEffect(pointScale)
		}
		
		var circle: some View {
			Circle()
				.fill(
					isCurrentDevice ? fillColor : .secondary.opacity(0.6)
				)
				.frame(width: diameter)
		}
		
	}
	
}

#Preview {
	PerformanceGaugeView()
}
