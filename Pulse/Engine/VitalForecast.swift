import Foundation

// Where home blood pressure and glucose are heading. The forecast works on weekly averages: a trend
// fitted to the recent weeks, carried forward with damping (trends rarely keep going in a straight
// line) and shown as a range that widens the further out it goes and the noisier the weeks have been.
// It never predicts a single reading, so it cannot be used to time or dose medication or insulin —
// the card says so — and when the trend heads past a care threshold it points to the doctor.

struct TrendForecast: Equatable {
    struct Week: Equatable {
        var start: Date
        var mid: Double
        var low: Double
        var high: Double
        var projected: Bool
    }
    enum Direction: Equatable { case rising, falling, steady }

    /// Observed weeks, then the projected ones.
    var weeks: [Week]
    var direction: Direction
    /// The last projected week.
    var end: Week { weeks.last! }
    /// The last observed week.
    var latest: Week { weeks.last { !$0.projected }! }
}

struct BloodPressureForecast: Equatable {
    var systolic: TrendForecast
    var diastolic: TrendForecast
    var message: String
    /// The trend leads to or stays above the home threshold (135/85).
    var needsDoctor: Bool
}

struct GlucoseForecast: Equatable {
    var mean: TrendForecast
    /// What is forecast: 空腹血糖 from fasting fingersticks, or 平均血糖 from a CGM.
    var measure: String
    /// The line drawn on the chart (7.0 fasting, 8.6 all-day mean ≈ GMI 7%).
    var threshold: Double
    var message: String
    var needsDoctor: Bool
}

enum VitalForecaster {
    /// Weeks looked back on and ahead.
    static let history = 8, horizon = 4
    /// Each further week keeps this share of the trend.
    static let damping = 0.8
    /// 80% range: wide enough to be honest, narrow enough to say something.
    static let z = 1.28
    static let caveat = "这是按近几周平均值推算的大致范围，不代表某一次测量，也不能用来调整药物或胰岛素。"

    /// Weekly means over the last `history` weeks; weeks with fewer than `minPerWeek` readings are left out.
    static func weekly(_ points: [(time: Date, value: Double)], now: Date, minPerWeek: Int) -> [(start: Date, mean: Double)] {
        let thisWeek = now.startOfDay.weekStart
        return (1...history).reversed().compactMap { k -> (Date, Double)? in
            let start = thisWeek.adding(days: -7 * k)
            let xs = points.filter { $0.time >= start && $0.time < start.adding(days: 7) }.map(\.value)
            guard xs.count >= minPerWeek, let m = Stats.mean(xs) else { return nil }
            return (start, m)
        }
    }

    /// A damped linear trend over the weekly means, carried to the end of the coming `horizon` weeks (this
    /// week and the next three); nil with fewer than 4 weeks, or when the last one is too old to say much.
    static func project(_ series: [(start: Date, mean: Double)], now: Date, minSpread: Double, steadyWithin: Double) -> TrendForecast? {
        let end = now.startOfDay.weekStart.adding(days: 7 * (horizon - 1))
        guard series.count >= 4, let first = series.first?.start, let last = series.last?.start else { return nil }
        let ahead = end.daysSince(last) / 7
        guard ahead >= 1, ahead <= horizon + 3 else { return nil }
        let x = series.map { Double($0.start.daysSince(first)) / 7 }, y = series.map(\.mean)
        let n = Double(series.count), mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        let sxx = x.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let slope = zip(x, y).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / sxx
        let fit = { (xi: Double) in my + slope * (xi - mx) }
        let sd = max(minSpread, sqrt(zip(x, y).map { pow($1 - fit($0), 2) }.reduce(0, +) / max(1, n - 2)))
        let xLast = x.last!, base = fit(xLast)
        var weeks = series.map { TrendForecast.Week(start: $0.start, mid: $0.mean, low: $0.mean, high: $0.mean, projected: false) }
        var carried = 0.0
        for k in 1...ahead {
            carried += slope * pow(damping, Double(k))
            let x0 = xLast + Double(k)
            let half = z * sd * sqrt(1 + 1 / n + pow(x0 - mx, 2) / sxx)
            weeks.append(.init(start: last.adding(days: 7 * k), mid: base + carried, low: base + carried - half, high: base + carried + half, projected: true))
        }
        let change = carried
        let direction: TrendForecast.Direction = abs(change) < steadyWithin ? .steady : (change > 0 ? .rising : .falling)
        return TrendForecast(weeks: weeks, direction: direction)
    }

