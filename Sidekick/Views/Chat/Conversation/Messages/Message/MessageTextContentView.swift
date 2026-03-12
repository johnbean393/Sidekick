//
//  MessageTextContentView.swift
//  Sidekick
//
//  Created by Bean John on 11/12/24.
//

import AppKit
import MarkdownUI
import OSLog
import Splash
import SwiftUI

struct MessageTextContentView: View {

    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var renderCoordinator: MarkdownRenderCoordinator = .init()

    var text: String
    var isStreaming: Bool = false
    var deprioritizeStreamingUpdates: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(self.renderCoordinator.snapshot.blocks) { block in
                RenderedMarkdownBlockView(
                    block: block,
                    colorScheme: self.colorScheme
                )
                .equatable()
            }
        }
        .onAppear {
            self.enqueueRender()
        }
        .onChange(of: self.text) { _, _ in
            self.enqueueRender()
        }
        .onChange(of: self.colorScheme) { _, _ in
            self.enqueueRender()
        }
        .onChange(of: self.isStreaming) { _, _ in
            self.enqueueRender()
        }
        .onChange(of: self.deprioritizeStreamingUpdates) { _, _ in
            self.enqueueRender()
        }
        .onDisappear {
            self.renderCoordinator.cancel()
        }
    }

    private func enqueueRender() {
        let request = RenderRequest(
            text: self.text,
            colorScheme: self.colorScheme,
            isStreaming: self.isStreaming,
            deprioritizeUpdates: self.deprioritizeStreamingUpdates
        )
        self.renderCoordinator.enqueueRender(request)
    }

}

struct RenderRequest: Equatable {

    var text: String
    var colorScheme: ColorScheme
    var isStreaming: Bool
    var deprioritizeUpdates: Bool

    var processedText: String {
        self.text.convertLaTeX()
    }

    var cacheKey: String {
        let mode = self.isStreaming ? "stream" : "final"
        let priority = self.deprioritizeUpdates ? "deprioritized" : "normal"
        let rendererMode = ChatMarkdownRendererDebugOptions.rendererMode.rawValue
        return "\(self.colorScheme.cacheKey)|\(rendererMode)|\(mode)|\(priority)|\(self.processedText.count)|\(self.processedText.hashValue)"
    }

}

struct RenderedMarkdownSnapshot: Equatable {

    static let empty: Self = .init(
        blocks: [],
        fallbackFeatures: []
    )

    var blocks: [RenderedMarkdownBlock]
    var fallbackFeatures: Set<MarkdownFeature>

}

struct RenderedMarkdownBlock: Identifiable, Equatable {

    enum RenderMode: Equatable {
        case fastText
        case markdownFallback
    }

    let id: String
    let markdown: String
    let kind: StreamingMarkdownBuffer.BlockKind
    let features: Set<MarkdownFeature>
    let renderMode: RenderMode
    let attributedText: NSAttributedString?
    let isStable: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        let attributedTextMatches: Bool
        switch (lhs.attributedText, rhs.attributedText) {
            case (nil, nil):
                attributedTextMatches = true
            case let (lhsText?, rhsText?):
                attributedTextMatches = lhsText.isEqual(to: rhsText)
            default:
                attributedTextMatches = false
        }
        return lhs.id == rhs.id &&
        lhs.markdown == rhs.markdown &&
        lhs.kind == rhs.kind &&
        lhs.features == rhs.features &&
        lhs.renderMode == rhs.renderMode &&
        lhs.isStable == rhs.isStable &&
        attributedTextMatches
    }

}

enum MarkdownFeature: String, CaseIterable, Hashable {
    case paragraph
    case emphasis
    case strong
    case link
    case image
    case inlineImage
    case blockquote
    case unorderedList
    case orderedList
    case taskList
    case inlineCode
    case fencedCode
    case table
    case heading
    case thematicBreak
    case latex
    case customData
    case rawHTML
}

struct MarkdownFeatureSupport {

    static let current: Self = .init(
        parityFeatures: Set(MarkdownFeature.allCases),
        fastPathFeatures: [
            .paragraph,
            .emphasis,
            .strong,
            .link,
            .inlineCode,
            .unorderedList,
            .orderedList
        ]
    )

    let parityFeatures: Set<MarkdownFeature>
    let fastPathFeatures: Set<MarkdownFeature>

    func shouldUseFastPath(
        for block: StreamingMarkdownBuffer.ParsedBlock,
        isStreaming: Bool
    ) -> Bool {
        guard isStreaming else {
            return false
        }
        guard ChatMarkdownRendererDebugOptions.rendererMode != .fallbackOnly else {
            return false
        }
        guard self.parityFeatures.isSuperset(of: block.features) else {
            return false
        }
        switch block.kind {
            case .paragraph:
                return block.features.isSubset(of: self.fastPathFeatures)
            case .list:
                return !block.features.contains(.taskList) &&
                block.features.isSubset(of: self.fastPathFeatures)
            default:
                return false
        }
    }

}

final class MarkdownRenderCoordinator: ObservableObject {

    @Published private(set) var snapshot: RenderedMarkdownSnapshot = .empty

    private static let renderQueue: DispatchQueue = .init(
        label: "Sidekick.MarkdownRenderQueue",
        qos: .userInitiated
    )

    private var workItem: DispatchWorkItem?
    private var activeRequestKey: String?

