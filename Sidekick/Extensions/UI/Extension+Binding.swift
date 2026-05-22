//
//  Extension+Binding.swift
//  Sidekick
//
//  Created by Bean John on 10/11/24.
//

import Foundation
import SwiftUI
import OSLog

extension Binding where Value == TemporaryResource {
    
    /// Function to scan temporary resource
    func scan() async {
        let _ = await wrappedValue.scan()
    }
}


extension Binding where Value == Expert {
    
    /// Function to add a resource
    func addResource(_ resource: Resource) async {
        // Create mutable copy
        var expert = wrappedValue
        await MainActor.run {
            expert.resources.addResource(resource)
            self.wrappedValue = expert
            ExpertManager.update(expert)
        }
        
        // Write back the modified expert
        await MainActor.run {
            self.wrappedValue = expert
            ExpertManager.update(expert)
        }
    }
    
    /// Function to add multiple resources
    func addResources(_ resources: [Resource]) async {
        // Create mutable copy
        var expert = wrappedValue
        await MainActor.run {
            expert.resources.addResources(resources)
            self.wrappedValue = expert
            ExpertManager.update(expert)
        }
    }
    
    /// Function to remove a resource
    func removeResource(_ resource: Resource) async {
        // Create mutable copy
        var expert = wrappedValue
        
        await MainActor.run {
            expert.resources.removeResource(resource)
            self.wrappedValue = expert
            ExpertManager.update(expert)
        }
    }
    
    /// Function to update a resource index
    @MainActor
    func update() async {
        // Create mutable copy
        var expert = wrappedValue
        let expertId = expert.id
        
        // Update index with progress updates
        await expert.resources.updateResourcesIndex(
            expertName: expert.name,
            progressUpdate: { progress in
                updateExpertProgress(expertId: expertId, progress: progress)
            }
        )
        
        // Write back the modified expert
        await MainActor.run {
            self.wrappedValue = expert
            ExpertManager.update(expert)
        }
    }
    
    private func updateExpertProgress(expertId: UUID, progress: Resources.GraphProgress) {
        Task { @MainActor in
            guard var current = ExpertManager.getExpert(id: expertId) else {
                return
            }
            current.resources.graphStatus = .building
            current.resources.graphProgress = progress
            ExpertManager.update(current)
        }
    }
    
}
