import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.hasAccess {
                accessPrompt
            } else if model.config.directedPairs.isEmpty {
                emptyState
            } else {
                pairs
            }
            if !model.log.isEmpty { activity }
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("CalSync").font(.headline)
                status.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if model.config.paused {
                Text("Syncing is paused")
            } else if let r = model.lastReport {
                let ago = Text(r.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                if let next = model.nextSync, next > context.date {
                    let until = Text(next, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    Text("Synced \(ago) · next \(until)")
                } else {
                    Text("Synced \(ago)")
                }
            } else {
                Text("Not synced yet")
            }
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) =
            !model.hasAccess ? ("No access", .orange)
            : model.lastError != nil ? ("Error", .red)
            : model.config.paused ? ("Paused", .secondary)
            : ("Active", .green)
        return Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
            .help(model.lastError ?? "")
    }

    // MARK: Body

    private var accessPrompt: some View {
        card {
            Label("CalSync needs full calendar access.", systemImage: "lock.shield")
            HStack {
                Button("Request Access") { Task { await model.requestAccess() } }
                Button("Open Privacy Settings") { model.openPrivacySettings() }
            }
        }
    }

    private var emptyState: some View {
        card {
            Text("No calendars linked yet.").foregroundStyle(.secondary)
            Button("Link Calendars…", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
    }

    private var pairs: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Mirroring")
            VStack(spacing: 0) {
                ForEach(Array(model.config.directedPairs.enumerated()), id: \.element) { i, p in
                    if i > 0 { Divider().padding(.leading, 10) }
                    pairRow(p)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func pairRow(_ p: DirectedPair) -> some View {
        let rep = model.lastReport?.pairs.first { $0.pair == p }
        return HStack(spacing: 6) {
            CalendarDot(color: model.calendar(p.from)?.color)
            Text(model.calendarName(p.from))
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            CalendarDot(color: model.calendar(p.to)?.color)
            Text(model.calendarName(p.to))
            if p.copyDetails {
                Image(systemName: "text.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Copies titles and join links")
            }
            Spacer(minLength: 8)
            if let err = rep?.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(err)
            } else if let rep {
                Text("\(rep.blockers)")
                    .monospacedDigit()
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("\(rep.blockers) event\(rep.blockers == 1 ? "" : "s") mirrored")
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Recent activity")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.log.suffix(5).reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.date, format: .dateTime.hour().minute())
                            .monospacedDigit().foregroundStyle(.secondary)
                        Text(e.text)
                            .foregroundStyle(e.isError ? .red : .primary)
                            .lineLimit(2)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.sync()
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasAccess || model.config.paused)

            Button {
                model.config.paused.toggle()
            } label: {
                Label(model.config.paused ? "Resume" : "Pause",
                      systemImage: model.config.paused ? "play.fill" : "pause.fill")
            }

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit CalSync")
        }
        .controlSize(.regular)
    }

    // MARK: Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}
