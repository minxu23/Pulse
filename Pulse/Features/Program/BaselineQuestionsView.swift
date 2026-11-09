import SwiftUI
import SwiftData

/// 基础信息补充 (基线期): safety questions before exercise (modelled on the PAR-Q+ general questions),
/// smoking, family history, the sports the user likes, whether there is a blood-pressure monitor, and the
/// optional strength self-test.
struct BaselineQuestionsView: View {
    @Bindable var profile: UserProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @State private var answers: [Bool?]
    @State private var sports: [WorkoutType: SportLevel]
    @State private var pushups: Int?
    @State private var chairStands: Int?
    private let hadMonitor: Bool?

    static let questions = ParQ.allCases.map(\.question)
    static let sportChoices: [WorkoutType] = [.run, .walk, .cycle, .swim, .tennis, .badminton, .tableTennis, .basketball, .soccer, .strength, .yoga, .hiit]

    init(profile: UserProfile) {
        self.profile = profile
        let saved = profile.parqAnswers
        _answers = State(initialValue: (0..<Self.questions.count).map { $0 < saved.count ? saved[$0] : nil })
        _sports = State(initialValue: Dictionary(profile.favoriteSports.map { ($0.type, $0.level) }, uniquingKeysWith: { a, _ in a }))
        _pushups = State(initialValue: profile.strengthPushups)
        _chairStands = State(initialValue: profile.strengthChairStands)
        hadMonitor = profile.hasBPMonitor
    }

    var body: some View {
        Form {
            if !profile.hasAge { BasicsSection(p: profile) }
            Section {
                ForEach(Self.questions.indices, id: \.self) { i in
                    Picker(Self.questions[i], selection: $answers[i]) {
                        Text("请选择").tag(nil as Bool?)
                        Text("否").tag(Optional(false))
                        Text("是").tag(Optional(true))
                    }
                    .font(Theme.TypeScale.body)
                }
            } header: {
                Text("运动前安全问题")
            } footer: {
                Text("参照 PAR-Q+ 的一般健康问题。任何一题回答「是」，建议先咨询医生，医生确认后再开始方案；在那之前可以做基础层（步行、拉伸、作息）。回答「是」不代表不能运动。")
            }

            Section {
                optionalAnswer("吸烟", value: $profile.smoker)
                optionalAnswer("父母或兄弟姐妹有早发心脏病（男性 55 岁、女性 65 岁以前）", value: $profile.familyHistoryCVD)
                optionalAnswer("家里有血压计或血压手表", value: $profile.hasBPMonitor)
            } header: {
                Text("生活习惯")
            } footer: {
                if profile.programTarget == .clinicBP { Text("添置了血压计，选「是」后当天就改用家庭血压，这一轮的基线不变。") }
            }

            Section {
                countRow("俯卧撑（个）", value: $pushups)
                countRow("30 秒坐站（次）", value: $chairStands)
            } header: {
                Text("力量自测（可选）")
            } footer: {
                Text("俯卧撑做到做不动为止，女性可以跪姿；60 岁以上做 30 秒坐站：双手抱胸，30 秒内从椅子上完全站起再坐下的次数。用来和同龄同性别的人比。")
            }

            Section {
                ForEach(Self.sportChoices) { t in
                    HStack {
                        Button {
                            if sports[t] == nil { sports[t] = .regular } else { sports[t] = nil }
                        } label: {
                            HStack(spacing: Theme.Space.block) {
                                Image(systemName: sports[t] == nil ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(sports[t] == nil ? Color.secondary : Color.accentColor)
                                Label(t.label, systemImage: t.icon).labelStyle(.titleAndIcon)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let level = sports[t] {
                            Picker("水平", selection: Binding(get: { level }, set: { sports[t] = $0 })) {
                                ForEach(SportLevel.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                }
            } header: {
                Text("喜欢、常做的运动")
            } footer: {
                Text("方案会把这些运动放进进阶训练，比如每周打两次网球的人，网球就算他的高强度训练。")
            }
        }
        .navigationTitle("基础信息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    profile.parqAnswers = answers.compactMap { $0 }
                    profile.parqDate = .app
                    profile.favoriteSports = Self.sportChoices.compactMap { t in sports[t].map { SportPreference(type: t, level: $0) } }
                    if pushups != profile.strengthPushups || chairStands != profile.strengthChairStands {
                        profile.strengthPushups = pushups
                        profile.strengthChairStands = chairStands
                        profile.strengthTestDate = pushups == nil && chairStands == nil ? nil : .app
                    }
                    profile.programQuestionsDone = true
                    try? ctx.save()
                    // A monitor bought during a round on clinic readings: home blood pressure from today.
                    if hadMonitor != true, profile.hasBPMonitor == true { ProgramFlow.switchToHomeBP(profile, in: ctx) }
                    dismiss()
                }
                .disabled(!profile.hasAge || answers.contains(where: { $0 == nil }))
            }
        }
    }
    private func countRow(_ title: String, value: Binding<Int?>) -> some View {
        LabeledContent(title) {
            TextField("未测", value: value, format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
        }
    }

    private func optionalAnswer(_ title: String, value: Binding<Bool?>) -> some View {
        Picker(title, selection: value) {
            Text("未填写").tag(nil as Bool?)
            Text("否").tag(Optional(false))
            Text("是").tag(Optional(true))
        }
    }

}
