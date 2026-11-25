import SwiftUI
import TorrentKit

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ServersTab(model: model).tabItem { Label(String(localized: "Servers", table: "Groups"), systemImage: "server.rack") }.tag("servers")
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            NotifyTab(model: model).tabItem { Label("Notifications", systemImage: "bell") }.tag("notify")
            SitesTab(model: model).tabItem { Label(String(localized: "Sites", table: "Groups"), systemImage: "globe") }.tag("sites")
        }
        .frame(width: 820, height: 580)
    }
}

// MARK: - 服务器

private struct ServersTab: View {
    let model: AppModel
    @State private var selection: String?
    @State private var draft: ServerConfig?
    @State private var adding = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.servers) { rt in ServerRow(runtime: rt, count: 0).tag(rt.id) }
                }
                Divider()
                // 和侧栏、文件菜单、添加种子面板走同一个添加流程：先探测再保存，保存后在右侧编辑
                Button { adding = true } label: {
                    Label("Add Server", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .padding(8)
            }
            .frame(minWidth: 190, maxWidth: 230)

            Group {
                if let draft {
                    ServerEditor(model: model, original: draft) { saved in
                        selection = saved.id
                        self.draft = saved
                    } onDelete: {
                        model.remove(draft.id)
                        selection = model.servers.first?.id
                    }
                    .id(draft.id)
                } else {
                    ContentUnavailableView("Select or add a server", systemImage: "server.rack")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $adding) {
            SetupSheet(model: model) { id in selection = id }
        }
        .onChange(of: selection) { _, id in if let id, let c = model.server(id)?.config { draft = c } }
        .onAppear {
            selection = model.settingsServerFocus ?? selection ?? model.servers.first?.id
            model.settingsServerFocus = nil
        }
        .onChange(of: model.settingsServerFocus) { _, id in
            if let id { selection = id; model.settingsServerFocus = nil }
        }
    }

}

private struct ServerEditor: View {
    let model: AppModel
    let original: ServerConfig
    let onSave: (ServerConfig) -> Void
    let onDelete: () -> Void
    @State private var config: ServerConfig
    @State private var results: [URL: String] = [:]
    @State private var testing = false
    @State private var confirmDelete = false
    @State private var useAPIKey: Bool
    @State private var expanded: Set<Int> = []

    init(model: AppModel, original: ServerConfig, onSave: @escaping (ServerConfig) -> Void, onDelete: @escaping () -> Void) {
        self.model = model
        self.original = original
        self.onSave = onSave
        self.onDelete = onDelete
        _config = State(initialValue: original)
        _useAPIKey = State(initialValue: !original.apiKey.isEmpty)
    }

