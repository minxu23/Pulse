import Foundation

// MARK: - Personal basics

enum Sex: String, Codable, CaseIterable, Identifiable {
    case female, male, unspecified
    var id: String { rawValue }
    var label: String {
        switch self {
        case .female: "女"
        case .male: "男"
        case .unspecified: "不透露"
        }
    }
}

enum ActivityLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary, light, moderate, active, athlete
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sedentary: "久坐少动"
        case .light: "偶尔运动"
        case .moderate: "规律运动"
        case .active: "经常训练"
        case .athlete: "系统训练"
        }
    }
    var detail: String {
        switch self {
        case .sedentary: "每周运动少于 30 分钟"
        case .light: "每周运动 30–90 分钟"
        case .moderate: "每周运动 90–180 分钟"
        case .active: "每周运动 3–5 小时"
        case .athlete: "每周训练 5 小时以上，有专项目标"
        }
    }
    /// A sensible starting weekly aerobic target in minutes.
    var startingWeeklyMinutes: Int {
        switch self {
        case .sedentary: 60
        case .light: 90
        case .moderate: 150
        case .active: 210
        case .athlete: 300
        }
    }
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

enum HealthCondition: String, Codable, CaseIterable, Identifiable {
    case hypertension, coronaryDisease, arrhythmia, heartFailure
    case diabetesT1, diabetesT2, prediabetes, ckd
    case thyroid, sleepApnea, respiratory, anemia, pregnancy, jointPain, mentalHealth
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hypertension: "高血压"
        case .coronaryDisease: "冠心病"
        case .arrhythmia: "心律失常 / 房颤"
        case .heartFailure: "心力衰竭"
        case .diabetesT1: "1 型糖尿病"
        case .diabetesT2: "2 型糖尿病"
        case .prediabetes: "糖尿病前期"
        case .ckd: "慢性肾病"
        case .thyroid: "甲状腺疾病"
        case .sleepApnea: "睡眠呼吸暂停（已确诊）"
        case .respiratory: "哮喘 / 慢阻肺"
        case .anemia: "贫血"
        case .pregnancy: "妊娠期"
        case .jointPain: "关节或肌肉损伤"
        case .mentalHealth: "焦虑 / 抑郁"
        }
    }
    var isCardiovascular: Bool { [.hypertension, .coronaryDisease, .arrhythmia, .heartFailure].contains(self) }
    var isDiabetes: Bool { [.diabetesT1, .diabetesT2].contains(self) }
    /// Conditions where a quick rise in weight usually means retained fluid.
    var watchesFluid: Bool { [.ckd, .heartFailure].contains(self) }
}

enum HREffect: String, Codable {
    case lowers, raises, variable, minimal
    var label: String {
        switch self {
        case .lowers: "可能降低心率"
        case .raises: "可能升高心率"
        case .variable: "可能影响心率"
        case .minimal: "对心率影响通常较小"
        }
    }
}

enum MedicationCategory: String, Codable, CaseIterable, Identifiable {
    case betaBlocker, rateLimitingCCB, antiarrhythmic, otherAntihypertensive
    case thyroid, stimulant, antidepressant, bronchodilator, decongestant
    case insulin, sulfonylurea, otherGlucose, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .betaBlocker: "β 受体阻滞剂"
        case .rateLimitingCCB: "非二氢吡啶类钙通道阻滞剂"
        case .antiarrhythmic: "抗心律失常药"
        case .otherAntihypertensive: "其他降压药"
        case .thyroid: "甲状腺相关药物"
        case .stimulant: "兴奋类 / ADHD 药物"
        case .antidepressant: "抗抑郁 / 抗焦虑药"
        case .bronchodilator: "支气管扩张剂"
        case .decongestant: "含伪麻黄碱的感冒药"
        case .insulin: "胰岛素"
        case .sulfonylurea: "磺脲类 / 格列奈类"
        case .otherGlucose: "其他降糖药"
        case .other: "其他"
        }
    }
    var hrEffect: HREffect {
        switch self {
        case .betaBlocker, .rateLimitingCCB: .lowers
        case .stimulant, .bronchodilator, .decongestant: .raises
        case .antiarrhythmic, .thyroid, .antidepressant: .variable
        default: .minimal
        }
    }
    /// Medications where heart-rate based intensity zones become unreliable.
    var bluntsHeartRate: Bool { self == .betaBlocker || self == .rateLimitingCCB }
    var hypoglycemiaRisk: Bool { self == .insulin || self == .sulfonylurea }
}

