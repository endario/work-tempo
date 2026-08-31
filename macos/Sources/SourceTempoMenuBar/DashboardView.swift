import SourceTempoCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let onRefresh: () -> Void
    let onAdd: () -> Void
    let onRemove: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.top, 14)

            if model.selectedWorkspace == nil {
                emptyState
            } else {
                dashboard
            }

            Divider()
            footer
        }
        .frame(width: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SourceTempo")
                    .font(.headline)
                if model.workspaces.isEmpty {
                    Text("Work momentum")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Workspace", selection: Binding(
                        get: { model.selectedWorkspace },
                        set: { if let workspace = $0 { model.select(workspace) } }
                    )) {
                        ForEach(model.workspaces, id: \.root.path) { workspace in
                            Text(workspace.displayName).tag(Optional(workspace))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            Spacer()
            actionButton(
                model.snapshot.isRefreshing ? "xmark" : "arrow.clockwise",
                help: model.snapshot.isRefreshing ? "Cancel refresh" : "Refresh",
                action: onRefresh
            )
                .disabled(model.selectedWorkspace == nil)
            actionButton("plus", help: "Add workspace", action: onAdd)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)

    }

    private var dashboard: some View {
        VStack(spacing: 16) {
            if let message = model.snapshot.errorMessage {
                errorBanner(message)
            }
            PaceGauge(snapshot: model.snapshot)
            metricRow
            chartSection
            workspaceSection
        }
        .padding(18)
    }

    private var metricRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.snapshot.metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 { Divider().frame(height: 34) }
                VStack(spacing: 3) {
                    Text(metric.value)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text(metric.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(metric.id == "docs" ? .tertiary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("SOURCE LOC")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    legend("Code", color: .blue)
                    legend("Tests", color: .orange)
                }
            }
            if model.snapshot.trend.isEmpty {
                ContentUnavailableView("No trend yet", systemImage: "chart.xyaxis.line")
                    .frame(height: 150)
            } else {
                TrendChart(points: model.snapshot.trend)
            }
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("WORKSPACES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.workspaceRows) { row in
                Button { model.select(row.workspace) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: row.workspace == model.selectedWorkspace ? "circle.inset.filled" : "circle")
                            .foregroundStyle(row.workspace == model.selectedWorkspace ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.workspace.displayName)
                                .font(.callout.weight(.medium))
                            Text(row.workspace.root.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(row.sourceValue)
                                .font(.callout.monospacedDigit())
                            Text("\(row.churnValue) / 30d")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No workspace", systemImage: "folder.badge.plus")
        } actions: {
            Button("Add Git Workspace", action: onAdd)
        }
        .frame(minHeight: 300)
        .padding(18)
    }

    private var footer: some View {
        HStack {
            Button("Remove", systemImage: "minus.circle", action: onRemove)
                .disabled(model.selectedWorkspace == nil)
            Spacer()
            Button("Quit SourceTempo", action: onQuit)
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func legend(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(9)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
