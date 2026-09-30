import AppKit
import WorkTempoCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var dashboardContentHeight: CGFloat = 445
    @State private var showingNotice = false
    @ScaledMetric(relativeTo: .caption2) private var legendFontSize: CGFloat = 10
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
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 7) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text("Work Tempo")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize()
            }
            if !model.workspaces.isEmpty {
                workspaceMenu
                if let message = model.snapshot.noticeMessage {
                    actionButton("info.circle", help: "Report notice") {
                        showingNotice.toggle()
                    }
                    .accessibilityValue(message)
                    .popover(isPresented: $showingNotice, arrowEdge: .bottom) {
                        Text(message)
                            .font(.caption)
                            .frame(maxWidth: 260, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            Spacer()
            HStack(alignment: .center, spacing: 6) {
                if !model.workspaces.isEmpty {
                    Text(lastUpdatedLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(model.snapshot.dataState == .stale ? Color.orange : Color.secondary)
                        .fixedSize()
                        .frame(height: 24)
                }
                // Each button is a 24-point box around a smaller glyph, so the
                // boxes touch and the glyphs still read as separate.
                HStack(alignment: .center, spacing: 0) {
                    actionButton(
                        model.snapshot.isRefreshing ? "xmark" : "arrow.clockwise",
                        symbolSize: model.snapshot.isRefreshing ? 14 : 12,
                        help: model.snapshot.isRefreshing ? "Cancel refresh" : "Refresh",
                        action: onRefresh
                    )
                    .disabled(model.workspaces.isEmpty)
                    actionButton("gearshape", help: "Settings", action: openSettingsWindow)
                    actionButton("plus", symbolSize: 14, help: "Add workspace", action: onAdd)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 2)
        .onChange(of: model.snapshot.noticeMessage) { _, message in
            if message == nil { showingNotice = false }
        }

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
                .font(.system(size: 11, weight: .medium))
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
                if let message = model.snapshot.coverageMessage {
                    statusBanner(message, symbol: "info.circle.fill", opticalOffset: 1.5)
                }
                if let progress = model.refreshProgress {
                    statusBanner(progress, symbol: "arrow.trianglehead.2.clockwise.rotate.90", opticalOffset: 0.75)
                }
                sourceBanner
                // The sparkline readout hangs below its plot, over the chart
                // section that follows it in this stack.
                MomentumHero(snapshot: model.snapshot)
                    .zIndex(1)
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

    /// The size of the codebase, split by kind.
    /// Source is code plus tests; documentation is counted apart from it.
    private var sourceBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(metricValue("source"))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(TempoPalette.source)
            Text("SOURCE LINES")
                .font(.caption2.weight(.semibold))
                .fixedSize()
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            // The breakdown never wraps; the big figure gives way first.
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                kindFigure("code", color: TempoPalette.codeDeleted)
                Text("+").foregroundStyle(.tertiary)
                kindFigure("tests", color: TempoPalette.testDeleted)
                kindFigure("docs", color: TempoPalette.docsDeleted)
                    .padding(.leading, 5)
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .fixedSize()
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { sectionRule }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Source lines \(metricValue("source")): \(metricValue("code")) code plus \(metricValue("tests")) tests. Documentation \(metricValue("docs"))."
        )
    }

    private func kindFigure(_ id: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(metricValue(id))
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(id)
                .foregroundStyle(.secondary)
        }
    }

    private func metricValue(_ id: String) -> String {
        model.snapshot.metrics.first { $0.id == id }?.value ?? "--"
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let chart = model.snapshot.chartTimeline {
                VStack(alignment: .leading, spacing: 4) {
                    sectionRule
                    chartHeader(
                        "LINES OVER TIME",
                        help: "Day-end code and test lines stacked as source; docs are drawn below zero for distinction, with actual counts in the hover readout",
                        legend: kindLegend
                    )
                    SourceVolumeChart(timeline: chart)
                }
                VStack(alignment: .leading, spacing: 4) {
                    sectionRule
                    chartHeader(
                        "MONTHLY ACTIVITY",
                        help: "Code and test lines added and removed per calendar month; docs are drawn below zero for distinction, with actual counts in the hover readout",
                        legend: changeLegend
                    )
                    MonthlyChurnChart(timeline: chart)
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

    private static let makerURL = URL(string: "http://2mw2lt.com/")!

    private var footer: some View {
        HStack {
            Button("Remove", systemImage: "minus.circle") {
                guard let workspace = model.selectedWorkspace else { return }
                confirmRemoval(of: workspace)
            }
            .disabled(model.selectedWorkspace == nil)
            .frame(height: 24)
            .contentShape(Rectangle())
            Spacer()
            // The header's icon buttons are 24 points square; matching that keeps
            // the icon under the header's plus and gives it a real click target.
            Button("Quit Work Tempo", systemImage: "power", action: onQuit)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .keyboardShortcut("q")
                .help("Quit Work Tempo")
        }
        // An overlay rather than a third HStack child, so it stays centred on the
        // panel whatever the widths of Remove and Quit.
        .overlay {
            Link("2mw2lt", destination: Self.makerURL)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help("2mw2lt.com")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    private func confirmRemoval(of workspace: Workspace) {
        // The menu-bar window can close before a SwiftUI alert presents.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove workspace?"
        alert.informativeText = "Work Tempo will stop tracking \(workspace.displayName) and delete any saved report. Your Git repository will remain on disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Workspace").hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn, model.selectedWorkspace == workspace {
            onRemove()
        }
    }

    private func actionButton(
        _ symbol: String,
        symbolSize: CGFloat = 12,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .help(help)
    }

    private var kindLegend: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            legend("Code", swatch: TempoPalette.code)
            legend("Tests", swatch: TempoPalette.tests)
            legend("Docs", swatch: TempoPalette.docs)
        }
    }

    private var changeLegend: some View {
        HStack(spacing: 10) {
            pairedLegend("Code", added: TempoPalette.codeAdded, removed: TempoPalette.codeDeleted)
            pairedLegend("Tests", added: TempoPalette.testAdded, removed: TempoPalette.testDeleted)
            pairedLegend("Docs", added: TempoPalette.docsAdded, removed: TempoPalette.docsDeleted)
        }
    }

    // Identity rides the swatch; the label stays in text ink so caption-sized
    // legend text is not asked to clear contrast on a series color.
    private func legend(_ label: String, swatch: Color, spoken: String? = nil) -> some View {
        HStack(spacing: 4) {
            Circle().fill(swatch).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.system(size: legendFontSize, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? label)
    }

    /// Added and removed share a kind, so they share an entry.
    private func pairedLegend(_ kind: String, added: Color, removed: Color) -> some View {
        HStack(spacing: 4) {
            KindChip(colors: [added, removed])
            Text("\(kind) +/-").foregroundStyle(.secondary)
        }
        .font(.system(size: legendFontSize, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind) added and removed")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .offset(y: 0.75)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer()
        }
        .padding(9)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func statusBanner(_ message: String, symbol: String, opticalOffset: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .offset(y: opticalOffset)
            Text(message)
                .font(.caption)
            Spacer()
        }
        .padding(9)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var sectionRule: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [Color.primary.opacity(0.22), Color.primary.opacity(0.02)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 1.5)
            .accessibilityHidden(true)
    }

    /// The legend sits at the right of the title, and drops below it when the
    /// two do not fit on one row.
    private func chartHeader<Legend: View>(_ title: String, help: String, legend: Legend) -> some View {
        let heading = Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .help(help)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                heading
                Spacer(minLength: 8)
                legend.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                heading
                // Wider than the popover, it scrolls rather than clips.
                ViewThatFits(in: .horizontal) {
                    legend.fixedSize(horizontal: true, vertical: false)
                    ScrollView(.horizontal) {
                        legend.fixedSize(horizontal: true, vertical: false)
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
    }

    private var lastUpdatedLabel: String {
        if model.snapshot.isRefreshing { return "Refreshing" }
        guard let date = model.snapshot.reportGeneratedAt else { return "No report" }
        return "Updated \(date.formatted(date: .omitted, time: .shortened))"
    }
}
