import SwiftUI
import TorrentKit

/// 添加服务器：填表 → 逐条线路探测（自签证书就地确认）→ 显示版本和能力 → 保存（mac 的 SetupSheet 的 iOS 版）
struct SetupScreen: View {
    let model: AppModel
    var onSaved: ((String) -> Void)? = nil
    @State private var config = ServerConfig.blank()
    @State private var url = ""
    @State private var extraURL = ""
    @State private var showExtra = false
    @State private var phase = Phase.form
    @State private var results: [Row] = []
    @Environment(\.dismiss) private var dismiss

    enum Phase { case form, probing, done }
    struct Row: Identifiable {
        let id = UUID()
        var ok: Bool?
        var title: String
        var detail: String
        var chips: [String] = []
        var trust: (Endpoint, String)?
    }

    var body: some View {
        NavigationStack {
            Form {
                if phase == .form { form } else { probeResults }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .form { Button("Cancel") { dismiss() } } else { Button("Go Back") { phase = .form } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .form {
                        Button("Connect") { Task { await probe() } }.disabled(Self.normalized(url)?.host() == nil)
                    } else {
                        Button("Save") { model.upsert(config); onSaved?(config.id); dismiss() }
                            .disabled(phase != .done || !(results.first?.ok ?? false))
                    }
                }
            }
        }
    }

    @ViewBuilder private var form: some View {
        Section {
            Picker("Type", selection: $config.kind) {
                Text("qBittorrent").tag(ClientKind.qbittorrent)
                Text("Transmission").tag(ClientKind.transmission)
                Text(verbatim: ClientKind.flood.displayName).tag(ClientKind.flood)
            }
            .pickerStyle(.segmented)
            .onChange(of: config.kind) { old, k in
                url = ServerConfig.switchingPort(in: url, from: old, to: k)
                if config.name == ServerConfig.blank(kind: old).name { config.name = ServerConfig.blank(kind: k).name }
            }
            FormField(L("Name"), text: $config.name)
        }
        Section {
            FormField(L("Address"), text: $url, prompt: ServerConfig.exampleAddress(config.kind), url: true)
            FormField(L("Username"), text: $config.username)
            FormField(L("Password"), text: $config.password, secure: true)
        } footer: {
            Text("Paste the WebUI URL; subpaths are fine")
        }
        Section {
            if showExtra {
                FormField(L("Remote route"), text: $extraURL, prompt: "https://nas.example.com/qb/", url: true)
            } else {
                Button("+ Add a remote route (DDNS, reverse proxy or overlay network)") { showExtra = true }
            }
        } footer: {
            if showExtra { Text("Uses the LAN at home and falls back to this route.") }
        }
    }

    @ViewBuilder private var probeResults: some View {
        ForEach(results) { r in
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if let ok = r.ok {
                            Image(systemName: ok ? "checkmark" : r.trust != nil ? "lock.trianglebadge.exclamationmark" : "xmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(ok ? .primary : .secondary)
                        } else { ProgressView() }
                    }
                    .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.title).fontWeight(.medium)
                        Text(r.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(r.chips, id: \.self) { Text($0).font(.caption) }
                        if let (ep, fp) = r.trust {
                            Button("Trust This Certificate") { trust(ep, fp) }.font(.callout.weight(.semibold)).buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    /// 只写了「192.168.1.2:8080」这样的地址时补上 http://
    static func normalized(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return URL(string: t.contains("://") ? t : "http://" + t)
    }

    private func buildEndpoints() {
        var eps: [Endpoint] = []
        if let u = Self.normalized(url) { eps.append(Endpoint(baseURL: u, kind: .lan)) }
        if showExtra, let u = Self.normalized(extraURL), u.host() != nil { eps.append(Endpoint(baseURL: u, kind: .ddns)) }
        for i in eps.indices { eps[i].pinnedCertificateSHA256 = config.endpoints.first { $0.baseURL == eps[i].baseURL }?.pinnedCertificateSHA256 }
        config.endpoints = eps
    }

    private func probe() async {
        buildEndpoints()
        phase = .probing
        results = config.endpoints.map { Row(ok: nil, title: "\(Fmt.endpointKind($0.kind)) \($0.baseURL.absoluteString)", detail: L("Connecting…")) }
        for (i, ep) in config.endpoints.enumerated() {
            let outcome = await EndpointSelector.select([ep], probePath: config.probePath)
            if let (_, fp) = outcome.untrusted.first {
                results[i] = Row(ok: false, title: results[i].title, detail: L("The certificate isn’t trusted by the system (self-signed). Trust it only if this is your own server.\nSHA256 \(fp)"), trust: (ep, fp))
                continue
            }
            guard outcome.selected != nil else {
                results[i] = Row(ok: false, title: results[i].title, detail: outcome.failures.values.first.map { "\($0)" } ?? L("Unreachable"))
                continue
            }
            let client = config.makeClient(ep)
            do {
                let info = try await client.connect()
                var chips: [String] = []
                chips.append(info.trackerStatusSummary)
                if info.capabilities.contains(.categories) { chips.append(L("✓ Categories and tags")) }
                if info.capabilities.contains(.apiKey) { chips.append(L("Supports API keys: no IP bans from wrong passwords. Recommended.")) }
                results[i] = Row(ok: true, title: "\(info.version) · \(Fmt.endpointKind(ep.kind))", detail: "API \(info.apiVersion)", chips: chips)
            } catch {
                results[i] = Row(ok: false, title: results[i].title, detail: "\(error)")
            }
        }
        phase = .done
    }

    private func trust(_ ep: Endpoint, _ fp: String) {
        if let i = config.endpoints.firstIndex(where: { $0.baseURL == ep.baseURL }) { config.endpoints[i].pinnedCertificateSHA256 = fp }
        let pins = config.endpoints
        Task {
            buildEndpoints()
            for i in config.endpoints.indices { config.endpoints[i].pinnedCertificateSHA256 = pins.first { $0.baseURL == config.endpoints[i].baseURL }?.pinnedCertificateSHA256 }
            await probe()
        }
    }
}
