//
//  MessageViewHelpers.swift
//  Sidekick
//
//  SwiftUI view helpers that previously lived directly on
//  ``Message``. Extracted to keep the data model pure (no SwiftUI
//  in stored types) ahead of the SwiftData migration.
//

import AppKit
import Foundation
import SwiftUI

extension Message {

    /// A view that displays the message's generated image, if any.
    public var image: some View {
        Group {
            if let url = imageUrl {
                AsyncImage(
                    url: url,
                    content: { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: 350,
                                maxHeight: 350
                            )
                            .clipShape(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 0,
                                    bottomLeadingRadius: 13,
                                    bottomTrailingRadius: 13,
                                    topTrailingRadius: 13
                                )
                            )
                            .draggable(
                                Image(
                                    nsImage: NSImage(
                                        contentsOf: url
                                    )!
                                )
                            )
                            .onTapGesture(count: 2) {
                                NSWorkspace.shared.open(url)
                            }
                            .contextMenu {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Text("Open")
                                }
                            }
                    },
                    placeholder: {
                        ProgressView()
                            .padding(11)
                    }
                )
            } else {
                EmptyView()
            }
        }
    }

    /// A view that displays the message sender's icon — the expert's
    /// avatar when an expert is attached, otherwise the sender role
    /// icon.
    @MainActor
    var icon: some View {
        Group {
            if let expertId = self.expertId,
               let expert = ExpertManager.getExpert(id: expertId)
            {
                expert.icon
            } else {
                getSender().icon
            }
        }
    }
}
