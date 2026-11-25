import SwiftUI
import TorrentKit

/// 设置：服务器、刷新、站点、tracker 问题的判定
struct SettingsScreen: View {
    @Bindable var model: AppModel
    @State private var path: [String] = []
    /// 设置本身是弹出的面板，再从根视图弹添加服务器会被忽略，所以在这里自己弹
    @State private var adding = false
    @State private var language = AppLanguage.saved
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section(String(localized: "Servers", table: "Groups")) {
                    ForEach(model.servers) { rt in
                        NavigationLink(value: rt.id) { ServerRow(runtime: rt, count: model.store.counts.servers[rt.id] ?? 0) }
                    }
                    Button { adding = true } label: { Label("Add Server…", systemImage: "plus.circle") }
                }
                Section {
                    Picker("Language", selection: $language) {
                        Text("Same as System").tag(AppLanguage.system)
                        ForEach(AppLanguage.allCases.filter { $0 != .system }) { Text(verbatim: $0.nativeName ?? "").tag($0) }
                    }
                    .onChange(of: language) { _, v in AppLanguage.save(v) }
                    Picker("Refresh interval (foreground)", selection: $model.prefs.refreshForeground) {
                        ForEach([1, 2, 5], id: \.self) { Text("\($0) s").tag($0) }
                    }
                } header: {
                    Text("General")
                } footer: {
                    // iOS 不能自己重启，只能提示
                    if language != AppLanguage.atLaunch { Text("Quit and reopen Peerdeck to use the new language.") }
                }
                Section {
                    NavigationLink("Sites") { IOSSitesScreen(model: model) }
                    Picker("“Unreachable for Long” after", selection: $model.prefs.longUnreachableHours) {
                        ForEach([1, 6, 24], id: \.self) { Text("\($0) h").tag($0) }
                    }
                    NavigationLink("Keywords for “Likely Unregistered”") { IOSKeywordsScreen(model: model) }
                } header: {
                    Text("Needs Attention")
                } footer: {
                    Text("Only trackers unreachable for longer than this go to Needs Attention. Recent ones are just marked in the list.")
                }
                MediaSettingsSection()
                BackupSection(model: model)
                AboutSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let c = model.server(id)?.config { ServerEditScreen(model: model, original: c) } else { EmptyView() }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $adding) { SetupScreen(model: model) }
            .onAppear {
                // 从横幅「编辑服务器…」进来时直接打开那台
                if let id = model.settingsServerFocus { path = [id]; model.settingsServerFocus = nil }
            }
        }
    }
}

