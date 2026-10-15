import EventKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var height: CGFloat = 620

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasAccess { AccessBanner() }
            TabView {
                LinksTab().tabItem { Label("Links", systemImage: "link") }
                GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
                ActivityTab().tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            }
        }
        .frame(width: 640, height: height)
    }
}

// MARK: - Shared pieces

private struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar access needed").font(.headline)
                Text("CalSync needs full access to read events and write blockers.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Request Access") { Task { await model.requestAccess() } }
            Button("Open Settings") { model.openPrivacySettings() }
        }
        .padding(12)
        .background(.orange.opacity(0.1))
    }
}

/// A coloured dot in the calendar's colour.
struct CalendarDot: View {
    let color: NSColor?
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Color(nsColor: color ?? .tertiaryLabelColor))
            .frame(width: size, height: size)
    }
}

/// A non-template circle image, so menus keep the calendar colour.
private func swatch(_ color: NSColor?) -> NSImage {
    let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
        (color ?? .tertiaryLabelColor).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - Links

private struct LinksTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.config.links.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No linked calendars", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Link two calendars to mirror busy time between them.")
                    } actions: {
                        Button("Add Link") { model.config.links.append(SyncLink()) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ForEach(model.config.links) { link in
                    LinkCard(link: binding(for: link.id))
                }
                Section {
                    Button("Add Link", systemImage: "plus.circle.fill") {
                        model.config.links.append(SyncLink())
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text("Events show up in the other calendar as “\(model.config.blockerTitle)” blockers unless you copy details. An alias names a calendar in title prefixes and around CalSync. Removing a link removes its blockers on the next sync.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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

private struct LinkCard: View {
    @Environment(AppModel.self) private var model
    @Binding var link: SyncLink

    private var copiesDetails: Bool {
        link.detailsToTarget || (link.bidirectional && link.detailsToSource)
    }

    var body: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    CalendarPicker(selection: $link.sourceID)
                    directionButton
                    CalendarPicker(selection: $link.targetID)
                }
                GridRow {
                    AliasField(calendarID: link.sourceID)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    AliasField(calendarID: link.targetID)
                }
            }

            Toggle(isOn: $link.detailsToTarget) {
                detailsLabel(into: link.targetID)
            }
            if link.bidirectional {
                Toggle(isOn: $link.detailsToSource) {
                    detailsLabel(into: link.sourceID)
                }
            }
            if copiesDetails {
                Toggle(isOn: $link.prefixTitles) {
                    Text("Prefix titles with the calendar alias")
                    Text("Shows which account to join with, e.g. “\(example)”.")
                }
                Label("Copied titles are visible to anyone who can see event details in that calendar. CalSync can't mark them private.",
                      systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let problem = model.problem(with: link) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button(role: .destructive) {
                    let id = link.id
                    model.config.links.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove link")
            }
        }
    }

    private var title: String {
        guard !link.sourceID.isEmpty, !link.targetID.isEmpty else { return "New link" }
        return "\(model.calendarName(link.sourceID)) \(link.bidirectional ? "↔" : "→") \(model.calendarName(link.targetID))"
    }

    private var example: String {
        let from = link.detailsToTarget || !link.bidirectional ? link.sourceID : link.targetID
        return "[\(from.isEmpty ? "Alias" : model.calendarName(from))] Weekly sync"
    }

    private var directionButton: some View {
        Button {
            link.bidirectional.toggle()
        } label: {
            Image(systemName: link.bidirectional ? "arrow.left.arrow.right" : "arrow.right")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.bordered)
        .help(link.bidirectional ? "Mirroring both ways. Click for one way." : "Mirroring one way. Click for both ways.")
    }

    // Two plain Texts (no stack) so the toggle styles the second as a subtitle.
    @ViewBuilder private func detailsLabel(into id: String) -> some View {
        Text("Copy titles and join links into \(id.isEmpty ? "this calendar" : model.calendarName(id))")
        Text("Otherwise it gets “\(model.config.blockerTitle)” blockers.")
    }
}

private struct AliasField: View {
    @Environment(AppModel.self) private var model
    let calendarID: String

    var body: some View {
        TextField("Alias", text: Binding(
            get: { model.config.aliases[calendarID] ?? "" },
            set: { model.setAlias($0, for: calendarID) }
        ), prompt: Text(model.calendar(calendarID)?.source.title ?? "Alias"))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .disabled(calendarID.isEmpty)
        .help("A short name for this calendar, e.g. the client or company. Used in title prefixes.")
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
            ForEach(model.calendarGroups, id: \.account) { group in
                Section(group.account) {
                    ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                        Label {
                            Text(cal.title + (cal.allowsContentModifications ? "" : " · read-only"))
                        } icon: {
                            Image(nsImage: swatch(cal.color))
                        }
                        .tag(cal.calendarIdentifier)
                    }
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Syncing") {
                Toggle("Pause syncing", isOn: $model.config.paused)
                Stepper(value: $model.config.intervalMinutes, in: 1...120) {
                    LabeledContent("Sync every", value: "\(model.config.intervalMinutes) min")
                }
                Stepper(value: $model.config.daysAhead, in: 1...180) {
                    LabeledContent("Look ahead", value: "\(model.config.daysAhead) days")
                }
            }
            Section {
                TextField("Blocker title", text: $model.config.blockerTitle)
                Toggle("Mirror tentative events", isOn: $model.config.mirrorTentative)
            } header: {
                Text("Blockers")
            } footer: {
                Text("All-day, free, cancelled and declined events are never mirrored.")
                    .foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Activity

private struct ActivityTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemoveAll = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Preview Changes", systemImage: "eye") { model.runPreview() }
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.sync() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.config.paused)
                    Spacer()
                }
                .disabled(!model.hasAccess)
                if let p = model.preview {
                    PreviewList(report: p)
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Preview shows what the next sync would change without touching any calendar.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.log.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.log.reversed()) { e in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(e.date, format: .dateTime.hour().minute())
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Text(e.text)
                                        .foregroundStyle(e.isError ? .red : .primary)
                                }
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(height: 180)
                }
            } header: {
                Text("Recent activity")
            } footer: {
                HStack(spacing: 4) {
                    Text("Full log: ~/Library/Logs/CalSync.log").foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.logURL]) }
                        .buttonStyle(.link)
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove all blockers")
                        Text("Deletes every blocker CalSync created and pauses syncing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove All…", role: .destructive) { confirmRemoveAll = true }
                        .disabled(!model.hasAccess)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove all CalSync blockers?", isPresented: $confirmRemoveAll) {
            Button("Remove All and Pause", role: .destructive) { model.removeAllBlockers() }
        } message: {
            Text("Deletes every blocker CalSync created in the next year, in all calendars, and pauses syncing.")
        }
    }
}

private struct PreviewList: View {
    let report: SyncReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(report.summary, systemImage: report.errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout.bold())
                .foregroundStyle(report.errors.isEmpty ? Color.primary : Color.orange)
            if report.changes.isEmpty && report.errors.isEmpty {
                Text("Everything is up to date.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(report.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                        ForEach(report.pairs.filter { $0.error != nil }) { Text($0.error!).foregroundStyle(.red) }
                        ForEach(Array(report.changes.enumerated()), id: \.offset) { Text($0.element) }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
    }
}
