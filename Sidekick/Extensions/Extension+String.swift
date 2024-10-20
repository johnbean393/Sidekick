//
//  Extension+String.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import Foundation
import AppKit

public extension String {
	
	func toRGBA() -> (r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat) {
		var hexSanitized = self.trimmingCharacters(in: .whitespacesAndNewlines)
		hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
		
		var rgb: UInt64 = 0
		var r: CGFloat = 0.0
		var g: CGFloat = 0.0
		var b: CGFloat = 0.0
		var a: CGFloat = 1.0
		
		Scanner(string: hexSanitized).scanHexInt64(&rgb)
		
		r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
		g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
		b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
		a = CGFloat(rgb & 0x000000FF) / 255.0
		
		return (r, g, b, a)
	}
	
	/// Splits a string into groups of `every` n characters, grouping from left-to-right by default. If `backwards` is true, right-to-left.
	func split(every: Int, backwards: Bool = false) -> [String] {
		var result = [String]()
		
		for i in stride(from: 0, to: self.count, by: every) {
			switch backwards {
				case true:
					let endIndex = self.index(self.endIndex, offsetBy: -i)
					let startIndex = self.index(endIndex, offsetBy: -every, limitedBy: self.startIndex) ?? self.startIndex
					result.insert(String(self[startIndex..<endIndex]), at: 0)
				case false:
					let startIndex = self.index(self.startIndex, offsetBy: i)
					let endIndex = self.index(startIndex, offsetBy: every, limitedBy: self.endIndex) ?? self.endIndex
					result.append(String(self[startIndex..<endIndex]))
			}
		}
		
		return result
	}
	
	
	func slice(from: String, to: String) -> String? {
		return (range(of: from)?.upperBound).flatMap { substringFrom in
			(range(of: to, range: substringFrom..<endIndex)?.lowerBound).map { substringTo in
				String(self[substringFrom..<substringTo])
			}
		}
	}
	
	/// Function to copy the string to the clipboard
	func copy() {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.declareTypes([.string], owner: nil)
		pasteboard.setString(self, forType: .string)
	}
	
	/// Function to add a trailing quote or space if needed
	func removeUnmatchedTrailingQuote() -> String {
		var outputString = self
		if self.last != "\"" { return outputString }
		
		// Count the number of quotes in the string
		let countOfQuotes = outputString.reduce(
			0,
			{ (count, character) -> Int in
				return character == "\"" ? count + 1 : count
			})
		
		// If there is an odd number of quotes, remove the last one
		if countOfQuotes % 2 != 0 {
			if let indexOfLastQuote = outputString.lastIndex(of: "\"") {
				outputString.remove(at: indexOfLastQuote)
			}
		}
		
		return outputString
	}
	
	/// Function to split a string by sentence
	func splitBySentence() -> [String] {
		var sentences: [String] = []
		self.enumerateSubstrings(in: self.startIndex..., options: [.localized, .bySentences]) { (tag, _, _, _) in
			let sentence: String = tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			sentences.append(sentence)
		}
		return sentences
	}
	
	/// Function to group sentences into chunks
	func groupIntoChunks(maxChunkSize: Int) -> [String] {
		// Split into sentences
		let sentences: [String] = self.splitBySentence()
		// Group
		var chunks: [String] = []
		var chunk: [String] = []
		for (index, sentence) in sentences.enumerated() {
			// Calculate length accounting for spaces
			let chunkLength: Int = chunk.map(\.count).reduce(0,+) + sentence.count - 1
			let islastSentence: Bool = index == (sentences.count - 1)
			if chunkLength < maxChunkSize || islastSentence {
				chunk.append(sentence)
			} else {
				chunks.append(chunk.joined(separator: " "))
				chunk.removeAll()
			}
		}
		// Return result
		return chunks
	}
	
}
