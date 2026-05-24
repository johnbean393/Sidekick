//
//  Extension+URL.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import Foundation

public extension URL {
	
	/// A `Bool` representing iif the URL is a web URL
	var isWebURL: Bool {
		return self.absoluteString.hasPrefix("http://") ||
		self.absoluteString.hasPrefix("https://") ||
		self.absoluteString.hasPrefix("www")
	}
	
	/// Function to get all files one level deep
	func getContentsOneLevelDeep() -> [URL]? {
		// If no directory
		guard self.hasDirectoryPath else {
			return nil
		}
		// Enumerate directory
		var files = [URL]()
		if let enumerator = FileManager.default.enumerator(
			at: self,
			includingPropertiesForKeys: [],
			options: [
				.skipsHiddenFiles,
				.skipsSubdirectoryDescendants
			]
		) {
			for case let url as URL in enumerator {
				files.append(url)
			}
		}
		return files
	}
    
    /// Function to get all files in a directory
    func getContents(
        recursive: Bool = false
    ) -> [URL]? {
        // If no directory
        guard self.hasDirectoryPath else {
            return nil
        }
        // Setup options
        var options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles
        ]
        if !recursive {
            options.insert(.skipsSubdirectoryDescendants)
        }
        // Enumerate directory
        var files = [URL]()
        if let enumerator = FileManager.default.enumerator(
            at: self,
            includingPropertiesForKeys: [],
            options: options
        ) {
            for case let url as URL in enumerator {
                files.append(url)
            }
        }
        return files
    }
	
	/// Function to verify if url is reachable
	///
	/// Treats any 2xx/3xx HTTP response as reachable (HuggingFace's
	/// download endpoints commonly issue 302 redirects via `HEAD`).
	/// `completion` is guaranteed to be invoked exactly once even when
	/// the request fails or returns a non-HTTP response, which prevents
	/// callers (e.g. the model downloader) from hanging on unreachable
	/// hosts.
	static func verifyURL(
		url: URL,
		timeoutInterval: Double = 3,
		completion: @escaping (_ isValid: Bool) ->()
	) {
		var request = URLRequest(
			url: url,
			timeoutInterval: timeoutInterval
		)
		request.httpMethod = "HEAD"
		let task = URLSession.shared.dataTask(
			with: request
		) { _, response, error in
			if error != nil {
				completion(false)
				return
			}
			guard let httpResponse = response as? HTTPURLResponse else {
				completion(false)
				return
			}
			let isValid: Bool = (200..<400).contains(httpResponse.statusCode)
			completion(isValid)
		}
		task.resume()
	}
	
	/// Function to check if a url is reachable
	func isReachable() async -> Bool {
		do {
			// Create a URL session with a data task
			let (_, response) = try await URLSession.shared.data(from: self)
			// Check if the response is an HTTPURLResponse and has a status code in the 200-299 range
			if let httpResponse = response as? HTTPURLResponse,
				(200...299).contains(httpResponse.statusCode) {
				return true
			} else {
				print("Failed to get HTTP response")
				return false
			}
		} catch {
			print("Error checking URL reachability: \(error)")
			return false
		}
	}
	
	/// Function to check if an API endpoint is reachable
	func isAPIEndpointReachable(
		method: String = "GET",
		timeout: TimeInterval = 3.0
	) async -> Bool {
        // Formulate request
		var request = URLRequest(url: self)
		request.httpMethod = method
		request.timeoutInterval = timeout
        // Attach API Key
        request.setValue(
            "Bearer \(InferenceSettings.inferenceApiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession.shared
        session.configuration.timeoutIntervalForRequest = timeout
        session.configuration.timeoutIntervalForResource = timeout
        do {
			let (_, response) = try await URLSession.shared.data(for: request)
			guard let httpResponse = response as? HTTPURLResponse else {
				return false
			}
			return (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 400
		} catch {
			return false
		}
	}
	
	/// A  `String` without the schema (e.g., removes `https://` from `https://example.com`).
	var withoutSchema: String {
		guard let schemeEnd = self.absoluteString.range(of: "://")?.upperBound else {
			// If no schema is found, return the entire string
			return self.absoluteString
		}
		// Extract the substring starting after the "://"
		return String(self.absoluteString[schemeEnd...])
	}
    
    /// Function to fetch the `<title>` tag content from the URL's HTML.
    func fetchTitle(
        timeout: TimeInterval = 3.0
    ) async throws -> String? {
        // Return if not web url
        if !self.isWebURL {
            return nil
        }
        // Try fetching data with timeout
        do {
            let (data, _) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group -> (Data, URLResponse) in
                group.addTask { try await URLSession.shared.data(from: self) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            guard let htmlString = String(data: data, encoding: .utf8) else { return nil }
            // Find title
            let pattern = "<title>(.*?)</title>"
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let range = NSRange(location: 0, length: htmlString.utf16.count)
            if let match = regex?.firstMatch(in: htmlString, options: [], range: range),
               let titleRange = Range(match.range(at: 1), in: htmlString) {
                return String(htmlString[titleRange])
            }
            return nil
        } catch let error as URLError where error.code == .timedOut {
            return self.host(percentEncoded: false)
        } catch {
            throw error
        }
    }

}
