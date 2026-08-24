// ContinuityDemoView.swift
//
// Makes the re-plan visible. The interesting number on screen is `retained`:
// it is the work the planner kept in flight across a display-class change that
// a naive migration would have cancelled and refetched.

#if canImport(SwiftUI)
import SwiftUI
import DisplayContinuity

@available(iOS 17.0, macOS 14.0, *)
public struct ContinuityDemoView: View {

    @State private var model: ContinuityDemoModel

    /// - Parameters:
    ///   - fallbackPlan: the compiled-in budget the host app owns. Shown before
    ///     the first re-plan lands.
    ///   - itemCount: number of rows in the demo feed.
    public init(fallbackPlan: CapacityPlan = .conservative, itemCount: Int = 40) {
        _model = State(
            wrappedValue: ContinuityDemoModel(fallbackPlan: fallbackPlan, itemCount: itemCount)
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls
                planCard
                directiveCard
                paneCard
                stormCard
                listPreview
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.start() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display Continuity")
                .font(.largeTitle.bold())
            Text("An unfold is a capacity event, not a layout event. Watch what the planner keeps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(model.displayClass == .expanded ? "Fold" : "Unfold") {
                    Task { await model.toggleFold() }
                }
                .buttonStyle(.borderedProminent)

                Button("Settle window") {
                    Task { await model.settle() }
                }
                .buttonStyle(.bordered)

                Button("Run fold storm") {
                    Task { await model.runStorm() }
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Text("Scroll anchor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Top") { Task { await model.scroll(to: 0) } }
                    .buttonStyle(.bordered)
                Button("Middle") { Task { await model.scroll(to: model.rows.count / 2) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var planCard: some View {
        card(title: "Capacity plan · \(model.displayClass.rawValue)") {
            metric("Visible window", "\(model.plan.visibleWindow) rows")
            metric("Prefetch depth", "\(model.plan.prefetchDepth) rows")
            metric("Concurrent decodes", "\(model.plan.concurrentDecodes)")
            metric("Decode budget", "\(model.plan.decodeByteBudget / 1_048_576) MB")
        }
    }

    @ViewBuilder
    private var directiveCard: some View {
        if let directive = model.lastDirective {
            card(title: "Last re-plan · epoch \(directive.epoch.value)") {
                metric("Started", "\(directive.admit.count)")
                metric("Retained (not refetched)", "\(directive.retain.count)")
                metric("Cancelled", "\(directive.cancel.count)")
                metric("Held pending reversal", "\(directive.deferredCancellations.count)")
                Divider().padding(.vertical, 2)
                metric("Session total started", "\(model.totalAdmitted)")
                metric("Session total retained", "\(model.totalRetained)")
            }
        } else {
            card(title: "Last re-plan") {
                Text("Planning…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var paneCard: some View {
        card(title: "Surface-scoped projection") {
            metric("List selection", model.projection.listSelection?.rawValue ?? "—")
            metric("Detail pane", model.projection.showsDetailPane ? "visible" : "hidden")
            metric("Detail content", model.projection.detail?.rawValue ?? "—")
            Text(
                model.projection.showsDetailPane
                    ? "The detail pane materialised already populated — same stored selection, no second source of truth."
                    : "Folded. The selection is untouched; there is nothing to re-seed on the way back."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stormCard: some View {
        if let summary = model.stormSummary {
            card(title: "Fold-storm harness") {
                HStack(spacing: 6) {
                    Image(systemName: (model.stormPassed ?? false) ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle((model.stormPassed ?? false) ? Color.green : Color.red)
                    Text((model.stormPassed ?? false) ? "Invariants held" : "Invariants broken")
                        .font(.callout.bold())
                }
                Text(summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var listPreview: some View {
        card(title: "Feed") {
            // `prefix` is safe on any count, including zero.
            ForEach(Array(model.rows.prefix(8))) { row in
                Button {
                    Task { await model.select(row.id) }
                } label: {
                    HStack {
                        Text(row.title)
                        Spacer()
                        if model.projection.listSelection == row.id {
                            Image(systemName: "checkmark")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.rows.isEmpty {
                Text("No items.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Building blocks

    private func card(
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview {
    ContinuityDemoView()
}
#endif
