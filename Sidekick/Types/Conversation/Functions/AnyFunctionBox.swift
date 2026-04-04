//
//  AnyFunctionBox.swift
//  Sidekick
//
//  Created by John Bean on 4/15/25.
//

import Foundation

public protocol AnyFunctionBox {
    
    var name: String { get }
    var description: String { get }
    var params: [FunctionParameter] { get }
    var allowsParallelExecution: Bool { get }
    
    func getJsonSchema() -> String
    func call(withData data: Data) async throws -> String?
    
    var paramsType: any FunctionParams.Type { get }
    var resultType: Codable.Type { get }
    
    var openAiFunctionCall: OpenAIFunction { get }
    
    var functionCallType: DecodableFunctionCall.Type { get }
    
}

public struct ToolRegistry {
    
    let functions: [AnyFunctionBox]
    private let functionMap: [String: AnyFunctionBox]
    
    init(functions: [AnyFunctionBox]) {
        self.functions = functions
        self.functionMap = Dictionary(
            uniqueKeysWithValues: functions.map { ($0.name, $0) }
        )
    }
    
    var sortedFunctions: [AnyFunctionBox] {
        return self.functions.sorted(by: {
            $0.params.count > $1.params.count
        })
    }
    
    func function(named name: String) -> AnyFunctionBox? {
        return self.functionMap[name]
    }
}
