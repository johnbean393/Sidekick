//
//  X86AssemblyRunner.swift
//  Sidekick
//
//  Created by John Bean on 11/17/25.
//

import Foundation

/// A class to compile and execute x86_64 assembly code
public class X86AssemblyRunner {
    
    /// Function to compile and execute x86_64 assembly code
    /// - Parameter code: The x86_64 assembly code to compile and execute
    /// - Returns: The output from executing the assembly program
    public static func executeX86Assembly(
        _ code: String
    ) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceFile = tempDir.appendingPathComponent("temp_asm_\(UUID().uuidString).s")
        let binaryFile = tempDir.appendingPathComponent("temp_asm_\(UUID().uuidString)")
        
        do {
            // Write assembly code to temporary file
            try code.write(to: sourceFile, atomically: true, encoding: .utf8)
            
            // Compile the assembly code for x86_64 architecture
            let compileProcess = Process()
            let compilePipe = Pipe()
            
            compileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gcc")
            compileProcess.arguments = ["-arch", "x86_64", sourceFile.path, "-o", binaryFile.path]
            compileProcess.standardOutput = compilePipe
            compileProcess.standardError = compilePipe
            
            try compileProcess.run()
            compileProcess.waitUntilExit()
            
            // Check if compilation was successful
            guard compileProcess.terminationStatus == 0 else {
                let errorData = compilePipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown compilation error"
                try? FileManager.default.removeItem(at: sourceFile)
                throw AssemblyError.compilationFailed(errorOutput)
            }
            
            // Execute the compiled binary
            let executeProcess = Process()
            let executePipe = Pipe()
            
            executeProcess.executableURL = binaryFile
            executeProcess.standardOutput = executePipe
            executeProcess.standardError = executePipe
            
            try executeProcess.run()
            executeProcess.waitUntilExit()
            
            // Get execution output
            let outputData = executePipe.fileHandleForReading.readDataToEndOfFile()
            var output = String(data: outputData, encoding: .utf8) ?? ""
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Clean up temporary files
            try? FileManager.default.removeItem(at: sourceFile)
            try? FileManager.default.removeItem(at: binaryFile)
            
            // Return output or success message
            if !output.isEmpty {
                return output
            } else {
                return "The assembly code was compiled and executed successfully, but did not produce any output."
            }
            
        } catch let error as AssemblyError {
            // Clean up on error
            try? FileManager.default.removeItem(at: sourceFile)
            try? FileManager.default.removeItem(at: binaryFile)
            throw error
        } catch {
            // Clean up on error
            try? FileManager.default.removeItem(at: sourceFile)
            try? FileManager.default.removeItem(at: binaryFile)
            throw AssemblyError.executionFailed(error.localizedDescription)
        }
    }
    
    /// Enum for possible errors during assembly execution
    public enum AssemblyError: LocalizedError {
        case compilationFailed(String)
        case executionFailed(String)
        
        public var errorDescription: String? {
            switch self {
                case .compilationFailed(let message):
                    return "Failed to compile assembly code: \(message)"
                case .executionFailed(let message):
                    return "Failed to execute assembly code: \(message)"
            }
        }
    }
    
    /// Helper function to check if x86_64 assembly compilation is supported
    public static func isX86AssemblySupported() -> Bool {
        // Check if gcc is available
        let gccCheck = Process()
        gccCheck.executableURL = URL(fileURLWithPath: "/bin/zsh")
        gccCheck.arguments = ["-c", "command -v gcc"]
        gccCheck.standardOutput = Pipe()
        gccCheck.standardError = Pipe()
        
        try? gccCheck.run()
        gccCheck.waitUntilExit()
        
        guard gccCheck.terminationStatus == 0 else {
            return false
        }
        
        // Check if gcc supports x86_64 architecture by attempting to compile a simple test
        let testAsm = """
        .globl _main
        _main:
            mov $8, %eax
            ret
        """
        
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_x86_\(UUID().uuidString).s")
        let testBinary = tempDir.appendingPathComponent("test_x86_\(UUID().uuidString)")
        
        defer {
            try? FileManager.default.removeItem(at: testFile)
            try? FileManager.default.removeItem(at: testBinary)
        }
        
        do {
            try testAsm.write(to: testFile, atomically: true, encoding: .utf8)
            
            let testProcess = Process()
            testProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gcc")
            testProcess.arguments = ["-arch", "x86_64", testFile.path, "-o", testBinary.path]
            testProcess.standardOutput = Pipe()
            testProcess.standardError = Pipe()
            
            try testProcess.run()
            testProcess.waitUntilExit()
            
            return testProcess.terminationStatus == 0
        } catch {
            return false
        }
    }
    
}