enum GoalDirection: String, Codable, CaseIterable, Identifiable {
    case lowerRHR, energy, fitness, event, careAligned
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lowerRHR: "改善静息心率"
        case .energy: "提升日常精力"
        case .fitness: "提升运动能力"
        case .event: "完成运动目标 / 赛事"
        case .careAligned: "配合疾病照护"
        }
    }
    var icon: String {
        switch self {
        case .lowerRHR: "heart"
        case .energy: "bolt"
        case .fitness: "figure.run"
        case .event: "flag.checkered"
        case .careAligned: "cross.case"
        }
    }
}

enum PreferredTime: String, Codable, CaseIterable, Identifiable {
    case morning, noon, evening, flexible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .morning: "早晨"
        case .noon: "午间"
        case .evening: "傍晚 / 晚上"
        case .flexible: "不固定"
        }
    }
}

// MARK: - Measurement

enum RHRSource: String, Codable, CaseIterable, Identifiable {
    case device, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .device: "手表 / 手环"
        case .manual: "晨起手动测量"
        }
    }
    var shortLabel: String { self == .device ? "设备" : "手动" }
}

enum DataSource: String, Codable, CaseIterable {
    case healthKit, cgm, manual, demo
    var label: String {
        switch self {
        case .healthKit: "健康 App"
        case .cgm: "CGM"
        case .manual: "手动"
        case .demo: "示例"
        }
    }
}

enum ContextTag: String, Codable, CaseIterable, Identifiable {
    case illness, highStress, alcohol, lateMeal, lateCaffeine, travel, hardTraining
    case medicationChange, poorSleep, menstrual, heat, altitude, dehydration
    var id: String { rawValue }
    var label: String {
        switch self {
        case .illness: "生病 / 不适"
        case .highStress: "压力大"
        case .alcohol: "饮酒"
        case .lateMeal: "晚餐过晚"
        case .lateCaffeine: "午后咖啡因"
        case .travel: "出差 / 时差"
        case .hardTraining: "高强度训练"
        case .medicationChange: "用药变化"
        case .poorSleep: "睡眠差"
        case .menstrual: "经期"
        case .heat: "高温 / 桑拿"
        case .altitude: "高海拔"
        case .dehydration: "饮水不足"
        }
    }
    var icon: String {
        switch self {
        case .illness: "thermometer.medium"
        case .highStress: "brain.head.profile"
        case .alcohol: "wineglass"
        case .lateMeal: "fork.knife"
        case .lateCaffeine: "cup.and.saucer"
        case .travel: "airplane"
        case .hardTraining: "flame"
        case .medicationChange: "pills"
        case .poorSleep: "moon.zzz"
        case .menstrual: "drop"
        case .heat: "sun.max"
        case .altitude: "mountain.2"
        case .dehydration: "drop.triangle"
        }
    }
    /// Behaviours logged on day D that typically show up in the morning of D+1.
    var actsOnNextMorning: Bool {
        [.alcohol, .lateMeal, .lateCaffeine, .hardTraining, .highStress, .dehydration, .heat].contains(self)
    }
    /// Tags manually chosen from the context picker (others are derived from logs).
    static var pickable: [ContextTag] {
        [.illness, .highStress, .travel, .medicationChange, .poorSleep, .menstrual, .heat, .altitude, .dehydration]
    }
}

// MARK: - Activity & plans

