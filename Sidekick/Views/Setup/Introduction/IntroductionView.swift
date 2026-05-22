//
//  IntroductionView.swift
//  Sidekick
//
//  Created by Bean John on 9/23/24.
//

import SwiftUI
import Combine

struct IntroductionView: View {
    
    @Environment(ConversationState.self) private var conversationState
    
    @StateObject private var introductionViewController: IntroductionViewController = .init()
    
    @Binding var showSetup: Bool
    
    var body: some View {
        Group {
            switch introductionViewController.page {
                case .done:
                    SetupCompleteView(
                        description: String(localized: "Sidekick is ready to use.")
                    ) {
                        Settings.finishSetup()
                        self.showSetup = false
                    }
                    .frame(maxHeight: 400)
                    .padding(.horizontal)
                default:
                    page
            }
        }
        .frame(maxHeight: 600)
        .environmentObject(introductionViewController)
    }
    
    var page: some View {
        VStack {
            HStack {
                introductionViewController.prevPage
                VStack {
                    IntroductionPageView(
                        content: introductionViewController.page.content!
                    )
                    .padding()
                    // Progress indicator
                    if introductionViewController.page.hasNext {
                        introductionViewController.progress
                    }
                }
                introductionViewController.nextPage
            }
            .padding(.horizontal)
            Divider()
            HStack {
                Spacer()
                Button {
                    Settings.finishSetup()
                    self.showSetup = false
                } label: {
                    Text("Skip")
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal)
            .padding(.top, 3)
            .padding(.bottom)
        }
    }

}
