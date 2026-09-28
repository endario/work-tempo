import AppKit
import WorkTempoCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var dashboardContentHeight: CGFloat = 445
    let onRefresh: () -> Void
    let onAdd: () -> Void
    let onRemove: () -> Void
    let onQuit: () -> Void
    @Environment(\.openSettings) private var openSettings

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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Work Tempo")
                .font(.system(size: 15, weight: .semibold))
                .fixedSize()
            if !model.workspaces.isEmpty {
                // The chevron-backed menu's synthetic baseline leaves its label high;
                // measured against the 15-point title and 14-point scope at 2x.
                workspaceMenu.offset(y: 2)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !model.workspaces.isEmpty {
                    Text(lastUpdatedLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.snapshot.dataState == .stale ? Color.orange : Color.secondary)
                        .fixedSize()
                }
                actionButton(
                    model.snapshot.isRefreshing ? "xmark" : "arrow.clockwise",
                    help: model.snapshot.isRefreshing ? "Cancel refresh" : "Refresh",
                    action: onRefresh
                )
                    .disabled(model.workspaces.isEmpty)
            }
            actionButton("gearshape", help: "Settings", action: openSettingsWindow)
            actionButton("plus", help: "Add workspace", action: onAdd)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 2)

    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
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
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: model.scope == .all, vertical: false)
        .frame(maxWidth: model.scope == .all ? nil : 105, alignment: .leading)
        .frame(height: 24)
        .layoutPriority(-1)
        .help(model.scope == .all ? "Choose workspace" : model.selectedWorkspace?.displayName ?? "Choose workspace")
    }

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 6) {
                if let message = model.snapshot.errorMessage {
                    errorBanner(message)
                }
                if let message = model.snapshot.noticeMessage {
                    statusBanner(message, symbol: "info.circle.fill")
                }
                if let progress = model.refreshProgress {
                    statusBanner(progress, symbol: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                // The sparkline readouts hang below their 24-point plots, over
                // the metric row that follows them in this stack.
                MomentumHero(snapshot: model.snapshot)
                    .zIndex(1)
                metricRow
                chartSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                dashboardContentHeight = height
            }
        }
        .frame(height: Self.viewportHeight(content: dashboardContentHeight, screenHeight: visibleScreenHeight))
    }

    private var visibleScreenHeight: CGFloat {
        NSApp.keyWindow?.screen?.visibleFrame.height
            ?? NSScreen.screens.map(\.visibleFrame.height).min()
            ?? 700
    }

    nonisolated static func viewportHeight(content: CGFloat, screenHeight: CGFloat) -> CGFloat {
        // Reserve space for the fixed header, footer, and window edge.
        min(content, max(180, screenHeight - 120))
    }

    private var metricRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(metricValue("source"))
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("SOURCE LINES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(metricValue("code")) code + \(metricValue("tests")) tests")
                Text("\(metricValue("docs")) docs · separate")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
    }

    private func metricValue(_ id: String) -> String {
        model.snapshot.metrics.first { $0.id == id }?.value ?? "--"
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let chart = model.snapshot.chartTimeline {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        chartTitle(
                            "SOURCE LINES OVER TIME",
                            help: "Day-end code and test lines stacked as source; documentation is counted separately, below the axis"
                        )
                        Spacer()
                        kindLegend
                    }
                    SourceVolumeChart(timeline: chart)
                    Text("Docs use the space below zero for separation")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        chartTitle(
                            "MONTHLY ACTIVITY",
                            help: "Code and test lines added and removed per calendar month; documentation is counted separately, below the axis"
                        )
                        Spacer()
                        Text("Docs separate · added + removed, not net")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
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
            Button("Quit Work Tempo", action: onQuit)
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
        .accessibilityLabel(help)
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        // SF Symbols have no text baseline; align their ink with the header labels.
        .offset(y: 1)
        .help(help)
    }

    private var kindLegend: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            legend("Code", swatch: TempoPalette.code)
            legend("Tests", swatch: TempoPalette.tests)
            legend("Docs · separate", swatch: TempoPalette.docs)
        }
    }

    private var changeLegend: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                legend("Code added", swatch: TempoPalette.codeAdded)
                legend("Tests added", swatch: TempoPalette.testAdded)
                legend("Docs added", swatch: TempoPalette.docsAdded)
            }
            GridRow {
                legend("Code removed", swatch: TempoPalette.codeDeleted)
                legend("Tests removed", swatch: TempoPalette.testDeleted)
                legend("Docs removed", swatch: TempoPalette.docsDeleted)
            }
        }
    }

    // Identity rides the swatch; the label stays in text ink so caption-sized
    // legend text is not asked to clear contrast on a series color.
    private func legend(_ label: String, swatch: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(swatch).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption2)
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

    private func chartTitle(_ title: String, help: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .help(help)
    }

    private var lastUpdatedLabel: String {
        if model.snapshot.isRefreshing { return "Refreshing" }
        guard let date = model.snapshot.reportGeneratedAt else { return "No report" }
        return "Updated \(date.formatted(date: .omitted, time: .shortened))"
    }
}
