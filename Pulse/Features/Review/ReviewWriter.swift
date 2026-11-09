import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// Guided generation for Apple Intelligence: the model fills exactly these fields (the headline is
/// the rules' verdict).
@available(iOS 26.0, *)
@Generable
struct GeneratedReviewCopy {
    @Guide(description: "2–3 句连贯的话，按【写作要点】讲主线、亮点、难点和下一步；最多 2 个数字，不要罗列指标，不超过 110 字")
    var summary: String
    // Capped, so a model that keeps adding items stops instead of running to the end of its context.
    @Guide(description: "按【条目】的顺序，每条把说明改成一两句口语（不超过 50 字），条数与【条目】相同", .maximumCount(8))
    var items: [String]
}
#endif

/// Writes the 复盘 cards with a language model (cloud if set up, otherwise Apple Intelligence),
/// keeps the results for the same facts, and says plainly when the rules text is shown instead.
@MainActor
@Observable
final class ReviewWriter {
    static let shared = ReviewWriter()
    typealias Generator = @MainActor (ReviewFacts) async throws -> (ReviewCopy, String)
    private let defaults: UserDefaults
    private let generator: Generator?

    init(defaults: UserDefaults = .standard, generator: Generator? = nil) {
        self.defaults = defaults
        self.generator = generator
    }

    enum State: Equatable {
        case writing
        case written(ReviewCopy, by: String)
        /// The rules text is shown; the reason says why.
        case rules(String)
    }

    private(set) var states: [String: State] = [:]
    private let storeKey = "review.copy.v3"

    func state(for facts: ReviewFacts) -> State? { states[facts.key] }

    /// The copy to show: the model's text once written, the rules text until then.
    func copy(for facts: ReviewFacts) -> ReviewCopy {
        if case .written(let c, _)? = states[facts.key] { return c }
        return facts.fallback
    }

    func write(_ facts: ReviewFacts) async {
        let key = facts.key
        guard states[key] == nil else { return }
        if let saved = stored(key) {
            // Checked again, so text kept from before a newer check still meets it.
            states[key] = .written(saved.copy.checked(against: facts).copy, by: saved.by)
            return
        }
        states[key] = .writing
        // Generation runs on its own, so a card that is redrawn or scrolled away does not cancel it.
        let job = Task {
            if let generator { return try await generator(facts) }
            return try await generate(facts)
        }
        do {
            let (raw, by) = try await job.value
            let (copy, replaced) = raw.checked(against: facts)
            let line = replaced > 0 ? by + " · \(replaced) 处用了规则原文" : by
            states[key] = .written(copy, by: line)
            store(key, copy: copy, by: line)
        } catch is CancellationError {
            states[key] = nil
        } catch WriterError.noModel(let reason) {
            states[key] = .rules("大模型不可用（\(reason)），显示规则分析")
        } catch {
            states[key] = .rules("这次没能生成（\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)），显示规则分析")
        }
    }

    /// Forget a page's text so it is written again.
    func rewrite(_ facts: ReviewFacts) async {
        states[facts.key] = nil
        var all = defaults.dictionary(forKey: storeKey) ?? [:]
        all[facts.key] = nil
        defaults.set(all, forKey: storeKey)
        await write(facts)
    }

    enum WriterError: Error { case noModel(String) }

    private func generate(_ facts: ReviewFacts) async throws -> (ReviewCopy, String) {
        let settings = CloudModelSettings.shared
        let instructions = ReviewCoach.writerInstructions + (facts.explainsWeek ? "\n本周复盘补充要求：优先解释【主靶点】的变化是否仍在测量波动范围内。可以结合【个人背景】【个人关联】【本人本周反馈】中的已知线索提出可能解释，但须明确尚不能确定；不添加未记录的行为、疾病、情绪或生活原因。相关不代表因果。只记录身体状况的人不要求完成训练或设立改善目标。建议只能采用【条目】和【下周已拟安排】中的既有内容。" : "")
        // 复盘 cards are made of the user's records: only 全部云端 sends them.
        if settings.effectiveMode == .cloud, let client = settings.client() {
            let outgoing = Self.cloudPrompt(for: facts)
            let raw = try await client.stream(system: instructions + "\n" + ReviewCoach.writerJSONFormat + "\n" + IdentityMask.instruction,
                                              prompt: outgoing.text, maxTokens: 900) { _ in }
            guard var copy = ReviewCoach.copy(fromJSON: raw) else { throw CloudModelError.empty }
            copy.summary = outgoing.mask.restore(copy.summary)
            copy.items = copy.items.map { outgoing.mask.restore($0) }
            return (copy, "云端模型 \(settings.model) 根据你的记录撰写")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), OnDeviceModel.isAvailable {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: facts.text, generating: GeneratedReviewCopy.self,
                                              options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 1000))
            return (ReviewCopy(headline: "", summary: r.content.summary, items: r.content.items),
                    "Apple 智能根据你的记录撰写")
        }
        #endif
        throw WriterError.noModel("\(OnDeviceModel.unavailableReason)；云端模型只在「全部云端」时撰写复盘")
    }

    static func cloudPrompt(for facts: ReviewFacts) -> (text: String, mask: IdentityMask) {
        var mask = IdentityMask(knownNames: facts.knownNames, keep: ["Pulse", AgentNameSettings.shared.name])
        let text = mask.mask(facts.text)
        return (text, mask)
    }

    // MARK: Kept on this device, so a page isn't rewritten on every visit

    private func stored(_ key: String) -> (copy: ReviewCopy, by: String)? {
        guard let entry = (defaults.dictionary(forKey: storeKey) ?? [:])[key] as? [String: Any],
              let data = entry["copy"] as? Data, let by = entry["by"] as? String,
              let copy = try? JSONDecoder().decode(ReviewCopy.self, from: data) else { return nil }
        return (copy, by)
    }

    private func store(_ key: String, copy: ReviewCopy, by: String) {
        var all = defaults.dictionary(forKey: storeKey) ?? [:]
        if all.count > 40 { all.removeAll() }
        if let data = try? JSONEncoder().encode(copy) { all[key] = ["copy": data, "by": by, "at": Date.app.timeIntervalSince1970] }
        defaults.set(all, forKey: storeKey)
    }
}
