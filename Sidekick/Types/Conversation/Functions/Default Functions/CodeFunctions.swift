//
//  CodeFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/14/25.
//

import Foundation

public class CodeFunctions {
    
    static var functions: [AnyFunctionBox] = [
        CodeFunctions.runJavaScript,
        CodeFunctions.runCommand
    ]
    
    /// A ``Function`` for running JavaScript
    static let runJavaScript = Function<RunJavaScriptParams, String>(
        name: "run_javascript",
        description: "Runs JavaScript code and returns the result. Useful for performing calculations with many steps or performing transformations on data.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "code",
                description: "The JavaScript code to run",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            return try JavaScriptRunner.executeJavaScript(params.code)
        }
    )
    struct RunJavaScriptParams: FunctionParams {
        let code: String
    }
    
    /// A function to run a terminal command
    static let runCommand = Function<RunCommandParams, String>(
        name: "run_command",
        description: "Executes the specified command in the macOS Terminal and returns the output.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "command",
                description: "The shell command to execute.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "workingDirectory",
                description: "The POSIX path of the working directory for command execution. Defaults to home directory `\(URL.homeDirectory.posixPath)` if not specified.",
                datatype: .string,
                isRequired: false
            )
        ],
        run: { params in
            // Check if Homebrew is installed
            var command: String = params.command
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") {
                // If yes, add it to the PATH
                let homebrewPath = "/opt/homebrew/bin"
                command = "export PATH=\"\(homebrewPath):$PATH\"; \(command)"
            }
            // Setup process and pipe
            let process = Process()
            let pipe = Pipe()
            // Configure the process
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            // Set working directory if provided
            if let workingDir = params.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
            } else {
                process.currentDirectoryURL = URL.homeDirectory
            }
            // Setup output pipe
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                // Get command output
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard var output = String(data: data, encoding: .utf8) else {
                    throw CommandError.outputEncodingFailed
                }
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                // If not blank
                if !output.isEmpty {
                    return output
                } else {
                    return "The command was executed successfully, but did not produce any output."
                }
            } catch {
                throw CommandError.executionFailed(error.localizedDescription)
            }
            enum CommandError: LocalizedError {
                case executionFailed(String)
                case outputEncodingFailed
                var errorDescription: String? {
                    switch self {
                        case .executionFailed(let message):
                            return "Failed to execute command: \(message)"
                        case .outputEncodingFailed:
                            return "Failed to encode command output"
                    }
                }
            }
        }
    )
    struct RunCommandParams: FunctionParams {
        var command: String
        var workingDirectory: String?
    }
    
}
