//
//  SidekickTests.swift
//  SidekickTests
//
//  Created by Bean John on 10/4/24.
//

import AppKit
import DefaultModels
import Foundation
import SwiftUI
import Testing
@testable import Sidekick

struct SidekickTests {
	
	/// Test to check model reccomendations on different hardware
	@Test func checkModelReccomendations() async throws {
		await DefaultModels.checkModelRecommendations()
	}

    @Test func markdownStreamingParserMarksOpenCodeFenceAsUnstable() async throws {
        let blocks = StreamingMarkdownBuffer.parse(
            """
            Intro paragraph.

            ```swift
            let x = 1
            """,
            outputEnded: false
        )
        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .paragraph)
        #expect(blocks[0].isStable)
        #expect(blocks[1].kind == .fencedCode)
        #expect(blocks[1].isStable == false)
        #expect(blocks[1].features.contains(.fencedCode))
    }

    @Test func markdownFeatureSupportKeepsTablesOnFallbackPath() async throws {
        let block = StreamingMarkdownBuffer.parse(
            """
            | Name | Value |
            | --- | --- |
            | A | 1 |
            """,
            outputEnded: true
        ).first
        #expect(block != nil)
        #expect(block?.kind == .table)
        #expect(block?.features.contains(.table) == true)
        #expect(MarkdownFeatureSupport.current.shouldUseFastPath(for: block!, isStreaming: true) == false)
    }

    @Test func markdownFeatureSupportUsesFastPathForPlainParagraphs() async throws {
        let block = StreamingMarkdownBuffer.parse(
            "Hello **world** with a [link](https://example.com).",
            outputEnded: true
        ).first
        #expect(block != nil)
        #expect(block?.kind == .paragraph)
        #expect(block?.features.contains(.strong) == true)
        #expect(block?.features.contains(.link) == true)
        #expect(MarkdownFeatureSupport.current.shouldUseFastPath(for: block!, isStreaming: true) == true)
    }

    @Test func markdownListParsingDoesNotSwallowTrailingParagraphs() async throws {
        let blocks = StreamingMarkdownBuffer.parse(
            """
            1. Gather ingredients
            - Flour
            - Water

            Would you like a shopping list too?
            """,
            outputEnded: true
        )
        #expect(blocks.count == 2)
        #expect(blocks[0].kind == .list)
        #expect(blocks[1].kind == .paragraph)
        #expect(blocks[1].markdown == "Would you like a shopping list too?")
    }

    @Test func markdownStreamingParserTracksBlockLineRanges() async throws {
        let blocks = StreamingMarkdownBuffer.parse(
            """
            ## Heading

            Intro paragraph

            - Flour
            - Water
            """,
            outputEnded: false
        )
        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .heading)
        #expect(blocks[0].startLine == 0)
        #expect(blocks[0].endLine == 1)
        #expect(blocks[1].kind == .paragraph)
        #expect(blocks[1].startLine == 2)
        #expect(blocks[1].endLine == 3)
        #expect(blocks[2].kind == .list)
        #expect(blocks[2].startLine == 4)
        #expect(blocks[2].endLine == 6)
    }

    @Test func markdownFeatureSupportUsesFastPathForStandardLists() async throws {
        let block = StreamingMarkdownBuffer.parse(
            """
            1. Gather ingredients
            - Flour
            - Water
            """,
            outputEnded: true
        ).first
        #expect(block != nil)
        #expect(block?.kind == .list)
        #expect(MarkdownFeatureSupport.current.shouldUseFastPath(for: block!, isStreaming: true) == true)
    }

    @Test func fastPathParagraphNormalizationPreservesSingleLineBreaks() async throws {
        let normalized = MarkdownRenderCoordinator.normalizedMarkdownForFastPath(
            markdown: """
            **Ingredients:**
            Flour
            Water
            """,
            kind: .paragraph
        )
        #expect(normalized.contains("**Ingredients:**  \nFlour  \nWater"))
    }

    @Test func streamingAttributedTextDoesNotAddParagraphSpacingToEachListItem() async throws {
        let attributedText = MarkdownRenderCoordinator.makeStreamingAttributedText(
            markdown: """
            - Flour
            - Water
            - Salt
            """,
            colorScheme: .dark
        )
        #expect(attributedText != nil)
        let paragraphStyles = self.paragraphStyles(
            in: attributedText!
        )
        #expect(paragraphStyles.count == 3)
        #expect(paragraphStyles.allSatisfy { $0.paragraphSpacing <= 0.5 })
        #expect(paragraphStyles.allSatisfy { $0.paragraphSpacingBefore <= 0.5 })
    }

    @Test func streamingAttributedTextUsesBlankLineAsSingleSectionGap() async throws {
        let attributedText = MarkdownRenderCoordinator.makeStreamingAttributedText(
            markdown: """
            Intro line

            ## Heading
            Body line
            """,
            colorScheme: .dark
        )
        #expect(attributedText != nil)
        let paragraphStyles = self.paragraphStyles(
            in: attributedText!
        )
        #expect(paragraphStyles.count == 3)
        #expect(paragraphStyles[0].paragraphSpacing <= 0.5)
        #expect(paragraphStyles[1].paragraphSpacingBefore > 0)
        #expect(paragraphStyles[1].paragraphSpacingBefore < 8)
        #expect(paragraphStyles[1].paragraphSpacing >= 3)
        #expect(paragraphStyles[2].paragraphSpacingBefore <= 0.5)
    }

    private func paragraphStyles(
        in attributedText: NSAttributedString
    ) -> [NSParagraphStyle] {
        let nsString = attributedText.string as NSString
        guard nsString.length > 0 else {
            return []
        }
        var styles: [NSParagraphStyle] = []
        var location: Int = 0
        while location < nsString.length {
            let range = nsString.paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let style = attributedText.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            if let style {
                styles.append(style)
            }
            location = NSMaxRange(range)
        }
        return styles
    }

}
