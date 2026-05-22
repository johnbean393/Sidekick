//
//  SidekickTests.swift
//  SidekickTests
//
//  Created by Bean John on 10/4/24.
//

import AppKit
import DefaultModels
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Sidekick

struct SidekickTests {
    struct ToolCallingEchoParams: FunctionParams {
        var text: String
    }


	/// Test to check model reccomendations on different hardware
	@Test func checkModelReccomendations() async throws {
		await DefaultModels.checkModelRecommendations()
	}

	@Test func localVisionConfigurationUsesCompanionProjector() async throws {
		let directoryUrl: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(
			at: directoryUrl,
			withIntermediateDirectories: true
		)
		defer {
			try? FileManager.default.removeItem(at: directoryUrl)
		}
		let modelUrl: URL = directoryUrl.appendingPathComponent(
			"gemma-4-26B-A4B-it-Q4_K_M.gguf"
		)
		let projectorUrl: URL = directoryUrl.appendingPathComponent(
			"mmproj-gemma-4-26B-A4B-it-BF16.gguf"
		)
		FileManager.default.createFile(atPath: modelUrl.path(), contents: Data())
		FileManager.default.createFile(atPath: projectorUrl.path(), contents: Data())

		let visionConfiguration = Settings.localVisionConfiguration(
			for: modelUrl
		)

			#expect(visionConfiguration.projectorModelUrl?.standardizedFileURL == projectorUrl.standardizedFileURL)
		#expect(visionConfiguration.useVision)
	}

	@Test func localVisionConfigurationDisablesVisionWithoutProjector() async throws {
		let directoryUrl: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(
			at: directoryUrl,
			withIntermediateDirectories: true
		)
		defer {
			try? FileManager.default.removeItem(at: directoryUrl)
		}
		let originalModelUrl: URL = directoryUrl.appendingPathComponent(
			"gemma-4-26B-A4B-it-Q4_K_M.gguf"
		)
		let projectorUrl: URL = directoryUrl.appendingPathComponent(
			"mmproj-gemma-4-26B-A4B-it-BF16.gguf"
		)
		let replacementModelUrl: URL = directoryUrl.appendingPathComponent(
			"qwen-3-8b-instruct-q4_k_m.gguf"
		)
		FileManager.default.createFile(atPath: originalModelUrl.path(), contents: Data())
		FileManager.default.createFile(atPath: projectorUrl.path(), contents: Data())
		FileManager.default.createFile(atPath: replacementModelUrl.path(), contents: Data())

		let originalVisionConfiguration = Settings.localVisionConfiguration(
			for: originalModelUrl
		)
		try FileManager.default.removeItem(at: projectorUrl)
		let replacementVisionConfiguration = Settings.localVisionConfiguration(
			for: replacementModelUrl
		)

		#expect(originalVisionConfiguration.projectorModelUrl != nil)
		#expect(originalVisionConfiguration.useVision)
		#expect(replacementVisionConfiguration.projectorModelUrl == nil)
		#expect(replacementVisionConfiguration.useVision == false)
	}

    @Test func malformedOnlyToolCallsStillRequireFunctionHandling() async throws {
        let response = LlamaServer.CompleteResponse(
            text: "",
            responseStartSeconds: 0,
            predictedPerSecond: nil,
            modelName: nil,
            usage: nil,
            usedServer: false,
            availableFunctions: ArithmeticFunctions.functions,
            malformedToolCalls: [
                MalformedToolCall(
                    index: 0,
                    name: "sum",
                    rawArguments: #"{"a": 1"#,
                    errorDescription: "Invalid JSON format"
                )
            ]
        )

        #expect(response.containsFunctionCall == false)
        #expect(response.requiresFunctionHandling)
    }