    private var runtime: ServerRuntime? { model.server(original.id) }
    private var isNew: Bool { runtime == nil }
    private var dirty: Bool { config != original || useAPIKey != !original.apiKey.isEmpty }
    /// API key 只在 qB 5.2+ 可用；还没连上过时不知道版本，先允许
    private var apiKeyAvailable: Bool {
        guard config.kind == .qbittorrent else { return false }
        guard let info = runtime?.info else { return true }
        return info.capabilities.contains(.apiKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if case .failed(let msg) = runtime?.status { trouble(msg) }
                Section {
                    TextField("Name", text: $config.name)
                    if isNew {
                        Picker("Type", selection: $config.kind) {
                            Text("qBittorrent").tag(ClientKind.qbittorrent)
                            Text("Transmission").tag(ClientKind.transmission)
                            Text(verbatim: ClientKind.flood.displayName).tag(ClientKind.flood)
                        }
                    } else {
                        LabeledContent("Type") {
                            Text((runtime?.info?.version).map { "\(config.kind.displayName) \($0)" } ?? config.kind.displayName)
                            Text("· type can’t be changed after creation").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    if config.kind == .qbittorrent {
                        Picker("Authentication", selection: $useAPIKey) {
                            Text("Username & Password").tag(false)
                            Text("API key").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .disabled(!apiKeyAvailable && !useAPIKey)
                        if !apiKeyAvailable { Text("API keys need qBittorrent 5.2 or later (this one is \(runtime?.info?.version ?? L("an older version"))).").font(.caption).foregroundStyle(.secondary) }
                    }
                    if config.kind == .qbittorrent, useAPIKey {
                        SecureField("API key", text: $config.apiKey)
                        Text("No login, no expiry, and no IP bans for typos. Generate one in qB’s WebUI settings.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Username", text: $config.username)
                        SecureField("Password", text: $config.password)
                    }
                    Toggle("Enabled", isOn: $config.enabled)
                }
                Section {
                    ForEach(config.endpoints.indices, id: \.self) { i in endpointRow(i) }
                    Button("+ Add Route") { config.endpoints.append(Endpoint(baseURL: URL(string: "https://")!, kind: .ddns)) }
                } header: {
                    Text("Routes · the first reachable one, from the top, is used")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if confirmDelete {
                    Text("Remove the connection settings for “\(original.name)”? Torrents on the client aren’t affected.")
                    Spacer()
                    Button("Cancel") { confirmDelete = false }
                    Button("Delete", role: .destructive) { onDelete() }
                } else {
                    if !isNew { Button("Remove Server…", role: .destructive) { confirmDelete = true } }
                    Text(dirty ? "Unsaved changes" : "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Test Connection") { Task { await test() } }.disabled(testing)
                    Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!dirty && !isNew)
                }
            }
            .padding(12)
        }
    }

    private func save() {
        var c = config
        if !useAPIKey { c.apiKey = "" }
        model.upsert(c)
        onSave(c)
        model.showToast(L("Saved “\(c.name)”"))
    }

    @ViewBuilder private func trouble(_ msg: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Can’t connect", systemImage: "exclamationmark.triangle.fill").labelStyle(TintedIconLabel(color: .red)).font(.headline)
                let is401 = msg.contains("401")
                // 401 的原因下面逐条列出，这里不再重复整段错误文案
                Text(is401 ? L("Login rejected (401)") : msg).font(.callout).textSelection(.enabled)
                if is401 {
                    Text("qB returns 401 in all of these cases and the app can’t tell them apart. Check in order:").font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• Wrong username or password")
                        Text("• The reverse proxy forwards its own Basic Auth (Authorization header) to qB: qB 5.x rejects it, so strip that header in the proxy")
                        Text("• The port in the Host header doesn’t match the WebUI port (common with Docker port mapping or a reverse proxy): make them match, or turn off Host header validation in qB")
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    Text("qB bans an IP after repeated failed logins, so the app won’t retry on its own. Click Test Connection after fixing it.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func endpointRow(_ i: Int) -> some View {
        let ep = config.endpoints[i]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                VStack(spacing: 0) {
                    Button { config.endpoints.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                    Button { config.endpoints.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }.disabled(i == config.endpoints.count - 1)
                }
                .buttonStyle(.borderless).font(.caption2)
                Picker("", selection: $config.endpoints[i].kind) {
                    ForEach(Endpoint.Kind.allCases, id: \.self) { Text(Fmt.endpointKind($0)).tag($0) }
                }
                .labelsHidden().frame(width: 80)
                TextField("Address", text: Binding(get: { ep.baseURL.absoluteString }, set: { if let u = URL(string: $0) { config.endpoints[i].baseURL = u } }))
                    .labelsHidden()
                if let r = results[ep.baseURL] { Text(r).font(.caption).lineLimit(1).frame(maxWidth: 160, alignment: .trailing) }
                Button("Advanced") { if expanded.contains(i) { expanded.remove(i) } else { expanded.insert(i) } }.controlSize(.small)
                Button { config.endpoints.remove(at: i); expanded.remove(i) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).disabled(config.endpoints.count == 1)
            }
            if expanded.contains(i) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Proxy username").foregroundStyle(.secondary)
                        TextField("", text: Binding(get: { ep.proxyAuth?.username ?? "" }, set: { setProxy(i, user: $0, pass: ep.proxyAuth?.password ?? "") })).labelsHidden()
                    }
                    GridRow {
                        Text("Proxy password").foregroundStyle(.secondary)
                        SecureField("", text: Binding(get: { ep.proxyAuth?.password ?? "" }, set: { setProxy(i, user: ep.proxyAuth?.username ?? "", pass: $0) })).labelsHidden()
                    }
                    GridRow {
                        Text("Extra headers").foregroundStyle(.secondary)
                        TextField("Name: Value, separate several with semicolons", text: Binding(get: { ep.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ") }, set: { setHeaders(i, $0) })).labelsHidden()
                    }
                    GridRow {
                        Text("Certificate trusted").foregroundStyle(.secondary)
                        HStack {
                            if let fp = ep.pinnedCertificateSHA256 {
                                Text("SHA256 \(fp.prefix(16))…").font(.caption.monospaced())
                                Button("Clear") { config.endpoints[i].pinnedCertificateSHA256 = nil }.controlSize(.small)
                            } else { Text("None (use system trust)").foregroundStyle(.secondary) }
                        }
                    }
                    GridRow {
                        Text("Use system proxy").foregroundStyle(.secondary)
                        Toggle("Off by default: with a system proxy like Clash on, LAN addresses would be sent to the proxy", isOn: $config.endpoints[i].useSystemProxy).font(.caption)
                    }
                }
                .padding(.leading, 26)
                .font(.callout)
            }
        }
    }

    private func setProxy(_ i: Int, user: String, pass: String) {
        config.endpoints[i].proxyAuth = user.isEmpty ? nil : Credentials(username: user, password: pass)
    }

    private func setHeaders(_ i: Int, _ text: String) {
        var h: [String: String] = [:]
        for part in text.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, !kv[0].isEmpty { h[kv[0]] = kv[1] }
        }
        config.endpoints[i].headers = h
    }

    private func test() async {
        testing = true
        results = [:]
        var c = config
        if !useAPIKey { c.apiKey = "" }
        for ep in c.endpoints {
            let start = ContinuousClock.now
            let outcome = await EndpointSelector.select([ep], probePath: c.probePath)
            if let (_, fp) = outcome.untrusted.first { results[ep.baseURL] = L("🔒 Certificate needs review \(fp.prefix(8))"); continue }
            guard outcome.selected != nil else { results[ep.baseURL] = "✗ " + (outcome.failures.values.first.map { "\($0)" } ?? L("Unreachable")); continue }
            let client = c.makeClient(ep)
            do {
                _ = try await client.connect()
                let ms = (ContinuousClock.now - start).components
                results[ep.baseURL] = "✓ \(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000) ms"
            } catch {
                results[ep.baseURL] = "✗ \(error)"
            }
        }
        testing = false
    }
}

// MARK: - 通用 / 通知 / 站点

private struct GeneralTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            LanguageRow()
            Picker("Refresh interval (foreground)", selection: $model.prefs.refreshForeground) { ForEach([1, 2, 5], id: \.self) { Text("\($0) s").tag($0) } }
            Picker("Refresh interval (background)", selection: $model.prefs.refreshBackground) { ForEach([10, 30, 60], id: \.self) { Text("\($0) s").tag($0) } }
            Text("The background interval is used when only the menu bar is open.").font(.caption).foregroundStyle(.secondary)
            Toggle("Stay in the menu bar after closing the main window", isOn: $model.prefs.keepInMenuBar)
            Toggle("Check for updates automatically", isOn: $model.prefs.autoCheckUpdates)
            Text("Looks for a new version on GitHub once a day. You can also choose Peerdeck › Check for Updates….").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Magnet links and .torrent files") {
                Button("Make Default") { setDefaultHandler() }
            }
            MediaSettingsSection()
            BackupSection(model: model)
        }
        .formStyle(.grouped)
    }

    private func setDefaultHandler() {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "magnet") { err in
            Task { @MainActor in model.showToast(err == nil ? L("Now the default app for magnet links") : L("Failed: \(err!.localizedDescription)")) }
        }
    }
}

