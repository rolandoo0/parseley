import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (menu bar → Settings…, or ⌘, while it's open).
/// SwiftUI's `Settings` scene gives us a standard macOS preferences window for free.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let env: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettings(settings: settings, env: env)
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings(settings: settings)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            SeriesSettings(settings: settings)
                .tabItem { Label("Series", systemImage: "sum") }
        }
        .frame(width: 520)
        .padding(20)
        // A menu-bar app isn't "active", so its windows open behind other apps. Bring
        // Parseley forward when Settings opens.
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let env: AppEnvironment
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                // Recorder: click it, press a new key combination, done. Saved automatically.
                KeyboardShortcuts.Recorder("Open clipboard panel:", name: .togglePanel)
            }

            Section {
                Picker("Keep history:", selection: $settings.historyLimit) {
                    ForEach(AppSettings.historyLimitChoices, id: \.self) { limit in
                        Text("\(limit.formatted()) clips").tag(limit)
                    }
                }
                Text("Pinned clips are always kept and don't count toward the limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch Parseley at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        // SMAppService registers this app as a login item (macOS 13+).
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                HStack {
                    Text("\(env.totalClipCount) clips in history")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
            Button("Clear All but Pinned", role: .destructive) { env.clearHistory(keepingPinned: true) }
            Button("Clear Everything", role: .destructive) { env.clearHistory(keepingPinned: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Series totals are kept.")
        }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @Bindable var settings: AppSettings
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Text("Copies made in these apps are never saved:")
                List(selection: $selection) {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        ExcludedAppRow(bundleID: bundleID).tag(bundleID)
                    }
                }
                .frame(minHeight: 140)
                .overlay {
                    if settings.excludedBundleIDs.isEmpty {
                        Text("No excluded apps").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Button { addApp() } label: { Image(systemName: "plus") }
                    Button {
                        if let selection { settings.excludedBundleIDs.removeAll { $0 == selection } }
                        selection = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                }
            }
            Section {
                Label("Passwords and one-time codes from password managers (1Password, Bitwarden, Keychain…) are skipped automatically.",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Lets the user pick an app; we store its bundle identifier.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.excludedBundleIDs.contains(id) {
                settings.excludedBundleIDs.append(id)
            }
        }
    }
}

private struct ExcludedAppRow: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 8) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
                Text(bundleID)
            }
            Spacer()
            Text(bundleID).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Series

private struct SeriesSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Start / stop series:", name: .toggleSeries)
                KeyboardShortcuts.Recorder("New series:", name: .newSeries)
            }

            Section("New series suggestions") {
                Picker("Ask after idle time:", selection: $settings.idleGapMinutes) {
                    ForEach(AppSettings.idleGapChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "\(minutes) minutes").tag(minutes)
                    }
                }
                Toggle("Ask when numbers come from a different app", isOn: $settings.askOnAppSwitch)
                Text("Parseley never splits a series on its own. It adds the copy and asks; choose \"Start new series\" to move it into a fresh one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What gets counted") {
                Label("Copies that are only numbers (a value, a list, a spreadsheet column or range) are added automatically.",
                      systemImage: "checkmark.circle")
                Label("Copies that mix text and numbers are skipped. Click Add in the series bar to include one.",
                      systemImage: "text.badge.plus")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}
