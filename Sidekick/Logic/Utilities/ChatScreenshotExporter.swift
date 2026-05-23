//
//  ChatScreenshotExporter.swift
//  Sidekick
//
//  Created by John Bean on 5/23/26.
//
//  Orchestrates the export pipeline: resolves the scope into a
//  message list, asks ``ChatScreenshotHTMLBuilder`` for the HTML
//  payload, spins up ``ChatScreenshotRenderer`` to produce either
//  an `NSImage` (PNG) or PDF `Data`, shows a cancellable progress
//  HUD, then writes the file to a destination picked through
//  `NSSavePanel`.
//

import AppKit
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ChatScreenshotExporter {
    
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Sidekick",
        category: "ChatScreenshotExporter"
    )
    
    /// Drives the full pipeline. Resolves messages, shows a HUD,
    /// renders, asks for a destination, and writes the file. Any
    /// thrown error surfaces as a `Dialogs.showAlert`; cancellation
    /// is silent.
    func capture(
        scope: ChatScreenshotScope,
        format: ChatScreenshotFormat = .png,
        conversation: Conversation,
        colorScheme: ColorScheme? = nil
    ) async {
        let messages = scope.resolve(in: conversation)
        guard !messages.isEmpty else {
            Dialogs.showAlert(
                title: String(localized: "Nothing to capture"),
                message: ChatScreenshotError.noMessages.errorDescription
            )
            return
        }
        
        let hudTitle = String(
            localized: "\(format.progressVerb) \(scope.displayName)…"
        )
        let hud = ProgressHUD(title: hudTitle, format: format)
        hud.show()
        defer { hud.hide() }
        
        let renderTask: Task<Data, Error> = Task { @MainActor in
            let output = try ChatScreenshotHTMLBuilder.build(
                conversation: conversation,
                messages: messages,
                scope: scope,
                colorScheme: colorScheme
            )
            let renderer = ChatScreenshotRenderer()
            switch format {
                case .png:
                    let image = try await renderer.renderImage(
                        templateURL: output.templateURL,
                        resourcesFolder: output.resourcesFolder,
                        payloadJSON: output.payloadJSON
                    )
                    return try Self.encodePNG(from: image)
                case .pdf:
                    return try await renderer.renderPDF(
                        templateURL: output.templateURL,
                        resourcesFolder: output.resourcesFolder,
                        payloadJSON: output.payloadJSON
                    )
            }
        }
        hud.onCancel = { renderTask.cancel() }
        
        let data: Data
        do {
            data = try await renderTask.value
        } catch is CancellationError {
            return
        } catch let error as ChatScreenshotError {
            if case .cancelled = error { return }
            Self.logger.error(
                "export failed: \(String(describing: error), privacy: .public)"
            )
            Dialogs.showAlert(
                title: Self.failureTitle(for: format),
                message: error.errorDescription
            )
            return
        } catch {
            Self.logger.error(
                "export failed: \(String(describing: error), privacy: .public)"
            )
            Dialogs.showAlert(
                title: Self.failureTitle(for: format),
                message: error.localizedDescription
            )
            return
        }
        
        // Hide the HUD before we put up the save panel — running
        // modal sheets on top of a child window looks broken.
        hud.hide()
        
        let defaultName: String = Self.defaultFilename(
            title: conversation.title,
            scope: scope,
            format: format
        )
        guard let destination = await Self.promptForSaveDestination(
            defaultName: defaultName,
            format: format
        ) else {
            return
        }
        
        do {
            try Self.write(data: data, to: destination)
            // Light follow-up: reveal in Finder so the user sees
            // where the file landed.
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch let error as ChatScreenshotError {
            Self.logger.error(
                "write failed: \(String(describing: error), privacy: .public)"
            )
            Dialogs.showAlert(
                title: Self.writeFailureTitle(for: format),
                message: error.errorDescription
            )
        } catch {
            Self.logger.error(
                "write failed: \(String(describing: error), privacy: .public)"
            )
            Dialogs.showAlert(
                title: Self.writeFailureTitle(for: format),
                message: error.localizedDescription
            )
        }
    }
    
    // MARK: - Failure copy
    
    private static func failureTitle(for format: ChatScreenshotFormat) -> String {
        switch format {
            case .png: return String(localized: "Screenshot Failed")
            case .pdf: return String(localized: "PDF Export Failed")
        }
    }
    
    private static func writeFailureTitle(for format: ChatScreenshotFormat) -> String {
        switch format {
            case .png: return String(localized: "Couldn't Save Screenshot")
            case .pdf: return String(localized: "Couldn't Save PDF")
        }
    }
    
    // MARK: - File naming
    
    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()
    
    static func defaultFilename(
        title: String,
        scope: ChatScreenshotScope,
        format: ChatScreenshotFormat,
        now: Date = .now
    ) -> String {
        let stamp: String = Self.filenameDateFormatter.string(from: now)
        let cleanTitle: String = Self.sanitizeFilename(title)
        let baseTitle: String = cleanTitle.isEmpty
            ? String(localized: "Chat")
            : cleanTitle
        return "\(baseTitle) - \(scope.displayName) - \(stamp).\(format.fileExtension)"
    }
    
    private static func sanitizeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = trimmed.components(separatedBy: illegal).joined(separator: " ")
        // Collapse runs of whitespace into single spaces — long
        // titles look much cleaner in Finder.
        let collapsed = safe
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Keep filenames reasonable (HFS limit is 255, but Finder
        // truncates display long before that).
        if collapsed.count > 80 {
            return String(collapsed.prefix(80))
        }
        return collapsed
    }
    
    // MARK: - Save panel
    
    private static func promptForSaveDestination(
        defaultName: String,
        format: ChatScreenshotFormat
    ) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let panel = NSSavePanel()
            switch format {
                case .png:
                    panel.title = String(localized: "Save Screenshot")
                case .pdf:
                    panel.title = String(localized: "Save PDF")
            }
            panel.prompt = String(localized: "Save")
            panel.nameFieldStringValue = defaultName
            panel.allowedContentTypes = [format.contentType]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            // PNGs default into ~/Pictures; PDFs into ~/Documents
            // unless the user has previously chosen another location
            // (NSSavePanel persists that on its own).
            let defaultDirectory: FileManager.SearchPathDirectory = (format == .pdf)
                ? .documentDirectory
                : .picturesDirectory
            if let dir = FileManager.default.urls(
                for: defaultDirectory,
                in: .userDomainMask
            ).first {
                panel.directoryURL = dir
            }
            let response = panel.runModal()
            if response == .OK, let url = panel.url {
                continuation.resume(returning: url)
            } else {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // MARK: - Write
    
    /// Encodes an `NSImage` into PNG `Data` so the rest of the
    /// pipeline can deal in a single `Data` type regardless of the
    /// chosen output format.
    private static func encodePNG(from image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(
                using: .png,
                properties: [.interlaced: false]
              ) else {
            throw ChatScreenshotError.writeFailed(
                NSError(
                    domain: "ChatScreenshotExporter",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG."]
                )
            )
        }
        return data
    }
    
    private static func write(data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ChatScreenshotError.writeFailed(error)
        }
    }
}

