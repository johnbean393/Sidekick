//
//  FunctionCallsView.swift
//  Sidekick
//
//  Created by John Bean on 4/9/25.
//

import Combine
import Shimmer
import SwiftUI

struct FunctionCallsView: View {
    
    var message: Message
    
    var functionCalls: [FunctionCallRecord] {
        return self.message.functionCallRecords ?? []
    }
    
    var body: some View {
        ForEach(
            functionCalls,
            id: \.self
        ) { call in
            FunctionCallView(functionCall: call)
        }
    }
    
    struct FunctionCallView: View {
        
        @State private var showDetails: Bool = false
        
        var functionCall: FunctionCallRecord
        
        var didExecute: Bool {
            functionCall.status?.didExecute ?? false
        }
        var boxColor: Color {
            functionCall.status?.color ?? .secondary
        }
        
        var body: some View {
            Button {
                if didExecute {
                    withAnimation(.linear) { showDetails.toggle() }
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
        }
        
        var label: some View {
            VStack(alignment: .leading, spacing: 0) {
                labelContent.frame(height: 33)
                if showDetails {
                    Divider()
                    details
                }
            }
            .background {
                Group {
                    if boxColor == .secondary {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(boxColor.opacity(0.8))
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(boxColor.opacity(0.2))
                    }
                }
            }
        }
        
        var labelContent: some View {
            HStack {
                Circle()
                    .frame(width: 10, height: 10)
                    .foregroundStyle(self.functionCall.status?.color ?? .gray)
                    .padding(.horizontal, 5)
                Group {
                    Text("Function: ").bold() + Text(self.functionCall.name).italic()
                }
                .opacity(0.8)
                .if(!self.didExecute) { view in
                    view.shimmering()
                }
                Spacer()
                if didExecute {
                    Image(systemName: "chevron.up")
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary.opacity(0.8))
                        .rotationEffect(showDetails ? .zero : .degrees(180))
                }
            }
            .padding(.horizontal, 7)
        }
        
        var details: some View {
            VStack(alignment: .leading) {
                if let result = functionCall.result {
                    Text("Result: ").bold() + Text(result).italic()
                }
            }
            .textSelection(.enabled)
            .opacity(0.9)
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
        }
        
    }
    
}
