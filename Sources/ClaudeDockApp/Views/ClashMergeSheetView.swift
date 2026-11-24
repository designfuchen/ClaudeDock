import AppKit
import ClaudeDockCore
import SwiftUI

// MARK: - Connections & guard

/// Every account's exit, side by side: which proxy, what the rule requires, what was actually measured.
struct NetworkPage: View {
    @ObservedObject var vm: DockViewModel

    var body: some View {
        PageScroll {
            PageHeader(String(localized: "连接与守护"), subtitle: vm.guardSummary.detail)

            VStack(alignment: .leading, spacing: DS.Space.m) {
                SectionLabel(String(localized: "各账号出口"), detail: String(localized: "打开账号前检测一次，运行中每 \(vm.settings.watchdogIntervalSeconds) 秒再检测"))
                if vm.accounts.isEmpty {
                    Text("添加账号后，这里会显示每个账号的出口检测结果。")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(.secondary)
                        .padding(DS.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(vm.accounts.enumerated()), id: \.element.id) { idx, acc in
                            if idx > 0 { Divider().padding(.leading, 56) } // 16 inset + 28 avatar + 12 gap
                            EgressRow(vm: vm, account: acc)
                        }
                    }
                    .surface()
                }
            }

            ClashSection(vm: vm)
        }
    }
}

private struct EgressRow: View {
    @ObservedObject var vm: DockViewModel
    let account: AccountProfile

    var body: some View {
        let health = vm.egressHealth(for: account)
        let guarded = account.egressPolicy.mode != .disabled
        let op = vm.operation(for: account.id)
        HStack(alignment: .center, spacing: DS.Space.m) {
            AccountAvatar(account: account, state: vm.runningStates[account.id] ?? .stopped, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(account.proxy.enabled ? account.proxy.proxyURLString : String(localized: "系统网络（不走独立代理）"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 200, alignment: .leading)
            .layoutPriority(1)

            ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 3) {
                Text("规则")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(guarded ? PolicyText.compact(account.egressPolicy) : String(localized: "不检查"))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .help(guarded ? PolicyText.expectation(account.egressPolicy) : "")
            }
            .frame(minWidth: 80, idealWidth: 160, maxWidth: 220, alignment: .leading)
            Color.clear.frame(width: 0) // narrow windows: rule column drops out (it's in the tooltip and the editor)
            }

            if guarded {
                ViewThatFits(in: .horizontal) {
                    EgressHealthChip(health: health, now: vm.clock)
                    EgressHealthChip(health: health, now: vm.clock, showsDetail: false)
                }
                .layoutPriority(2)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }

            Spacer(minLength: DS.Space.s)

            if guarded {
                if let op {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(op.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    if vm.runningStates[account.id]?.isFrozen == true {
                        Button("重新检测并恢复") { vm.resume(account: account) }
                            .controlSize(.small)
                            .help("检测出口，通过后继续运行")
                    } else {
                        Button("检测") { vm.recheckEgress(account: account) }
                            .controlSize(.small)
                            .help("现在检测一次这个账号的出口")
                    }
                    Menu {
                        Button("用当前出口填写规则") { vm.pinCurrentEgress(for: account) }
                        Button("仅允许当前 IP") { vm.pinCurrentEgress(for: account, exactIP: true) }
                        Divider()
                        Button("编辑规则…") { vm.showAccount(account.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(account.name) 的出口规则操作")
                }
            } else {
                Button("开启守护…") { vm.showAccount(account.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }
}

/// Clash Verge detection and the multi-port config generator.
struct ClashSection: View {
    @ObservedObject var vm: DockViewModel
    @State private var defaultNodeName: String = ""
    @State private var copiedYAML = false
    @State private var showGenerator = false

    private var generatedYAML: String {
        ClashVergeHelper.generateMergeYAML(for: vm.accounts, defaultProxyName: defaultNodeName.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "你的固定节点") : defaultNodeName.trimmingCharacters(in: .whitespaces), mixedPort: vm.clashInfo?.mixedPort ?? 7897)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionLabel("Clash Verge", detail: String(localized: "可选：给每个账号一个专属端口，固定走某个节点"))

            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let info = vm.clashInfo {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("已找到 Clash Verge Rev")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("重新检测") { vm.refreshClashDetection() }
                            .controlSize(.small)
                        Button("打开配置文件夹") { NSWorkspace.shared.open(info.configDirectory) }
                            .controlSize(.small)
                    }
                    Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: 6) {
                        GridRow {
                            Text("混合端口").foregroundStyle(.secondary)
                            Text(verbatim: "127.0.0.1:\(info.mixedPort)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }
                        GridRow {
                            Text("TUN 模式").foregroundStyle(.secondary)
                            Text(info.tunEnabled ? String(localized: "开启（专属端口仍然各走各的节点）") : String(localized: "关闭"))
                        }
                        GridRow {
                            Text("当前订阅").foregroundStyle(.secondary)
                            Text(info.activeProfileName ?? "—").fontWeight(.medium)
                        }
                    }
                    .font(.system(size: 12))
                } else {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("没有找到 Clash Verge。也可以在账号设置里直接填写任意 HTTP / SOCKS5 代理端口。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重新检测") { vm.refreshClashDetection() }
                            .controlSize(.small)
                    }
                }

                DisclosureGroup(isExpanded: $showGenerator) {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("把下面的内容粘贴到 Clash Verge 的“全局扩展覆写配置 (Merge)”。日常上网照常走规则，每个账号通过自己的端口固定走指定节点，不用再手动切换。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            TextField("节点或策略组名称", text: $defaultNodeName, prompt: Text("填写 Clash 里已有的节点或策略组名称"))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Spacer()
                            Button(copiedYAML ? String(localized: "已复制") : String(localized: "复制配置")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generatedYAML, forType: .string)
                                withAnimation(DS.Motion.quick) { copiedYAML = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedYAML = false }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        ScrollView([.vertical, .horizontal]) {
                            // YAML is indentation-sensitive: never soft-wrap it.
                            Text(generatedYAML)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DS.Space.m)
                        }
                        .frame(height: 200)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                        .hairlineBorder(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                    }
                    .padding(.top, DS.Space.s)
                } label: {
                    Text("生成多端口配置")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .padding(DS.Space.l)
            .surface()
        }
    }
}