    func enqueueRender(
        _ request: RenderRequest
    ) {
        if request.isStreaming,
           request.deprioritizeUpdates,
           !self.snapshot.blocks.isEmpty {
            self.workItem?.cancel()
            return
        }
        if request.cacheKey == self.activeRequestKey,
           !self.snapshot.blocks.isEmpty {
            return
        }
        self.activeRequestKey = request.cacheKey
        if let cachedSnapshot = MarkdownRenderCache.snapshot(for: request.cacheKey) {
            self.snapshot = cachedSnapshot
            if !request.isStreaming {
                return
            }
        }
        self.workItem?.cancel()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let signpost = MarkdownRenderMetrics.begin("BuildSnapshot")
            let snapshot = Self.buildSnapshot(
                request: request
            )
            MarkdownRenderMetrics.end("BuildSnapshot", signpost)
            guard workItem?.isCancelled == false else { return }
            MarkdownRenderCache.store(snapshot: snapshot, for: request.cacheKey)
            DispatchQueue.main.async {
                guard self.activeRequestKey == request.cacheKey else { return }
                let applySignpost = MarkdownRenderMetrics.begin("ApplySnapshot")
                self.snapshot = snapshot
                MarkdownRenderMetrics.end("ApplySnapshot", applySignpost)
            }
        }
        self.workItem = workItem
        let delay = StreamingMarkdownBuffer.renderDelay(
            for: request.processedText,
            isStreaming: request.isStreaming,
            deprioritizeUpdates: request.deprioritizeUpdates
        )
        Self.renderQueue.asyncAfter(
            deadline: .now() + delay,
            execute: workItem!
        )
    }

    func cancel() {
        self.workItem?.cancel()
        self.workItem = nil
    }

    private static func buildSnapshot(
        request: RenderRequest
    ) -> RenderedMarkdownSnapshot {
        if !request.isStreaming {
            return Self.fullMarkdownSnapshot(
                markdown: request.processedText,
                isStable: true
            )
        }
        if ChatMarkdownRendererDebugOptions.rendererMode == .fallbackOnly {
            return Self.fullMarkdownSnapshot(
                markdown: request.processedText,
                isStable: false
            )
        }
        if ChatMarkdownRendererDebugOptions.rendererMode == .fastPathOnly {
            if let attributedText = Self.makeStreamingAttributedText(
                markdown: request.processedText,
                colorScheme: request.colorScheme
            ) {
                let block = RenderedMarkdownBlock(
                    id: "stream-\(request.processedText.count)-\(request.processedText.hashValue)",
                    markdown: request.processedText,
                    kind: .paragraph,
                    features: [.paragraph],
                    renderMode: .fastText,
                    attributedText: attributedText,
                    isStable: false
                )
                return RenderedMarkdownSnapshot(
                    blocks: [block],
                    fallbackFeatures: []
                )
            }
            return Self.fullMarkdownSnapshot(
                markdown: request.processedText,
                isStable: false
            )
        }
        let blocks = StreamingMarkdownBuffer.parse(
            request.processedText,
            outputEnded: !request.isStreaming
        )
        if request.isStreaming {
            return Self.streamingSnapshot(
                markdown: request.processedText,
                blocks: blocks,
                colorScheme: request.colorScheme
            )
        }
        let featureSupport = MarkdownFeatureSupport.current
        let renderedBlocks = blocks.map { block in
            Self.renderedBlock(
                from: block,
                featureSupport: featureSupport,
                colorScheme: request.colorScheme,
                isStreaming: request.isStreaming
            )
        }
        let fallbackFeatures = renderedBlocks.reduce(into: Set<MarkdownFeature>()) { result, block in
            guard block.renderMode == .markdownFallback else { return }
            result.formUnion(block.features)
        }
        if !fallbackFeatures.isEmpty {
            MarkdownRenderMetrics.logFallback(features: fallbackFeatures)
        }
        return RenderedMarkdownSnapshot(
            blocks: renderedBlocks,
            fallbackFeatures: fallbackFeatures
        )
    }

    private static func streamingSnapshot(
        markdown: String,
        blocks: [StreamingMarkdownBuffer.ParsedBlock],
        colorScheme: ColorScheme
    ) -> RenderedMarkdownSnapshot {
        guard !blocks.isEmpty else {
            return .empty
        }

        guard let firstUnstableIndex = blocks.firstIndex(where: { !$0.isStable }) else {
            return Self.fullMarkdownSnapshot(
                markdown: markdown,
                isStable: false
            )
        }

        let featureSupport = MarkdownFeatureSupport.current
        let lines = markdown.components(separatedBy: .newlines)
        var renderedBlocks: [RenderedMarkdownBlock] = []
        var fallbackFeatures: Set<MarkdownFeature> = []

        let firstUnstableBlock = blocks[firstUnstableIndex]
        if firstUnstableBlock.startLine > 0 {
            let stablePrefixMarkdown = lines[..<firstUnstableBlock.startLine]
                .joined(separator: "\n")
            if !stablePrefixMarkdown.isEmpty {
                renderedBlocks.append(
                    Self.markdownFallbackBlock(
                        markdown: stablePrefixMarkdown,
                        isStable: true,
                        idPrefix: "stream-stable-prefix"
                    )
                )
            }
        }

        for block in blocks[firstUnstableIndex...] {
            let renderedBlock = Self.renderedBlock(
                from: block,
                featureSupport: featureSupport,
                colorScheme: colorScheme,
                isStreaming: true
            )
            renderedBlocks.append(renderedBlock)
            if renderedBlock.renderMode == .markdownFallback {
                fallbackFeatures.formUnion(renderedBlock.features)
            }
        }

        if !fallbackFeatures.isEmpty {
            MarkdownRenderMetrics.logFallback(features: fallbackFeatures)
        }

        return RenderedMarkdownSnapshot(
            blocks: renderedBlocks,
            fallbackFeatures: fallbackFeatures
        )
    }

    private struct StreamingLineDescriptor: Equatable {

        enum Kind: Equatable {
            case paragraph
            case code
            case thematicBreak
            case heading(level: Int)
            case list(
                depth: Int,
                visibleMarker: String,
                isContinuation: Bool
            )
            case blockquote
        }

        let kind: Kind
        let content: String
        let blankLinesBefore: Int

        var renderCacheKey: String {
            let kindKey: String
            switch self.kind {
                case .paragraph:
                    kindKey = "paragraph"
                case .code:
                    kindKey = "code"
                case .thematicBreak:
                    kindKey = "thematicBreak"
                case let .heading(level):
                    kindKey = "heading|\(level)"
                case let .list(depth, visibleMarker, isContinuation):
                    kindKey = "list|\(depth)|\(visibleMarker)|\(isContinuation)"
                case .blockquote:
                    kindKey = "blockquote"
            }
            return "\(kindKey)|\(self.content.count)|\(self.content.hashValue)"
        }

    }

    static func makeStreamingAttributedText(
        markdown: String,
        colorScheme: ColorScheme
    ) -> NSAttributedString? {
        let signpost = MarkdownRenderMetrics.begin("BuildStreamingText")
        defer { MarkdownRenderMetrics.end("BuildStreamingText", signpost) }
        guard !markdown.isEmpty else {
            return nil
        }

        let descriptors = Self.makeStreamingLineDescriptors(
            markdown: markdown
        )
        guard !descriptors.isEmpty else {
            return nil
        }

        let output = NSMutableAttributedString()
        for index in descriptors.indices {
            let descriptor = descriptors[index]
            let paragraph = NSMutableAttributedString(
                attributedString: Self.makeStreamingLineAttributedText(
                    descriptor,
                    colorScheme: colorScheme
                )
            )
            let paragraphStyle = Self.streamingParagraphStyle(
                for: descriptor,
                previous: index > 0 ? descriptors[index - 1] : nil,
                next: index < descriptors.count - 1 ? descriptors[index + 1] : nil
            )
            paragraph.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: paragraph.length)
            )
            output.append(paragraph)
            if index < descriptors.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }

        return output
    }

    private static func makeStreamingLineDescriptors(
        markdown: String
    ) -> [StreamingLineDescriptor] {
        let lines = markdown.components(separatedBy: .newlines)
        var descriptors: [StreamingLineDescriptor] = []
        var inCodeFence: Bool = false
        var pendingBlankLines: Int = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeFence.toggle()
                continue
            }

            if inCodeFence {
                descriptors.append(
                    StreamingLineDescriptor(
                        kind: .code,
                        content: line,
                        blankLinesBefore: pendingBlankLines
                    )
                )
                pendingBlankLines = 0
                continue
            }

            if trimmed.isEmpty {
                pendingBlankLines += 1
                continue
            }

            if Self.looksLikeThematicBreak(line) {
                descriptors.append(
                    StreamingLineDescriptor(
                        kind: .thematicBreak,
                        content: String(repeating: "—", count: 24),
                        blankLinesBefore: pendingBlankLines
                    )
                )
                pendingBlankLines = 0
                continue
            }

            if let heading = Self.streamingHeading(
                from: line
            ) {
                descriptors.append(
                    StreamingLineDescriptor(
                        kind: .heading(level: heading.level),
                        content: heading.content,
                        blankLinesBefore: pendingBlankLines
                    )
                )
                pendingBlankLines = 0
                continue
            }

            if let listItem = Self.streamingListItem(
                from: line
            ) {
                descriptors.append(
                    StreamingLineDescriptor(
                        kind: .list(
                            depth: listItem.depth,
                            visibleMarker: listItem.visibleMarker,
                            isContinuation: false
                        ),
                        content: listItem.content,
                        blankLinesBefore: pendingBlankLines
                    )
                )
                pendingBlankLines = 0
                continue
            }

            let isIndentedContinuation = line.hasPrefix("    ") || line.hasPrefix("\t")
            if let previousDescriptor = descriptors.last,
               case let .list(depth, visibleMarker, _) = previousDescriptor.kind,
               isIndentedContinuation {
                descriptors.append(
                    StreamingLineDescriptor(
                        kind: .list(
                            depth: depth,
                            visibleMarker: visibleMarker,
                            isContinuation: true
                        ),
                        content: line.trimmingCharacters(in: .whitespaces),
                        blankLinesBefore: pendingBlankLines
                    )
                )
                pendingBlankLines = 0
                continue
            }

            if let blockquote = Self.streamingBlockquote(
                from: line
            ) {
                descriptors.append(
                    StreamingLineDescriptor(
                        kind: .blockquote,
                        content: blockquote,
                        blankLinesBefore: pendingBlankLines
                    )
                )
                pendingBlankLines = 0
                continue
            }

            descriptors.append(
                StreamingLineDescriptor(
                    kind: .paragraph,
                    content: line,
                    blankLinesBefore: pendingBlankLines
                )
            )
            pendingBlankLines = 0
        }

        return descriptors
    }

    private static func makeStreamingLineAttributedText(
        _ descriptor: StreamingLineDescriptor,
        colorScheme: ColorScheme
    ) -> NSAttributedString {
        let cacheKey = "\(colorScheme.cacheKey)|stream-line|\(descriptor.renderCacheKey)"
        if let cachedText = MarkdownRenderCache.attributedText(for: cacheKey) {
            return cachedText
        }

        let attributedText: NSAttributedString
        switch descriptor.kind {
            case .paragraph:
                attributedText = Self.makeInlineAttributedText(
                    markdown: descriptor.content,
                    colorScheme: colorScheme
                )
            case .code:
                let visibleLine = descriptor.content.isEmpty ? "\u{200B}" : descriptor.content
                let codeText = NSMutableAttributedString(string: visibleLine)
                codeText.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize * 0.92, weight: .regular),
                        .foregroundColor: colorScheme.markdownTextColor,
                        .backgroundColor: colorScheme.inlineCodeBackgroundColor
                    ],
                    range: NSRange(location: 0, length: codeText.length)
                )
                attributedText = codeText
            case .thematicBreak:
                let rule = NSMutableAttributedString(string: descriptor.content)
                rule.addAttributes(
                    [
                        .foregroundColor: colorScheme.markdownSecondaryTextColor,
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
                    ],
                    range: NSRange(location: 0, length: rule.length)
                )
                attributedText = rule
            case let .heading(level):
                let text = Self.makeInlineAttributedText(
                    markdown: descriptor.content,
                    colorScheme: colorScheme
                )
                let fontSize: CGFloat = switch level {
                    case 1: 22
                    case 2: 18
                    case 3: 16
                    default: 14
                }
                text.addAttribute(
                    .font,
                    value: NSFont.boldSystemFont(ofSize: fontSize),
                    range: NSRange(location: 0, length: text.length)
                )
                attributedText = text
            case let .list(_, visibleMarker, isContinuation):
                if isContinuation {
                    attributedText = Self.makeInlineAttributedText(
                        markdown: descriptor.content,
                        colorScheme: colorScheme
                    )
                } else {
                    let output = NSMutableAttributedString(
                        string: visibleMarker + " ",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1.0),
                            .foregroundColor: colorScheme.markdownTextColor
                        ]
                    )
                    output.append(
                        Self.makeInlineAttributedText(
                            markdown: descriptor.content,
                            colorScheme: colorScheme
                        )
                    )
                    attributedText = output
                }
            case .blockquote:
                let output = NSMutableAttributedString(
                    string: "▍ ",
                    attributes: [
                        .foregroundColor: colorScheme.markdownSecondaryTextColor,
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1.0)
                    ]
                )
                output.append(
                    Self.makeInlineAttributedText(
                        markdown: descriptor.content,
                        colorScheme: colorScheme
                    )
                )
                attributedText = output
        }

        MarkdownRenderCache.store(
            attributedText: attributedText,
            for: cacheKey
        )
        return attributedText
    }

    private static func streamingParagraphStyle(
        for descriptor: StreamingLineDescriptor,
        previous: StreamingLineDescriptor?,
        next: StreamingLineDescriptor?
    ) -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = Self.streamingLineSpacing(
            for: descriptor.kind
        )
        paragraphStyle.paragraphSpacingBefore = Self.streamingSpacingBefore(
            for: descriptor,
            previous: previous
        )
        paragraphStyle.paragraphSpacing = Self.streamingSpacingAfter(
            for: descriptor,
            next: next
        )

        if case let .list(depth, _, isContinuation) = descriptor.kind {
            let indentWidth = CGFloat(depth) * 18
            paragraphStyle.firstLineHeadIndent = isContinuation ? indentWidth + 20 : indentWidth
            paragraphStyle.headIndent = indentWidth + 20
        }

        return paragraphStyle
    }

    private static func streamingLineSpacing(
        for kind: StreamingLineDescriptor.Kind
    ) -> CGFloat {
        switch kind {
            case .heading:
                return 2
            case .thematicBreak:
                return 1
            default:
                return 2
        }
    }

    private static func streamingSpacingBefore(
        for descriptor: StreamingLineDescriptor,
        previous: StreamingLineDescriptor?
    ) -> CGFloat {
        guard previous != nil else {
            return 0
        }
        guard descriptor.blankLinesBefore > 0 else {
            return 0
        }
        let multiplier = CGFloat(min(descriptor.blankLinesBefore, 2))
        let baseSpacing: CGFloat
        switch descriptor.kind {
            case let .heading(level):
                baseSpacing = level == 1 ? 6 : 5
            case .thematicBreak:
                baseSpacing = 8
            case .list:
                baseSpacing = 4
            case .code:
                baseSpacing = 5
            case .blockquote:
                baseSpacing = 4
            case .paragraph:
                baseSpacing = 4
        }
        return baseSpacing * multiplier
    }

    private static func streamingSpacingAfter(
        for descriptor: StreamingLineDescriptor,
        next: StreamingLineDescriptor?
    ) -> CGFloat {
        if let next, next.blankLinesBefore > 0 {
            return 0
        }
        switch descriptor.kind {
            case let .heading(level):
                return level == 1 ? 4 : 3
            case .thematicBreak:
                return 6
            default:
                return 0
        }
    }

    private static func streamingHeading(
        from line: String
    ) -> (level: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(
            of: #"^#{1,6}\s+"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let marker = String(trimmed[..<range.upperBound])
        return (
            level: marker.filter { $0 == "#" }.count,
            content: String(trimmed[range.upperBound...])
        )
    }

    private static func streamingListItem(
        from line: String
    ) -> (
        depth: Int,
        visibleMarker: String,
        content: String
    )? {
        let pattern = #"^(\s*)([-*+]|\d+\.)\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range) else {
            return nil
        }
        let whitespace = nsLine.substring(with: match.range(at: 1))
        let marker = nsLine.substring(with: match.range(at: 2))
        let content = nsLine.substring(with: match.range(at: 3))
        return (
            depth: Self.listIndentDepth(from: whitespace),
            visibleMarker: marker.range(of: #"^\d+\.$"#, options: .regularExpression) != nil ? marker : "•",
            content: content
        )
    }

    private static func streamingBlockquote(
        from line: String
    ) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else {
            return nil
        }
        return String(
            trimmed.drop { $0 == ">" || $0 == " " }
        )
    }

    private static func looksLikeThematicBreak(
        _ line: String
    ) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(
            of: #"^([-*_])(\s*\1){2,}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func fullMarkdownSnapshot(
        markdown: String,
        isStable: Bool
    ) -> RenderedMarkdownSnapshot {
        let block = Self.markdownFallbackBlock(
            markdown: markdown,
            isStable: isStable,
            idPrefix: "full"
        )
        return RenderedMarkdownSnapshot(
            blocks: markdown.isEmpty ? [] : [block],
            fallbackFeatures: Set(MarkdownFeature.allCases)
        )
    }

    private static func markdownFallbackBlock(
        markdown: String,
        isStable: Bool,
        idPrefix: String
    ) -> RenderedMarkdownBlock {
        RenderedMarkdownBlock(
            id: "\(idPrefix)-\(markdown.count)-\(markdown.hashValue)",
            markdown: markdown,
            kind: .paragraph,
            features: Set(MarkdownFeature.allCases),
            renderMode: .markdownFallback,
            attributedText: nil,
            isStable: isStable
        )
    }

    private static func renderedBlock(
        from block: StreamingMarkdownBuffer.ParsedBlock,
        featureSupport: MarkdownFeatureSupport,
        colorScheme: ColorScheme,
        isStreaming: Bool
    ) -> RenderedMarkdownBlock {
        let useFastPath = featureSupport.shouldUseFastPath(
            for: block,
            isStreaming: isStreaming
        )
        let attributedText: NSAttributedString?
        if useFastPath {
            let cacheKey = "\(colorScheme.cacheKey)|\(block.cacheKey)"
            attributedText = MarkdownRenderCache.attributedText(for: cacheKey) ?? Self.makeFastAttributedText(
                markdown: block.markdown,
                kind: block.kind,
                colorScheme: colorScheme
            )
            if let attributedText {
                MarkdownRenderCache.store(
                    attributedText: attributedText,
                    for: cacheKey
                )
            }
        } else {
            attributedText = nil
        }
        return RenderedMarkdownBlock(
            id: block.id,
            markdown: block.markdown,
            kind: block.kind,
            features: block.features,
            renderMode: attributedText == nil ? .markdownFallback : .fastText,
            attributedText: attributedText,
            isStable: block.isStable
        )
    }

    private static func makeFastAttributedText(
        markdown: String,
        kind: StreamingMarkdownBuffer.BlockKind,
        colorScheme: ColorScheme
    ) -> NSAttributedString? {
        if kind == .paragraph {
            return Self.makeFastParagraphAttributedText(
                markdown: markdown,
                colorScheme: colorScheme,
                bottomSpacing: kind.bottomSpacing
            )
        }
        if kind == .list {
            return Self.makeFastListAttributedText(
                markdown: markdown,
                colorScheme: colorScheme
            )
        }
        let signpost = MarkdownRenderMetrics.begin("BuildFastText")
        defer { MarkdownRenderMetrics.end("BuildFastText", signpost) }
        let markdownOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let normalizedMarkdown = Self.normalizedMarkdownForFastPath(
            markdown: markdown,
            kind: kind
        )
        guard let attributedString = try? AttributedString(
            markdown: normalizedMarkdown,
            options: markdownOptions
        ) else {
            return nil
        }
        let mutableText = NSMutableAttributedString(
            attributedString: NSAttributedString(attributedString)
        )
        let fullRange = NSRange(
            location: 0,
            length: mutableText.length
        )
        mutableText.addAttributes(
            [
                .foregroundColor: colorScheme.markdownTextColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1.0)
            ],
            range: fullRange
        )
        Self.applyParagraphSpacing(
            to: mutableText,
            kind: kind
        )
        mutableText.enumerateAttribute(
            .inlinePresentationIntent,
            in: fullRange
        ) { value, range, _ in
            guard let number = value as? NSNumber else { return }
            let intent = InlinePresentationIntent(
                rawValue: number.uintValue
            )
            var font = NSFont.systemFont(
                ofSize: NSFont.systemFontSize + 1.0
            )
            let fontManager = NSFontManager.shared
            if intent.contains(.stronglyEmphasized) {
                font = fontManager.convert(
                    font,
                    toHaveTrait: .boldFontMask
                )
            }
            if intent.contains(.emphasized) {
                font = fontManager.convert(
                    font,
                    toHaveTrait: .italicFontMask
                )
            }
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(
                    ofSize: NSFont.systemFontSize * 0.92,
                    weight: .regular
                )
                mutableText.addAttribute(
                    .backgroundColor,
                    value: colorScheme.inlineCodeBackgroundColor,
                    range: range
                )
            }
            if intent.contains(.strikethrough) {
                mutableText.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
            mutableText.addAttribute(
                .font,
                value: font,
                range: range
            )
        }
        mutableText.enumerateAttribute(
            .link,
            in: fullRange
        ) { value, range, _ in
            guard value != nil else { return }
            mutableText.addAttributes(
                [
                    .foregroundColor: colorScheme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: range
            )
        }
        return mutableText
    }

    private static func makeFastParagraphAttributedText(
        markdown: String,
        colorScheme: ColorScheme,
        bottomSpacing: CGFloat
    ) -> NSAttributedString? {
        let signpost = MarkdownRenderMetrics.begin("BuildFastParagraphText")
        defer { MarkdownRenderMetrics.end("BuildFastParagraphText", signpost) }

        let lines = markdown.components(separatedBy: .newlines)
        let output = NSMutableAttributedString()
        for index in lines.indices {
            output.append(
                Self.makeInlineAttributedText(
                    markdown: lines[index],
                    colorScheme: colorScheme
                )
            )
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = bottomSpacing
        paragraphStyle.paragraphSpacingBefore = 0
        output.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: output.length)
        )
        return output
    }

    private static func makeFastListAttributedText(
        markdown: String,
        colorScheme: ColorScheme
    ) -> NSAttributedString? {
        let signpost = MarkdownRenderMetrics.begin("BuildFastListText")
        defer { MarkdownRenderMetrics.end("BuildFastListText", signpost) }

        let items = Self.fastListItems(from: markdown)
        guard !items.isEmpty else {
            return nil
        }

        let output = NSMutableAttributedString()
        for index in items.indices {
            let item = items[index]
            let paragraph = NSMutableAttributedString()
            let indentWidth = CGFloat(item.depth) * 18

            if item.isContinuation {
                paragraph.append(
                    Self.makeInlineAttributedText(
                        markdown: item.content,
                        colorScheme: colorScheme
                    )
                )
            } else {
                let markerAttributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: colorScheme.markdownTextColor,
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1.0)
                ]
                paragraph.append(
                    NSAttributedString(
                        string: item.visibleMarker + " ",
                        attributes: markerAttributes
                    )
                )
                paragraph.append(
                    Self.makeInlineAttributedText(
                        markdown: item.content,
                        colorScheme: colorScheme
                    )
                )
            }

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4
            paragraphStyle.paragraphSpacing = 8
            paragraphStyle.paragraphSpacingBefore = 0
            paragraphStyle.firstLineHeadIndent = item.isContinuation ? indentWidth + 20 : indentWidth
            paragraphStyle.headIndent = indentWidth + 20
            paragraph.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: paragraph.length)
            )

            output.append(paragraph)
            if index < items.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }

        return output
    }

    private static func makeInlineAttributedText(
        markdown: String,
        colorScheme: ColorScheme
    ) -> NSMutableAttributedString {
        let markdownOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let attributedString = (
            try? AttributedString(
                markdown: markdown,
                options: markdownOptions
            )
        ).map(NSAttributedString.init) ?? NSAttributedString(string: markdown)

        let mutableText = NSMutableAttributedString(
            attributedString: attributedString
        )
        let fullRange = NSRange(location: 0, length: mutableText.length)
        mutableText.addAttributes(
            [
                .foregroundColor: colorScheme.markdownTextColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1.0)
            ],
            range: fullRange
        )
        mutableText.enumerateAttribute(
            .inlinePresentationIntent,
            in: fullRange
        ) { value, range, _ in
            guard let number = value as? NSNumber else { return }
            let intent = InlinePresentationIntent(rawValue: number.uintValue)
            var font = NSFont.systemFont(
                ofSize: NSFont.systemFontSize + 1.0
            )
            let fontManager = NSFontManager.shared
            if intent.contains(.stronglyEmphasized) {
                font = fontManager.convert(
                    font,
                    toHaveTrait: .boldFontMask
                )
            }
            if intent.contains(.emphasized) {
                font = fontManager.convert(
                    font,
                    toHaveTrait: .italicFontMask
                )
            }
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(
                    ofSize: NSFont.systemFontSize * 0.92,
                    weight: .regular
                )
                mutableText.addAttribute(
                    .backgroundColor,
                    value: colorScheme.inlineCodeBackgroundColor,
                    range: range
                )
            }
            if intent.contains(.strikethrough) {
                mutableText.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
            mutableText.addAttribute(
                .font,
                value: font,
                range: range
            )
        }
        mutableText.enumerateAttribute(
            .link,
            in: fullRange
        ) { value, range, _ in
            guard value != nil else { return }
            mutableText.addAttributes(
                [
                    .foregroundColor: colorScheme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: range
            )
        }
        return mutableText
    }

    static func normalizedMarkdownForFastPath(
        markdown: String,
        kind: StreamingMarkdownBuffer.BlockKind
    ) -> String {
        guard kind == .paragraph else {
            return markdown
        }
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.count > 1 else {
            return markdown
        }
        return lines.enumerated().map { index, line in
            guard index < lines.count - 1 else {
                return line
            }
            if line.hasSuffix("  ") || line.hasSuffix("\\") {
                return line
            }
            return line + "  "
        }
        .joined(separator: "\n")
    }

    static func fastListItems(
        from markdown: String
    ) -> [FastListItem] {
        let pattern = #"^(\s*)([-*+]|\d+\.)\s+(.*)$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let lines = markdown.components(separatedBy: .newlines)
        var items: [FastListItem] = []

        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            if let match = regex?.firstMatch(in: line, range: range) {
                let whitespace = nsLine.substring(with: match.range(at: 1))
                let marker = nsLine.substring(with: match.range(at: 2))
                let content = nsLine.substring(with: match.range(at: 3))
                let depth = Self.listIndentDepth(from: whitespace)
                let visibleMarker = marker.range(
                    of: #"^\d+\.$"#,
                    options: .regularExpression
                ) != nil ? marker : "•"
                items.append(
                    FastListItem(
                        depth: depth,
                        visibleMarker: visibleMarker,
                        content: content,
                        isContinuation: false
                    )
                )
            } else if let lastItem = items.last,
                      line.hasPrefix("    ") || line.hasPrefix("\t") {
                items.append(
                    FastListItem(
                        depth: lastItem.depth,
                        visibleMarker: lastItem.visibleMarker,
                        content: line.trimmingCharacters(in: .whitespaces),
                        isContinuation: true
                    )
                )
            }
        }

        return items
    }

    private static func listIndentDepth(
        from whitespace: String
    ) -> Int {
        var width: Int = 0
        for character in whitespace {
            if character == "\t" {
                width += 4
            } else {
                width += 1
            }
        }
        return width / 4
    }

    private static func applyParagraphSpacing(
        to attributedText: NSMutableAttributedString,
        kind: StreamingMarkdownBuffer.BlockKind
    ) {
        let nsString = attributedText.string as NSString
        var location: Int = 0
        while location < nsString.length {
            let paragraphRange = nsString.paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let existingStyle = attributedText.attribute(
                .paragraphStyle,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let paragraphStyle = (existingStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4
            paragraphStyle.paragraphSpacing = max(
                paragraphStyle.paragraphSpacing,
                kind.bottomSpacing
            )
            paragraphStyle.paragraphSpacingBefore = 0
            attributedText.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: paragraphRange
            )
            location = NSMaxRange(paragraphRange)
        }
    }

}