    static func bloodPressure(_ vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date = .app) -> BloodPressureForecast? {
        let bp = vitals.filter { $0.kind == .bloodPressure }
        // Twice a week is a common home routine; noisy weeks widen the range rather than being dropped.
        let sys = weekly(bp.map { ($0.time, $0.value) }, now: now, minPerWeek: 2)
        let dia = weekly(bp.compactMap { v in v.value2.map { (v.time, $0) } }, now: now, minPerWeek: 2)
        guard let s = project(sys, now: now, minSpread: 2, steadyWithin: 2), let d = project(dia, now: now, minSpread: 1.5, steadyWithin: 1.5) else { return nil }
        let range = "\(s.end.low.noDecimal)–\(s.end.high.noDecimal) / \(d.end.low.noDecimal)–\(d.end.high.noDecimal) mmHg"
        let when = s.end.start.formatted(.dateTime.month().day())
        let target = "\(p.bpTargetSys)/\(p.bpTargetDia)"
        let above = s.end.mid > Double(p.bpTargetSys) || d.end.mid > Double(p.bpTargetDia)
        let home = s.end.mid >= 135 || d.end.mid >= 85
        let message: String = switch s.direction {
        case .rising: "按最近几周的变化，到 \(when) 那周，家庭血压平均可能升到 \(range)" + (above ? "，高于目标 \(target)。" : "。")
        case .falling: "按最近几周的变化，到 \(when) 那周，家庭血压平均可能降到 \(range)" + (above ? "，仍高于目标 \(target)。" : "，继续保持现在的做法。")
        case .steady: "最近几周大致平稳，到 \(when) 那周家庭血压平均可能在 \(range)" + (above ? "，仍高于目标 \(target)。" : "，在目标以内。")
        }
        return BloodPressureForecast(systolic: s, diastolic: d,
                                     message: message + (home ? "复诊时带上记录和医生讨论。" : ""), needsDoctor: home)
    }

    static func glucose(_ vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date = .app) -> GlucoseForecast? {
        let g = vitals.filter { $0.kind == .glucose }
        // One measure throughout: fasting fingersticks, or a CGM's all-day readings. Mixed, a change of
        // meter would read as a trend.
        // Fasting checks are often once or twice a week; a sparse week only widens the range.
        let fasting = weekly(g.filter { $0.context == .fasting }.map { ($0.time, $0.value) }, now: now, minPerWeek: 1)
        let cgm = weekly(g.filter { $0.context == .random }.map { ($0.time, $0.value) }, now: now, minPerWeek: 4 * 24 * 3)
        let (measure, threshold, m): (String, Double, TrendForecast)
        if let f = project(cgm, now: now, minSpread: 0.2, steadyWithin: 0.3) {
            (measure, threshold, m) = ("平均血糖", 8.6, f)
        } else if let f = project(fasting, now: now, minSpread: 0.2, steadyWithin: 0.3) {
            (measure, threshold, m) = ("空腹血糖", 7.0, f)
        } else {
            return nil
        }
        let range = "\(m.end.low.oneDecimal)–\(m.end.high.oneDecimal) mmol/L"
        let when = m.end.start.formatted(.dateTime.month().day())
        let high = m.end.mid > threshold
        let low = m.end.low < p.glucoseLow + 1
        var message: String = switch m.direction {
        case .rising: "按最近几周的变化，到 \(when) 那周，\(measure)平均可能升到 \(range)。"
        case .falling: "按最近几周的变化，到 \(when) 那周，\(measure)平均可能降到 \(range)。"
        case .steady: "最近几周大致平稳，到 \(when) 那周\(measure)平均可能在 \(range)。"
        }
        if high { message += "高于常用目标 \(threshold.oneDecimal) mmol/L，和医生一起看看最近的饮食、运动和作息。" }
        else if low && m.direction == .falling { message += "接近低血糖范围，留意不适并及时测量，需要时联系医生。" }
        return GlucoseForecast(mean: m, measure: measure, threshold: threshold, message: message,
                               needsDoctor: high || (low && m.direction == .falling))
    }
}

