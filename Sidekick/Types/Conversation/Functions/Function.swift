//
//  Function.swift
//  Sidekick
//
//  Created by John Bean on 4/7/25.
//

import Foundation
import LocalAuthentication
import SwiftUI

// MARK: Function Call
public protocol DecodableFunctionCall {
    
    init?(
        name: String,
        params: any FunctionParams,
        toolCallID: String?
    )
    
    var name: String { get }
    var toolCallID: String? { get set }
    
    mutating func call(using registry: ToolRegistry) async throws -> String?
    func getArgumentsJSONString() -> String
    
}

// MARK: - Function Parameter
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
        if !Settings.runFunctionsWithoutApproval {
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
    
    public var functionCallType: DecodableFunctionCall.Type {
        return Self.FunctionCall.self
    }
    
    public struct FunctionCall: Equatable, Hashable, DecodableFunctionCall {
        
        public static func == (lhs: FunctionCall, rhs: FunctionCall) -> Bool {
            return lhs.name == rhs.name
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
        }
        
        /// The name of the function
        public let name: String
        /// The arguments passed to the function
        public let arguments: Parameter
        /// The id provided by the inference server for matching to its tool result
        public var toolCallID: String?
        
        public init?(
            name: String,
            params: any FunctionParams,
            toolCallID: String? = nil
        ) {
            guard let params = params as? Parameter else {
                return nil
            }
            self.name = name
            self.arguments = params
            self.toolCallID = toolCallID
        }
        
        /// Function to call the function
        mutating public func call(using registry: ToolRegistry) async throws -> String? {
            // Locate the function by name
            guard let function = registry.function(named: self.name) else {
                throw FunctionCallError.functionNotFound
            }
            let encoder: JSONEncoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let argumentData: Data = try encoder.encode(self.arguments)
            return try await function.call(withData: argumentData)
        }
        
        public func getArgumentsJSONString() -> String {
            let encoder: JSONEncoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData: Data? = try? encoder.encode(self.arguments)
            return String(data: jsonData ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
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
        
    }
    
}

// MARK: - Parameter Parsing Error
enum ParameterParsingError: Error {
    case invalidArrayFormat(String)
    case incompatibleType(String)
    case invalidValue(String)
}