struct FastListItem: Equatable {
    let depth: Int
    let visibleMarker: String
    let content: String
    let isContinuation: Bool
}

struct StreamingMarkdownBuffer {

    enum BlockKind: String, Equatable {
        case paragraph
        case heading
        case fencedCode
        case table
        case blockquote
        case list
        case thematicBreak
        case rawHTML

        var bottomSpacing: CGFloat {
            switch self {
                case .thematicBreak:
                    return 24
                default:
                    return 16
            }
        }
    }

    struct ParsedBlock: Equatable {
        let id: String
        let cacheKey: String
        let markdown: String
        let kind: BlockKind
        let features: Set<MarkdownFeature>
        let isStable: Bool
        let startLine: Int
        let endLine: Int
    }

    static func parse(
        _ text: String,
        outputEnded: Bool
    ) -> [ParsedBlock] {
        guard !text.isEmpty else { return [] }
        let lines = text.components(separatedBy: .newlines)
        var blocks: [ParsedBlock] = []
        var lineIndex: Int = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lineIndex += 1
                continue
            }
            if let fence = fenceDelimiter(for: line) {
                let startIndex = lineIndex
                lineIndex += 1
                var didClose = false
                while lineIndex < lines.count {
                    if lines[lineIndex].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        didClose = true
                        lineIndex += 1
                        break
                    }
                    lineIndex += 1
                }
                let markdown = lines[startIndex..<min(lineIndex, lines.count)].joined(separator: "\n")
                blocks.append(
                    makeBlock(
                        markdown: markdown,
                        kind: .fencedCode,
                        isStable: outputEnded || didClose,
                        fallbackFeatures: [.fencedCode],
                        startLine: startIndex,
                        endLine: min(lineIndex, lines.count)
                    )
                )
                continue
            }
            if isTableHeader(at: lineIndex, lines: lines) {
                let startIndex = lineIndex
                lineIndex += 2
                while lineIndex < lines.count && looksLikeTableRow(lines[lineIndex]) {
                    lineIndex += 1
                }
                let markdown = lines[startIndex..<lineIndex].joined(separator: "\n")
                let isStable = outputEnded || lineIndex < lines.count
                blocks.append(
                    makeBlock(
                        markdown: markdown,
                        kind: .table,
                        isStable: isStable,
                        fallbackFeatures: [.table, .customData],
                        startLine: startIndex,
                        endLine: lineIndex
                    )
                )
                continue
            }
            if isThematicBreak(line) {
                lineIndex += 1
                blocks.append(
                    makeBlock(
                        markdown: line,
                        kind: .thematicBreak,
                        isStable: true,
                        fallbackFeatures: [.thematicBreak],
                        startLine: lineIndex - 1,
                        endLine: lineIndex
                    )
                )
                continue
            }
            if isRawHTML(line) {
                let startIndex = lineIndex
                lineIndex += 1
                while lineIndex < lines.count &&
                        !lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lineIndex += 1
                }
                let markdown = lines[startIndex..<lineIndex].joined(separator: "\n")
                blocks.append(
                    makeBlock(
                        markdown: markdown,
                        kind: .rawHTML,
                        isStable: outputEnded || lineIndex < lines.count,
                        fallbackFeatures: [.rawHTML],
                        startLine: startIndex,
                        endLine: lineIndex
                    )
                )
                continue
            }
            if isHeading(line) {
                lineIndex += 1
                blocks.append(
                    makeBlock(
                        markdown: line,
                        kind: .heading,
                        isStable: true,
                        fallbackFeatures: [.heading],
                        startLine: lineIndex - 1,
                        endLine: lineIndex
                    )
                )
                continue
            }
            if isListItem(line) {
                let startIndex = lineIndex
                lineIndex += 1
                while lineIndex < lines.count {
                    let nextLine = lines[lineIndex]
                    if nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        break
                    }
                    if isListItem(nextLine) || nextLine.hasPrefix("    ") || nextLine.hasPrefix("\t") {
                        lineIndex += 1
                    } else {
                        break
                    }
                }
                let markdown = lines[startIndex..<lineIndex].joined(separator: "\n")
                let features = detectedFeatures(
                    in: markdown,
                    base: [.unorderedList, .orderedList]
                ).subtracting([.paragraph])
                blocks.append(
                    ParsedBlock(
                        id: blockID(for: markdown, index: blocks.count),
                        cacheKey: blockCacheKey(for: markdown, index: blocks.count),
                        markdown: markdown,
                        kind: .list,
                        features: listFeatures(for: markdown).union(features),
                        isStable: outputEnded || lineIndex < lines.count,
                        startLine: startIndex,
                        endLine: lineIndex
                    )
                )
                continue
            }
            if isBlockquote(line) {
                let startIndex = lineIndex
                lineIndex += 1
                while lineIndex < lines.count && isBlockquote(lines[lineIndex]) {
                    lineIndex += 1
                }
                let markdown = lines[startIndex..<lineIndex].joined(separator: "\n")
                blocks.append(
                    makeBlock(
                        markdown: markdown,
                        kind: .blockquote,
                        isStable: outputEnded || lineIndex < lines.count,
                        fallbackFeatures: [.blockquote],
                        startLine: startIndex,
                        endLine: lineIndex
                    )
                )
                continue
            }
            let startIndex = lineIndex
            lineIndex += 1
            while lineIndex < lines.count {
                let nextLine = lines[lineIndex]
                if nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                if beginsNewBlock(nextLine, at: lineIndex, lines: lines) {
                    break
                }
                lineIndex += 1
            }
            let markdown = lines[startIndex..<lineIndex].joined(separator: "\n")
            let isStable = outputEnded || lineIndex < lines.count
            blocks.append(
                makeBlock(
                    markdown: markdown,
                    kind: .paragraph,
                    isStable: isStable,
                    fallbackFeatures: [.paragraph],
                    startLine: startIndex,
                    endLine: lineIndex
                )
            )
        }
        return coalescedParagraphs(from: blocks)
    }

    static func renderDelay(
        for text: String,
        isStreaming: Bool,
        deprioritizeUpdates: Bool
    ) -> DispatchTimeInterval {
        guard isStreaming else { return .milliseconds(0) }
        if deprioritizeUpdates {
            if text.count < 2_048 {
                return .milliseconds(80)
            }
            return .milliseconds(120)
        }
        if text.hasSuffix("\n\n") || fenceDelimiter(for: text.components(separatedBy: .newlines).last ?? "") != nil {
            return .milliseconds(12)
        }
        if text.count < 512 {
            return .milliseconds(18)
        }
        if text.count < 2_048 {
            return .milliseconds(28)
        }
        return .milliseconds(40)
    }

    private static func coalescedParagraphs(
        from blocks: [ParsedBlock]
    ) -> [ParsedBlock] {
        var result: [ParsedBlock] = []
        for block in blocks {
            if let lastBlock = result.last,
               lastBlock.kind == .paragraph,
               block.kind == .paragraph,
               lastBlock.isStable,
               block.isStable,
               lastBlock.features == block.features {
                let mergedMarkdown = "\(lastBlock.markdown)\n\n\(block.markdown)"
                result[result.count - 1] = ParsedBlock(
                    id: blockID(for: mergedMarkdown, index: result.count - 1),
                    cacheKey: blockCacheKey(for: mergedMarkdown, index: result.count - 1),
                    markdown: mergedMarkdown,
                    kind: .paragraph,
                    features: lastBlock.features.union(block.features),
                    isStable: true,
                    startLine: lastBlock.startLine,
                    endLine: block.endLine
                )
            } else {
                result.append(block)
            }
        }
        return result
    }

    private static func makeBlock(
        markdown: String,
        kind: BlockKind,
        isStable: Bool,
        fallbackFeatures: Set<MarkdownFeature>,
        startLine: Int,
        endLine: Int
    ) -> ParsedBlock {
        let features = detectedFeatures(
            in: markdown,
            base: fallbackFeatures
        )
        return ParsedBlock(
            id: blockID(for: markdown, index: markdown.hashValue),
            cacheKey: blockCacheKey(for: markdown, index: markdown.hashValue),
            markdown: markdown,
            kind: kind,
            features: features,
            isStable: isStable,
            startLine: startLine,
            endLine: endLine
        )
    }

    private static func blockID(
        for markdown: String,
        index: Int
    ) -> String {
        "\(index)-\(markdown.count)-\(markdown.hashValue)"
    }

    private static func blockCacheKey(
        for markdown: String,
        index: Int
    ) -> String {
        "\(index)|\(markdown.count)|\(markdown.hashValue)"
    }

    private static func detectedFeatures(
        in markdown: String,
        base: Set<MarkdownFeature>
    ) -> Set<MarkdownFeature> {
        var features = base
        if base.isEmpty {
            features.insert(.paragraph)
        }
        if markdown.contains("**") || markdown.contains("__") {
            features.insert(.strong)
        }
        if markdown.contains("*") || markdown.contains("_") {
            features.insert(.emphasis)
        }
        if markdown.contains("`") {
            features.insert(.inlineCode)
        }
        if markdown.contains("](") {
            if markdown.contains("![") {
                features.insert(.image)
                features.insert(.inlineImage)
            } else {
                features.insert(.link)
            }
        }
        if markdown.contains("latex://") {
            features.insert(.latex)
            features.insert(.image)
            features.insert(.inlineImage)
        }
        if markdown.contains("- [") || markdown.contains("* [") {
            features.insert(.taskList)
        }
        return features
    }

    private static func listFeatures(
        for markdown: String
    ) -> Set<MarkdownFeature> {
        var result: Set<MarkdownFeature> = []
        if markdown.contains("- [") || markdown.contains("* [") {
            result.insert(.taskList)
        }
        let lines = markdown.components(separatedBy: .newlines)
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).range(of: #"^\d+\."#, options: .regularExpression) != nil }) {
            result.insert(.orderedList)
        }
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("* ") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("+ ") }) {
            result.insert(.unorderedList)
        }
        return result
    }

    private static func fenceDelimiter(
        for line: String
    ) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            return "```"
        }
        if trimmed.hasPrefix("~~~") {
            return "~~~"
        }
        return nil
    }

    private static func isTableHeader(
        at index: Int,
        lines: [String]
    ) -> Bool {
        guard index + 1 < lines.count else { return false }
        return looksLikeTableRow(lines[index]) && isTableDivider(lines[index + 1])
    }

    private static func looksLikeTableRow(
        _ line: String
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.hasPrefix(">") && !trimmed.hasPrefix("```")
    }

    private static func isTableDivider(
        _ line: String
    ) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(
            of: #"^\|?(\s*:?-{3,}:?\s*\|)+\s*:?-{3,}:?\s*\|?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isThematicBreak(
        _ line: String
    ) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(
            of: #"^([-*_])(\s*\1){2,}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isHeading(
        _ line: String
    ) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(
            of: #"^#{1,6}\s+"#,
            options: .regularExpression
        ) != nil
    }

    private static func isListItem(
        _ line: String
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(
            of: #"^([-*+]|\d+\.)\s+"#,
            options: .regularExpression
        ) != nil
    }

    private static func isBlockquote(
        _ line: String
    ) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func isRawHTML(
        _ line: String
    ) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("<")
    }

    private static func beginsNewBlock(
        _ line: String,
        at index: Int,
        lines: [String]
    ) -> Bool {
        fenceDelimiter(for: line) != nil ||
        isHeading(line) ||
        isListItem(line) ||
        isBlockquote(line) ||
        isThematicBreak(line) ||
        isRawHTML(line) ||
        isTableHeader(at: index, lines: lines)
    }

    private static func isNewBlockBoundary(
        at index: Int,
        lines: [String]
    ) -> Bool {
        guard index < lines.count else { return true }
        let line = lines[index]
        return beginsNewBlock(
            line,
            at: index,
            lines: lines
        )
    }

}

