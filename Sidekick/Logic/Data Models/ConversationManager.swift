//
//  ConversationManager.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import Foundation
import FSKit_macOS
import os.log
import SwiftUI

@MainActor
public class ConversationManager: ObservableObject {
    
    /// A `Logger` object for the `ConversationManager` object
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: ConversationManager.self)
    )
    
    init() {
        let signpost = StartupMetrics.begin("ConversationManager.init")
        self.patchFileIntegrity()
        self.loadAsync()
        StartupMetrics.end("ConversationManager.init", signpost)
    }
    
    /// Static constant for the global `ConversationManager` object
    static public let shared: ConversationManager = .init()
    
    /// Published property for all conversations
    @Published public var conversations: [Conversation] = [] {
        didSet {
            self.save()
        }
    }
    
    /// Published state tracking whether the datastore has been loaded
    @Published private(set) var isLoaded: Bool = false
    
    /// Task handling the asynchronous datastore load
    private var loadTask: Task<Void, Never>?
    
    /// Computed property returning the IDs of all messages
    var allMessagesIds: [UUID] {
        return self.conversations.flatMap(\.messages).map(\.id)
    }
    
    /// Computed property returning the first conversation
    var firstConversation: Conversation? {
        guard self.isLoaded else { return nil }
        return self.conversations.first
    }
    
    /// Computed property returning the last conversation
    var lastConversation: Conversation? {
        guard self.isLoaded else { return nil }
        return self.conversations.last
    }
    
    /// Computed property returning the most recent conversation
    var recentConversation: Conversation? {
        guard self.isLoaded else { return nil }
        return self.conversations.sorted(
            by: \.createdAt
        ).last
    }
    
    /// A `Bool` representing whether a backup exists
    var backupExists: Bool {
        return self.backupDatastoreUrl.fileExists
    }
    
    /// Function to create a new conversation
    public func newConversation() {
        let defaultTitle: String = Date.now.formatted(
            date: .abbreviated,
            time: .shortened
        )
        let newConversation: Conversation = Conversation(
            title: defaultTitle,
            createdAt: .now,
            messages: []
        )
        self.conversations = [newConversation] + self.conversations
        NotificationCenter.default.post(
            name: Notifications.newConversation.name,
            object: nil
        )
        Self.logger.notice("Created a new conversation")
    }
    /// Function to save conversations to disk
    public func save() {
        do {
            // Save data
            let rawData: Data = try JSONEncoder().encode(
                self.conversations
            )
            try rawData.write(
                to: self.datastoreUrl,
                options: .atomic
            )
        } catch {
            os_log("error = %@", error.localizedDescription)
        }
    }
    
    /// Loads conversations off the main actor to avoid blocking startup
    private func loadAsync(
        fromBackup: Bool = false
    ) {
        if let loadTask = self.loadTask, !loadTask.isCancelled {
            return
        }
        let targetUrl: URL = fromBackup ? self.backupDatastoreUrl : self.datastoreUrl
        self.loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let signpost = StartupMetrics.begin("ConversationManager.loadDatastore")
            defer { StartupMetrics.end("ConversationManager.loadDatastore", signpost) }
            let conversations: [Conversation]
            do {
                let rawData: Data = try Data(contentsOf: targetUrl)
                let decoder: JSONDecoder = JSONDecoder()
                conversations = try decoder.decode([Conversation].self, from: rawData)
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.newDatastore()
                    self.isLoaded = true
                    self.loadTask = nil
                }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.conversations = conversations
                self.isLoaded = true
                self.loadTask = nil
            }
        }
    }
    
    /// Function returning a converation with the given ID
    public func getConversation(
        id conversationId: UUID
    ) -> Conversation? {
        return self.conversations.filter({ $0.id == conversationId }).first
    }
    
    /// Function to load conversations from disk
    public func load(
        fromBackup: Bool = false
    ) {
        let targetUrl: URL = fromBackup ? self.backupDatastoreUrl : self.datastoreUrl
        do {
            let rawData: Data = try Data(contentsOf: targetUrl)
            let decoder: JSONDecoder = JSONDecoder()
            let conversations: [Conversation] = try decoder.decode(
                [Conversation].self,
                from: rawData
            )
            self.conversations = conversations
            self.isLoaded = true
        } catch {
            print("Failed to load conversations: \(error)")
            self.newDatastore()
        }
    }
    
    /// Function to delete a conversation
    public func delete(_ conversation: Binding<Conversation>) {
        withAnimation(.spring()) {
            self.conversations = self.conversations.filter {
                $0.id != conversation.wrappedValue.id
            }
        }
    }
    
    /// Function to delete a conversation
    public func delete(_ conversation: Conversation) {
        withAnimation(.spring()) {
            self.conversations = self.conversations.filter {
                $0.id != conversation.id
            }
        }
    }
    
    /// Function to add a conversation
    public func add(_ conversation: Conversation) {
        withAnimation(.spring()) {
            self.conversations.append(conversation)
        }
    }
    
    /// Function to update a conversation
    public func update(_ conversation: Conversation) {
        for conversationIndex in self.conversations.indices {
            if conversation.id == self.conversations[conversationIndex].id {
                self.conversations[conversationIndex] = conversation
                return
            }
        }
    }
    
    /// Function to update a conversation
    public func update(_ conversation: Binding<Conversation>) {
        withAnimation(.spring()) {
            let targetId: UUID = conversation.wrappedValue.id
            for index in self.conversations.indices {
                if targetId == self.conversations[index].id {
                    self.conversations[index] = conversation.wrappedValue
                    break
                }
            }
        }
    }
    
    /// Function to make new datastore
    public func newDatastore() {
        // Setup directory
        self.patchFileIntegrity()
        // Add new datastore
        self.conversations = []
        self.isLoaded = true
        self.save()
    }
    
    /// Function to reset datastore
    public func resetDatastore() {
        // Present confirmation modal
        let _ = Dialogs.showConfirmation(
            title: String(localized: "Delete All Conversations"),
            message: String(localized: "Are you sure you want to delete all conversations?")
        ) {
            // If yes, delete datastore
            FileManager.removeItem(at: self.datastoreUrl)
            // Make new datastore
            self.newDatastore()
        }
    }
    
    /// Function to create backup for datastore
    public func createBackup() {
        // Delete if exists
        if self.backupDatastoreUrl.fileExists {
            FileManager.removeItem(at: self.backupDatastoreUrl)
        }
        // Make a copy
        FileManager.copyItem(
            from: self.datastoreUrl,
            to: self.backupDatastoreUrl
        )
    }
    
    /// Function to restore from backup
    public func retoreFromBackup() {
        // Present confirmation modal
        let _ = Dialogs.showConfirmation(
            title: String(localized: "Restore"),
            message: String(localized: "Are you sure you want to restore conversations from a backup? All current conversations will be deleted.")
        ) {
            // If yes, restore
            self.load(fromBackup: true)
            self.save()
        }
    }
    
    /// Function to patch file integrity
    public func patchFileIntegrity() {
        // Setup directory if needed
        if !self.datastoreDirExists {
            try! FileManager.default.createDirectory(
                at: datastoreDirUrl,
                withIntermediateDirectories: true
            )
        }
    }
    
    /// Computed property returning the datastore's directory's url
    public var datastoreDirUrl: URL {
        return Settings.containerUrl.appendingPathComponent(
            "Conversations"
        )
    }
    
    /// Computed property returning if datastore directory exists
    private var datastoreDirExists: Bool {
        return self.datastoreDirUrl.fileExists
    }
    
    /// Computed property returning the datastore's url
    public var datastoreUrl: URL {
        return self.datastoreDirUrl.appendingPathComponent(
            "conversations.json"
        )
    }
    
    /// Computed property returning the datastore's url
    public var backupDatastoreUrl: URL {
        return self.datastoreDirUrl.appendingPathComponent(
            "conversationsBackup.json"
        )
    }
    
    /// Computed property returning if datastore exists
    private var datastoreExists: Bool {
        return self.datastoreUrl.fileExists
    }
    
}