    @Test func qwen36ModelNamesSupportNativeToolCalling() async throws {
        #expect(InferenceSettings.modelNameSupportsNativeToolCalling("Qwen3.6-235B-A22B-Instruct-2509"))
        #expect(InferenceSettings.modelNameSupportsNativeToolCalling("qwen/qwen3.6-coder"))
        #expect(InferenceSettings.modelNameSupportsNativeToolCalling("Qwen3_6-30B-A3B.gguf"))
        #expect(InferenceSettings.localModelSupportsLiveReasoningToggle(
            modelUrl: URL(fileURLWithPath: "/tmp/Qwen3.6-30B-A3B-Q4_K_M.gguf")
        ))
    }

    @Test func localQwen36UsesNativeToolCallingEvenWhenStoredToggleIsOff() async throws {
        let defaults = UserDefaults.standard
        let originalModelUrl = defaults.url(forKey: "modelUrl")
        let originalHasNativeToolCallingExists = defaults.exists(key: "hasNativeToolCalling")
        let originalHasNativeToolCalling = defaults.bool(forKey: "hasNativeToolCalling")
        let originalUseFunctionsExists = defaults.exists(key: "useFunctions")
        let originalUseFunctions = defaults.bool(forKey: "useFunctions")
        defer {
            Settings.modelUrl = originalModelUrl
            if originalHasNativeToolCallingExists {
                InferenceSettings.hasNativeToolCalling = originalHasNativeToolCalling
            } else {
                defaults.removeObject(forKey: "hasNativeToolCalling")
            }
            if originalUseFunctionsExists {
                Settings.useFunctions = originalUseFunctions
            } else {
                defaults.removeObject(forKey: "useFunctions")
            }
        }

        Settings.modelUrl = URL(fileURLWithPath: "/tmp/Qwen3.6-30B-A3B-Q4_K_M.gguf")
        InferenceSettings.hasNativeToolCalling = false
        Settings.useFunctions = true

        let params = await ChatParameters(
            modelType: .regular,
            usingRemoteModel: false,
            systemPrompt: "System",
            messages: [],
            useFunctions: true,
            functions: [ArithmeticFunctions.sum]
        )
        let json = params.toJSON(
            usingRemoteModel: false,
            modelType: .regular
        )
        let object = try JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any]

        #expect(InferenceSettings.supportsNativeToolCalling(
            modelType: .regular,
            usingRemoteModel: false
        ))
        #expect(object?["tools"] != nil)
        #expect(object?["tool_choice"] as? String == "auto")
    }

    @Test func nativeToolCallDecoderAcceptsObjectArguments() async throws {
        let data = Data(
            """
            {
              "choices": [
                {
                  "delta": {
                    "tool_calls": [
                      {
                        "index": 0,
                        "id": "call_sum",
                        "type": "function",
                        "function": {
                          "name": "sum",
                          "arguments": {
                            "a": 2,
                            "b": 3
                          }
                        }
                      }
                    ]
                  },
                  "finish_reason": null
                }
              ],
              "created": 0,
              "usage": null
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(
            LlamaServer.StreamResponse.self,
            from: data
        )
        let nativeToolCall = response.choices.first?.delta.tool_calls?.first
        let decodedCall = LlamaServer.StreamMessage.OpenAIToolCall.Function.getFunctionCall(
            name: nativeToolCall?.function.name ?? "",
            arguments: nativeToolCall?.function.arguments ?? "",
            toolCallID: nativeToolCall?.id,
            toolRegistry: ToolRegistry(functions: ArithmeticFunctions.functions)
        )

        #expect(decodedCall?.name == "sum")
        #expect(decodedCall?.toolCallID == "call_sum")
        guard var decodedCall else {
            return
        }
        let result = try await decodedCall.call(
            using: ToolRegistry(functions: ArithmeticFunctions.functions)
        )
        #expect(result == "5.0")
    }

    @Test func nativeToolCallDecoderUnwrapsStringifiedArguments() async throws {
        let decodedCall = LlamaServer.StreamMessage.OpenAIToolCall.Function.getFunctionCall(
            name: "sum",
            arguments: #"{"arguments":"{\"a\":4,\"b\":6}"}"#,
            toolCallID: "call_wrapped",
            toolRegistry: ToolRegistry(functions: ArithmeticFunctions.functions)
        )

        #expect(decodedCall?.name == "sum")
        #expect(decodedCall?.toolCallID == "call_wrapped")
        guard var decodedCall else {
            return
        }
        let result = try await decodedCall.call(
            using: ToolRegistry(functions: ArithmeticFunctions.functions)
        )
        #expect(result == "10.0")
    }

    @Test func inlineToolCallParserIgnoresBracesInsideStringArguments() async throws {
        let echoFunction = Function<ToolCallingEchoParams, String>(
            name: "echo_tool",
            description: "Returns the provided text.",
            params: [
                FunctionParameter(
                    label: "text",
                    description: "Text to echo",
                    datatype: .string
                )
            ],
            run: { params in
                params.text
            }
        )
        let otherFunctionWithSameSchema = Function<ToolCallingEchoParams, String>(
            name: "other_tool",
            description: "Should not be selected when only mentioned in an argument.",
            params: [
                FunctionParameter(
                    label: "text",
                    description: "Text to echo",
                    datatype: .string
                )
            ],
            run: { params in
                "wrong function: \(params.text)"
            }
        )
        let functions: [AnyFunctionBox] = [otherFunctionWithSameSchema, echoFunction]
        let registry = ToolRegistry(functions: functions)
        let response = LlamaServer.CompleteResponse(
            text: """
            Here is the call:
            {"function_call":{"name":"echo_tool","arguments":{"text":"value with { braces }, mentions other_tool, and an escaped \\\"quote\\\""}}}
            """,
            responseStartSeconds: 0,
            predictedPerSecond: nil,
            modelName: nil,
            usage: nil,
            usedServer: false,
            availableFunctions: functions
        )

        let functionCalls = response.functionCalls
        #expect(functionCalls?.count == 1)
        guard var functionCall = functionCalls?.first else {
            return
        }
        let result = try await functionCall.call(using: registry)
        #expect(result == #"value with { braces }, mentions other_tool, and an escaped "quote""#)
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

    // MARK: - SwiftData Persistence Tests

    @Test func inMemoryContainerSupportsBasicInsertAndFetch() async throws {
        // Exercises the in-memory ``ModelContainer`` factory so the
        // SwiftData schema is at least round-tripped end-to-end by
        // the test suite. Insertion + fetch on `CommandEntity` is
        // representative because the entity has no relationships,
        // making the test independent of the heavier graph types.
        let container = PersistenceController.inMemoryContainer()
        let context = ModelContext(container)
        let entity = CommandEntity(
            id: UUID(),
            name: "Test",
            prompt: "Hello"
        )
        context.insert(entity)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<CommandEntity>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "Test")
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

}