struct ChatMarkdownTextView: NSViewRepresentable {

    var attributedText: NSAttributedString

    func makeNSView(
        context: Context
    ) -> ChatMarkdownTextContainerView {
        let view = ChatMarkdownTextContainerView()
        view.setAttributedText(self.attributedText)
        return view
    }

    func updateNSView(
        _ nsView: ChatMarkdownTextContainerView,
        context: Context
    ) {
        nsView.setAttributedText(self.attributedText)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ChatMarkdownTextContainerView,
        context: Context
    ) -> CGSize? {
        let width = Self.sanitizedWidth(
            proposal.width,
            fallback: nsView.bounds.width
        )
        return nsView.fittingSize(
            width: width
        )
    }

    private static func sanitizedWidth(
        _ proposedWidth: CGFloat?,
        fallback: CGFloat
    ) -> CGFloat? {
        if let proposedWidth,
           proposedWidth.isFinite,
           proposedWidth > 0,
           proposedWidth < 100_000 {
            return proposedWidth
        }
        if fallback.isFinite,
           fallback > 0,
           fallback < 100_000 {
            return fallback
        }
        return nil
    }

}

final class ChatMarkdownTextContainerView: NSView {

    private let textStorage: NSTextStorage = .init()
    private let layoutManager: NSLayoutManager = .init()
    private let textContainer: NSTextContainer = .init(size: .zero)
    private let textView: NSTextView

