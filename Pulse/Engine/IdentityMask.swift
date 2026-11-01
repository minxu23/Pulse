import Foundation
import NaturalLanguage

// MARK: - What can tell who the user is

/// Before anything goes to a cloud model, what can tell who the user is — names, phone numbers,
/// ID and card numbers, e-mail, street addresses, hospitals and doctors — is swapped for a code like
/// 「[姓名1]」, and the answer gets the originals back on the phone. Ages, dates, cities and all health
/// data go as they are (the user's choice, 2026-11-01): the cloud needs them to answer.
/// Names are found by what is around them: the user's own name, 「我是／我叫…」, 「我女儿／我妈…」 and
/// 「…医生／…主任」. Apple's name tagger adds to that where it reads Chinese (it does on the Mac; on
/// iOS 27 it finds nothing), so a bare name with no such word around it can still go out.
struct IdentityMask {
    enum Kind: String, CaseIterable {
        case name = "姓名", doctor = "医生", hospital = "医院", phone = "电话", idNumber = "证件号", number = "编号", email = "邮箱", address = "地址"
    }
    struct Entry: Equatable {
        let code: String
        let original: String
        let kind: Kind
    }

    private(set) var entries: [Entry] = []
    /// Always masked, even when the tagger misses them: the user's own name.
    let knownNames: [String]
    /// Never masked: the name the user gave Health Agent, product names.
    let keep: [String]

    init(knownNames: [String] = [], keep: [String] = []) {
        self.knownNames = knownNames.filter { $0.count >= 2 && $0 != "你" }
        self.keep = keep.filter { !$0.isEmpty }
    }

    var isEmpty: Bool { entries.isEmpty }
    /// 「姓名、医院」: what was taken out, for the line under the answer.
    var summary: String {
        Kind.allCases.filter { k in entries.contains { $0.kind == k } }.map(\.rawValue).joined(separator: "、")
    }

    /// Tells the cloud model what the codes are.
    static let instruction = "问题和对话里形如 [姓名1]、[医院1]、[电话1] 的方括号代号，是 Pulse 在本机替换掉的个人信息：需要提到时照原样写出代号，不要猜测它们是什么，也不要改写。"

    // MARK: Masking

    /// The text with every identifier replaced by its code; the same name always gets the same code.
    mutating func mask(_ text: String) -> String {
        var found: [(range: Range<String.Index>, kind: Kind)] = []
        func add(_ r: Range<String.Index>, _ k: Kind) {
            // The first finder of a stretch of text wins; patterns run before the tagger.
            guard !found.contains(where: { $0.range.overlaps(r) }), !keep.contains(String(text[r])) else { return }
            found.append((r, k))
        }
        for (pattern, kind, group) in Self.patterns {
            for r in Self.matches(pattern, in: text, group: group) { add(r, kind) }
        }
        for name in knownNames {
            var from = text.startIndex
            while let r = text.range(of: name, range: from..<text.endIndex) { add(r, .name); from = r.upperBound }
        }
        for r in Self.matches(Self.introducedName, in: text, group: 1) where Self.isGivenName(String(text[r]).dropFirst()) { add(r, .name) }
        for (r, k) in Self.tagged(text) { add(r, k) }
        for r in Self.matches(Self.doctorPattern, in: text, group: 0) where Self.isDoctor(text, r) { add(r, .doctor) }
        for r in Self.matches(Self.hospitalPattern, in: text, group: 1) { add(r, .hospital) }

        // Codes are numbered in reading order, then replaced from the end so earlier ranges stay valid.
        let ordered = found.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let codes = ordered.map { code(for: String(text[$0.range]), kind: $0.kind) }
        var out = text
        for (f, c) in zip(ordered, codes).reversed() { out.replaceSubrange(f.range, with: c) }
        return out
    }

    private mutating func code(for original: String, kind: Kind) -> String {
        if let e = entries.first(where: { $0.original == original && $0.kind == kind }) { return e.code }
        let code = "[\(kind.rawValue)\(entries.filter { $0.kind == kind }.count + 1)]"
        entries.append(Entry(code: code, original: original, kind: kind))
        return code
    }

