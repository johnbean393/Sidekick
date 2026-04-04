//
//  Function.swift
//  Sidekick
//
//  Created by John Bean on 4/7/25.
//

import Foundation
import LocalAuthentication
import SwiftUI

// MARK: Function Call Decoder
public protocol DecodableFunctionCall: Decodable {
    
    init?(
        name: String,
        params: any FunctionParams,
        toolCallID: String?
    )
    
    static func parse(from data: Data, using decoder: JSONDecoder) -> Self?
    
    var name: String { get }
    var toolCallID: String? { get set }
    
    mutating func call(using registry: ToolRegistry) async throws -> String?
    func getJsonSchema() -> String
    func getArgumentsJSONString() -> String
    
}

// MARK: - Updated Function Parameter
public struct FunctionParameter: Codable {
    
    var label: String
    var description: String
    var datatype: Datatype
    var isRequired: Bool = true
    
    public enum Datatype: String, Codable {
        
        case string
        case integer
        case float
        case boolean
        case stringArray
        case integerArray
        case floatArray
        
        var isArray: Bool {
            switch self {
                case .stringArray, .integerArray, .floatArray:
                    return true
                default:
                    return false
            }
        }
        
    }
    
}

// MARK: - Function Protocol
protocol FunctionProtocol: Identifiable {
    
    associatedtype Parameters
    associatedtype Result
    
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var params: [FunctionParameter] { get }
    var run: (Parameters) async throws -> Result { get }
    
    func getJsonSchema() -> String
    
}

// MARK: - Generic Function Implementation
public struct Function<Parameter: FunctionParams, Result: Codable>: FunctionProtocol, AnyFunctionBox {

    public var id: String { return name }
    
    public var name: String
    public var description: String
    public var clearance: Clearance
    public var allowsParallelExecution: Bool
    
    public var params: [FunctionParameter]
    public var run: (Parameter) async throws -> Result
    
    public var paramsType: any FunctionParams.Type
    public var resultType: Codable.Type
    
    public init(
        name: String,
        description: String,
        clearance: Clearance = .regular,
        allowsParallelExecution: Bool = false,
        params: [FunctionParameter] = [],
        run: @MainActor @escaping (Parameter) async throws -> Result
    ) {
        self.name = name
        self.description = description
        self.clearance = clearance
        self.allowsParallelExecution = allowsParallelExecution
        self.params = params
        self.paramsType = Parameter.self
        self.resultType = Result.self
        self.run = run
    }
    
    public var functionObject: FunctionObject {
        // Create numbered properties to ensure order
        let properties = Dictionary(uniqueKeysWithValues: params.enumerated().map { index, param in
            let numberedKey = String(format: "%04d_%@", index, param.label)
            return (numberedKey, FunctionObject.Function.InputSchema.Property(
                type: param.datatype.rawValue,
                description: param.description,
                isRequired: param.isRequired
            ))
        })
        
        return FunctionObject(
            type: "function",
            function: FunctionObject.Function(
                name: self.name,
                description: self.description,
                inputSchema: FunctionObject.Function.InputSchema(
                    type: "object",
                    properties: properties,
                    paramLabels: params.map { $0.label }
                )
            )
        )
    }
    
