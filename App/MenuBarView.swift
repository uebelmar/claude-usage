import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Noch keine Accounts").font(.headline)
                    Text("Füge pro Claude-Abo einen eigenen Monitoring-Login hinzu.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(store.orderedUsage) { u in
                AccountCard(usage: u) { store.remove(u.id) }
            }
            if let pending = store.pendingLogin {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Warte auf Login für „\(pending)“ …").font(.callout)
                    Spacer()
                    Button("Abbrechen") { store.cancelPendingLogin() }.controlSize(.small)
                }
            }

            Divider()

            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text("Stand: \(UsageFormat.ago(store.lastUpdate, now: ctx.date))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button {
                    Task { await store.refresh(force: true) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Jetzt aktualisieren")
                    .disabled(store.isRefreshing)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button("Account hinzufügen …") { store.addAccount() }
                    .disabled(store.pendingLogin != nil)
                Button("Account wechseln in Orca …") { store.openOrca() }
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                Button("Beenden") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct AccountCard: View {
    let usage: AccountUsage
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage.name).font(.headline).emailBlur(usage.name)
                if let plan = usage.plan {
                    Text(plan.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Spacer()
                if hovering {
                    Button(action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Account entfernen")
                }
            }
            if let email = usage.email, email.caseInsensitiveCompare(usage.name) != .orderedSame {
                Text(email).font(.caption).foregroundStyle(.secondary).emailBlur(email)
            }
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                VStack(alignment: .leading, spacing: 6) {
                    if let s = usage.session {
                        WindowRow(window: s, now: ctx.date, prominent: true)
                    } else if usage.updatedAt != nil {
                        // Kein laufendes 5-h-Fenster: startet erst mit der nächsten Nachricht.
                        HStack {
                            Text("5 h").font(.callout)
                            Spacer()
                            Text("frei · startet bei Nutzung").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let w = usage.weekly { WindowRow(window: w, now: ctx.date, prominent: true) }
                    ForEach(usage.modelWeekly, id: \.label) { WindowRow(window: $0, now: ctx.date, prominent: false) }
                }
            }
            if let e = usage.extra, e.enabled {
                HStack {
                    Text("Extra-Usage").font(.caption)
                    Spacer()
                    Text("\(UsageFormat.money(e.spent, e.currency)) / \(UsageFormat.money(e.limit, e.currency))")
                        .font(.caption).monospacedDigit()
                }
            }
            if let err = usage.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .onHover { hovering = $0 }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let now: Date
    let prominent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(prominent ? .callout : .caption)
                Spacer()
                Text(UsageFormat.percent(window.usedPercent))
                    .font((prominent ? Font.callout : .caption).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(UsageFormat.color(window.usedPercent))
            }
            UsageBar(percent: window.usedPercent, height: prominent ? 6 : 4)
            Text("Reset \(UsageFormat.reset(window.resetsAt, now: now))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
