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

    // MARK: - Provider Tests

    @Test func popularProvidersContainsMiniMax() async throws {
        let minimax = Provider.popularProviders.first { $0.name == "MiniMax" }
        #expect(minimax != nil)
        #expect(minimax?.endpointUrl.absoluteString == "https://api.minimax.io/v1")
        #expect(minimax?.supportsToolCalling == true)
    }

    @Test func popularProvidersAreSortedAlphabetically() async throws {
        let names = Provider.popularProviders.map(\.name)
        let sorted = names.sorted()
        #expect(names == sorted)
    }

    @Test func providerIdUsesName() async throws {
        let minimax = Provider.popularProviders.first { $0.name == "MiniMax" }
        #expect(minimax?.id == "MiniMax")
    }

    @Test func allPopularProvidersHaveValidEndpoints() async throws {
        for provider in Provider.popularProviders {
            #expect(provider.endpointUrl.scheme == "http" || provider.endpointUrl.scheme == "https")
            #expect(!provider.name.isEmpty)
        }
    }

    // MARK: - KnownModel Organization Tests

    @Test func minimaxOrganizationMapsCorrectly() async throws {
        let org = KnownModel.Organization.from(string: "minimax")
        #expect(org == .minimax)
    }

    @Test func minimaxOrganizationHasCorrectDisplayName() async throws {
        #expect(KnownModel.Organization.minimax.rawValue == "Minimax")
    }

    @Test func minimaxModelFullIdentifierUsesCorrectPrefix() async throws {
        let model = KnownModel(
            primaryName: "MiniMax-M2.7",
            organization: .minimax,
            capabilities: [.reasoning]
        )
        #expect(model.fullIdentifier == "minimax/MiniMax-M2.7")
        #expect(model.isReasoningModel == true)
    }

    @Test func minimaxMModelDetectedAsReasoningByOpenRouter() async throws {
        // Simulate OpenRouter model detection: "minimax-m" triggers reasoning
        let modelName = "minimax-m2.7"
        #expect(modelName.contains("minimax-m"))
    }

    @Test func minimaxHighspeedModelFullIdentifier() async throws {
        let model = KnownModel(
            primaryName: "MiniMax-M2.7-highspeed",
            organization: .minimax,
            capabilities: [.reasoning]
        )
        #expect(model.fullIdentifier == "minimax/MiniMax-M2.7-highspeed")
        #expect(model.isReasoningModel == true)
    }

    @Test func minimaxModelFindByNormalizedIdentifier() async throws {
        let models = [
            KnownModel(
                primaryName: "MiniMax-M2.7",
                organization: .minimax,
                capabilities: [.reasoning]
            ),
            KnownModel(
                primaryName: "MiniMax-M2.7-highspeed",
                organization: .minimax,
                capabilities: [.reasoning]
            ),
        ]
        let found = KnownModel.findModel(
            byIdentifier: "minimax/MiniMax-M2.7",
            in: models
        )
        #expect(found != nil)
        #expect(found?.primaryName == "MiniMax-M2.7")
    }

    // MARK: - Integration Tests (MiniMax Provider)

    @Test func minimaxProviderToolCallingDetection() async throws {
        // When endpoint matches MiniMax, providerSupportsToolCalling should
        // find it in the popularProviders list
        let minimaxUrl = "https://api.minimax.io/v1"
        let match = Provider.popularProviders.first {
            minimaxUrl == $0.endpointUrl.absoluteString
        }
        #expect(match != nil)
        #expect(match?.supportsToolCalling == true)
    }

    @Test func minimaxOrganizationIncludedInCaseIterable() async throws {
        let allOrgs = KnownModel.Organization.allCases
        #expect(allOrgs.contains(.minimax))
    }

    @Test func minimaxKnownModelRoundTrip() async throws {
        // Create a MiniMax model, encode to JSON, decode back
        let original = KnownModel(
            primaryName: "MiniMax-M2.7",
            organization: .minimax,
            modalities: [.text],
            capabilities: [.reasoning]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KnownModel.self, from: data)
        #expect(decoded.primaryName == "MiniMax-M2.7")
        #expect(decoded.organization == .minimax)
        #expect(decoded.isReasoningModel == true)
        #expect(decoded.fullIdentifier == "minimax/MiniMax-M2.7")
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
