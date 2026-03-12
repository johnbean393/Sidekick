//
//  CodeFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/14/25.
//

import Foundation

public class CodeFunctions {
    
    static var functions: [AnyFunctionBox] = {
        var baseFunctions: [AnyFunctionBox] = [
            CodeFunctions.runJavaScript,
            CodeFunctions.runCommand
        ]
        // Add runPython if Python is installed
        if PythonRunner.isPythonInstalled() {
            baseFunctions.append(CodeFunctions.runPython)
        }
        // Add runX86Assembly if x86_64 assembly is supported
        if X86AssemblyRunner.isX86AssemblySupported() {
            baseFunctions.append(CodeFunctions.runX86Assembly)
        }
        return baseFunctions
    }()
    
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
    
    /// A ``Function`` for running Python
    static let runPython = Function<RunPythonParams, String>(
        name: "run_python",
        description: "Runs Python code and returns the result. Useful for performing calculations with many steps or performing transformations on data.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "code",
                description: "The Python code to run",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            return try PythonRunner.executePython(params.code)
        }
    )
    
    struct RunPythonParams: FunctionParams {
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
    
    /// A function to run x86_64 assembly code
    static let runX86Assembly = Function<RunX86AssemblyParams, String>(
        name: "run_x86_assembly",
        description: "Compiles and executes x86_64 assembly code using Rosetta 2 on Apple Silicon Macs. The assembly code should use AT&T syntax and include a _main entry point.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "code",
                description: "The x86_64 assembly code to compile and execute. Should use AT&T syntax with .globl _main and _main: label.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            return try X86AssemblyRunner.executeX86Assembly(params.code)
        }
    )
    
    struct RunX86AssemblyParams: FunctionParams {
        let code: String
    }
    
}
