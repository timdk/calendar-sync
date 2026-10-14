import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if !model.hasAccess {
                accessPrompt
            } else if model.config.directedPairs.isEmpty {
                Text("No calendars linked yet.").foregroundStyle(.secondary)
                Button("Link Calendars…", action: openSettings)
            } else {
                pairs
            }
            if !model.log.isEmpty {
                Divider()
                activity
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CalSync").font(.headline)
                status.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let err = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(err)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.config.paused {
            Text("Paused")
        } else if let r = model.lastReport {
            if let next = model.nextSync {
                Text("Synced \(r.date, style: .relative) ago · next in \(next, style: .relative)")
            } else {
                Text("Synced \(r.date, style: .relative) ago")
            }
        } else {
            Text("Not synced yet")
        }
    }

    private var accessPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CalSync needs full calendar access.")
            HStack {
                Button("Request Access") { Task { await model.requestAccess() } }
                Button("Open Privacy Settings") { model.openPrivacySettings() }
            }
        }
    }

    private var pairs: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.config.directedPairs, id: \.self) { p in
                let rep = model.lastReport?.pairs.first { $0.pair == p }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.calendarName(p.from))
                        Text("→ \(model.calendarName(p.to))").foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer()
                    if let err = rep?.error {
                        Text(err).foregroundStyle(.red).multilineTextAlignment(.trailing)
                    } else if let rep {
                        Text("\(rep.blockers) blocker\(rep.blockers == 1 ? "" : "s")")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Recent activity").font(.caption).foregroundStyle(.secondary)
            ForEach(model.log.suffix(6).reversed()) { e in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
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

    private var footer: some View {
        HStack {
            Button("Sync Now") { model.sync() }
                .disabled(!model.hasAccess || model.config.paused)
            Button(model.config.paused ? "Resume" : "Pause") { model.config.paused.toggle() }
            Spacer()
            Button("Settings…", action: openSettings)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit CalSync")
        }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}
