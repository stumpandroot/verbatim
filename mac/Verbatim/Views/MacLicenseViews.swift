import SwiftUI

/// Settings › Account and plan › License (mockup "Verbose License and Calls"): the trial, Buy, and the key field
/// while free; days left during the trial; the masked key and Deactivate this Mac once licensed. The store is
/// App/MacLicenseStore.swift; the rules and every line are Model/MacLicense.swift.
struct MacLicenseSettingsRow: View {
    @ObservedObject private var store = MacLicenseStore.shared
    @State private var key = ""

    var body: some View {
        SettingsRow("account.license", detail: detail, stacked: true) {
            VStack(alignment: .leading, spacing: 10) {
                if !MacLicense.isConfigured {
                    Text(MacLicenseCopy.notReady).font(.system(size: 12.5)).foregroundStyle(Refined.dim)
                } else if let l = store.license, l.isGranted {
                    licensed(l)
                } else {
                    buying
                }
                if let p = store.problem {
                    Text(store.localOnlyRefused ? LocalOnly.message(.licenseCheck) : MacLicenseCopy.problem(p))
                        .font(.system(size: 12.5)).foregroundStyle(Refined.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let n = store.note {
                    Text(n).font(.system(size: 12.5)).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var detail: String {
        switch store.state {
        case .unlocked: return MacLicenseCopy.licensed
        case .trial(let ends, let days): return MacLicenseCopy.trialLeft(days) + ". " + MacLicenseCopy.trialBody(ends: Formats.style(date: .full, time: .none).string(from: ends))
        case .trialEnded: return MacLicenseCopy.trialEnded
        case .free: return MacLicenseCopy.pitch
        }
    }

    @ViewBuilder private var buying: some View {
        HStack(spacing: 8) {
            if store.state.offersTrial {
                Button(MacLicenseCopy.tryFree) { store.startTrial() }.buttonStyle(.settingsPrimaryPill)
                Button(MacLicenseCopy.buy()) { store.openCheckout() }.buttonStyle(.settingsPill)
            } else {
                Button(MacLicenseCopy.buy()) { store.openCheckout() }.buttonStyle(.settingsPrimaryPill)
            }
        }
        Text(MacLicenseCopy.haveKey).font(.system(size: 12, weight: .semibold)).foregroundStyle(Refined.mute)
        HStack(spacing: 8) {
            TextField(MacLicenseCopy.keyPlaceholder, text: $key)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                .font(.system(size: 12.5, design: .monospaced))
                .onSubmit { Task { await store.activate(key) } }
                .accessibilityLabel("License key")
            Button(MacLicenseCopy.activate) { Task { await store.activate(key) } }
                .buttonStyle(.settingsPill)
                .disabled(store.busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if store.busy { ProgressView().controlSize(.small) }
        }
        Text(MacLicenseCopy.iPhoneSeparate).font(.system(size: 12)).foregroundStyle(Refined.mute)
    }

    @ViewBuilder private func licensed(_ l: MacLicenseRecord) -> some View {
        Text(MacLicenseCopy.licensedBody(ending: l.keyEnding)).font(.system(size: 12.5)).foregroundStyle(Refined.dim)
        if l.lastFailedAttempt != nil {
            Text(MacLicenseCopy.offlineNote).font(.system(size: 12.5)).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            Button(MacLicenseCopy.deactivate) { Task { await store.deactivate() } }.buttonStyle(.settingsPill).disabled(store.busy)
            Button(MacLicenseCopy.manage) { store.openPortal() }.buttonStyle(.settingsPill)
            if store.busy { ProgressView().controlSize(.small) }
        }
        Text(MacLicenseCopy.deactivateNote).font(.system(size: 12)).foregroundStyle(Refined.mute)
    }
}
