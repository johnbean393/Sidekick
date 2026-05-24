//
//  MessageStep.swift
//  Sidekick
//
//  Captures a single iteration of the assistant's tool-calling loop:
//  the chain of thought it produced, the user-facing explainer text
//  it emitted before invoking tools, and the tools it invoked at the
//  end of the iteration.
//
//  Persisting this lets us show the full reasoning + narration trail
//  between tool calls in completed conversations, not just the very
//  last turn the model produced.
//

import Foundation

/// A single iteration of the assistant's agentic loop.
///
/// A `Message` accumulates one ``MessageStep`` for every iteration in
/// which the model emitted tool calls. The *final* iteration — the
/// one that produces the user-facing answer with no further tool
/// calls — is not stored as a step; it lives directly on the parent
/// ``Message`` (`text`, `reasoningText`, `responseText`, etc.).
public struct MessageStep: Codable, Identifiable, Hashable {

    public var id: UUID

    /// Chain of thought emitted by the model during this iteration,
    /// with the surrounding `<think>` / `</think>` tokens stripped.
    /// `nil` when the model did not produce reasoning for the step.
    public var reasoningText: String?

    /// User-facing text the model emitted between its reasoning and
    /// its tool calls (e.g. "Let me look that up for you…"). Stored
    /// after `reasoningRemoved`, trimmed of surrounding whitespace.
    public var explainerText: String

    /// Tool calls invoked at the end of this iteration, with their
    /// post-execution status and result attached.
    public var functionCallRecords: [FunctionCallRecord]

    /// When the iteration began streaming. Used together with
    /// ``reasoningEndTime`` to render a per-step "Thought for …"
    /// pill that mirrors the top-level reasoning banner.
    public var startTime: Date

    /// When the iteration's reasoning phase ended — i.e. when the
    /// model closed `</think>` and started emitting the explainer
    /// text or its tool calls. `nil` for steps with no reasoning.
    public var reasoningEndTime: Date?

    public init(
        id: UUID = UUID(),
        reasoningText: String? = nil,
        explainerText: String = "",
        functionCallRecords: [FunctionCallRecord] = [],
        startTime: Date = .now,
        reasoningEndTime: Date? = nil
    ) {
        self.id = id
        self.reasoningText = reasoningText
        self.explainerText = explainerText
        self.functionCallRecords = functionCallRecords
        self.startTime = startTime
        self.reasoningEndTime = reasoningEndTime
    }

    /// `true` when this step has any reasoning content to display.
    public var hasReasoning: Bool {
        guard let reasoningText else { return false }
        return !reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `true` when the model emitted user-facing explainer text
    /// between its reasoning and its tool calls.
    public var hasExplainerText: Bool {
        return !self.explainerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Formatted "Thought for N seconds" label for the step's
    /// reasoning banner. Falls back to "Thinking…" until the
    /// reasoning phase has closed.
    public var formattedReasoningDuration: String? {
        guard self.hasReasoning else { return nil }
        guard let reasoningEndTime else { return nil }
        let duration: Double = max(
            0,
            reasoningEndTime.timeIntervalSince(self.startTime)
        )
        if duration < 10 {
            return String(format: "%.2f seconds", duration)
        }
        return String(format: "%.0f seconds", duration)
    }
}
