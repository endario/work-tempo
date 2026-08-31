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

            if model.workspaces.isEmpty {
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
            // Measured at 2x: mixed text sizes need a one-point optical lift against SF Symbols.
            Text("Source Tempo")
                .font(.system(size: 15, weight: .semibold))
                .fixedSize()
                .frame(height: 24)
                .offset(y: -1)
            if !model.workspaces.isEmpty {
                workspaceMenu
            }
            Spacer()
            HStack(alignment: .center, spacing: 6) {
                if !model.workspaces.isEmpty {
                    Text(lastUpdatedLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.snapshot.dataState == .stale ? Color.orange : Color.secondary)
                        .fixedSize()
                        .frame(height: 24)
                        .offset(y: -1)
                }
                actionButton(
                    model.snapshot.isRefreshing ? "xmark" : "arrow.clockwise",
                    help: model.snapshot.isRefreshing ? "Cancel refresh" : "Refresh",
                    action: onRefresh
                )
                    .disabled(model.workspaces.isEmpty)
            }
            actionButton("plus", help: "Add workspace", action: onAdd)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 2)

    }

    private var workspaceMenu: some View {
        Menu {
            Button {
                model.selectAll()
            } label: {
                Label("All Workspaces", systemImage: model.scope == .all ? "checkmark" : "square.stack.3d.up")
            }
            Divider()
            ForEach(model.workspaces, id: \.root.path) { workspace in
                Button {
                    model.select(workspace)
                } label: {
                    Label(
                        workspace.displayName,
                        systemImage: model.selectedWorkspace == workspace ? "checkmark" : "folder"
                    )
                }
            }
        } label: {
            Text(model.scope == .all ? "All" : model.selectedWorkspace?.displayName ?? "Workspace")
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(height: 24)
        .help("Choose workspace")
    }

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let message = model.snapshot.errorMessage {
                    errorBanner(message)
                }
                if let message = model.snapshot.noticeMessage {
                    statusBanner(message, symbol: "info.circle.fill")
                }
                if let progress = model.refreshProgress {
                    statusBanner(progress, symbol: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                MomentumHero(snapshot: model.snapshot)
                metricRow
                chartSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(height: 445)
    }

    private var metricRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.snapshot.metrics.enumerated()), id: \.element.id) { index, metric in
                if index == 1 {
                    // Source is the total; code, tests, and docs are its constituent metrics.
                    Rectangle()
                        .fill(Color.secondary.opacity(0.24))
                        .frame(width: 1.5, height: 40)
                } else if index > 1 {
                    Divider().frame(height: 34)
                }
                VStack(spacing: 3) {
                    Text(metric.value)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(metricColor(metric.id))
                    Text(metric.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(metricColor(metric.id))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let chart = model.snapshot.chartTimeline {
                VStack(alignment: .leading, spacing: 4) {
                    chartTitle("CUMULATIVE CHURN")
                    CumulativeChurnChart(timeline: chart)
                }
                VStack(alignment: .leading, spacing: 4) {
                    chartTitle("MONTHLY CHURN")
                    MonthlyChurnChart(timeline: chart)
                    changeLegend
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                ContentUnavailableView(
                    model.snapshot.historyMessage ?? "No trend yet",
                    systemImage: "chart.xyaxis.line"
                )
                .frame(height: 180)
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
            Button("Quit Source Tempo", action: onQuit)
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
                .font(.system(size: 14, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .help(help)
    }

    private var changeLegend: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            legend("Code +", swatch: TempoPalette.codeAdded, text: TempoPalette.code)
            legend("Tests +", swatch: TempoPalette.testAdded, text: TempoPalette.tests)
            legend("Code -", swatch: TempoPalette.codeDeleted, text: TempoPalette.code)
            legend("Tests -", swatch: TempoPalette.testDeleted, text: TempoPalette.tests)
            legend("Docs +", swatch: TempoPalette.docsAdded, text: TempoPalette.docs)
            legend("Docs -", swatch: TempoPalette.docsDeleted, text: TempoPalette.docs)
        }
    }

    private func legend(_ label: String, swatch: Color, text: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(swatch).frame(width: 6, height: 6)
            Text(label).foregroundStyle(text)
        }
        .font(.caption2)
    }

    private func metricColor(_ id: String) -> Color {
        switch id {
        case "code": TempoPalette.code
        case "tests": TempoPalette.tests
        case "docs": TempoPalette.docs
        default: TempoPalette.source
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer()
        }
        .padding(9)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func statusBanner(_ message: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
            Spacer()
        }
        .padding(9)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func chartTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var lastUpdatedLabel: String {
        if model.snapshot.isRefreshing { return "Refreshing" }
        guard let date = model.snapshot.reportGeneratedAt else { return "No report" }
        return "Updated \(date.formatted(date: .omitted, time: .shortened))"
    }
}