// MARK: - Progress HUD

/// Floating SwiftUI-styled HUD shown while the renderer runs.
/// Uses an `NSPanel` so it sits above the main window without
/// stealing focus, but the contents are SwiftUI so the visual
/// language matches the rest of the app.
@MainActor
private final class ProgressHUD {
    
    var onCancel: (() -> Void)?
    
    private let title: String
    private let format: ChatScreenshotFormat
    private var panel: NSPanel?
    
    init(title: String, format: ChatScreenshotFormat) {
        self.title = title
        self.format = format
    }
    
    func show() {
        guard self.panel == nil else { return }
        let contentSize = NSSize(width: 320, height: 132)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        
        let host = NSHostingView(
            rootView: ScreenshotProgressView(
                title: self.title,
                symbol: Self.symbol(for: self.format),
                onCancel: { [weak self] in self?.cancelTapped() }
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container
        
        // Centre over the focused window when one exists, otherwise
        // over the screen.
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            let parentFrame = parent.frame
            let origin = NSPoint(
                x: parentFrame.midX - contentSize.width / 2,
                y: parentFrame.midY - contentSize.height / 2
            )
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let frame = screen.frame
            let origin = NSPoint(
                x: frame.midX - contentSize.width / 2,
                y: frame.midY - contentSize.height / 2
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFront(nil)
        self.panel = panel
    }
    
    func hide() {
        if let panel = self.panel {
            panel.orderOut(nil)
        }
        self.panel = nil
    }
    
    private func cancelTapped() {
        self.onCancel?()
        self.hide()
    }
    
    private static func symbol(for format: ChatScreenshotFormat) -> String {
        switch format {
            case .png: return "camera.fill"
            case .pdf: return "doc.richtext.fill"
        }
    }
}

/// SwiftUI body for the HUD. Uses a translucent material so the
/// chat behind it stays visible and the visual matches macOS
/// system HUDs.
private struct ScreenshotProgressView: View {
    
    let title: String
    let symbol: String
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: self.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(self.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.regular)
                .tint(.accentColor)
            HStack {
                Spacer()
                Button(role: .cancel) {
                    self.onCancel()
                } label: {
                    Text("Cancel")
                        .frame(minWidth: 60)
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 6)
    }
}
