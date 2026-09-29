import AppKit
import SwiftUI
import MailCore

/// Accounts, shown in the main window: add one gog already signed in, or
/// sign in with google; aliases show as accounts of their own; writes on.
final class SettingsPane: NSView {
    let model: SettingsModel

    init(engine: Engine, changed: @escaping () -> Void) {
        model = SettingsModel(engine: engine, changed: changed)
        super.init(frame: .zero)
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        let width = host.widthAnchor.constraint(equalToConstant: 720)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor, constant: 12), host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.centerXAnchor.constraint(equalTo: centerXAnchor), width,
            host.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() { model.refresh() }
}

final class SettingsModel: ObservableObject {
    let engine: Engine
    let changed: () -> Void
    @Published var file = AccountsFile()
    @Published var gog: [String] = []
    @Published var status = ""
    @Published var signingIn = false

    init(engine: Engine, changed: @escaping () -> Void) {
        self.engine = engine
        self.changed = changed
    }

    func refresh() {
        file = (try? AccountsStore.load()) ?? AccountsFile()
        DispatchQueue.global().async {
            let names = Keychain.gogAccounts()
            DispatchQueue.main.async { self.gog = names }
        }
    }

    var addable: [String] {
        gog.filter { g in !file.accounts.contains { $0.email.lowercased() == g.lowercased() } }
    }

    private func save() {
        do {
            try AccountsStore.save(file)
            changed()
        } catch { status = "Couldn't save: \(error)" }
    }

    func add(_ email: String) {
        file.accounts.append(AccountConfig(email: email))
        save()
        status = "Added \(email) — first sync running"
    }

    func remove(_ email: String) {
        file.accounts.removeAll { $0.email == email }
        file.writesEnabled.removeAll { $0 == email.lowercased() }
        save()
        try? engine.store.forget(email)
        status = "Removed \(email) and its cache"
    }

    func addAlias(_ email: String, address: String, label: String) {
        guard let i = file.accounts.firstIndex(where: { $0.email == email }), address.contains("@") else { return }
        let l = label.isEmpty ? String(address.split(separator: "@").last ?? "") : label
        file.accounts[i].aliases.append(AliasRule(address: address.trimmingCharacters(in: .whitespaces), label: l))
        file.accounts[i].ignoredAliases.removeAll { $0 == address.lowercased() }
        save()
        engine.store.config = file
        try? engine.store.recomputeAll()
        changed()
    }

    func removeAlias(_ email: String, _ address: String) {
        guard let i = file.accounts.firstIndex(where: { $0.email == email }) else { return }
        file.accounts[i].aliases.removeAll { $0.address == address }
        if !file.accounts[i].ignoredAliases.contains(address.lowercased()) { file.accounts[i].ignoredAliases.append(address.lowercased()) }
        save()
        engine.store.config = file
        try? engine.store.recomputeAll()
        changed()
    }

    func setWrites(_ email: String, _ on: Bool) {
        file.writesEnabled.removeAll { $0 == email.lowercased() }
        if on { file.writesEnabled.append(email.lowercased()) }
        save()
    }

    func signIn() {
        signingIn = true
        status = "Finish signing in in your browser…"
        Task {
            do {
                let r = try await Consent.run(email: nil) { NSWorkspace.shared.open($0) }
                await MainActor.run {
                    self.signingIn = false
                    if !self.file.accounts.contains(where: { $0.email.lowercased() == r.email.lowercased() }) { self.add(r.email) }
                    self.status = "Signed in as \(r.email)" + (r.token.scopes.contains(Scope.full) ? " — push on" : "")
                }
            } catch {
                await MainActor.run { self.signingIn = false; self.status = "\(error)" }
            }
        }
    }
}

struct SettingsView: SwiftUI.View {
    @ObservedObject var model: SettingsModel
    @State private var aliasFor: String?
    @State private var aliasAddress = ""
    @State private var aliasLabel = ""

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Accounts").font(.title2.weight(.semibold))
                Spacer()
                Text("esc to go back").font(.caption).foregroundStyle(.secondary)
            }
            if model.file.accounts.isEmpty {
                Text("Add a gmail account to start.").foregroundStyle(.secondary)
            }
            ForEach(model.file.accounts, id: \.email) { a in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(a.email).font(.headline)
                        Spacer()
                        Toggle("Allow changes to gmail", isOn: Binding(get: { model.file.writes(a.email) }, set: { model.setWrites(a.email, $0) }))
                            .toggleStyle(.switch).controlSize(.small)
                        Button("Remove") { model.remove(a.email) }
                    }
                    ForEach(a.aliases, id: \.address) { r in
                        HStack {
                            Text("↳ \(r.label)").foregroundStyle(.secondary)
                            Text(r.address).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { model.removeAlias(a.email, r.address) }.controlSize(.small)
                        }
                    }
                    if aliasFor == a.email {
                        HStack {
                            TextField("alias address, e.g. you@duck.com", text: $aliasAddress)
                            TextField("shown as", text: $aliasLabel).frame(width: 110)
                            Button("Add") {
                                model.addAlias(a.email, address: aliasAddress, label: aliasLabel)
                                aliasFor = nil; aliasAddress = ""; aliasLabel = ""
                            }
                        }
                    } else {
                        Button("Add an alias by hand…") { aliasFor = a.email }.buttonStyle(.link).controlSize(.small)
                    }
                }
                Divider()
            }
            if !model.addable.isEmpty {
                Text("Signed in with gog").font(.subheadline).foregroundStyle(.secondary)
                ForEach(model.addable, id: \.self) { e in
                    HStack { Text(e); Spacer(); Button("Add") { model.add(e) } }
                }
            }
            HStack {
                Button(model.signingIn ? "Waiting for Google…" : "Sign in with Google…") { model.signIn() }.disabled(model.signingIn)
                Spacer()
            }
            Text("With changes off, nothing is written to gmail: sorting and done stay on this Mac, and sending saves a draft instead.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.status.isEmpty { Text(model.status).font(.caption) }
            Spacer()
        }
        .padding(.vertical, 16)
    }
}