// MARK: - The next hour

// Glucose from a CGM: the current rate of change, damped as it goes (a rise or fall rarely keeps its
// pace for an hour), with a range calibrated on this person's own past: the same predictor is run on
// the last week of readings, at moments changing about as fast as now, and its errors at each horizon
// give the band — so the swings after meals do not widen a quiet hour. It is an early warning of a
// coming low or high, as CGM "soon" alerts are — never a number to dose insulin by, which the card says.
// Blood pressure is measured now and then, not continuously, so its next hour is what this person's
// readings at that time of day have been, shifted part of the way toward a reading taken in the last hours.

struct NextHourForecast: Equatable {
    struct Point: Equatable {
        var minutes: Int
        var mid: Double
        var low: Double
        var high: Double
    }
    enum Alert: Equatable {
        /// The range reaches below the low line within `minutes`.
        case lowSoon(minutes: Int)
        case highSoon(minutes: Int)
    }
    var from: Date
    var now: Double
    /// 15, 30, 45 and 60 minutes ahead.
    var points: [Point]
    /// mmol/L per minute (glucose) over the last half hour.
    var rate: Double?
    var alert: Alert?
    var message: String
    var end: Point { points.last! }
}

struct BPNextHour: Equatable {
    var systolic: NextHourForecast
    var diastolic: NextHourForecast
    /// Readings at this time of day it was based on.
    var basis: Int
    var message: String
}

enum NextHourForecaster {
    static let horizons = [15, 30, 45, 60]
    /// Minutes for a rate of change to fade (e^-t/τ).
    static let fade = 30.0
    static let caveat = "这是按最近的变化推算的范围，用于提前留意，不能用来计算胰岛素或药物剂量。"

    /// The damped change after `t` minutes at `rate` per minute.
    static func carried(_ rate: Double, _ t: Double) -> Double { rate * fade * (1 - exp(-t / fade)) }

    /// Least-squares slope (per minute) of readings in the half hour up to `at`; nil with fewer than 3.
    static func rate(_ pts: [(time: Date, value: Double)], at: Date) -> Double? {
        let w = pts.filter { $0.time <= at && $0.time > at.addingTimeInterval(-31 * 60) }
        guard w.count >= 3 else { return nil }
        let x = w.map { $0.time.timeIntervalSince(at) / 60 }, y = w.map(\.value)
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        let sxx = x.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        return sxx > 0 ? zip(x, y).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / sxx : nil
    }

    /// CGM readings only: the source of the next hour has to be continuous.
    static func cgm(_ vitals: [VitalPoint]) -> [(time: Date, value: Double)] {
        vitals.filter { $0.kind == .glucose && $0.context == .random }.map { ($0.time, $0.value) }.sorted { $0.time < $1.time }
    }

