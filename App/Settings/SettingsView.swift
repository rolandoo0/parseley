import AppKit
import KeyboardShortcuts
import ParseleyCore
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
            ModeSettings(modes: env.modes, recipes: env.recipes)
                .tabItem { Label("Modes", systemImage: "square.stack.3d.up") }
            RecipeSettings(recipes: env.recipes)
                .tabItem { Label("Recipes", systemImage: "wand.and.stars") }
            SeriesSettings(settings: settings)
                .tabItem { Label("Series", systemImage: "sum") }
        }
        .frame(width: 640)
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
                HStack(spacing: 14) {
                    ParseleyLogo(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parseley").font(.title3.weight(.semibold))
                        Text(verbatim: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · everything stays on this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstall Parseley")
                        Text("Removes the app, the parseley command, settings and permissions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uninstall…", role: .destructive) { Uninstaller.confirmAndUninstall() }
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
                KeyboardShortcuts.Recorder("Copy series total:", name: .copySeriesTotal)
                KeyboardShortcuts.Recorder("Paste series result:", name: .pasteSeriesResult)
            }

            Section("Pasting the result") {
                Picker("⌃⌥⌘V / ⌃⌥⌘= pastes the series:", selection: $settings.seriesPasteStat) {
                    ForEach(AppSettings.seriesPasteChoices, id: \.self) { choice in
                        Text(choice == AppSettings.followMode ? "Mode's main stat" : choice).tag(choice)
                    }
                }
                Text("⌃⌥⌘V (when no paste queue is running) and ⌃⌥⌘= paste a result straight into the app you're in: the running series first; otherwise the numbers you just copied (copy a column, press the shortcut); otherwise the last finished series. Your clipboard is left as it was.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

// MARK: - Modes

private struct ModeSettings: View {
    let modes: ModeController
    let recipes: RecipeController
    @State private var selectedID: String? = Mode.generalID
    @State private var confirmingReset = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selectedID) {
                    ForEach(modes.library.modes) { mode in
                        Label(mode.name, systemImage: mode.icon).tag(mode.id)
                    }
                }
                .frame(width: 180, height: 320)
                HStack(spacing: 6) {
                    Button { selectedID = modes.addCustomMode().id } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selectedID { modes.remove(id: id) }
                        selectedID = Mode.generalID
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil || selectedID == Mode.generalID)
                }
                Button("Reset Built-in Modes…") { confirmingReset = true }
                    .controlSize(.small)
                Text("Mode: \(modes.current.name)\(modes.isAutomatic ? " (automatic)" : " (locked)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let id = selectedID, modes.library.mode(id: id) != nil {
                ModeEditor(mode: modes.binding(for: id), modes: modes, recipes: recipes)
                    .id(id)   // fresh editor state per mode
            } else {
                Text("Select a mode").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Reset the built-in modes?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { modes.resetBuiltIns() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("General, Finance, SQL, Dev and Writing go back to their original apps and settings. Your own modes are kept.")
        }
    }
}

private struct ModeEditor: View {
    @Binding var mode: Mode
    let modes: ModeController
    let recipes: RecipeController

    private static let icons = [
        "list.clipboard", "dollarsign.circle", "cylinder.split.1x2",
        "chevron.left.forwardslash.chevron.right", "text.alignleft", "chart.bar",
        "doc.text", "cart", "briefcase", "flask", "graduationcap", "star",
    ]

    var body: some View {
        Form {
            Section {
                TextField("Name:", text: $mode.name)
                Picker("Icon:", selection: $mode.icon) {
                    ForEach(Self.icons, id: \.self) { Image(systemName: $0).tag($0) }
                }
                Picker("Numbers look like:", selection: $mode.numberFormat) {
                    ForEach(NumberFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Main stat (⌘1):", selection: $mode.primaryStat) {
                    ForEach(NumberStats.labels, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Show stats and sums", isOn: $mode.showsNumbers)
                Toggle("Copies count toward a running series", isOn: $mode.countsInSeries)
                Picker("Run a recipe on every copy:", selection: $mode.autoRecipeID) {
                    Text("Off").tag(String?.none)
                    ForEach(recipes.recipes) { recipe in
                        Text(recipe.name).tag(String?.some(recipe.id))
                    }
                }
                if mode.autoRecipeID != nil {
                    Text("Each copy made in this mode's apps is transformed and the result replaces the clipboard. The original stays in history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Switches on in these apps") {
                if mode.id == Mode.generalID {
                    Text("General is used for every app that no other mode claims.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mode.apps, id: \.self) { bundleID in
                        HStack {
                            ExcludedAppRow(bundleID: bundleID)
                            Button {
                                mode.apps.removeAll { $0 == bundleID }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add App…") { addApps() }
                }
            }

            Section("Transform buttons shown first") {
                ForEach(TransformRegistry.all.indices, id: \.self) { index in
                    let transform = TransformRegistry.all[index]
                    Toggle(transform.title, isOn: Binding(
                        get: { mode.pinnedTransforms.contains(transform.id) },
                        set: { pinned in
                            if pinned { mode.pinnedTransforms.append(transform.id) }
                            else { mode.pinnedTransforms.removeAll { $0 == transform.id } }
                        }
                    ))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Pick apps; each one moves to this mode (an app belongs to one mode).
    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { modes.assign(app: id, to: mode.id) }
        }
    }
}

// MARK: - Recipes

private struct RecipeSettings: View {
    let recipes: RecipeController
    @State private var selectedID: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selectedID) {
                    ForEach(recipes.recipes) { recipe in
                        Label(recipe.name, systemImage: "wand.and.stars").tag(recipe.id)
                    }
                }
                .frame(width: 180, height: 320)
                HStack(spacing: 6) {
                    Button { selectedID = recipes.addRecipe().id } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selectedID { recipes.remove(id: id) }
                        selectedID = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                }
                Text("Recipes appear after the transform buttons and in the > command bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 180, alignment: .leading)
            }

            if let id = selectedID, recipes.recipe(id: id) != nil {
                RecipeEditor(recipe: recipes.binding(for: id)).id(id)
            } else {
                Text("Select a recipe").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .onAppear { if selectedID == nil { selectedID = recipes.recipes.first?.id } }
    }
}

private struct RecipeEditor: View {
    @Binding var recipe: Recipe
    @State private var sample = "  banana\napple\n\nbanana\n cherry "

    var body: some View {
        Form {
            Section {
                TextField("Name:", text: $recipe.name)
            }
            Section("Steps (run top to bottom)") {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, stepID in
                    HStack {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(TransformRegistry.transform(id: stepID)?.title ?? stepID)
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == recipe.steps.count - 1)
                        Button { recipe.steps.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    }
                    .buttonStyle(.borderless)
                }
                Menu("Add Step") {
                    ForEach(TransformRegistry.all.indices, id: \.self) { i in
                        let transform = TransformRegistry.all[i]
                        Button(transform.title) { recipe.steps.append(transform.id) }
                    }
                }
            }
            Section("Try it") {
                TextEditor(text: $sample)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                Text(verbatim: preview)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var preview: String {
        guard let transform = recipe.transform() else { return "Add a step to see the result." }
        do { return try transform.apply(sample) } catch let error as TransformError { return error.message }
        catch { return error.localizedDescription }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard recipe.steps.indices.contains(target) else { return }
        recipe.steps.swapAt(index, target)
    }
}
