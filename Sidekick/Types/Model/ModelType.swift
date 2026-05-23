//
//  ModelType.swift
//  Sidekick
//
//  Created by John Bean on 3/18/25.
//

import Foundation

public enum ModelType: String, CaseIterable {
	
	case regular // A model used for most tasks, including chat
	case worker // A lightweight model used for most simple tasks to lower costs and raise speed
	
}