    static func glucose(_ vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date = .app) -> NextHourForecast? {
        let pts = cgm(vitals)
        guard let last = pts.last, now.timeIntervalSince(last.time) <= 20 * 60, let r = rate(pts, at: last.time) else { return nil }
        // Calibrate the band on the last week: run the same predictor every hour and keep its errors at the
        // moments whose rate was within 0.01/min of now's. Errors keep their sign: an unlogged meal only
        // pushes glucose up, so it widens the band above, not below.
        var errors: [Int: [Double]] = [:]
        let byTime = Dictionary(pts.map { (Int($0.time.timeIntervalSince1970 / 300), $0.value) }, uniquingKeysWith: { a, _ in a })
        for o in pts where o.time >= last.time.adding(days: -7) && o.time <= last.time.addingTimeInterval(-3600)
            && Int(o.time.timeIntervalSince1970) % 3600 < 900 {
            guard let ro = rate(pts, at: o.time), abs(ro - r) <= 0.01 else { continue }
            for h in horizons {
                let key = Int(o.time.addingTimeInterval(Double(h) * 60).timeIntervalSince1970 / 300)
                if let actual = byTime[key] ?? byTime[key + 1] ?? byTime[key - 1] {
                    errors[h, default: []].append(actual - (o.value + carried(ro, Double(h))))
                }
            }
        }
        let points = horizons.map { h -> NextHourForecast.Point in
            let e = errors[h] ?? []
            // 80%: the 10th and 90th percentile errors, at least ±0.4. Too few past cases: a conservative
            // band that grows with time.
            let spread: (below: Double, above: Double) = if e.count >= 20, let q10 = Stats.quantile(e, 0.1), let q90 = Stats.quantile(e, 0.9) {
                (max(0.4, -q10), max(0.4, q90))
            } else {
                (1.28 * (0.4 + 0.025 * Double(h)), 1.28 * (0.4 + 0.025 * Double(h)))
            }
            let mid = max(2.2, last.value + carried(r, Double(h)))
            return .init(minutes: h, mid: mid, low: max(2.2, mid - spread.below), high: mid + spread.above)
        }
        let steady = abs(r) < 0.03
        // A steady reading warns only when its own line reaches the low; the lower edge counts once it falls.
        let lowAt = points.first { $0.mid < p.glucoseLow || (!steady && r < 0 && $0.low < p.glucoseLow) }?.minutes
        let highAt = points.first { $0.mid > p.glucoseHigh }?.minutes
        // Only a coming change: a reading already out of range is the abnormal value itself.
        var alert: NextHourForecast.Alert?
        if last.value >= p.glucoseLow, let m = lowAt { alert = .lowSoon(minutes: m) }
        else if last.value <= p.glucoseHigh, let m = highAt { alert = .highSoon(minutes: m) }
        let range = "\(points.last!.low.oneDecimal)–\(points.last!.high.oneDecimal) mmol/L"
        let move = steady ? "基本平稳" : (r > 0 ? (r >= 0.1 ? "上升较快" : "在上升") : (r <= -0.1 ? "下降较快" : "在下降"))
        let message: String = switch alert {
        case .lowSoon(let m)?: "血糖\(move)，约 \(m) 分钟内可能低于 \(p.glucoseLow.oneDecimal)。留意心慌、出汗、手抖，按医生给你的低血糖处理方案做，需要时先测一次指尖血糖确认。"
        case .highSoon(let m)?: "血糖\(move)，约 \(m) 分钟后可能高于 \(p.glucoseHigh.oneDecimal)。可以回想一下这一餐吃了什么，饭后散步 10–15 分钟通常有帮助。"
        case nil: "血糖\(move)，1 小时后大约在 \(range)。"
        }
        return NextHourForecast(from: last.time, now: last.value, points: points, rate: r, alert: alert, message: message)
    }

