import SwiftUI

// MARK: - The agent's name (settings)

/// The name the user gave the Health Agent. Views read `name` (or `phrase`) and redraw when it changes.
@MainActor
@Observable
final class AgentNameSettings {
    static let shared = AgentNameSettings()

    /// nil: 「Health Agent」.
    private(set) var custom: String?
    var name: String { custom ?? AgentName.standard }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        custom = AgentName.cleaned(defaults.string(forKey: AgentName.key) ?? "")
    }

    /// Saves a name (nil or empty: back to 「Health Agent」).
    func set(_ s: String?) {
        custom = s.flatMap(AgentName.cleaned).map { String($0.prefix(AgentName.maxLength)) }
        if let c = custom { defaults.set(c, forKey: AgentName.key) }
        else { defaults.removeObject(forKey: AgentName.key) }
    }

    /// 「问问 Health Agent」 / 「问问小安」.
    func phrase(_ before: String, _ after: String = "") -> String { AgentName.phrase(before, name, after) }
}

/// The 「给它取个名字」 dialog, shared by 我的 and the chat menu.
private struct AgentRenameAlert: ViewModifier {
    @Binding var isPresented: Bool
    @State private var draft = ""
    private var names: AgentNameSettings { .shared }

    func body(content: Content) -> some View {
        content
            .alert("给 \(AgentName.standard) 取个名字", isPresented: $isPresented) {
                TextField(AgentName.standard, text: $draft)
                Button("保存") { names.set(draft) }
                if names.custom != nil {
                    Button("改回 \(AgentName.standard)", role: .destructive) { names.set(nil) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("最多 \(AgentName.maxLength) 个字，回答和入口都会用这个名字。也可以在对话里说「以后叫你小安」。")
            }
            .onChange(of: isPresented) { _, shown in if shown { draft = names.custom ?? "" } }
            // At most `maxLength` characters, kept as they are typed.
            .onChange(of: draft) { _, d in if d.count > AgentName.maxLength { draft = String(d.prefix(AgentName.maxLength)) } }
    }
}

extension View {
    func agentRenameAlert(isPresented: Binding<Bool>) -> some View { modifier(AgentRenameAlert(isPresented: isPresented)) }
}
