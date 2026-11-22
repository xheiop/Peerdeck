import QBittorrentClient
import SwiftUI
import TorrentKit
import TransmissionClient

/// 第一次添加服务器：填表 → 逐条线路探测（自签证书就地确认）→ 显示版本和能力 → 保存
struct SetupSheet: View {
    let model: AppModel
    /// 保存后回调新服务器的 id（从添加种子面板打开时，用来选中它）
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Server").font(.title3.weight(.semibold))
            if phase == .form {
                Form {
                    Picker("Type", selection: $config.kind) {
                        Text("qBittorrent").tag(ClientKind.qbittorrent)
                        Text("Transmission").tag(ClientKind.transmission)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: config.kind) { old, k in
                        if url.hasSuffix(":8080") || url.hasSuffix(":9091") { url = String(url.dropLast(5)) + (k == .qbittorrent ? ":8080" : ":9091") }
                        // 名称还是默认值时跟着类型改，免得 TR 服务器叫「qBittorrent」
                        if config.name == ServerConfig.blank(kind: old).name { config.name = ServerConfig.blank(kind: k).name }
                    }
                    TextField("Name", text: $config.name)
                    TextField("Address", text: $url, prompt: Text(config.kind == .qbittorrent ? "http://192.168.1.2:8080" : "http://192.168.1.2:9091"))
                    Text("Paste the WebUI URL; subpaths are fine").font(.caption).foregroundStyle(.secondary)
                    TextField("Username", text: $config.username)
                    SecureField("Password", text: $config.password)
                    if showExtra {
                        TextField("Remote route", text: $extraURL, prompt: Text("https://nas.example.com/qb/"))
                        Text("Uses the LAN at home and falls back to this route.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("+ Add a remote route (DDNS, reverse proxy or overlay network)") { showExtra = true }.buttonStyle(.link)
                    }
                }
                .formStyle(.grouped)
                .frame(height: showExtra ? 350 : 310)
            } else {
                VStack(spacing: 8) {
                    ForEach(results) { r in
                        HStack(alignment: .top, spacing: 8) {
                            Group {
                                if let ok = r.ok {
                                    Image(systemName: ok ? "checkmark.circle.fill" : r.trust != nil ? "lock.trianglebadge.exclamationmark" : "xmark.circle.fill")
                                        .foregroundStyle(ok ? .green : r.trust != nil ? .orange : .red)
                                } else { ProgressView().controlSize(.small) }
                            }
                            .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.title).fontWeight(.medium)
                                Text(r.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if !r.chips.isEmpty {
                                    HStack { ForEach(r.chips, id: \.self) { Text($0).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).overlay(Capsule().stroke(.separator)) } }
                                }
                            }
                            Spacer()
                            if let (ep, fp) = r.trust {
                                Button("Trust This Certificate") { trust(ep, fp) }
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    }
                }
            }
            HStack {
                Spacer()
                if phase == .form {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Connect") { Task { await probe() } }.keyboardShortcut(.defaultAction).disabled(Self.normalized(url)?.host() == nil)
                } else {
                    Button("Go Back") { phase = .form }
                    Button("Save") { model.upsert(config); onSaved?(config.id); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(phase != .done || !(results.first?.ok ?? false))
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func buildEndpoints() {
        var eps: [Endpoint] = []
        if let u = Self.normalized(url) { eps.append(Endpoint(baseURL: u, kind: .lan)) }
        if showExtra, let u = Self.normalized(extraURL), u.host() != nil { eps.append(Endpoint(baseURL: u, kind: .ddns)) }
        // 保留已经信任过的指纹
        for i in eps.indices { eps[i].pinnedCertificateSHA256 = config.endpoints.first { $0.baseURL == eps[i].baseURL }?.pinnedCertificateSHA256 }
        config.endpoints = eps
    }

    /// 只写了「192.168.1.2:8080」这样的地址时补上 http://
    static func normalized(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return URL(string: t.contains("://") ? t : "http://" + t)
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
            let client: any TorrentClient = config.kind == .qbittorrent
                ? QBittorrentClient(serverID: config.serverID, endpoint: ep, credentials: config.credentials)
                : TransmissionClient(serverID: config.serverID, endpoint: ep, credentials: config.credentials)
            do {
                let info = try await client.connect()
                var chips: [String] = []
                chips.append(info.capabilities.contains(.trackerHealthInList) ? L("✓ Tracker status") : L("✗ No tracker status (qB 5.1.x)"))
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
        Task { await probeKeepingPins() }
    }

    private func probeKeepingPins() async {
        let pins = config.endpoints
        buildEndpoints()
        for i in config.endpoints.indices { config.endpoints[i].pinnedCertificateSHA256 = pins.first { $0.baseURL == config.endpoints[i].baseURL }?.pinnedCertificateSHA256 }
        await probe()
    }
}