    override init(
        frame frameRect: NSRect
    ) {
        self.textView = NSTextView(
            frame: .zero,
            textContainer: textContainer
        )
        super.init(frame: frameRect)
        self.setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        let safeWidth = self.sanitizedWidth(self.bounds.width) ?? 1
        self.textContainer.containerSize = NSSize(
            width: safeWidth,
            height: .greatestFiniteMagnitude
        )
        self.textView.frame = self.bounds
        self.invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        self.fittingSize(
            width: self.bounds.width == 0 ? nil : self.bounds.width
        )
    }

    func fittingSize(
        width: CGFloat?
    ) -> CGSize {
        let safeWidth = self.sanitizedWidth(width)
        if let safeWidth {
            self.textContainer.containerSize = NSSize(
                width: safeWidth,
                height: .greatestFiniteMagnitude
            )
            self.textView.frame.size.width = safeWidth
        }
        self.layoutManager.ensureLayout(for: self.textContainer)
        let usedRect = self.layoutManager.usedRect(for: self.textContainer)
        let resolvedWidth = safeWidth ?? self.sanitizedWidth(usedRect.width) ?? 1
        return CGSize(
            width: resolvedWidth,
            height: ceil(usedRect.height) + (self.textView.textContainerInset.height * 2)
        )
    }

