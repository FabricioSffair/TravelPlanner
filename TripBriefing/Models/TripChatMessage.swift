//
//  TripChatMessage.swift
//  TripBriefing
//
//  One message in the Chat tab.
//

import Foundation

struct TripChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user, assistant
        /// A line from the app, e.g. why a message could not be sent.
        case notice
    }

    let id = UUID()
    let role: Role
    /// Empty while the assistant's answer is still coming.
    var text: String
    /// `Your briefing › Weather` and `Wikivoyage › Lisbon › Get in` labels the searches returned.
    var sources: [String] = []
    /// The model that answered, e.g. "Apple Intelligence" or "Apple Intelligence → claude-sonnet-4-6".
    var model: String?
    var isError = false
}

extension Array where Element == TripChatMessage {
    /// The last few finished exchanges as `User:` / `Assistant:` lines, newest kept, capped so the
    /// on-device prompt stays small. Notices, errors and a pending reply are left out. Empty when
    /// there is nothing to carry over.
    func historyPrompt(maxMessages: Int = 6, maxCharacters: Int = 1500) -> String {
        var lines: [String] = []
        var used = 0
        for message in reversed() where !message.isError && !message.text.isEmpty {
            let line: String
            switch message.role {
            case .user: line = "User: \(message.text)"
            case .assistant: line = "Assistant: \(message.text)"
            case .notice: continue
            }
            guard lines.count < maxMessages, used + line.count <= maxCharacters else { break }
            lines.insert(line, at: 0)
            used += line.count
        }
        return lines.isEmpty ? "" : "RECENT CONVERSATION:\n" + lines.joined(separator: "\n")
    }
}
