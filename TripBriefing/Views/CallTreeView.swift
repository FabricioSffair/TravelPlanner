//
//  CallTreeView.swift
//  TripBriefing
//
//  The call tree, drawn by the app instead of RailtracksSwiftUI's
//  RTSNodeTreeView so each row can also say what ran: an Agent, Tool or
//  Workflow tag, and for agents the model behind them. It reads the same
//  RTSNodeTreeViewModel rows, so collapse, run dividers and live state work
//  as before.
//

import SwiftUI
import RailtracksSwift
import RailtracksSwiftUI

struct CallTreeView: View {
    let viewModel: RTSNodeTreeViewModel
    /// Model label per agent name, e.g. "Concierge" → "Apple Intelligence". Agents missing from
    /// it show no model.
    var agentModels: [String: String] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.rows) { row in
                    if row.startsNewRun {
                        Divider().padding(.vertical, .spacingMD)
                    }
                    CallTreeRow(
                        row: row,
                        model: row.item.nodeType == .agent ? agentModels[row.item.name] : nil
                    ) {
                        viewModel.toggleCollapse(row.id)
                    }
                }
            }
            .padding(.spacingXL)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
            if viewModel.rows.isEmpty {
                Text("Agents and tools appear here as they run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension RTSLLMProvider {
    /// What the call tree shows for an agent's model.
    var callTreeLabel: String {
        switch self {
        case .appleAI: "Apple Intelligence"
        case .anthropic(let model): model
        case .gemini(let model, _): model
        case .openAI(let model): model
        default: description
        }
    }
}

private struct CallTreeRow: View {
    let row: RTSNodeTreeRow
    let model: String?
    let onToggleCollapse: () -> Void

    /// Width of one level. The status circle sits in a column of the same width, so a child's
    /// elbow lands on its parent's circle.
    static let indent: CGFloat = 24
    static let rowHeight: CGFloat = 28
    static let lineWidth: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            connectors
            StatusCircle(state: row.item.state, showsChildStem: row.hasChildren && !row.isCollapsed)
            // The name wins the space; the model is the first thing to truncate.
            Text(row.item.name)
                .font(.callout.weight(row.item.nodeType == .tool ? .regular : .medium))
                .lineLimit(1)
                .layoutPriority(2)
                .padding(.leading, .spacingSM)
            TypeTag(nodeType: row.item.nodeType)
                .fixedSize()
                .layoutPriority(1)
                .padding(.leading, .spacingSM)
            if let model {
                HStack(spacing: 2) {
                    Image(systemName: model == "Apple Intelligence" ? "sparkles" : "cloud")
                    Text(model).lineLimit(1).truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, .spacingSM)
            }
            if row.hasChildren {
                Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, .spacingSM)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.hasChildren { onToggleCollapse() }
        }
        .accessibilityElement(children: .combine)
    }

    /// Lines passing through toward an ancestor's later sibling, plus this row's own elbow.
    private var connectors: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(row.ancestorLines.enumerated()), id: \.offset) { level, destination in
                if let destination {
                    Rectangle()
                        .fill(destination.callTreeTint.opacity(0.5))
                        .frame(width: Self.lineWidth, height: Self.rowHeight)
                        .offset(x: CGFloat(level) * Self.indent + (Self.indent - Self.lineWidth) / 2)
                }
            }
            Elbow(depth: row.depth, isLastSibling: row.isLastSibling, indent: Self.indent)
                .stroke(row.item.state.callTreeTint.opacity(0.5), lineWidth: Self.lineWidth)
        }
        .frame(width: CGFloat(row.depth) * Self.indent, height: Self.rowHeight)
    }
}

/// "Agent", "Tool" or "Workflow", with the node type's glyph.
private struct TypeTag: View {
    let nodeType: RTSFlowNodeType

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(title)
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, .spacingSM)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var title: String {
        switch nodeType {
        case .agent: "Agent"
        case .tool: "Tool"
        case .function: "Workflow"
        }
    }

    private var symbol: String {
        switch nodeType {
        case .agent: "brain"
        case .tool: "wrench.and.screwdriver"
        case .function: "point.3.connected.trianglepath.dotted"
        }
    }

    private var color: Color {
        switch nodeType {
        case .agent: .purple
        case .tool: .orange
        case .function: .teal
        }
    }
}

private struct StatusCircle: View {
    let state: RTSNodeStatus.State
    let showsChildStem: Bool

    var body: some View {
        ZStack {
            if showsChildStem {
                Path { path in
                    path.move(to: CGPoint(x: CallTreeRow.indent / 2, y: CallTreeRow.rowHeight / 2))
                    path.addLine(to: CGPoint(x: CallTreeRow.indent / 2, y: CallTreeRow.rowHeight))
                }
                .stroke(state.callTreeTint.opacity(0.5), lineWidth: CallTreeRow.lineWidth)
            }
            Circle()
                .fill(state.callTreeTint)
                .frame(width: 14, height: 14)
            if case .executing = state {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: CallTreeRow.indent, height: CallTreeRow.rowHeight)
    }
}

/// The trunk down from the parent's circle and the arm across to this row's circle.
private struct Elbow: Shape {
    let depth: Int
    let isLastSibling: Bool
    let indent: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard depth > 0 else { return path }
        let trunkX = CGFloat(depth - 1) * indent + indent / 2
        path.move(to: CGPoint(x: trunkX, y: rect.minY))
        path.addLine(to: CGPoint(x: trunkX, y: isLastSibling ? rect.midY : rect.maxY))
        path.move(to: CGPoint(x: trunkX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX + indent / 2, y: rect.midY))
        return path
    }
}

private extension RTSNodeStatus.State {
    var callTreeTint: Color {
        switch self {
        case .queued: .secondary.opacity(0.4)
        case .executing: .blue
        case .completed: .green
        case .failed: .red
        }
    }
}