    func setAttributedText(
        _ attributedText: NSAttributedString
    ) {
        if self.textStorage.isEqual(to: attributedText) {
            return
        }
        self.textStorage.setAttributedString(attributedText)
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }

    private func setup() {
        self.textStorage.addLayoutManager(self.layoutManager)
        self.layoutManager.addTextContainer(self.textContainer)
        self.textContainer.widthTracksTextView = true
        self.textContainer.lineFragmentPadding = 0

        self.textView.drawsBackground = false
        self.textView.isEditable = false
        self.textView.isSelectable = true
        self.textView.isRichText = true
        self.textView.importsGraphics = true
        self.textView.textContainerInset = .zero
        self.textView.textContainer?.lineFragmentPadding = 0
        self.textView.textColor = .labelColor
        self.textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        self.addSubview(self.textView)
    }

    private func sanitizedWidth(
        _ width: CGFloat?
    ) -> CGFloat? {
        guard let width,
              width.isFinite,
              width > 0,
              width < 100_000 else {
            return nil
        }
        return width
    }

}

private struct RenderedMarkdownBlockView: View, Equatable {

    let block: RenderedMarkdownBlock
    let colorScheme: ColorScheme

    private let imageScaleFactor: CGFloat = 1.0

    @ViewBuilder
    var body: some View {
        switch self.block.renderMode {
            case .fastText:
                if let attributedText = self.block.attributedText {
                    ChatMarkdownTextView(
                        attributedText: attributedText
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, self.block.kind.bottomSpacing)
                } else {
                    EmptyView()
                }
            case .markdownFallback:
                Markdown(
                    MarkdownContent(
                        self.block.markdown
                    )
                )
                .markdownTheme(.gitHub)
                .markdownCodeSyntaxHighlighter(
                    .splash(
                        theme: self.colorScheme.splashTheme
                    )
                )
                .markdownImageProvider(
                    MarkdownImageProvider(
                        scaleFactor: self.imageScaleFactor
                    )
                )
                .markdownInlineImageProvider(
                    MarkdownInlineImageProvider(
                        scaleFactor: self.imageScaleFactor
                    )
                )
                .textSelection(.enabled)
        }
    }