    // MARK: Restoring

    /// The answer with the originals back. Codes the model wrote with other brackets count too; a code
    /// that was never given out is dropped. While streaming, a half-written code at the end waits.
    func restore(_ text: String, streaming: Bool = false) -> String {
        var s = text
        if streaming, let open = s.lastIndex(where: { "[［【〔".contains($0) }), !s[open...].contains(where: { "]］】〕".contains($0) }),
           s.distance(from: open, to: s.endIndex) <= 6 {
            s = String(s[..<open])
        }
        let kinds = Kind.allCases.map(\.rawValue).joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: "[\\[［【〔](\(kinds))(\\d+)[\\]］】〕]") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let code = "[\(ns.substring(with: m.range(at: 1)))\(ns.substring(with: m.range(at: 2)))]"
            out += entries.first { $0.code == code }?.original ?? ""
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    // MARK: Finders

    private static let titles = "医生|大夫|主任|教授|医师|护士长|护士|院长"
    private static let hospitalSuffix = "医院|卫生院|诊所|卫生服务中心|卫生室|门诊部|医学中心|体检中心|透析中心|保健院"

    /// (pattern, kind, capture group to mask).
    private static let patterns: [(String, Kind, Int)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, .email, 0),
        // 医保卡号是 12345678: the number after its name.
        (#"(?:身份证号码?|身份证|护照号码?|护照)\s*(?:是|为|：|:)?\s*([A-Za-z0-9]{6,})"#, .idNumber, 1),
        (#"(?:医保卡号|社保卡号|医保号|社保号|病历号|住院号|门诊号|就诊卡号|就诊号|银行卡号?|会员号|卡号)\s*(?:是|为|：|:)?\s*([A-Za-z0-9]{5,})"#, .number, 1),
        // Digit boundaries, not \b: Chinese characters count as word characters next to a number.
        (#"(?<![\dXx])\d{17}[\dXx](?![\dXx])"#, .idNumber, 0),
        (#"(?<!\d)\d{16,19}(?!\d)"#, .number, 0),
        (#"(?<!\d)(?:\+?86[- ]?)?1[3-9]\d(?:[- ]?\d{4}){2}(?!\d)"#, .phone, 0),
        (#"(?<![\d.])0\d{2,3}-?\d{7,8}(?!\d)"#, .phone, 0),
        // 文三路90号, 张杨路1500号3栋201室, 阳光小区5栋302.
        (#"[[\p{Han}A-Za-z0-9]--[去到在从回找进做住的了是我你他她们个家]]{2,10}?(?:路|街|大道|大街|巷|弄|胡同)\d+(?:-\d+)?号(?:院)?(?:\d+(?:号楼|栋|幢|座|单元|楼|层|室|号))*\d*"#, .address, 0),
        (#"[\p{Han}--[去到在从回找进做住的了是我你他她们个家]]{2,6}?(?:小区|花园|公寓|新村|大厦|家园|苑)\d+(?:号楼|栋|幢|座|单元|室|号)(?:\d+(?:号楼|栋|幢|座|单元|楼|层|室|号))*\d*"#, .address, 0),
        (#"(?<!\d)\d+(?:号楼|栋|幢)\d+(?:单元)?\d*室?"#, .address, 0),
    ]

    private static let surname = "(?:欧阳|司马|上官|诸葛|[王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔汤])"
    /// 王医生, 李明主任: a surname, up to two more characters, a title.
    private static let doctorPattern = surname + "\\p{Han}{0,2}?(?:\(titles))"
    /// Characters that end a name: what usually comes right after one (verbs, time words, body words).
    private static let afterName = "打说让在是的了最今昨明也都很还要会想有吃喝去来做跑走睡就和跟给被把时候血压糖脂肾心肺肝胃肠科内外病症管专主治床班诊家庭社区个这那哪位一二三四五六七八九十日天末每老总经常一直已刚才前后"
    /// 我是王建国, 我叫晓林, 我女儿小美, 我老公张伟: the name after the words that introduce one.
    private static let introducedName = "(?:我是|我叫|名字是|名字叫|我(?:的)?(?:女儿|儿子|老公|老婆|妻子|丈夫|爱人|先生|太太|妈妈|妈|爸爸|爸|母亲|父亲|爷爷|奶奶|外婆|外公|姥姥|姥爷|哥哥|姐姐|弟弟|妹妹|孩子|孙子|孙女|朋友|同事|邻居|室友|同学))\\s*(" + surname + "[\\p{Han}--[\(afterName)]]{1,2}|[小阿][\\p{Han}--[\(afterName)]])"

    private static func isGivenName(_ s: Substring) -> Bool { s.unicodeScalars.allSatisfy { !notGivenName.contains($0) } }
    /// Words that make 「高血压医生」 or 「肾内科主任」 a kind of doctor rather than a person.
    private static let notGivenName = CharacterSet(charactersIn: "血压糖脂肾心肺肝胃肠科内外病症管专主治床班诊家庭社区的个这那哪位一二三四五六七八九十日天末")

    /// Words whose second character is also a surname: 「对方医生」 is the other person's doctor, not Dr 方.
    private static let endsInSurname: Set<String> = ["对方", "处方", "地方", "双方", "药方", "配方", "官方", "一方", "东方", "西方", "南方", "北方",
                                                     "多方", "前方", "后方", "上方", "下方", "远方", "偏方", "秘方", "比方", "大方", "病史", "历史",
                                                     "偏高", "提高", "最高", "升高", "增高", "太高", "较高", "过高", "很高", "更高", "身高",
                                                     "责任", "信任", "担任", "长江", "黄金", "结石", "蛋白", "明白", "空白"]

    private static func isDoctor(_ text: String, _ r: Range<String.Index>) -> Bool {
        let s = String(text[r])
        guard let t = s.range(of: titles, options: .regularExpression) else { return false }
        if r.lowerBound > text.startIndex {
            let before = String(text[text.index(before: r.lowerBound)]) + String(s.prefix(1))
            if endsInSurname.contains(before) { return false }
        }
        return s[s.startIndex..<t.lowerBound].dropFirst().unicodeScalars.allSatisfy { !notGivenName.contains($0) }
    }

    /// A named hospital the tagger missed. Group 1 is the name with its suffix; generic words
    /// (大医院, 社区医院, 附近的诊所) are not names.
    private static let hospitalPattern = "([[\\p{Han}A-Za-z0-9]--[去到在从回找进做住的了是我你他她们个家]]{2,12}?(?:\(hospitalSuffix)))"
    private static let genericHospital = ["大", "小", "社区", "附近", "附近的", "当地", "本地", "三甲", "二甲", "正规", "公立", "私立", "民营", "专科", "综合",
                                          "这", "那", "哪", "一", "什么", "好", "普通", "大型", "小型", "中", "中西医结合", "口腔", "眼科", "儿童",
                                          "肿瘤", "精神", "妇幼", "妇产", "骨科", "康复", "人民", "医科", "门口", "楼下", "小区门口", "小区"]

    private static func matches(_ pattern: String, in text: String, group: Int) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let isHospital = pattern == hospitalPattern
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let r = Range(m.range(at: group), in: text) else { return nil }
            if isHospital {
                let name = String(text[r])
                let prefix = name.replacingOccurrences(of: hospitalSuffix, with: "", options: .regularExpression)
                if prefix.count < 2 || genericHospital.contains(prefix) { return nil }
            }
            return r
        }
    }

    /// Person names and hospitals as Apple's name tagger sees them. Places stay: a city is not a person.
    private static func tagged(_ text: String) -> [(Range<String.Index>, Kind)] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(.simplifiedChinese, range: text.startIndex..<text.endIndex)
        var out: [(Range<String.Index>, Kind)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            let word = String(text[r])
            switch tag {
            case .personalName?:
                out.append((r, word.range(of: titles, options: .regularExpression) != nil ? .doctor : .name))
            case .organizationName? where word.range(of: hospitalSuffix + "|医科大学|附属", options: .regularExpression) != nil:
                out.append((r, .hospital))
            default: break
            }
            return true
        }
        return out
    }
}