enum WorkoutType: String, Codable, CaseIterable, Identifiable {
    case run, walk, cycle, swim, strength, hiit, yoga, ball, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .run: "跑步"
        case .walk: "步行 / 徒步"
        case .cycle: "骑行"
        case .swim: "游泳"
        case .strength: "力量训练"
        case .hiit: "间歇训练"
        case .yoga: "瑜伽 / 拉伸"
        case .ball: "球类"
        case .other: "其他"
        }
    }
    var icon: String {
        switch self {
        case .run: "figure.run"
        case .walk: "figure.walk"
        case .cycle: "figure.outdoor.cycle"
        case .swim: "figure.pool.swim"
        case .strength: "dumbbell"
        case .hiit: "bolt.heart"
        case .yoga: "figure.yoga"
        case .ball: "figure.basketball"
        case .other: "figure.mixed.cardio"
        }
    }
    var defaultRPE: Int {
        switch self {
        case .walk, .yoga: 3
        case .run, .cycle, .swim: 5
        case .strength, .ball: 6
        case .hiit: 8
        case .other: 4
        }
    }
}

enum Intensity: String, Codable, CaseIterable, Identifiable, Comparable {
    case rest, easy, moderate, hard
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rest: "休息"
        case .easy: "低强度"
        case .moderate: "中等强度"
        case .hard: "较高强度"
        }
    }
    var talkTest: String {
        switch self {
        case .rest: "放松身体，以恢复为主"
        case .easy: "可以轻松对话（RPE 2–3/10）"
        case .moderate: "能说完整句子但无法唱歌（RPE 4–6/10）"
        case .hard: "只能说几个词（RPE 7–8/10）"
        }
    }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: Intensity, rhs: Intensity) -> Bool { lhs.order < rhs.order }
    var lowered: Intensity {
        switch self {
        case .hard: .moderate
        case .moderate: .easy
        default: self
        }
    }
}

enum WorkoutFeeling: String, Codable, CaseIterable, Identifiable {
    case great, good, ok, hard, unwell
    var id: String { rawValue }
    var label: String {
        switch self {
        case .great: "很好"
        case .good: "良好"
        case .ok: "一般"
        case .hard: "吃力"
        case .unwell: "不适"
        }
    }
    var icon: String {
        switch self {
        case .great: "face.smiling.inverse"
        case .good: "face.smiling"
        case .ok: "minus.circle"
        case .hard: "tortoise"
        case .unwell: "exclamationmark.triangle"
        }
    }
}

enum PlanKind: String, Codable, CaseIterable, Identifiable {
    case aerobic, long, quality, strength, mobility, walk, rest, test
    var id: String { rawValue }
    var label: String {
        switch self {
        case .aerobic: "有氧"
        case .long: "长时间有氧"
        case .quality: "强度课"
        case .strength: "力量"
        case .mobility: "灵活性"
        case .walk: "日常活动"
        case .rest: "休息恢复"
        case .test: "能力测试"
        }
    }
    var icon: String {
        switch self {
        case .aerobic: "heart.circle"
        case .long: "road.lanes"
        case .quality: "bolt.heart"
        case .strength: "dumbbell"
        case .mobility: "figure.flexibility"
        case .walk: "figure.walk"
        case .rest: "bed.double"
        case .test: "stopwatch"
        }
    }
    var isTraining: Bool { ![.walk, .rest].contains(self) }
}

enum PlanStatus: String, Codable, CaseIterable, Identifiable {
    case planned, done, partial, skipped
    var id: String { rawValue }
    var label: String {
        switch self {
        case .planned: "待完成"
        case .done: "已完成"
        case .partial: "部分完成"
        case .skipped: "未完成"
        }
    }
    var icon: String {
        switch self {
        case .planned: "circle"
        case .done: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .skipped: "xmark.circle"
        }
    }
}

enum SorenessArea: String, Codable, CaseIterable, Identifiable {
    case none, upper, lower, whole
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "无明显部位"
        case .upper: "上肢 / 背部"
        case .lower: "下肢"
        case .whole: "全身"
        }
    }
}

// MARK: - Vitals & events