    static func == (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.block == rhs.block &&
        lhs.colorScheme == rhs.colorScheme
    }

}

private enum ChatMarkdownRendererDebugOptions {

    static var rendererMode: RendererMode {
        let rawValue = UserDefaults.standard.string(
            forKey: "chatMarkdownRendererMode"
        )
        return RendererMode(rawValue: rawValue ?? "") ?? .mixed
    }

    enum RendererMode: String {
        case mixed
        case fallbackOnly
        case fastPathOnly
    }

}

private enum MarkdownRenderCache {

    private static let snapshotCache: NSCache<NSString, SnapshotBox> = .init()
    private static let attributedTextCache: NSCache<NSString, AttributedTextBox> = .init()

    static func snapshot(
        for key: String
    ) -> RenderedMarkdownSnapshot? {
        self.snapshotCache.object(
            forKey: key as NSString
        )?.snapshot
    }

    static func store(
        snapshot: RenderedMarkdownSnapshot,
        for key: String
    ) {
        self.snapshotCache.setObject(
            SnapshotBox(snapshot: snapshot),
            forKey: key as NSString
        )
    }

    static func attributedText(
        for key: String
    ) -> NSAttributedString? {
        self.attributedTextCache.object(
            forKey: key as NSString
        )?.attributedText
    }