    /// A function to get the function's JSON schema to inject into the system prompt
    public func getJsonSchema() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try! encoder.encode(self.functionObject)
        let jsonStr = String(data: jsonData, encoding: .utf8)!
        // Process the JSON to remove the number prefixes
        return cleanNumberedKeys(jsonStr)
    }
    
    private func cleanNumberedKeys(_ jsonStr: String) -> String {
        // Remove the numbered prefixes from property keys
        var lines = jsonStr.components(separatedBy: .newlines)
        lines = lines.map { line in
            if line.contains("\"0") { // Matches our numbered format
                let components = line.split(separator: "\"", omittingEmptySubsequences: false)
                if components.count >= 2 {
                    var key = String(components[1])
                    if let underscoreIndex = key.firstIndex(of: "_") {
                        key = String(key[key.index(after: underscoreIndex)...])
                        return line.replacingOccurrences(of: components[1], with: key)
                    }
                }
            }
            return line
        }
        return lines.joined(separator: "\n")
    }
    
    /// A function to call the function
    public func call(
        withData data: Data
    ) async throws -> String? {
        // Decode the provided arguments to the generic Parameter type
        let params: Parameter = try JSONDecoder().decode(
            Parameter.self,
            from: data
        )
        // Ask for permissions if needed
        let requestDescription: String = String(localized: """
Sidekick wants to run the function `\(self.name)` to complete your request with the parameters below.

\(String(data: data, encoding: .utf8)!)

Do you wish to permit this?
""")
        switch self.clearance {
            case .regular:
                break
            case .sensitive:
                // Ask with dialog
                if await !Dialogs.showConfirmation(
                    title: String(localized: "Function Use"),
                    message: requestDescription
                ) {
                    // If denied, throw error
                    throw FunctionCallError.permissionsDenied
                }
            case .dangerous:
                // Ask for identification
                let context: LAContext = LAContext()
                let policy: LAPolicy = LAPolicy.deviceOwnerAuthentication
                let result = try await context.evaluatePolicy(
                    policy,
                    localizedReason: requestDescription
                )
                if !result {
                    // If denied, throw error
                    throw FunctionCallError.permissionsDenied
                }
        }
        // Execute the wrapped run closure.
        let result = try await run(params)
        return String(describing: result)
    }
    
    /// The function mapped to an OpenAI compatible function call
    public var openAiFunctionCall: OpenAIFunction {
        // Map the function parameters to the OpenAI function properties
        let properties = self.params.reduce(
            into: [String: PropertyDetail]()
        ) { dict, param in
            dict[param.label] = PropertyDetail(
                functionParameter: param
            )
        }
        let requiredFields = self.params.filter { $0.isRequired }.map { $0.label }
        
        let parameterSchema = ParameterSchema(
            type: "object",
            properties: properties,
            required: requiredFields,
            additionalProperties: false
        )
        
        let funcDetail = FunctionDetail(
            name: self.name,
            description: self.description,
            parameters: parameterSchema,
            strict: true
        )
        
        return OpenAIFunction(
            type: "function",
            function: funcDetail
        )
    }
    
    public enum Clearance: String, CaseIterable, Codable {
        case regular
        case sensitive
        case dangerous
    }
    
    public enum FunctionCallError: LocalizedError {
        
        case permissionsDenied
        case functionNotFound
        
        public var errorDescription: String? {
            switch self {
                case .permissionsDenied:
                    return "The user denied your request to use this tool."
                case .functionNotFound:
                    return "The function called is not available."
            }
        }
        
    }
    
    public struct FunctionObject: Codable {
        
        var type: String = "function"
        var function: Function
        
        public struct Function: Codable {
            
            var name: String
            var description: String
            var inputSchema: InputSchema
            
            public struct InputSchema: Codable {
                
                let type: String
                let properties: [String: Property]
                var required: [String]
                private let paramLabels: [String]
                
                init(
                    type: String,
                    properties: [String: Property],
                    paramLabels: [String]
                ) {
                    self.type = type
                    self.properties = properties
                    self.paramLabels = paramLabels
                    // Compute required preserving the original param order
                    self.required = paramLabels.filter { label in
                        // Find the numbered key that ends with this label
                        properties.first { key, prop in
                            key.hasSuffix("_\(label)") && prop.isRequired
                        } != nil
                    }
                }
                
                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(type, forKey: .type)
                    try container.encode(properties, forKey: .properties)
                    // Encode required without number prefixes
                    try container.encode(required, forKey: .required)
                }
                
                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.type = try container.decode(String.self, forKey: .type)
                    self.properties = try container.decode([String: Property].self, forKey: .properties)
                    self.required = try container.decode([String].self, forKey: .required)
                    self.paramLabels = self.required.isEmpty ? Array(properties.keys) : self.required
                }
                
                public enum CodingKeys: String, CodingKey {
                    case type, properties, required
                }
                
                public struct Property: Codable {
                    let type: String
                    let description: String
                    let isRequired: Bool
                }
                
            }
            
        }
        
    }
    
    public var functionCallType: DecodableFunctionCall.Type {
        return Self.FunctionCall.self
    }
    
    public struct FunctionCall: Codable, Equatable, Hashable, DecodableFunctionCall {
        
        /// Function to conform to equatable
        public static func == (lhs: FunctionCall, rhs: FunctionCall) -> Bool {
            return lhs.config == rhs.config
        }
        
        /// The name of the function
        public var name: String {
            return self.config.name
        }
        
        public var toolCallID: String?
        /// The function call's configuration
        let config: FunctionCallConfig
        
        // Custom coding keys to match both possible JSON structures
        enum CodingKeys: String, CodingKey {
            case functionCall = "function_call"
            case function = "function"
        }
        
        // Custom initializer to handle OpenAI tool calling format
        public init?(
            name: String,
            params: any FunctionParams,
            toolCallID: String? = nil
        ) {
            // Cast params
            guard let params = params as? Parameter else {
                return nil
            }
            self.toolCallID = toolCallID
            // Create config
            self.config = FunctionCallConfig(
                name: name,
                arguments: params
            )
        }
        
        // Custom decoding initialization to handle both keys
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Try decoding using function_call first, then function
            if let config = try? container.decode(
                FunctionCallConfig.self,
                forKey: .functionCall
            ) {
                self.config = config
                self.toolCallID = nil
            } else if let config = try? container.decode(
                FunctionCallConfig.self,
                forKey: .function
            ) {
                self.config = config
                self.toolCallID = nil
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Neither 'function_call' nor 'function' key found in JSON"
                    )
                )
            }
        }
        
        // Custom encoding to use function_call key
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(config, forKey: .functionCall)
        }
        
        /// Function to call the function
        mutating public func call(using registry: ToolRegistry) async throws -> String? {
            // Locate the function by name
            guard let function = registry.function(named: self.config.name) else {
                throw FunctionCallError.functionNotFound
            }
            // Instead of expecting a raw type (like a tuple or a simple String), we are using Codable structs for parameters
            let encoder: JSONEncoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let argumentData: Data = try encoder.encode(self.config.arguments)
            // Use the type erased call method.
            return try await function.call(withData: argumentData)
        }
        
        /// Function to convert the function call to JSON
        public func getJsonSchema() -> String {
            let encoder: JSONEncoder = JSONEncoder()
            let jsonData: Data? = try? encoder.encode(self)
            return String(data: jsonData!, encoding: .utf8)!
        }
        
        public func getArgumentsJSONString() -> String {
            let encoder: JSONEncoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData: Data? = try? encoder.encode(self.config.arguments)
            return String(data: jsonData ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        }
        
        /// Function to decode the function from data
        public static func parse(
            from data: Data,
            using decoder: JSONDecoder
        ) -> Function<Parameter, Result>.FunctionCall? {
            do {
                return try decoder.decode(
                    Function<Parameter, Result>.FunctionCall.self,
                    from: data
                )
            } catch {
                return nil
            }
        }
        
        public enum Status: Codable, CaseIterable {
            
            case succeeded
            case failed
            case executing
            
            var color: Color {
                switch self {
                    case .succeeded:
                        return .brightGreen
                    case .failed:
                        return .red
                    case .executing:
                        return .secondary
                }
            }
            
        }
        
        public struct FunctionCallConfig: Codable, Hashable {
            
            public static func == (lhs: Function<Parameter, Result>.FunctionCall.FunctionCallConfig, rhs: Function<Parameter, Result>.FunctionCall.FunctionCallConfig) -> Bool {
                return lhs.name == rhs.name
            }
            
            let name: String
            let arguments: Parameter
            
        }
        
    }
    
}

// MARK: - Parameter Parsing Error
enum ParameterParsingError: Error {
    case invalidArrayFormat(String)
    case incompatibleType(String)
    case invalidValue(String)
}
