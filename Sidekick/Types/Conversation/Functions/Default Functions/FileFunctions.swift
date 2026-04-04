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
        FileFunctions.extractFileText,
        FileFunctions.writePlaintextToFile,
        FileFunctions.deleteFile
    ]
    
    /// A function to list files in a directory
    static let listDirectory = Function<ListDirectoryParams, [String]>(
        name: "list_directory",
        description: "Lists the files in a directory, non-recursively.\n\nThe user's home directory is `\(URL.homeDirectory.posixPath)`, their downloads directory is \(URL.downloadsDirectory.posixPath), and their desktop directory is \(URL.desktopDirectory.posixPath)",
        allowsParallelExecution: true,
        params: [
            FunctionParameter(
                label: "posixPath",
                description: "The POSIX path of the directory.",
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
        description: "Extracts and outputs the contents of a file. Supports plain text, images, PDFs, Word documents, PowerPoints, Excel spreadsheets, and more file formats. OCR is used for images.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "posixPath",
                description: "The POSIX path of the file.",
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
    
    /// A function to write to a text file
    static let writePlaintextToFile = Function<WritePlaintextToFileParams, String>(
        name: "write_plaintext_to_file",
        description: "Writes the provided text to a file at the specified POSIX path.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "text",
                description: "The text to write to the file.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "posixPath",
                description: "The POSIX path of the file.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            // Check URL
            let url: URL = URL(filePath: params.posixPath)
            // Write text
            try params.text.write(to: url, atomically: true, encoding: .utf8)
            return "The text was written successfully to the file at \(params.posixPath)."
            enum WriteToTxtFileError: LocalizedError {
                case invalidPath
                var errorDescription: String? {
                    switch self {
                        case .invalidPath:
                            return "The provided POSIX path is not valid."
                    }
                }
            }
        }
    )
    struct WritePlaintextToFileParams: FunctionParams {
        var text: String
        var posixPath: String
    }
    
    /// A function to delete a file
    static let deleteFile = Function<DeleteFileParams, String>(
        name: "delete_file",
        description: "Deletes the file or directory at the specified POSIX path. Directories are deleted recursively.",
        clearance: .dangerous,
        params: [
            FunctionParameter(
                label: "posixPath",
                description: "The POSIX path of the file.",
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
            // Delete the file
            FileManager.removeItem(at: url)
            return "The file at `\(params.posixPath)` was deleted successfully."
            enum ExtractFileTextError: LocalizedError {
                
                case invalidPath
                case pathNotFound
                
                var errorDescription: String? {
                    switch self {
                        case .invalidPath:
                            return "The provided POSIX path is not valid."
                        case .pathNotFound:
                            return "The file does not exist at the specified path."
                    }
                }
            }
        }
    )
    struct DeleteFileParams: FunctionParams {
        var posixPath: String
    }
    
}
