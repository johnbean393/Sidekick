//
//  Extension+String.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import AppKit
import Foundation
import Highlightr

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
    
    /// Function to copy the string to the clipboard while preserving formatting
    func copyWithFormatting() {
        if let highlightr: Highlightr = Highlightr() {
            highlightr.setTheme(to: "purebasic.min")
            // Convert the string to an attributed string with Markdown highlighting
            if let attributedString: NSAttributedString = highlightr.highlight(
                self,
                as: "markdown"
            ) {
                // Create a mutable copy to perform modifications
                let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)
                // Process markdown elements using dedicated NSAttributedString extensions
                mutableAttributedString.convertCourierFonts()
                mutableAttributedString.removeTextColor()
                mutableAttributedString.processMarkdownImages()
                mutableAttributedString.processMarkdownLinks()
                mutableAttributedString.processMarkdownHeadings()
                mutableAttributedString.removeMarkdownBlockCodes()
                mutableAttributedString.removeMarkdownDividers()
                mutableAttributedString.stripMarkdownSymbols()
                // Copy the processed attributed string to the pasteboard
                mutableAttributedString.copyToPasteboard()
                return
            }
        }
        // If failed, just copy plain text
        self.copy()
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
    
    subscript (i: Int) -> String {
        return self[i ..< i + 1]
    }
    
    func substring(fromIndex: Int) -> String {
        return self[min(fromIndex, count)..<count]
    }
    
    func substring(toIndex: Int) -> String {
        return self[0 ..< max(0, toIndex)]
    }
    
    subscript (r: Range<Int>) -> String {
        let range = Range(
            uncheckedBounds: (
                lower: max(
                    0,
                    min(count, r.lowerBound)
                ),
                upper: min(count, max(0, r.upperBound))
            )
        )
        let start = index(startIndex, offsetBy: range.lowerBound)
        let end = index(start, offsetBy: range.upperBound - range.lowerBound)
        return String(self[start ..< end])
    }
    
    /// An `NSString` derived from the string
    private var nsString: NSString {
        return NSString(string: self)
    }
    
    /// Function to split the string into LaTeX and non-LaTeX sections
    func splitByLatex() -> [(string: String, isLatex: Bool)] {
        // Regex pattern to match LaTeX
        let latexPattern: String = "(\\\\\\[(.*?)\\\\\\])|(\\$\\$(.*?)\\$\\$)"
        let regex = try! NSRegularExpression(
            pattern: latexPattern,
            options: [.dotMatchesLineSeparators]
        )
        
        // Define variables
        var sections: [(string: String, isLatex: Bool)] = []
        var lastIndex = 0
        
        // Get matches
        let matches = regex.matches(
            in: self,
            options: [],
            range: NSRange(location: 0, length: self.utf16.count)
        )
        
        // Loop through matches
        for match in matches {
            let matchRange = match.range
            
            // Add text before LaTeX if any
            if matchRange.location > lastIndex {
                let textRange = NSRange(location: lastIndex, length: matchRange.location - lastIndex)
                let textSection = nsString.substring(with: textRange)
                if !textSection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sections.append((textSection, false))
                }
            }
            
            // Add LaTeX section
            let latexSection = nsString.substring(with: matchRange)
            sections.append((latexSection, true))
            
            lastIndex = matchRange.location + matchRange.length
        }
        
        // Add remaining text if any
        if lastIndex < self.utf16.count {
            let textSection = nsString.substring(from: lastIndex)
            if !textSection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append((textSection, false))
            }
        }
        
        return sections
    }
    
    /// Function to replace the suffix in a `String`
    func replacingSuffix(_ suffix: String, with newSuffix: String) -> String {
        if self.hasSuffix(suffix) {
            return self.dropLast(suffix.count) + newSuffix
        }
        return self
    }
    
    /// Function to drop all characters preceding a substring
    func dropPrecedingSubstring(
        _ substring: String,
        options: String.CompareOptions = [],
        includeCharacter: Bool = false
    ) -> String {
        // Find the range of the substring
        guard let range = self.range(
            of: substring,
            options: options
        ) else {
            // Return the original string if the substring is not found
            return self
        }
        // Drop substring
        if !includeCharacter {
            return String(self[range.upperBound...])
        } else {
            return String(self[range.lowerBound...])
        }
    }
    
    /// Function to drop all characters following a substring
    func dropFollowingSubstring(
        _ substring: String,
        options: String.CompareOptions = [],
        includeCharacter: Bool = false
    ) -> String {
        // Find the range of the substring
        guard let range = self.range(
            of: substring,
            options: options
        ) else {
            // Return the original string if the substring is not found
            return self
        }
        // Drop substring
        if !includeCharacter {
            return String(self[..<range.lowerBound])
        } else {
            return String(self[...range.lowerBound])
        }
    }
    
    /// Function to remove enclosing characters
    func removeEnclosingCharacters(
        character: Character
    ) -> String {
        guard self.hasPrefix(String(character)) && self
            .hasSuffix(String(character)) else {
            return self
        }
        return String(self.dropFirst().dropLast())
    }
    
    /// A list of standard special reasoning tokens
    static let specialReasoningTokens: [[String]] = [
        ["<think>", "</think>"],
        ["<thought>", "</thought>"]
    ]
    
    /// A `String` containing the reasoning process
    var reasoningProcess: String? {
        // List special reasoning tokens
        let specialTokenSets: [[String]] = String.specialReasoningTokens
        // Extract text between tokens
        // For each set of tokens
        for specialTokenSet in specialTokenSets {
            // Get range of start token
            if let startRange = self.range(
                of: specialTokenSet.first!
            ) {
                // Get range of end token
                if let endRange = self.range(
                    of: specialTokenSet.last!,
                    range: startRange.upperBound..<self.endIndex
                ) {
                    // Return text
                    return String(
                        self[startRange.upperBound..<endRange.lowerBound]
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        // If failed to locate reasoning text, return nil
        return nil
    }
    
    /// A `String` containing the text with the reasoning process removed
    var reasoningRemoved: String {
        // List special reasoning tokens
        let specialTokenSets: [[String]] = Self.specialReasoningTokens
        // Init variable for stripped text
        var processedResponse: String = self
        // Extract text
        for tokenSet in specialTokenSets {
            // If only the first token is found, return empty response
            if self.contains(tokenSet.first!) && !self.contains(tokenSet.last!) {
                return ""
            }
            // Extract text between tokens
            if let startRange = processedResponse.range(of: tokenSet.first!),
               let endRange = processedResponse.range(
                of: tokenSet.last!,
                range: startRange.upperBound..<processedResponse.endIndex
               ) {
                // Remove reasoning tokens and the text inside them
                processedResponse.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            }
        }
        // Return clean result
        return processedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Computed property to extract the first top‐level JSON object or array (including all nested content), dropping any surrounding text
    var extractedJson: String? {
        // 1. Locate the first opener
        guard let start = firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        let openChar = self[start]
        let closeChar: Character = (openChar == "{") ? "}" : "]"
        // 2. Locate the last closer of the same type
        guard let end = lastIndex(where: { $0 == closeChar }), end > start else {
            return nil
        }
        // 3. Extract the candidate JSON substring
        let candidate = String(self[start...end])
        // 4. Validate by round‐tripping through JSONSerialization
        guard
            let data = candidate.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
        else {
            return nil
        }
        return candidate
    }
    
    /// Function to convert LaTeX within a string into a Markdown image block containing a URL-encoded version
    func convertLaTeX() -> String {
        // Updated regex pattern:
        //   • Block LaTeX using \[ ... \] or $$ ... $$
        //   • Inline LaTeX using \( ... \)
        //   • Inline LaTeX using $...$, where the content is any character except '$'
        let pattern: String = "(\\\\\\[(?:.|\\s)*?\\\\\\])|(\\$\\$(?:.|\\s)*?\\$\\$)|(\\\\\\((?:.|\\s)*?\\\\\\))|(\\$(?!\\$)([^$]|\\$(?=[^$]))+\\$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }
        let mutableText: NSMutableString = NSMutableString(string: self)
        let matches: [NSTextCheckingResult] = regex.matches(
            in: self,
            options: [],
            range: NSRange(location: 0, length: mutableText.length)
        )
        // Iterate backwards so that range replacements don't affect upcoming ranges.
        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            guard let range = Range(fullRange, in: self) else { continue }
            // Capture the entire LaTeX string (including delimiters).
            let rawLaTeX = String(self[range])
            // Determine if this is a block LaTeX expression.
            // Considering only block LaTeX using \[ and $$.
            let isBlock: Bool = rawLaTeX.hasPrefix("\\[") || rawLaTeX.hasPrefix("$$")
            // Check for new lines in inline LaTeX, which is not allowed
            if rawLaTeX.contains("\n") && !isBlock {
                continue
            }
            // Remove newlines and extra spaces.
            let stripped = rawLaTeX
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Percent-encode the full, stripped LaTeX expression.
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: ".-_~")
            let encoded = stripped.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            // Compose the Markdown image. Block LaTeX gets newlines before and after.
            let replacement = (isBlock ? "\n" : "") + "![](latex://\(encoded))" + (isBlock ? "\n" : "")
            regex.replaceMatches(in: mutableText, options: [], range: fullRange, withTemplate: replacement)
        }
        return mutableText as String
    }
    
    /// Functions to extract email addresses from a `String`
    func extractEmailAddresses() -> [String] {
        var results = [String]()
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let nsText = self as NSString
        do {
            let regExp = try NSRegularExpression(pattern: emailRegex, options: .caseInsensitive)
            let range = NSMakeRange(0, self.count)
            let matches = regExp.matches(in: self, options: .reportProgress, range: range)
            
            for match in matches {
                let matchRange = match.range
                results.append(nsText.substring(with: matchRange))
            }
        } catch (let error) {
            print(error)
        }
        return results
    }
    
    /// Returns a string with each word capitalized
    var capitalizeEachWord: String {
        let words: [String] = self.split(separator: " ").map { String($0) }
        let capitalizedWords: [String] = words.map { word in
            if word.uppercased() != word {
                return word.capitalized
            }
            return word
        }
        return capitalizedWords.joined(separator: " ")
    }
    
    /// Function to calculate the percentage of the string made of non-special characters
    func nonSpecialCharactersPercent() -> Double {
        guard !self.isEmpty else { return 0.0 }
        let totalCharacters = self.count
        let letterCharacterSet = CharacterSet.letters
        let chineseCharacterRange = UnicodeScalar("一")...UnicodeScalar(
            "龥"
        )  // covers a broad range of Chinese ideographs
        let nonSpecialCount = self.unicodeScalars.filter { scalar in
            letterCharacterSet.contains(scalar) ||
            (chineseCharacterRange.contains(scalar))
        }.count
        
        return (Double(nonSpecialCount) / Double(totalCharacters)) * 100.0
    }
    
    /// Function to remove all base64-encoded images (data URLs) from a string. Matches image data syntax using a data URL
    func removingBase64Images() -> String {
        // Regex for Markdown images and inline data:image/...;base64,....)
        let pattern = #"data:image\/[a-zA-Z0-9\+\-\.]+;base64,[a-zA-Z0-9\/\+=]+"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        // Get range and replace
        let range: NSRange = NSRange(
            self.startIndex..<self.endIndex,
            in: self
        )
        let result: String = regex.stringByReplacingMatches(
            in: self,
            options: [],
            range: range,
            withTemplate: ""
        )
        return result
    }
    
    /// The dominant language of the string using NSLinguisticTagger
    private var detectedLanguage: DetectedLanguage {
        // Emoji-heavy detection
        let emojiScalars = self.unicodeScalars.filter { $0.properties.isEmoji }
        if !self.isEmpty && Double(emojiScalars.count) / Double(self.count) > 0.5 {
            return .emoji
        }
        // Use NSLinguisticTagger to detect language
        let tagger = NSLinguisticTagger(tagSchemes: [.language], options: 0)
        tagger.string = self
        let langCode = tagger.dominantLanguage ?? ""
        switch langCode {
            case "en": return .english
            case "zh": return .chinese
            case "ja": return .japanese
            case "ko": return .korean
            case "ru": return .russian
            case "ar": return .arabic
            default: return .other
        }
    }
    
    /// Estimates the token count for the string, using heuristics based on detected language.
    var estimatedTokenCount: Int {
        switch self.detectedLanguage {
            case .english:
                // English: ~4 characters per token
                return max(1, self.count / 4)
            case .chinese, .japanese, .korean:
                // CJK: ~1 character per token
                return max(1, self.count)
            case .russian, .arabic:
                // Russian/Arabic: ~2 characters per token
                return max(1, self.count / 2)
            case .emoji:
                // Emojis: estimate 3 tokens per emoji
                let emojiCount = self.unicodeScalars.filter { $0.properties.isEmoji }.count
                return max(1, emojiCount * 3)
            case .other:
                // Fallback: ~4 chars per token
                return max(1, self.count / 4)
        }
    }
    
    /// Function to returns a new string by trimming the suffix so that the estimatedTokenCount is at most `maxTokens`
    mutating func trimmingSuffixToTokens(
        maxTokens: Int
    ) {
        // Exit if no trim needed
        let currentTokens = self.estimatedTokenCount
        if currentTokens <= maxTokens {
            return
        }
        // Estimate how many characters to keep based on language heuristic
        let keepLength: Int
        switch self.detectedLanguage {
            case .english, .other:
                keepLength = maxTokens * 4
            case .chinese, .japanese, .korean:
                keepLength = maxTokens
            case .russian, .arabic:
                keepLength = maxTokens * 2
            case .emoji:
                // Each emoji ~3 tokens
                keepLength = maxTokens / 3
        }
        // Take prefix, then trim one-by-one if still over (for accuracy)
        var trimmed = String(self.prefix(keepLength))
        while trimmed.estimatedTokenCount > maxTokens && !trimmed.isEmpty {
            trimmed.removeLast()
        }
        self = trimmed
    }
    
    func dropPrefixIfPresent(
        _ prefix: String
    ) -> String {
        if self.hasPrefix(prefix) {
            return String(self.dropFirst(prefix.count))
        }
        return self
    }
    
    func dropSuffixIfPresent(
        _ suffix: String
    ) -> String {
        if self.hasSuffix(suffix) {
            return String(self.dropLast(suffix.count))
        }
        return self
    }
    
    func trim(
        prefix: String,
        suffix: String
    ) -> String {
        var result = self
        if result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
        }
        if result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
        }
        return result
    }
    
    func index(atDistance distance: Int) -> String.Index {
        return index(
            startIndex,
            offsetBy: max(0, min(distance, count))
        )
    }

    func index(utf16Distance distance: Int) -> String.Index {
        let clampedDistance = max(0, min(distance, self.utf16.count))
        let utf16Index = self.utf16.index(
            self.utf16.startIndex,
            offsetBy: clampedDistance
        )
        return String.Index(
            utf16Index,
            within: self
        ) ?? self.endIndex
    }
    
    /// Extract parameter count from model name for sorting
    var modelParameterCount: Double {
        let lowercased = self.lowercased()
        
        // Extract number + unit patterns (e.g., "235b", "8b", "405m")
        let paramPattern = #"(\d+\.?\d*)\s*([bm])"#
        if let regex = try? NSRegularExpression(pattern: paramPattern, options: .caseInsensitive) {
            let nsString = lowercased as NSString
            let matches = regex.matches(in: lowercased, options: [], range: NSRange(location: 0, length: nsString.length))
            
            var maxParams: Double = 0
            for match in matches {
                if match.numberOfRanges >= 3 {
                    let numberRange = match.range(at: 1)
                    let unitRange = match.range(at: 2)
                    
                    if let number = Double(nsString.substring(with: numberRange)) {
                        let unit = nsString.substring(with: unitRange)
                        let multiplier: Double = unit == "b" ? 1000 : 1 // billions or millions
                        let paramCount = number * multiplier
                        maxParams = max(maxParams, paramCount)
                    }
                }
            }
            
            if maxParams > 0 {
                return maxParams
            }
        }
        
        // For proprietary models without explicit parameter counts, use version numbers and tiers
        var score: Double = 0
        
        // Extract version numbers (e.g., "4.5", "3.7", "3.5", "4")
        let versionPattern = #"(\d+)\.?(\d*)"#
        if let versionRegex = try? NSRegularExpression(pattern: versionPattern, options: []) {
            let nsString = lowercased as NSString
            let matches = versionRegex.matches(in: lowercased, options: [], range: NSRange(location: 0, length: nsString.length))
            
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let majorRange = match.range(at: 1)
                    if let major = Double(nsString.substring(with: majorRange)) {
                        var minor: Double = 0
                        if match.numberOfRanges >= 3 {
                            let minorRange = match.range(at: 2)
                            let minorStr = nsString.substring(with: minorRange)
                            if !minorStr.isEmpty {
                                minor = Double(minorStr) ?? 0
                            }
                        }
                        let versionScore = (major * 100) + minor
                        score = max(score, versionScore)
                    }
                }
            }
        }
        
        // Add tier bonuses to ensure proper ordering within versions
        // (opus > sonnet > haiku)
        if lowercased.contains("opus") {
            score += 30
        } else if lowercased.contains("sonnet") {
            score += 20
        } else if lowercased.contains("haiku") {
            score += 10
        }
        
        // Handle other special named models (for models without version numbers)
        if score == 0 {
            if lowercased.contains("ultra") { score = 10000 }
            else if lowercased.contains("max") { score = 1000 }
            else if lowercased.contains("pro") { score = 1000 }
            else if lowercased.contains("plus") { score = 500 }
            else if lowercased.contains("mini") { score = 500 }
            else if lowercased.contains("flash") && !lowercased.contains("flash-lite") { score = 500 }
            else if lowercased.contains("nano") { score = 100 }
            else if lowercased.contains("flash-lite") { score = 100 }
        }
        
        return score
    }
    
    /// Extract model family name (e.g., "qwen3" from "qwen3-235b", "claude-3.5" from "claude-3.5-sonnet")
    var modelFamily: String {
        let lowercased = self.lowercased()
        var family = lowercased
        
        // For proprietary models with tier names, remove the tier and date stamps
        // but keep the base name and version number
        let tierPattern = #"[-_](opus|sonnet|haiku|ultra|max|pro|plus|mini|flash|nano)(?:[-_]\d{8})?(?:[-_].*)?$"#
        if let tierRegex = try? NSRegularExpression(pattern: tierPattern, options: .caseInsensitive) {
            let nsString = family as NSString
            let range = NSRange(location: 0, length: nsString.length)
            if let match = tierRegex.firstMatch(in: family, options: [], range: range) {
                family = nsString.substring(with: NSRange(location: 0, length: match.range.location))
            }
        }
        
        // Remove date stamps (e.g., "-20241022")
        let datePattern = #"[-_]\d{8}$"#
        if let dateRegex = try? NSRegularExpression(pattern: datePattern, options: []) {
            let nsString = family as NSString
            let range = NSRange(location: 0, length: nsString.length)
            family = dateRegex.stringByReplacingMatches(in: family, options: [], range: range, withTemplate: "")
        }
        
        // Pattern to match explicit size indicators (e.g., "235b", "8b", "405m")
        let sizePattern = #"[-_](\d+\.?\d*\s*[bm])"#
        if let regex = try? NSRegularExpression(pattern: sizePattern, options: .caseInsensitive) {
            let nsString = family as NSString
            let range = NSRange(location: 0, length: nsString.length)
            
            // Find the first size indicator and extract everything before it
            if let match = regex.firstMatch(in: family, options: [], range: range) {
                let familyRange = NSRange(location: 0, length: match.range.location)
                family = nsString.substring(with: familyRange)
            }
        }
        
        // Remove trailing hyphens or underscores
        family = family.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        
        return family.isEmpty ? lowercased : family
    }
    
    /// Extract version number from family name for sorting (e.g., "claude-3.5" → 3.5, "llama-3.1" → 3.1)
    var familyVersion: Double {
        let lowercased = self.lowercased()
        
        // Pattern to extract version numbers like "3.5", "3.7", "4", etc.
        let versionPattern = #"[-_]?(\d+)\.?(\d*)"#
        if let regex = try? NSRegularExpression(pattern: versionPattern, options: []) {
            let nsString = lowercased as NSString
            let matches = regex.matches(in: lowercased, options: [], range: NSRange(location: 0, length: nsString.length))
            
            var maxVersion: Double = 0
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let majorRange = match.range(at: 1)
                    if let major = Double(nsString.substring(with: majorRange)) {
                        var version = major
                        if match.numberOfRanges >= 3 {
                            let minorRange = match.range(at: 2)
                            let minorStr = nsString.substring(with: minorRange)
                            if !minorStr.isEmpty, let minor = Double(minorStr) {
                                // Handle both "3.5" (minor=5) and "3.5.1" style versions
                                version += (minor < 10 ? minor / 10.0 : minor / 100.0)
                            }
                        }
                        maxVersion = max(maxVersion, version)
                    }
                }
            }
            return maxVersion
        }
        
        return 0
    }
    
    /// Extract provider name from model string
    /// Prioritizes "Provider:" prefix for consistency, then checks OpenRouter cache
    var modelProvider: String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = trimmed.lowercased()
        
        func normalize(_ value: Substring) -> String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        
        // Prefer an explicit "Provider: model" prefix when the segment before the colon
        // is not a path (colon used for thinking suffixes, etc.).
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let prefix = trimmed[..<colonIndex]
            let normalizedPrefix = normalize(prefix)
            if !normalizedPrefix.isEmpty && !prefix.contains("/") {
                return normalizedPrefix
            }
        }
        
        // Handle path-style model identifiers like "openrouter/anthropic/claude-3.5-sonnet".
        let pathComponents = trimmed.split(separator: "/").map { normalize($0) }
        if !pathComponents.isEmpty {
            let first = pathComponents[0]
            let second = pathComponents.count > 1 ? pathComponents[1] : ""
            if first == "openrouter", !second.isEmpty {
                return second
            }
            if let org = KnownModel.Organization.from(string: first) {
                return org.rawValue.lowercased()
            }
            if !first.isEmpty {
                return first
            }
        }
        
        // Fallback: extract from model name using OpenRouter cache when available.
        if let knownModel = KnownModel(identifier: trimmed) {
            return knownModel.organization.rawValue.lowercased()
        }
        
        // Final heuristic: scan tokens for a recognizable organization alias.
        let tokenDelimiters = CharacterSet(charactersIn: "/:_-. ")
        for token in lowercase.components(separatedBy: tokenDelimiters) where !token.isEmpty {
            if let org = KnownModel.Organization.from(string: token) {
                return org.rawValue.lowercased()
            }
        }
        
        return "unknown"
    }
    
}

enum DetectedLanguage {
    case english
    case chinese
    case japanese
    case korean
    case russian
    case arabic
    case emoji
    case other
}