    static func store(
        attributedText: NSAttributedString,
        for key: String
    ) {
        self.attributedTextCache.setObject(
            AttributedTextBox(attributedText: attributedText),
            forKey: key as NSString
        )
    }

    private final class SnapshotBox: NSObject {
        let snapshot: RenderedMarkdownSnapshot

        init(snapshot: RenderedMarkdownSnapshot) {
            self.snapshot = snapshot
        }
    }

    private final class AttributedTextBox: NSObject {
        let attributedText: NSAttributedString

        init(attributedText: NSAttributedString) {
            self.attributedText = attributedText
        }
    }

}

private enum MarkdownRenderMetrics {

    private static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.pattonium.Sidekick"
    private static let log = OSLog(
        subsystem: subsystem,
        category: "MarkdownRenderer"
    )
    private static let logger = Logger(
        subsystem: subsystem,
        category: "MarkdownRenderer"
    )

    @discardableResult
    static func begin(
        _ name: StaticString
    ) -> OSSignpostID {
        let signpostID = OSSignpostID(log: self.log)
        os_signpost(
            .begin,
            log: self.log,
            name: name,
            signpostID: signpostID
        )
        return signpostID
    }

    static func end(
        _ name: StaticString,
        _ signpostID: OSSignpostID
    ) {
        os_signpost(
            .end,
            log: self.log,
            name: name,
            signpostID: signpostID
        )
    }

    static func logFallback(
        features: Set<MarkdownFeature>
    ) {
        let names = features
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        self.logger.debug("Markdown fallback features: \(names, privacy: .public)")
    }

}

private extension ColorScheme {

    var cacheKey: String {
        switch self {
            case .dark:
                return "dark"
            case .light:
                return "light"
            @unknown default:
                return "unknown"
        }
    }

    var splashTheme: Splash.Theme {
        switch self {
            case .dark:
                return .wwdc17(withFont: .init(size: 16))
            default:
                return .sunset(withFont: .init(size: 16))
        }
    }

    var markdownTextColor: NSColor {
        switch self {
            case .dark:
                return NSColor(
                    red: 251 / 255,
                    green: 251 / 255,
                    blue: 252 / 255,
                    alpha: 1
                )
            default:
                return NSColor(
                    red: 6 / 255,
                    green: 6 / 255,
                    blue: 6 / 255,
                    alpha: 1
                )
        }
    }

    var linkColor: NSColor {
        switch self {
            case .dark:
                return NSColor(
                    red: 76 / 255,
                    green: 142 / 255,
                    blue: 248 / 255,
                    alpha: 1
                )
            default:
                return NSColor(
                    red: 44 / 255,
                    green: 101 / 255,
                    blue: 207 / 255,
                    alpha: 1
                )
        }
    }

    var markdownSecondaryTextColor: NSColor {
        switch self {
            case .dark:
                return NSColor(
                    red: 146 / 255,
                    green: 148 / 255,
                    blue: 160 / 255,
                    alpha: 1
                )
            default:
                return NSColor(
                    red: 107 / 255,
                    green: 110 / 255,
                    blue: 123 / 255,
                    alpha: 1
                )
        }
    }

    var inlineCodeBackgroundColor: NSColor {
        switch self {
            case .dark:
                return NSColor(
                    red: 37 / 255,
                    green: 38 / 255,
                    blue: 42 / 255,
                    alpha: 1
                )
            default:
                return NSColor(
                    red: 247 / 255,
                    green: 247 / 255,
                    blue: 249 / 255,
                    alpha: 1
                )
        }
    }

}