/// 界面语言。写进 app 的 AppleLanguages，重启后生效，所以改了以后给个「立即重启」
private struct LanguageRow: View {
    @State private var language = AppLanguage.saved

    var body: some View {
        Picker("Language", selection: $language) {
            Text("Same as System").tag(AppLanguage.system)
            ForEach(AppLanguage.allCases.filter { $0 != .system }) { Text(verbatim: $0.nativeName ?? "").tag($0) }
        }
        .onChange(of: language) { _, v in AppLanguage.save(v) }
        if language != AppLanguage.atLaunch {
            LabeledContent {
                Button("Restart Now") { relaunch() }
            } label: {
                Text("Restart Peerdeck to use the new language.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 等自己退出后再用 open 重新打开（直接 open 会被 LaunchServices 当成激活已在运行的这个）
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            Log.info("重启失败：\(error)")
        }
    }
}

private struct NotifyTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle(isOn: $model.prefs.notifyDone) { Text("Download Complete"); Text("Once for each completed torrent") }
            // 「新的 tracker 问题」「服务器离线」两项还没实现，实现之前不显示（偏好里的值保留）
            Text("Notification permission is managed in System Settings › Notifications.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct SitesTab: View {
    @Bindable var model: AppModel
    @State private var keywords = ""

    var body: some View {
        let counts = model.store.counts.sites
        Form {
            Section(String(localized: "Sites", table: "Groups")) {
                ForEach($model.prefs.sites) { $site in
                    if counts[site.id] != nil {
                        HStack {
                            TextField("Name", text: $site.name).labelsHidden().frame(width: 130)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(site.currentHost).font(.caption.monospaced())
                                if site.hosts.count > 1 { Text(L("Formerly \(site.hosts.dropFirst().joined(separator: L(", ")))")).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Picker("Default server", selection: $site.defaultServer) {
                                Text("None").tag(String?.none)
                                ForEach(model.servers) { Text($0.config.name).tag(Optional($0.id)) }
                            }
                            .frame(width: 220)
                            Text(Fmt.count(counts[site.id] ?? 0)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }
            Section {
                Picker("“Unreachable for Long” after", selection: $model.prefs.longUnreachableHours) { ForEach([1, 6, 24], id: \.self) { Text("\($0) h").tag($0) } }
                Text("Only trackers unreachable for longer than this go to Needs Attention. Recent ones are just marked in the list.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Keywords for “Likely Unregistered”") {
                TextEditor(text: $keywords).font(.callout.monospaced()).frame(height: 90)
                    .onChange(of: keywords) { _, v in
                        model.prefs.unregisteredKeywords = v.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                Text("One per line. A tracker message containing any of them (case-insensitive) counts as “Likely Unregistered”.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { keywords = model.prefs.unregisteredKeywords.joined(separator: "\n") }
    }
}