    static func bloodPressure(_ vitals: [VitalPoint], now: Date = .app) -> BPNextHour? {
        let bp = vitals.filter { $0.kind == .bloodPressure && $0.time >= now.adding(days: -60) && $0.time <= now }
        // Readings within 90 minutes of a time of day, on earlier days.
        func around(_ t: Date) -> [VitalPoint] {
            let m = t.minutesOfDay
            return bp.filter { v in
                let d = abs(v.time.minutesOfDay - m)
                return min(d, 1440 - d) <= 90 && !v.time.isSameDay(now)
            }
        }
        func stats(_ xs: [Double]) -> (mean: Double, sd: Double)? {
            guard xs.count >= 4, let m = Stats.mean(xs) else { return nil }
            return (m, max(3, Stats.sd(xs) ?? 5))
        }
        let target = now.addingTimeInterval(3600)
        let basis = around(target)
        guard let s = stats(basis.map(\.value)), let d = stats(basis.compactMap(\.value2)) else { return nil }
        // A reading in the last 3 hours keeps half of its difference from what is usual at its own time.
        var shift = (sys: 0.0, dia: 0.0)
        if let recent = bp.filter({ $0.time > now.addingTimeInterval(-3 * 3600) }).max(by: { $0.time < $1.time }),
           let rs = stats(around(recent.time).map(\.value)), let rd = stats(around(recent.time).compactMap(\.value2)) {
            shift = ((recent.value - rs.mean) / 2, ((recent.value2 ?? rd.mean) - rd.mean) / 2)
        }
        func line(_ mean: Double, _ sd: Double, _ now: Double) -> NextHourForecast {
            let pts = horizons.map { h in
                NextHourForecast.Point(minutes: h, mid: mean, low: mean - 1.28 * sd, high: mean + 1.28 * sd)
            }
            return NextHourForecast(from: Date.app, now: now, points: pts, rate: nil, alert: nil, message: "")
        }
        let sys = line(s.mean + shift.sys, s.sd, s.mean), dia = line(d.mean + shift.dia, d.sd, d.mean)
        let range = "\(sys.end.low.noDecimal)–\(sys.end.high.noDecimal) / \(dia.end.low.noDecimal)–\(dia.end.high.noDecimal) mmHg"
        let high = sys.end.mid >= 135 || dia.end.mid >= 85
        let message = "按你在这个时段的 \(basis.count) 次读数，如果 1 小时内测量，血压大约在 \(range)。"
            + (high ? "这个时段通常偏高，测量前先安静坐 5 分钟。" : "")
        return BPNextHour(systolic: sys, diastolic: dia, basis: basis.count, message: message)
    }
}

extension NextHourForecaster {
    /// After a meal, that meal's usual curve (from the person's past meals) says more than the slope:
    /// the next hour follows it, anchored at the current reading.
    static func following(_ f: NextHourForecast, meal p: MealPrediction, eatenAt: Date, label: String, profile pr: ProfileSnapshot) -> NextHourForecast {
        let since = f.from.timeIntervalSince(eatenAt) / 60
        // The meal curve at any minute (15-minute steps, linear in between, flat after 3 hours).
        func at(_ m: Double) -> MealPrediction.Point {
            let pts = p.points
            guard m > 0 else { return pts[0] }
            guard let j = pts.firstIndex(where: { Double($0.minutes) >= m }) else { return pts[pts.count - 1] }
            guard j > 0 else { return pts[0] }
            let a = pts[j - 1], b = pts[j], w = (m - Double(a.minutes)) / Double(b.minutes - a.minutes)
            func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * w }
            return .init(minutes: Int(m), mid: mix(a.mid, b.mid), low: mix(a.low, b.low), high: mix(a.high, b.high))
        }
        let base = at(since)
        let points = horizons.map { h -> NextHourForecast.Point in
            let q = at(since + Double(h))
            let mid = f.now + (q.mid - base.mid)
            let half = max(q.high - q.mid, 0.4 + 0.015 * Double(h))
            return .init(minutes: h, mid: mid, low: max(2.2, mid - half), high: mid + half)
        }
        var alert: NextHourForecast.Alert?
        if f.now >= pr.glucoseLow, let m = points.first(where: { $0.low < pr.glucoseLow })?.minutes { alert = .lowSoon(minutes: m) }
        else if f.now <= pr.glucoseHigh, let m = points.first(where: { $0.mid > pr.glucoseHigh })?.minutes { alert = .highSoon(minutes: m) }
        let end = points[points.count - 1]
        let peakAt = eatenAt.addingTimeInterval(Double(p.peakMinutes) * 60)
        let when = "\(Clock.text(eatenAt.minutesOfDay)) \(label)后"
        let message = (peakAt > f.from.addingTimeInterval(5 * 60)
            ? "\(when)还在上升，按你过去的\(label)，预计 \(Clock.text(peakAt.minutesOfDay)) 前后到达高点，"
            : "\(when)高点已过，") + "1 小时后大约在 \(end.low.oneDecimal)–\(end.high.oneDecimal) mmol/L。"
        return NextHourForecast(from: f.from, now: f.now, points: points, rate: f.rate, alert: alert, message: message)
    }
}
