//
//  Notifications.swift
//  Sidekick
//
//  Created by Bean John on 10/10/24.
//

import Foundation

public enum Notifications: String, NotificationName {
    
    case systemPromptChanged
    case changedInferenceConfig
    case didCommandSelectExpert
    case newConversation
    case switchToConversation
    case requestResubmit
    
}