/// 编辑一台服务器（mac 设置页 ServerEditor 的 iOS 版）
struct ServerEditScreen: View {
    let model: AppModel
    let original: ServerConfig
    @State private var config: ServerConfig
    @State private var useAPIKey: Bool
    @State private var results: [URL: String] = [:]
    @State private var testing = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, original: ServerConfig) {
        self.model = model
        self.original = original
        _config = State(initialValue: original)
        _useAPIKey = State(initialValue: !original.apiKey.isEmpty)
    }

    private var runtime: ServerRuntime? { model.server(original.id) }
    private var dirty: Bool { config != original || useAPIKey != !original.apiKey.isEmpty }

    var body: some View {
        Form {
            if case .failed(let msg) = runtime?.status {
                Section {
                    Label("Can’t connect", systemImage: "powerplug.portrait").font(.headline)
                    Text(msg).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section {
                FormField(L("Name"), text: $config.name)
                LabeledContent("Type", value: (runtime?.info?.version).map { "\(config.kind.displayName) \($0)" } ?? config.kind.displayName)
                if config.kind == .qbittorrent {
                    Picker("Authentication", selection: $useAPIKey) {
                        Text("Username & Password").tag(false)
                        Text("API key").tag(true)
                    }
                }
                if config.kind == .qbittorrent, useAPIKey {
                    FormField("API key", text: $config.apiKey, secure: true)
                } else {
                    FormField(L("Username"), text: $config.username)
                    FormField(L("Password"), text: $config.password, secure: true)
                }
                Toggle("Enabled", isOn: $config.enabled)
            }
            Section {
                ForEach(config.endpoints.indices, id: \.self) { i in endpointRow(i) }
                    .onMove { config.endpoints.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { if config.endpoints.count - $0.count >= 1 { config.endpoints.remove(atOffsets: $0) } }
                Button("+ Add Route") { config.endpoints.append(Endpoint(baseURL: URL(string: "https://")!, kind: .ddns)) }
            } header: {
                Text("Routes · the first reachable one, from the top, is used")
            }
            Section {
                Button { Task { await test() } } label: {
                    HStack { Text("Test Connection"); if testing { Spacer(); ProgressView() } }
                }
                .disabled(testing)
            }
            Section {
                Button("Remove Server…", role: .destructive) { confirmDelete = true }
                    // 挂在按钮上，确认框才会从按钮这里弹出（挂在整个表单上会指向页面顶部）
                    .confirmationDialog("Remove the connection settings for “\(original.name)”? Torrents on the client aren’t affected.", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { model.remove(original.id); dismiss() }
                    }
            }
        }
        .navigationTitle(original.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!dirty) }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
    }

    @ViewBuilder private func endpointRow(_ i: Int) -> some View {
        let ep = config.endpoints[i]
        VStack(alignment: .leading, spacing: 6) {
            Picker("Route", selection: $config.endpoints[i].kind) {
                ForEach(Endpoint.Kind.allCases, id: \.self) { Text(Fmt.endpointKind($0)).tag($0) }
            }
            TextField("Address", text: Binding(get: { ep.baseURL.absoluteString }, set: { if let u = URL(string: $0) { config.endpoints[i].baseURL = u } }))
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.callout.monospaced())
            if let r = results[ep.baseURL] { Text(r).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Advanced") {
                TextField("Proxy username", text: Binding(get: { ep.proxyAuth?.username ?? "" }, set: { setProxy(i, user: $0, pass: ep.proxyAuth?.password ?? "") }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Proxy password", text: Binding(get: { ep.proxyAuth?.password ?? "" }, set: { setProxy(i, user: ep.proxyAuth?.username ?? "", pass: $0) }))
                TextField("Extra headers", text: Binding(get: { ep.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ") }, set: { setHeaders(i, $0) }), prompt: Text("Name: Value, separate several with semicolons"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if let fp = ep.pinnedCertificateSHA256 {
                    HStack {
                        Text("SHA256 \(fp.prefix(16))…").font(.caption.monospaced())
                        Spacer()
                        Button("Clear") { config.endpoints[i].pinnedCertificateSHA256 = nil }
                    }
                }
            }
            .font(.callout)
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

    private func save() {
        var c = config
        if !useAPIKey { c.apiKey = "" }
        model.upsert(c)
        model.showToast(L("Saved “\(c.name)”"))
        dismiss()
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

/// 站点：显示名、默认服务器
struct IOSSitesScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        let counts = model.store.counts.sites
        Form {
            ForEach($model.prefs.sites) { $site in
                if counts[site.id] != nil {
                    Section {
                        FormField(L("Name"), text: $site.name)
                        Picker("Default server", selection: $site.defaultServer) {
                            Text("None").tag(String?.none)
                            ForEach(model.servers) { Text($0.config.name).tag(Optional($0.id)) }
                        }
                    } header: {
                        Text("\(site.currentHost) · \(Fmt.torrents(counts[site.id] ?? 0))")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Sites", table: "Groups"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 「疑似未注册」的关键词
struct IOSKeywordsScreen: View {
    @Bindable var model: AppModel
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("One per line. A tracker message containing any of them (case-insensitive) counts as “Likely Unregistered”.")
            }
        }
        .navigationTitle("Keywords for “Likely Unregistered”")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = model.prefs.unregisteredKeywords.joined(separator: "\n") }
        .onChange(of: text) { _, v in
            model.prefs.unregisteredKeywords = v.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}
