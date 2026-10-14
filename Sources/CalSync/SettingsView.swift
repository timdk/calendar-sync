import EventKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemoveAll = false

    var body: some View {
        @Bindable var model = model
        Form {
            if !model.hasAccess {
                Section("Calendar access") {
                    Text("CalSync needs full calendar access to read events and write blockers.")
                    HStack {
                        Button("Request Access") { Task { await model.requestAccess() } }
                        Button("Open Privacy Settings") { model.openPrivacySettings() }
                    }
                }
            }

            Section {
                ForEach(model.config.links) { link in
                    LinkRow(link: binding(for: link.id))
                }
                Button("Add Link", systemImage: "plus") {
                    model.config.links.append(SyncLink())
                }
            } header: {
                Text("Linked calendars")
            } footer: {
                Text("Busy time in one calendar appears as “\(model.config.blockerTitle)” blockers in the other. Use ↔ to mirror both ways or → for one way. Removing a link removes its blockers on the next sync.")
                    .foregroundStyle(.secondary)
            }

            Section("Options") {
                Stepper("Look ahead: \(model.config.daysAhead) days", value: $model.config.daysAhead, in: 1...180)
                Stepper("Sync every \(model.config.intervalMinutes) min", value: $model.config.intervalMinutes, in: 1...120)
                TextField("Blocker title", text: $model.config.blockerTitle)
                Toggle("Mirror tentative events", isOn: $model.config.mirrorTentative)
                Toggle("Pause syncing", isOn: $model.config.paused)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            Section {
                HStack {
                    Button("Preview Changes") { model.runPreview() }
                    Button("Sync Now") { model.sync() }
                        .disabled(model.config.paused)
                    Spacer()
                    Button("Remove All Blockers…", role: .destructive) { confirmRemoveAll = true }
                }
                .disabled(!model.hasAccess)
                if let p = model.preview {
                    PreviewList(report: p)
                }
            } header: {
                Text("Actions")
            } footer: {
                HStack {
                    Text("Log: ~/Library/Logs/CalSync.log").foregroundStyle(.secondary)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.logURL]) }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .frame(minHeight: 560)
        .confirmationDialog("Remove all CalSync blockers?", isPresented: $confirmRemoveAll) {
            Button("Remove All and Pause", role: .destructive) { model.removeAllBlockers() }
        } message: {
            Text("Deletes every blocker CalSync created in the next year, in all calendars, and pauses syncing.")
        }
    }

    /// Looks the link up by id so deleting a row can't leave a dangling index binding.
    private func binding(for id: UUID) -> Binding<SyncLink> {
        Binding(
            get: { model.config.links.first { $0.id == id } ?? SyncLink(id: id) },
            set: { new in
                if let i = model.config.links.firstIndex(where: { $0.id == id }) { model.config.links[i] = new }
            }
        )
    }
}

private struct LinkRow: View {
    @Environment(AppModel.self) private var model
    @Binding var link: SyncLink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                CalendarPicker(selection: $link.sourceID)
                Button {
                    link.bidirectional.toggle()
                } label: {
                    Image(systemName: link.bidirectional ? "arrow.left.arrow.right" : "arrow.right")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help(link.bidirectional ? "Mirroring both ways. Click for one way." : "Mirroring one way. Click for both ways.")
                CalendarPicker(selection: $link.targetID)
                Button {
                    let id = link.id
                    model.config.links.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove link")
            }
            if let problem = model.problem(with: link) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct CalendarPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String

    var body: some View {
        Picker("", selection: $selection) {
            Text("Choose calendar…").tag("")
            if !selection.isEmpty && model.calendar(selection) == nil {
                Text("Missing calendar").tag(selection)
            }
            ForEach(model.calendars, id: \.calendarIdentifier) { cal in
                Text(SyncEngine.label(cal) + (cal.allowsContentModifications ? "" : " · read-only"))
                    .tag(cal.calendarIdentifier)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

private struct PreviewList: View {
    let report: SyncReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.summary).bold()
            if report.changes.isEmpty && report.errors.isEmpty {
                Text("Everything is up to date.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                    ForEach(report.pairs.filter { $0.error != nil }) { Text($0.error!).foregroundStyle(.red) }
                    ForEach(Array(report.changes.enumerated()), id: \.offset) { Text($0.element) }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
        }
    }
}
