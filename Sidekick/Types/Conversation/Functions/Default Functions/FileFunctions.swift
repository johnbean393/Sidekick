//
//  FileFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/14/25.
//

import ExtractKit_macOS
import Foundation
import FSKit_macOS

public class FileFunctions {
    
    static var functions: [AnyFunctionBox] = [
        FileFunctions.listDirectory,
        FileFunctions.extractFileText
    ]
    
    /// A function to list files in a directory
    static let listDirectory = Function<ListDirectoryParams, [String]>(
        name: "list_directory",
        description: "Lists files in a directory (non-recursive).",
        allowsParallelExecution: true,
        params: [
            FunctionParameter(
                label: "posixPath",
                description: "POSIX path of the directory.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            // Check URL
            let url: URL = URL(filePath: params.posixPath)
            if !url.fileExists {
                throw ListDirectoryError.pathNotFound
            }
            if !url.hasDirectoryPath {
                throw ListDirectoryError.notDirectory
            }
            // Fetch items
            let urls: [URL] = url.getContents(recursive: false) ?? []
            let paths: [String] = urls.map { url in
                return url.posixPath
            }
            return paths
            enum ListDirectoryError: LocalizedError {
                case invalidPath
                case pathNotFound
                case notDirectory
                var errorDescription: String? {
                    switch self {
                        case .invalidPath:
                            return "The provided POSIX path is not valid."
                        case .pathNotFound:
                            return "The specified path does not exist."
                        case .notDirectory:
                            return "The specified path is not a directory."
                    }
                }
            }
        }
    )
    struct ListDirectoryParams: FunctionParams {
        var posixPath: String
    }
    
    /// A function to extract the text from a file
    static let extractFileText = Function<ExtractFileTextParams, String>(
        name: "extract_file_text",
        description: "Extracts text from a file. Supports plain text, images (OCR), PDF, Word, PowerPoint, Excel, and more.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "posixPath",
                description: "POSIX path of the file.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            // Check URL
            let url: URL = URL(filePath: params.posixPath)
            if !url.fileExists {
                throw ExtractFileTextError.pathNotFound
            }
            if !url.isFileURL {
                throw ExtractFileTextError.notFile
            }
            // Extract text
            let text = try await ExtractKit.shared.extractText(
                url: url,
                speed: ExtractionSpeed.default
            )
            return text
            enum ExtractFileTextError: LocalizedError {
                case invalidPath
                case pathNotFound
                case notFile
                var errorDescription: String? {
                    switch self {
                        case .invalidPath:
                            return "The provided POSIX path is not valid."
                        case .pathNotFound:
                            return "The file does not exist at the specified path."
                        case .notFile:
                            return "The specified path is not a file."
                    }
                }
            }
        }
    )
    struct ExtractFileTextParams: FunctionParams {
        var posixPath: String
    }
    
}
