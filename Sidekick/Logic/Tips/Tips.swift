//
//  Tips.swift
//  Sidekick
//
//  Created by Bean John on 10/23/24.
//

import Foundation
import TipKit

struct CreateExpertsTip: Tip {
	
	var title: Text {
		Text("Create an Expert")
	}
	
	var message: Text? {
		Text("Create experts that **customise** chatbot behaviour, making it **reply with context from your files**.")
	}
	
	var image: Image? {
		Image(systemName: "person.fill")
	}
	
	var actions: [Action] {
		[
			Action(
				id: "view",
				title: String(localized: "View Experts")
			)
		]
	}
	
	var options: [TipOption] {
		[
			Tip.IgnoresDisplayFrequency(true)
		]
	}
	
}

struct LengthyTasksProgressTip: Tip {
	
	// Track whether there is a lengthy task
	@Parameter
	static var hasLengthyTask: Bool = false
	
	var title: Text {
		Text("View Progress")
	}
	
	var message: Text? {
		Text("Check progress of lengthy tasks, like updating your expert with new resources.")
	}
	
	var rules: [Rule] {
		[
			#Rule(Self.$hasLengthyTask) {
				$0 == true
			}
		]
	}
	
}

struct AddFilesTip: Tip {
	
	// Track whether the user is ready for adding files
	@Parameter
	static var readyForAddingFiles: Bool = false
	
	var title: Text {
		Text("Add a File")
	}
	
	var message: Text? {
		Text("Give the chatbot temporary access to a file by dropping it here.")
	}
	
	var imageName: String {
		if #available(macOS 15, *) {
			return "document.fill"
		}
		return "doc.fill"
	}
	
	var image: Image? {
		Image(systemName: imageName)
	}
	
	var rules: [Rule] {
		[
			#Rule(Self.$readyForAddingFiles) {
				$0 == true
			}
		]
	}
	
}

struct ViewReferenceTip: Tip {
	
	// Track whether a reference was displayed
	@Parameter
	static var hasReference: Bool = false
	
	var title: Text {
		Text("View Reference")
	}
	
	var message: Text? {
		Text("Click to view a resource referenced in the chatbot's response.")
	}
	
	var rules: [Rule] {
		[
			#Rule(Self.$hasReference) {
				$0 == true
			}
		]
	}
	
	var actions: [Action] {
		[
			Action(
				id: "try",
				title: String(localized: "Open Reference")
			)
		]
	}
	
}

struct UseWebSearchTip: Tip {
	
	var title: Text {
		Text("Use Web Search")
	}
	
	var message: Text? {
		Text("Use web search to allow the chatbot to respond with up-to-date information.")
	}
	
	var image: Image? {
		Image(systemName: "magnifyingglass")
	}
	
}

struct UseFunctionsTip: Tip {
    
    var title: Text {
        Text("Use Functions")
    }
    
    var message: Text? {
        Text("Encourage models to use functions, which are evaluated to execute actions.")
    }
    
    var image: Image? {
        Image(systemName: "function")
    }
    
}

struct PopularEndpointsTip: Tip {
    
    var title: Text {
        Text("Popular Providers")
    }
    
    var message: Text? {
        Text("Use popular inference providers like OpenAI, Anthropic, or Groq.")
    }
    
    var image: Image? {
        Image(systemName: "cpu")
    }
    
}
