//
//  ChatScreenshotHTMLBuilder.swift
//  Sidekick
//
//  Created by John Bean on 5/23/26.
//
//  Builds the payload that drives the chat screenshot template.
//  The renderer loads the bundled `screenshot.html` directly and
//  then evaluates a JS bootstrap call with the payload — so all
//  this type has to produce is the JSON.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
struct ChatScreenshotHTMLBuilder {
    
    /// Inputs the renderer needs to drive an offscreen page.
    struct Output {
        /// JSON string ready to be passed to `window.skBootstrap(...)`.
        let payloadJSON: String
        /// Bundled `screenshot.html` URL.
        let templateURL: URL
        /// Containing folder — passed to
        /// `WKWebView.loadFileURL(_:allowingReadAccessTo:)` so
        /// every sibling resource is reachable.
        let resourcesFolder: URL
    }
    
    static func build(
        conversation: Conversation,
        messages: [Message],
        scope: ChatScreenshotScope,
        colorScheme: ColorScheme? = nil,
        fontSize: CGFloat = 14
    ) throws -> Output {
        guard let folderURL = ChatMarkdownWebViewResources.shared.bundleFolderURL else {
            throw ChatScreenshotError.templateMissing
        }
        let templateURL: URL = folderURL.appendingPathComponent("screenshot.html")
        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            throw ChatScreenshotError.templateMissing
        }
        
        let theme: String = Self.resolveTheme(preferred: colorScheme)
        let timeLabel: String = Self.timeLabelFormatter.string(from: .now)
        
        let rows: [[String: Any]] = messages.map { message in
            return Self.payload(for: message, conversation: conversation)
        }
        
        let payload: [String: Any] = [
            "theme": theme,
            "fontSize": Double(fontSize),
            "scope": scope.filenameTag,
            "title": conversation.title,
            "timeLabel": timeLabel,
            "rows": rows,
        ]
        
