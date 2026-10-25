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
    init() {}

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
        let job = Task { try await generate(facts) }
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
        var all = UserDefaults.standard.dictionary(forKey: storeKey) ?? [:]
        all[facts.key] = nil
        UserDefaults.standard.set(all, forKey: storeKey)
        await write(facts)
    }

    enum WriterError: Error { case noModel(String) }

    private func generate(_ facts: ReviewFacts) async throws -> (ReviewCopy, String) {
        let settings = CloudModelSettings.shared
        if settings.isActive, let client = settings.client() {
            let raw = try await client.stream(system: ReviewCoach.writerInstructions + "\n" + ReviewCoach.writerJSONFormat,
                                              prompt: facts.text, maxTokens: 900) { _ in }
            guard let copy = ReviewCoach.copy(fromJSON: raw) else { throw CloudModelError.empty }
            return (copy, "云端模型 \(settings.model) 根据你的记录撰写")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), OnDeviceModel.isAvailable {
            let session = LanguageModelSession(instructions: ReviewCoach.writerInstructions)
            let r = try await session.respond(to: facts.text, generating: GeneratedReviewCopy.self,
                                              options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 1000))
            return (ReviewCopy(headline: "", summary: r.content.summary, items: r.content.items),
                    "Apple 智能根据你的记录撰写")
        }
        #endif
        throw WriterError.noModel("\(OnDeviceModel.unavailableReason)，云端模型未启用")
    }

    // MARK: Kept on this device, so a page isn't rewritten on every visit

    private func stored(_ key: String) -> (copy: ReviewCopy, by: String)? {
        guard let entry = (UserDefaults.standard.dictionary(forKey: storeKey) ?? [:])[key] as? [String: Any],
              let data = entry["copy"] as? Data, let by = entry["by"] as? String,
              let copy = try? JSONDecoder().decode(ReviewCopy.self, from: data) else { return nil }
        return (copy, by)
    }

    private func store(_ key: String, copy: ReviewCopy, by: String) {
        var all = UserDefaults.standard.dictionary(forKey: storeKey) ?? [:]
        if all.count > 40 { all.removeAll() }
        if let data = try? JSONEncoder().encode(copy) { all[key] = ["copy": data, "by": by, "at": Date.app.timeIntervalSince1970] }
        UserDefaults.standard.set(all, forKey: storeKey)
    }
}