enum VitalKind: String, Codable, CaseIterable, Identifiable {
    case bloodPressure, glucose, spo2, weight, temperature, heartRate, lactate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bloodPressure: "血压"
        case .glucose: "血糖"
        case .spo2: "血氧"
        case .weight: "体重"
        case .temperature: "体温"
        case .heartRate: "即时心率"
        case .lactate: "血乳酸"
        }
    }
    var unit: String {
        switch self {
        case .bloodPressure: "mmHg"
        case .glucose, .lactate: "mmol/L"
        case .spo2: "%"
        case .weight: "kg"
        case .temperature: "°C"
        case .heartRate: "bpm"
        }
    }
    var icon: String {
        switch self {
        case .bloodPressure: "gauge.with.dots.needle.33percent"
        case .glucose: "drop.fill"
        case .spo2: "lungs"
        case .weight: "scalemass"
        case .temperature: "thermometer"
        case .heartRate: "heart.text.square"
        case .lactate: "testtube.2"
        }
    }
}

enum MeasureContext: String, Codable, CaseIterable, Identifiable {
    case morning, fasting, preMeal, postMeal, preExercise, duringExercise, postExercise, bedtime, night, symptom, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .morning: "晨起"
        case .fasting: "空腹"
        case .preMeal: "餐前"
        case .postMeal: "餐后 2 小时"
        case .preExercise: "运动前"
        case .duringExercise: "运动中"
        case .postExercise: "运动后"
        case .bedtime: "睡前"
        case .night: "夜间"
        case .symptom: "出现症状时"
        case .random: "随机"
        }
    }
}

enum Symptom: String, Codable, CaseIterable, Identifiable {
    case chestPain, fainting, breathless, palpitations, dizziness, unusualFatigue, swelling, hypoSymptoms
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chestPain: "胸痛 / 胸闷"
        case .fainting: "晕厥或几乎晕倒"
        case .breathless: "明显气短"
        case .palpitations: "心悸 / 心跳不规律感"
        case .dizziness: "头晕"
        case .unusualFatigue: "异常疲劳"
        case .swelling: "下肢水肿"
        case .hypoSymptoms: "疑似低血糖（出汗、手抖、心慌）"
        }
    }
    var severity: Severity {
        switch self {
        case .chestPain, .fainting, .breathless: .urgent
        case .palpitations, .dizziness, .swelling, .hypoSymptoms: .consult
        case .unusualFatigue: .verify
        }
    }
}

enum Severity: String, Codable, CaseIterable, Identifiable, Comparable {
    case info, verify, consult, urgent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .info: "提示"
        case .verify: "需要核实"
        case .consult: "建议咨询医生"
        case .urgent: "紧急"
        }
    }
    var icon: String {
        switch self {
        case .info: "info.circle"
        case .verify: "exclamationmark.magnifyingglass"
        case .consult: "stethoscope"
        case .urgent: "exclamationmark.triangle.fill"
        }
    }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.order < rhs.order }
}

enum EventStatus: String, Codable, CaseIterable, Identifiable {
    case open, rechecking, consulted, resolved, dismissed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .open: "待处理"
        case .rechecking: "复测中"
        case .consulted: "已咨询 / 就医"
        case .resolved: "已解决"
        case .dismissed: "已排除（测量问题等）"
        }
    }
    var isActive: Bool { self == .open || self == .rechecking }
}

