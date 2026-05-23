//
//  MermaidRenderer.swift
//  Sidekick
//
//  Created by John Bean on 5/7/25.
//

import Foundation
import OSLog

public class MermaidRenderer: @unchecked Sendable {
    
    /// The mermaid child process to render the preview
    var mermaidRenderProcess: Process = Process()
    
    /// A file monitor to watch for changes in the preview
    private var fileMonitor: FileMonitor?
    
    /// The URL of the mermaid code file, of type `URL`
    public static var mermaidFileUrl: URL {
        let mermaidDirUrl: URL = Settings
            .cacheUrl
            .appendingPathComponent("MermaidRenderer")
        if !mermaidDirUrl.fileExists {
            FileManager.createDirectory(
                at: mermaidDirUrl,
                withIntermediateDirectories: true
            )
        }
        return mermaidDirUrl.appendingPathComponent(
            "newDiagram.mmd"
        )
    }
    
    /// The URL of the previewed file, of type `URL`
    public static var previewFileUrl: URL {
        let mermaidDirUrl: URL = Settings
            .cacheUrl
            .appendingPathComponent("MermaidRenderer")
        if !mermaidDirUrl.fileExists {
            FileManager.createDirectory(
                at: mermaidDirUrl,
                withIntermediateDirectories: true
            )
        }
        return mermaidDirUrl.appendingPathComponent(
            "newDiagram.svg"
        )
    }
    
    /// A `Logger` object for the `MermaidRenderer` object
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: MermaidRenderer.self)
    )
    
    /// Function to reset mermaid code
    public static func resetMermaidCode() {
        Self.saveMermaidCode(code: "")
    }
    
    /// Function to save the mermaid code
    public static func saveMermaidCode(
        code: String
    ) {
        // If config not prefixed, add
        var code: String = code
        let config: String = "%%{init: {\"flowchart\": { \"htmlLabels\": false}} }%%"
        if !code.hasPrefix(config) {
            code = config + "\n" + code
        }
        // Save mermaid text to file
        do {
            try code.write(
                to: Self.mermaidFileUrl,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            Self.logger.error("Error saving mermaid code: \(error, privacy: .public)")
        }
    }
    
    /// Function to render the preview from the mermaid code
    public func render(
        attemptsRemaining: Int = 3
    ) async throws {
        // Add flag for finished rendering
        var didFinishRendering: Bool = false
        // Start the mermaid child process
        self.mermaidRenderProcess = Process()
        self.mermaidRenderProcess.executableURL = Bundle.main.resourceURL?.appendingPathComponent("mermaid-cli")
        let arguments = [
            "-log",
            Self.mermaidFileUrl.posixPath
        ]
        self.mermaidRenderProcess.arguments = arguments
        self.mermaidRenderProcess.standardInput = FileHandle.nullDevice
        // Capture stdout and stderr
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        self.mermaidRenderProcess.standardOutput = outputPipe
        self.mermaidRenderProcess.standardError = errorPipe
        
        var renderError: String?
        
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Ensure we only resume the continuation once
                var didResume = false
                func resumeOnce(_ block: (CheckedContinuation<Void, Error>) -> Void) {
                    guard !didResume else { return }
                    didResume = true
                    block(continuation)
                }
                
                do {
                    // Setup monitor
                    self.fileMonitor = try? FileMonitor(
                        url: Self.previewFileUrl
                    ) {
                        didFinishRendering = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.fileMonitor = nil
                            errorPipe.fileHandleForReading.readabilityHandler = nil
                            if !Task.isCancelled {
                                resumeOnce { $0.resume() }
                            }
                        }
                    }
                    try self.mermaidRenderProcess.run()
                    // Read error output asynchronously
                    errorPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty,
                           let output = String(data: data, encoding: .utf8),
                           !output.isEmpty,
                           output.lowercased().contains("error:") || output.lowercased().contains("parse error") {
                            renderError = output
                            self.fileMonitor = nil
                            errorPipe.fileHandleForReading.readabilityHandler = nil
                            if !Task.isCancelled {
                                resumeOnce { $0.resume(throwing: RenderError.error(output)) }
                            }
                        }
                    }
                    // Timeout
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if !didFinishRendering, renderError == nil {
                            self.fileMonitor = nil
                            errorPipe.fileHandleForReading.readabilityHandler = nil
                            resumeOnce { $0.resume(throwing: RenderError.error(nil)) }
                        }
                    }
                } catch {
                    self.fileMonitor = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    resumeOnce { $0.resume(throwing: error) }
                }
            }
        }, onCancel: {
            // Only synchronous, non-throwing cleanup here
            self.fileMonitor = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
        })
    }
    
    private enum RenderError: LocalizedError {
        case error(String?)
        public var errorDescription: String? {
            switch self {
                case .error(let string):
                    if let string {
                        return string
                    } else {
                        return "An error occurred while rendering the diagram."
                    }
            }
        }
    }
    
}