        let payloadJSON: String = try Self.encodePayload(payload)
        return Output(
            payloadJSON: payloadJSON,
            templateURL: templateURL,
            resourcesFolder: folderURL
        )
    }
    
    // MARK: - Payload assembly
    
    private static func payload(
        for message: Message,
        conversation: Conversation
    ) -> [String: Any] {
        let sender: Sender = message.getSender()
        let avatar: AvatarStyle = Self.avatarStyle(for: message)
        let senderName: String = Self.senderName(
            for: message,
            sender: sender,
            avatar: avatar
        )
        
        var row: [String: Any] = [
            "id": message.id.uuidString,
            "sender": sender.rawValue,
            "senderName": senderName,
            "timeLabel": Self.timestampLabel(message.startTime),
            "avatar": [
                "fillHex": avatar.fillHex,
                "foregroundHex": avatar.foregroundHex,
                "symbol": avatar.symbol,
            ] as [String: Any],
        ]
        
        if sender == .assistant {
            // The model field is "Unknown" for messages that didn't
            // record one — show it only when meaningful.
            let trimmed = message.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty
                && trimmed.lowercased() != "unknown"
                && trimmed != String(localized: "Unknown") {
                row["modelLabel"] = trimmed
            }
        }
        
        // Image messages skip Markdown entirely.
        if message.contentType == .image, let url = message.imageUrl {
            row["imageUrl"] = Self.assetURL(for: url)
            row["imageAlt"] = "Generated image"
            // The Markdown body of an image message is the prompt
            // narration; surface it as a caption so the screenshot
            // explains what was generated.
            let trimmed = message.responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                row["imageCaption"] = trimmed
            }
        } else {
            row["text"] = message.responseText
        }
        
        // Reasoning banner — body included so the screenshot shows
        // the full chain of thought (matches the expanded SwiftUI
        // view a user would take a screenshot of).
        if message.hasReasoning {
            var reasoning: [String: Any] = [
                "durationLabel": Self.reasoningDurationLabel(message),
            ]
            if let body = message.reasoningText, !body.isEmpty {
                reasoning["body"] = body
            }
            row["reasoning"] = reasoning
        }
        
        // Per-iteration agent loop steps: reasoning + explainer text
        // + the tool calls invoked at the end of the step. Rendered
        // before the final reasoning banner / answer so the export
        // mirrors the chronological "think → narrate → call → …"
        // trail shown in the live UI.
        if !message.steps.isEmpty {
            row["steps"] = message.steps.map { step -> [String: Any] in
                var stepRow: [String: Any] = [
                    "id": step.id.uuidString,
                ]
                if step.hasReasoning, let reasoning = step.reasoningText {
                    var reasoningPayload: [String: Any] = [:]
                    if let label = step.formattedReasoningDuration {
                        reasoningPayload["durationLabel"] = String(
                            format: String(localized: "Thought for %@"), label
                        )
                    }
                    reasoningPayload["body"] = reasoning
                    stepRow["reasoning"] = reasoningPayload
                }
                if step.hasExplainerText {
                    stepRow["explainerText"] = step.explainerText
                }
                if !step.functionCallRecords.isEmpty {
                    stepRow["functionCalls"] = Self.encodeFunctionCalls(step.functionCallRecords)
                }
                return stepRow
            }
        } else if let calls = message.functionCallRecords, !calls.isEmpty {
            // Legacy single-bubble path: no per-step breakdown
            // available, so render the flat function call list the
            // way older messages have always been exported.
            row["functionCalls"] = Self.encodeFunctionCalls(calls)
        }
        
        // Attachments are a user-side concept; references are an
        // assistant-side concept (model-cited URLs). Both come from
        // `referencedURLs` — split by sender.
        if !message.referencedURLs.isEmpty {
            let chips: [[String: Any]] = message.referencedURLs.map { ref in
                return [
                    "filename": ref.displayName,
                    "isWeb": ref.url.isWebURL,
                ]
            }
            switch sender {
                case .user:
                    row["attachments"] = chips
                default:
                    row["references"] = chips
            }
        }
        
        return row
    }
    
    /// Serialize a flat list of ``FunctionCallRecord`` into the
    /// payload shape the JS renderer expects.
    private static func encodeFunctionCalls(
        _ calls: [FunctionCallRecord]
    ) -> [[String: Any]] {
        return calls.map { call -> [String: Any] in
            let status: String = call.status.map { $0.jsKey } ?? "executing"
            var payload: [String: Any] = [
                "name": call.name,
                "status": status,
                "didExecute": call.status?.didExecute ?? false,
            ]
            // Include the result so the export carries enough
            // context to make sense of the call; mirrors
            // ``FunctionCallsView.FunctionCallView.details`` which
            // truncates to ~1000 chars to keep the bubble compact.
            if let result = call.result, !result.isEmpty {
                payload["result"] = Self.truncateMiddle(result)
            }
            return payload
        }
    }

    /// Mirrors ``FunctionCallsView.FunctionCallView.truncateMiddle``
    /// so the screenshot and the live chat clip results the same way.
    private static func truncateMiddle(
        _ text: String,
        maxLength: Int = 1000,
        indicator: String = "..."
    ) -> String {
        guard text.count > maxLength else { return text }
        guard maxLength >= indicator.count + 2 else {
            return String(text.prefix(maxLength))
        }
        let availableLength = maxLength - indicator.count
        let leftLength = (availableLength + 1) / 2
        let rightLength = availableLength / 2
        return String(text.prefix(leftLength)) + indicator + String(text.suffix(rightLength))
    }

    // MARK: - Theming + formatting
    
    /// Picks `"dark"` or `"light"` from the requested ``ColorScheme``,
    /// falling back to the app's current `effectiveAppearance` when no
    /// preference is supplied.
    private static func resolveTheme(preferred: ColorScheme?) -> String {
        if let preferred {
            return (preferred == .dark) ? "dark" : "light"
        }
        let appearance = NSApp?.effectiveAppearance
        let matched = appearance?.bestMatch(from: [.darkAqua, .aqua])
        return (matched == .darkAqua) ? "dark" : "light"
    }
    
    private static let timeLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    
    private static let perMessageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    
    private static func timestampLabel(_ date: Date) -> String {
        return Self.perMessageFormatter.string(from: date)
    }
    
    private static func reasoningDurationLabel(_ message: Message) -> String {
        // Mirror MessageReasoningProcessView: freeze the duration at
        // the moment reasoning ended so screenshots match what the
        // user sees in the chat.
        let endTime: Date = message.reasoningEndTime ?? message.lastUpdated
        let seconds: Double = max(
            0,
            endTime.timeIntervalSince(message.startTime)
        )
        if seconds < 10 {
            return String(format: String(localized: "Thought for %.2f seconds"), seconds)
        }
        return String(format: String(localized: "Thought for %.0f seconds"), seconds)
    }
    
    // MARK: - Avatar resolution
    
    private struct AvatarStyle {
        let fillHex: String
        let foregroundHex: String
        let symbol: String
        let expertName: String?
    }
    
    private static func avatarStyle(for message: Message) -> AvatarStyle {
        if let expertId = message.expertId,
           let expert = ExpertManager.getExpert(id: expertId) {
            return AvatarStyle(
                fillHex: Self.cssHex(for: expert.color),
                foregroundHex: Self.cssHex(for: expert.color.adaptedTextColor),
                symbol: expert.symbolName,
                expertName: expert.name
            )
        }
        // Sender-default avatar mirrors ``Sender/icon``.
        let sender: Sender = message.getSender()
        let fill: Color
        let symbol: String
        switch sender {
            case .user:
                fill = .purple
                symbol = "person.fill"
            case .assistant, .system:
                fill = .green
                symbol = "cpu.fill"
            case .tool:
                fill = .green
                symbol = "wrench.and.screwdriver.fill"
        }
        return AvatarStyle(
            fillHex: Self.cssHex(for: fill),
            foregroundHex: Self.cssHex(for: .white),
            symbol: symbol,
            expertName: nil
        )
    }
    
    private static func senderName(
        for message: Message,
        sender: Sender,
        avatar: AvatarStyle
    ) -> String {
        if let expertName = avatar.expertName {
            return expertName
        }
        switch sender {
            case .user:      return String(localized: "You")
            case .assistant: return String(localized: "Assistant")
            case .system:    return String(localized: "System")
            case .tool:      return String(localized: "Tool")
        }
    }
    
    /// Returns a CSS-ready `#RRGGBB` string from a SwiftUI `Color`.
    /// Falls back to a stable neutral gray if the color refuses to
    /// resolve (e.g. before the SwiftUI environment is ready).
    private static func cssHex(for color: Color) -> String {
        if let hex = color.toHex() {
            // `toHex` returns RRGGBBAA — strip the alpha for CSS.
            let trimmed = hex.count == 8 ? String(hex.prefix(6)) : hex
            return "#" + trimmed
        }
        return "#7c4dff"
    }
    
    // MARK: - Asset URL proxying
    
    /// Generates the same `sidekick-asset://load?u=...` URL that
    /// the in-chat Markdown renderer uses, so embedded images route
    /// through ``ChatMarkdownAssetSchemeHandler``.
    private static func assetURL(for url: URL) -> String {
        let raw: String = url.isFileURL ? url.path : url.absoluteString
        var components = URLComponents()
        components.scheme = "sidekick-asset"
        components.host = "load"
        components.queryItems = [URLQueryItem(name: "u", value: raw)]
        return components.url?.absoluteString ?? raw
    }
    
    // MARK: - Payload encoding
    
    private static func encodePayload(_ payload: [String: Any]) throws -> String {
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        } catch {
            throw ChatScreenshotError.payloadEncodingFailed(error)
        }
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ChatScreenshotError.payloadEncodingFailed(nil)
        }
        return jsonString
    }
}

// MARK: - JS-friendly status mapping

private extension FunctionCallRecord.Status {
    var jsKey: String {
        switch self {
            case .succeeded: return "succeeded"
            case .failed:    return "failed"
            case .executing: return "executing"
        }
    }
}
