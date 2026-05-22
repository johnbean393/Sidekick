//
//  Expert.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import Foundation
import SwiftUI

/// An object that manages a chatbot expert
public struct Expert: Identifiable, Codable, Hashable, Sendable {
    
    /// Stored property for `Identifiable` conformance
    public var id: UUID = UUID()
    
    /// The expert's name, of type `String`
    public var name: String
    
    /// The expert's symbol name, of type `String`
    public var symbolName: String
    
    /// The expert's color of type `Color`
    public var color: Color
    
    /// Whether web search is used, of type `Bool`
    public var useWebSearch: Bool = true
    
    /// The expert's associated resources, of type `Resource`
    public var resources: Resources = Resources()
    
    /// The expert's system prompt (if customised), of type `String?`
    public var systemPrompt: String? = nil
    
    /// Controls whether the expert's resources is persisted across sessions, of type `Bool`
    public var persistResources: Bool = true
    
    /// Whether Graph RAG is enabled for this expert
    public var useGraphRAG: Bool {
        get { return resources.useGraphRAG }
        set { resources.useGraphRAG = newValue }
    }
    
    /// A `Bool` representing whether the expert is the default expert
    @MainActor
    public var isDefault: Bool {
        return self == ExpertManager.default
    }
    
    /// The `default` expert of type ``Expert``
    public static let `default`: Expert = Expert(
        name: String(localized: "Default"),
        symbolName: "person.fill",
        color: Color.blue,
        useWebSearch: false,
        resources: Resources(),
        persistResources: false
    )
    
    /// Stub for `Equatable` conformance
    public static func == (lhs: Expert, rhs: Expert) -> Bool {
        lhs.id == rhs.id
    }
    
}