enum EventKind: String, Codable, CaseIterable {
    case rhrSustainedRise, rhrHigh, rhrLow, bpCrisis, bpHigh, bpLow
    case glucoseLow, glucoseSevereLow, glucoseHigh, spo2Low, irregularRhythm, deviceHRAlert
    case weightGain, labAbnormal, symptom, other
    var label: String {
        switch self {
        case .rhrSustainedRise: "静息心率持续升高"
        case .rhrHigh: "静息心率偏高"
        case .rhrLow: "静息心率偏低"
        case .bpCrisis: "血压显著升高"
        case .bpHigh: "血压高于目标"
        case .bpLow: "血压偏低"
        case .glucoseLow: "低血糖"
        case .glucoseSevereLow: "严重低血糖"
        case .glucoseHigh: "高血糖"
        case .spo2Low: "夜间血氧偏低"
        case .irregularRhythm: "不规则心律提示"
        case .deviceHRAlert: "设备心率提醒"
        case .weightGain: "体重快速上升"
        case .labAbnormal: "化验结果需要关注"
        case .symptom: "身体症状"
        case .other: "其他"
        }
    }
    var icon: String {
        switch self {
        case .rhrSustainedRise, .rhrHigh, .rhrLow, .deviceHRAlert: "heart.text.square"
        case .bpCrisis, .bpHigh, .bpLow: "gauge.with.dots.needle.67percent"
        case .glucoseLow, .glucoseSevereLow, .glucoseHigh: "drop.fill"
        case .spo2Low: "lungs"
        case .irregularRhythm: "waveform.path.ecg"
        case .weightGain: "scalemass"
        case .labAbnormal: "testtube.2"
        case .symptom: "person.fill.questionmark"
        case .other: "exclamationmark.circle"
        }
    }
}

// MARK: - Modules & care

enum ProModule: String, Codable, CaseIterable, Identifiable {
    case marathon, cardioCare, diabetesCare
    var id: String { rawValue }
    var label: String {
        switch self {
        case .marathon: "专项运动支持"
        case .cardioCare: "心血管健康"
        case .diabetesCare: "血糖管理"
        }
    }
    var subtitle: String {
        switch self {
        case .marathon: "全马等明确目标：评估、计划、补给与复盘"
        case .cardioCare: "按专业照护要求协调指标、症状、用药与随访"
        case .diabetesCare: "血糖、饮食、运动、补给与 CGM 数据关联管理"
        }
    }
    var icon: String {
        switch self {
        case .marathon: "flag.checkered"
        case .cardioCare: "heart.text.square"
        case .diabetesCare: "drop.fill"
        }
    }
}

enum ApneaStatus: String, Codable, CaseIterable, Identifiable {
    case unknown, lowConcern, suspected, evaluating, diagnosed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unknown: "未评估"
        case .lowConcern: "暂无明显线索"
        case .suspected: "存在线索，待专业评估"
        case .evaluating: "评估 / 睡眠检查中"
        case .diagnosed: "已确诊睡眠呼吸暂停"
        }
    }
}

enum ApneaTreatment: String, Codable, CaseIterable, Identifiable {
    case none, cpap, oralAppliance, positional, lifestyle, surgery, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "暂无治疗"
        case .cpap: "正压通气（CPAP）"
        case .oralAppliance: "口腔矫治器"
        case .positional: "体位治疗"
        case .lifestyle: "体重与生活方式管理"
        case .surgery: "手术治疗"
        case .other: "其他"
        }
    }
}

enum CareArea: String, Codable, CaseIterable, Identifiable {
    case general, sleep, cardio, diabetes, kidney, training
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: "综合"
        case .sleep: "睡眠呼吸"
        case .cardio: "心血管"
        case .diabetes: "糖尿病"
        case .kidney: "肾脏"
        case .training: "专项运动"
        }
    }
    var icon: String {
        switch self {
        case .general: "list.clipboard"
        case .sleep: "bed.double"
        case .cardio: "heart"
        case .diabetes: "drop"
        case .kidney: "testtube.2"
        case .training: "figure.run"
        }
    }
}

enum InsightStatus: String, Codable, CaseIterable, Identifiable {
    case observed, testing, confirmed, notSupported
    var id: String { rawValue }
    var label: String {
        switch self {
        case .observed: "观察到的关联"
        case .testing: "个人验证中"
        case .confirmed: "已确认"
        case .notSupported: "未得到支持"
        }
    }
}

enum MealKind: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack, exerciseFuel
    var id: String { rawValue }
    var label: String {
        switch self {
        case .breakfast: "早餐"
        case .lunch: "午餐"
        case .dinner: "晚餐"
        case .snack: "加餐"
        case .exerciseFuel: "运动补给"
        }
    }
    var icon: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon"
        case .snack: "carrot"
        case .exerciseFuel: "bolt"
        }
    }
}
