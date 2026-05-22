//
//  ExpertViewHelpers.swift
//  Sidekick
//
//  SwiftUI view helpers that previously lived directly on
//  ``Expert``. Extracted to keep the data model pure (no SwiftUI
//  in stored types) ahead of the SwiftData migration.
//

import Foundation
import SwiftUI

extension Expert {

    /// Circular avatar containing the expert's symbol on its color
    /// fill. Used throughout the chat sidebar and message list.
    public var icon: some View {
        ZStack {
            Circle()
                .fill(self.color)
                .frame(width: 25)
            Image(systemName: self.symbolName)
                .foregroundStyle(self.color.adaptedTextColor)
                .font(.system(size: 14))
                .shadow(
                    color: .secondary.opacity(0.3),
                    radius: 2, x: 0, y: 0.5
                )
        }
        .clipShape(Circle())
    }

    /// Larger pill-shaped label combining the expert's symbol and
    /// name. Used in toolbars and selection menus.
    public var label: some View {
        Label(self.name, systemImage: symbolName)
            .labelStyle(.titleAndIcon)
            .bold()
            .padding(7)
            .padding(.horizontal, 2)
            .foregroundStyle(
                self.color.adaptedTextColor
            )
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.color)
            }
    }
}
