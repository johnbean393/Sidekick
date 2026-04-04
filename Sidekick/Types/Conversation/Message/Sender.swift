//
//  User.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import Foundation
import SwiftUI

public enum Sender: String, Codable {
		
	case user = "user"
	case assistant = "assistant"
	case system = "system"
    case tool = "tool"
		
	/// A `View` for the sender's icon
	var icon: some View {
			ZStack {
				Circle()
					.fill(self == .user ? Color.purple : Color.green)
					.frame(width: 25)
				Image(systemName: self == .user ? "person.fill" : (self == .tool ? "wrench.and.screwdriver.fill" : "cpu.fill"))
					.foregroundStyle(Color.white)
					.font(.system(size: 14))
					.shadow(
					color: .secondary.opacity(0.3),
					radius: 2, x: 0, y: 0.5
				)
		}
	}
	
}
