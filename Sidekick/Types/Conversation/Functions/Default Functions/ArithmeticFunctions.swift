//
//  ArithmeticFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/14/25.
//

import Foundation

public class ArithmeticFunctions {
    
    static var functions: [AnyFunctionBox] = [
        ArithmeticFunctions.sum,
        ArithmeticFunctions.average,
        ArithmeticFunctions.multiply,
        ArithmeticFunctions.sumRange
    ]
    
    /// A ``Function`` for adding up 2 numbers
    static let sum = Function<SumParams, Float>(
        name: "sum",
        description: "Adds a maximum of 5 numbers together. All but the first number is optional.",
        allowsParallelExecution: true,
        params: [
            FunctionParameter(
                label: "a",
                description: "The first number to add",
                datatype: .float,
                isRequired: true
            ),
            FunctionParameter(
                label: "b",
                description: "The second number to add (optional)",
                datatype: .float,
                isRequired: false
            ),
            FunctionParameter(
                label: "c",
                description: "The third number to add (optional)",
                datatype: .float,
                isRequired: false
            ),
            FunctionParameter(
                label: "d",
                description: "The fourth number to add (optional)",
                datatype: .float,
                isRequired: false
            ),
            FunctionParameter(
                label: "e",
                description: "The fifth number to add (optional)",
                datatype: .float,
                isRequired: false
            )
        ],
        run: { params in
            return params.a + (params.b ?? 0) + (params.c ?? 0) + (params.d ?? 0) + (params.e ?? 0)
        }
    )
    struct SumParams: FunctionParams {
        var a: Float
        var b: Float? = nil
        var c: Float? = nil
        var d: Float? = nil
        var e: Float? = nil
    }
    
    /// A ``Function`` for getting the product of 2 numbers
    static let multiply = Function<MultiplyParams, Float>(
        name: "multiply",
        description: "Multiplies 2 numbers.",
        allowsParallelExecution: true,
        params: [
            FunctionParameter(
                label: "a",
                description: "The first number to multiply",
                datatype: .float,
                isRequired: true
            ),
            FunctionParameter(
                label: "b",
                description: "The second number to multiply",
                datatype: .float,
                isRequired: true
            )
        ],
        run: { params in
            return params.a * params.b
        }
    )
    struct MultiplyParams: FunctionParams {
        var a: Float
        var b: Float
    }
    
    /// A ``Function`` for getting the sum of all numbers within a range
    static let sumRange = Function<SumRangeParams, Int>(
        name: "sum_range",
        description: "Sums all integers between 2 integers, inclusive.",
        allowsParallelExecution: true,
        params: [
            FunctionParameter(
                label: "a",
                description: "The first number in the range",
                datatype: .integer,
                isRequired: true
            ),
            FunctionParameter(
                label: "b",
                description: "The second number in the range",
                datatype: .integer,
                isRequired: true
            )
        ],
        run: { params in
            return Array(params.a...params.b).reduce(0, +)
        }
    )
    struct SumRangeParams: FunctionParams {
        var a: Int
        var b: Int
    }
    
    /// A ``Function`` for getting the average of numbers
    static let average = Function<AverageParams, Float>(
        name: "average",
        description: "Calculates the average of an array of numbers.",
        allowsParallelExecution: true,
        params: [
            FunctionParameter(
                label: "numbers",
                description: "Array of numbers to calculate the average from",
                datatype: .floatArray,
                isRequired: true
            )
        ],
        run: { params in
            guard !params.numbers.isEmpty else {
                throw AverageError.noNumbers
            }
            return params.numbers.reduce(0, +) / Float(params.numbers.count)
            // Custom error for average function
            enum AverageError: LocalizedError {
                case noNumbers
                var errorDescription: String? {
                    switch self {
                        case .noNumbers:
                            return "No numbers were provided from which to calculate an average."
                    }
                }
            }
        }
    )
    struct AverageParams: FunctionParams {
        var numbers: [Float]
    }
    
}
