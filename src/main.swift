import AppKit
import ServiceManagement

// ════════════════════════════════════════════════════════════
//  AttentionTimer — 로컬 집중 타이머
//  화면 위에 항상 떠있는 알약. 딴짓하면 빨개지고 기록이 남는다.
// ════════════════════════════════════════════════════════════

let fm = FileManager.default
let appDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".attentiontimer")
let configURL = appDir.appendingPathComponent("config.json")
let logURL    = appDir.appendingPathComponent("events.jsonl")
let posURL    = appDir.appendingPathComponent("position.json")

// ───────────────────────── Config ─────────────────────────

struct Config: Codable {
    var focusMinutes: Double = 25
    var graceSeconds: Double = 6          // 이만큼 넘게 머물러야 '딴짓'으로 인정
    var watchBrowserURL: Bool = true      // 브라우저 탭 URL까지 감시할지
    var logAllSites: Bool = false         // 집중 중 방문한 모든 사이트를 기록에 남길지
    var distractionApps: [String] = [
        "com.kakao.KakaoTalkMac",
        "com.apple.MobileSMS",
        "com.hnc.Discord",
        "com.netflix.Netflix",
        "com.apple.AppStore",
        "com.tencent.xin"
    ]
    var distractionSites: [String] = [
        "youtube.com", "youtu.be", "netflix.com", "twitch.tv",
        "instagram.com", "x.com", "twitter.com", "reddit.com",
        "tiktok.com", "dcinside.com", "fmkorea.com", "ruliweb.com",
        "clien.net", "inven.co.kr", "chzzk.naver.com"
    ]

    enum CodingKeys: String, CodingKey {
        case focusMinutes, graceSeconds, watchBrowserURL, logAllSites, distractionApps, distractionSites
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        focusMinutes     = try c.decodeIfPresent(Double.self,   forKey: .focusMinutes)     ?? d.focusMinutes
        graceSeconds     = try c.decodeIfPresent(Double.self,   forKey: .graceSeconds)     ?? d.graceSeconds
        watchBrowserURL  = try c.decodeIfPresent(Bool.self,     forKey: .watchBrowserURL)  ?? d.watchBrowserURL
        logAllSites      = try c.decodeIfPresent(Bool.self,     forKey: .logAllSites)      ?? d.logAllSites
        distractionApps  = try c.decodeIfPresent([String].self, forKey: .distractionApps)  ?? d.distractionApps
        distractionSites = try c.decodeIfPresent([String].self, forKey: .distractionSites) ?? d.distractionSites
    }

    static func load() -> Config {
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configURL),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            c.save()          // 새로 생긴 설정 키가 파일에도 채워지도록
            return c
        }
        let c = Config()
        c.save()
        return c
    }
    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        try? enc.encode(self).write(to: configURL)
    }
}

// ───────────────────────── Utils ─────────────────────────

func mmss(_ t: TimeInterval) -> String {
    let s = max(0, Int(ceil(t)))
    return String(format: "%d:%02d", s / 60, s % 60)
}
func compactDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s < 60 { return "\(s)초" }
    return "\(s / 60)분"
}
let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.timeZone = .current
    f.formatOptions = [.withInternetDateTime]
    return f
}()
let dayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
}()

// ───────────────────── Distraction watcher ─────────────────────

/// 지금 앞에 있는 앱 / 브라우저 탭이 딴짓인지 판정한다. LLM 없음, 순수 macOS API.
final class Watcher {
    private let scriptQueue = DispatchQueue(label: "attentiontimer.osascript")
    private(set) var cachedURL: String = ""
    private(set) var frontBundle = ""
    private(set) var frontName = ""
    private var lastURLFetch = Date.distantPast
    private var fetching = false
    private let selfBundle = Bundle.main.bundleIdentifier ?? ""

    static let browsers: [String: String] = [
        "com.google.Chrome":            "active tab of front window",
        "com.brave.Browser":            "active tab of front window",
        "com.microsoft.edgemac":        "active tab of front window",
        "company.thebrowser.dia":       "active tab of front window",   // Dia
        "company.thebrowser.Browser":   "active tab of front window",   // Arc
        "com.naver.Whale":              "active tab of front window",
        "com.vivaldi.Vivaldi":          "active tab of front window",
        "com.apple.Safari":             "current tab of front window"
    ]

    struct Verdict { var bad: Bool; var app: String; var detail: String }

    /// 지금 앞에 뭐가 있는지 계속 기록해둔다. (메뉴에서 "이거 추가" 하려면 항상 알고 있어야 함)
    /// 우리 앱 자신은 무시 — 메뉴바 클릭했다고 직전 앱을 잊으면 안 되니까.
    func sample(_ cfg: Config, active: Bool) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let bid = front.bundleIdentifier ?? ""
        if bid == selfBundle || bid.isEmpty { return }
        frontBundle = bid
        frontName = front.localizedName ?? bid
        if cfg.watchBrowserURL, let target = Watcher.browsers[bid] {
            refreshURL(bundleID: bid, target: target, active: active)
        } else {
            cachedURL = ""
        }
    }

    /// URL에서 호스트만 (www. 떼고)
    var currentHost: String {
        guard let h = URL(string: cachedURL)?.host, !h.isEmpty else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    func check(_ cfg: Config) -> Verdict {
        let name = frontName
        if cfg.distractionApps.contains(where: { $0.caseInsensitiveCompare(frontBundle) == .orderedSame }) {
            return Verdict(bad: true, app: name, detail: "")
        }
        let url = cachedURL.lowercased()
        if !url.isEmpty, let hit = cfg.distractionSites.first(where: { url.contains($0.lowercased()) }) {
            return Verdict(bad: true, app: name, detail: hit)
        }
        return Verdict(bad: false, app: name, detail: "")
    }

    private func refreshURL(bundleID: String, target: String, active: Bool) {
        // 집중 중엔 촘촘히, 아니면 느슨하게 (osascript 프로세스 아끼기)
        guard !fetching, Date().timeIntervalSince(lastURLFetch) > (active ? 1.2 : 4.0) else { return }
        fetching = true
        lastURLFetch = Date()
        let src = "tell application id \"\(bundleID)\" to return URL of \(target)"
        scriptQueue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", src]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            var out = ""
            do {
                try p.run()
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                out = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch { out = "" }
            DispatchQueue.main.async {
                self?.cachedURL = out
                self?.fetching = false
            }
        }
    }
}

// ───────────────────────── State ─────────────────────────

enum Phase { case idle, focusing, paused, finished }
enum Mood  { case sleeping, working, angry, happy }

struct PetState {
    var phase: Phase = .idle
    var remaining: TimeInterval = 25 * 60
    var total: TimeInterval = 25 * 60
    var alerting = false
    var alertApp = ""
    var alertDetail = ""
    var alertRunSeconds: TimeInterval = 0
    var bubble = ""                          // 말풍선 대사 (빈 문자열이면 안 띄움)
    var sessionDistracted: TimeInterval = 0
    var sessionWarnings = 0
    var todayWarnings = 0
    var todayDistracted: TimeInterval = 0
    var hovering = false
    var anim: Double = 0
}

// ───────────────────────── Desk pet view ─────────────────────────
//
//   ╭──────────────────╮
//   │   ◔  24:13       │   ← 타이머 (위)
//   ╰──────────────────╯
//     ╭──────────────╮
//     │ 지금 뭐 하는데 │     ← 말풍선
//     ╰───────▽──────╯
//          (╯°□°)╯          ← 전신 캐릭터
//
final class PetView: NSView {
    var state = PetState()
    var onPrimary: () -> Void = {}
    var onReset:   () -> Void = {}
    var onStop:    () -> Void = {}

    // 레이아웃 (창 크기 고정, 바닥 기준)
    static let winW: CGFloat = 280, winH: CGFloat = 212
    private var badgeRect  = NSRect(x: 40, y: 174, width: 200, height: 36)
    private var petRect    = NSRect(x: 101, y: 2, width: 78, height: 104)
    private var bubbleRect = NSRect.zero      // 매 프레임 계산

    private var btnPrimary = NSRect.zero
    private var btnReset   = NSRect.zero
    private var btnStop    = NSRect.zero
    private var cachedKey  = ""            // 말풍선 텍스트 레이아웃 캐시
    private var cachedSize = NSSize.zero
    private var dragOrigin: NSPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?

    // 팔레트
    // 흰 강아지 — 스티커풍 손그림
    private let furC    = NSColor(srgbRed: 0.995, green: 0.99, blue: 0.98, alpha: 1)
    private let furShade = NSColor(srgbRed: 0.90, green: 0.89, blue: 0.87, alpha: 1)
    private let ink     = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.10, alpha: 1)
    private let tongue  = NSColor(srgbRed: 0.95, green: 0.52, blue: 0.55, alpha: 1)

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { state.hovering = true;  needsDisplay = true }
    override func mouseExited(with e: NSEvent)  { state.hovering = false; needsDisplay = true }

    /// 투명한 부분은 클릭이 뒤쪽 앱으로 통과해야 한다 (안 그러면 데스크가 막힌다)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if badgeRect.contains(p) || petRect.contains(p) { return self }
        if !bubbleRect.isEmpty && bubbleRect.contains(p) { return self }
        return nil
    }

    private var mood: Mood {
        if state.alerting { return .angry }
        switch state.phase {
        case .finished: return .happy
        case .focusing: return .working
        default:        return .sleeping
        }
    }
    private var accent: NSColor {
        if state.alerting { return NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1) }
        switch state.phase {
        case .paused:   return NSColor(srgbRed: 0.99, green: 0.76, blue: 0.30, alpha: 1)
        case .finished: return NSColor(srgbRed: 0.45, green: 0.87, blue: 0.65, alpha: 1)
        case .idle:     return NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1)
        case .focusing: return NSColor(srgbRed: 0.42, green: 0.85, blue: 0.62, alpha: 1)
        }
    }

    override func draw(_ dirty: NSRect) {
        NSGraphicsContext.current!.cgContext.clear(bounds)
        let t = state.anim
        drawBubble(t)
        drawBadge(t)
        drawPet(in: petRect, mood: mood, t: t)
    }

    // ── 말풍선 ──
    private func drawBubble(_ t: Double) {
        bubbleRect = .zero
        let text = state.bubble
        guard !text.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 12.5, weight: state.alerting ? .bold : .medium)
        let maxW: CGFloat = 236
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: state.alerting ? NSColor.white : ink,
            .paragraphStyle: ps
        ]
        let ns = text as NSString
        // 대사는 몇 초에 한 번 바뀌는데 화면은 초당 30번 그린다 → 레이아웃은 캐시
        let key = text + (state.alerting ? "!" : "")
        if key != cachedKey {
            var b = ns.boundingRect(with: NSSize(width: maxW - 26, height: 60),
                                    options: [.usesLineFragmentOrigin], attributes: attrs)
            b.size.width = min(ceil(b.width), maxW - 26)
            cachedSize = b.size
            cachedKey = key
        }
        let box = NSRect(origin: .zero, size: cachedSize)

        let w = max(76, box.width + 26)
        let h = max(32, ceil(box.height) + 18)
        let tailH: CGFloat = 7
        let x = petRect.midX - w/2
        let y = petRect.maxY + 6 + tailH
        let r = NSRect(x: x, y: y, width: w, height: h)
        bubbleRect = r.insetBy(dx: -2, dy: -tailH)

        // 살짝 떠다니는 느낌
        let bob = CGFloat(sin(t * 1.6)) * 1.0
        let rr = r.offsetBy(dx: 0, dy: bob)

        let path = NSBezierPath(roundedRect: rr, xRadius: 11, yRadius: 11)
        // 꼬리
        let tip = NSPoint(x: petRect.midX, y: rr.minY - tailH)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: petRect.midX - 7, y: rr.minY + 1))
        tail.line(to: tip)
        tail.line(to: NSPoint(x: petRect.midX + 7, y: rr.minY + 1))
        tail.close()

        (state.alerting ? NSColor(srgbRed: 0.80, green: 0.13, blue: 0.16, alpha: 0.98)
                        : NSColor(srgbRed: 0.99, green: 0.99, blue: 0.98, alpha: 0.97)).setFill()
        path.fill(); tail.fill()
        (state.alerting ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.18)).setStroke()
        path.lineWidth = 1; path.stroke()

        ns.draw(with: NSRect(x: rr.minX + 13, y: rr.minY + (h - box.height)/2,
                             width: w - 26, height: box.height + 2),
                options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    // ── 타이머 배지 ──
    private func drawBadge(_ t: Double) {
        let r = badgeRect
        let path = NSBezierPath(roundedRect: r, xRadius: r.height/2, yRadius: r.height/2)
        NSColor(srgbRed: 0.06, green: 0.06, blue: 0.075, alpha: 0.92).setFill()
        path.fill()
        NSColor(white: 1, alpha: state.alerting ? 0.30 : 0.13).setStroke()
        path.lineWidth = 1; path.stroke()

        // 진행 링
        let ringR: CGFloat = 10
        let c = NSPoint(x: r.minX + 15 + ringR, y: r.midY)
        NSColor(white: 1, alpha: 0.15).setStroke()
        let bg = NSBezierPath(); bg.appendArc(withCenter: c, radius: ringR, startAngle: 0, endAngle: 360)
        bg.lineWidth = 2.4; bg.stroke()
        let left = state.phase == .finished ? 1
                 : (state.total > 0 ? max(0, min(1, state.remaining / state.total)) : 0)
        if left > 0.001 {
            let a = NSBezierPath()
            a.appendArc(withCenter: c, radius: ringR, startAngle: 90,
                        endAngle: 90 - 360 * CGFloat(left), clockwise: true)
            a.lineWidth = 2.4; a.lineCapStyle = .round
            accent.setStroke(); a.stroke()
        }

        // 시간
        let str = state.phase == .finished ? "완료" : mmss(state.remaining)
        let font = state.phase == .finished
            ? NSFont.systemFont(ofSize: 17, weight: .semibold)
            : NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: state.alerting ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0.97, alpha: 1)
        ]
        let sz = str.size(withAttributes: attr)
        let tx = c.x + ringR + 10
        str.draw(at: NSPoint(x: tx, y: r.midY - sz.height/2 + 0.5), withAttributes: attr)

        btnPrimary = .zero; btnReset = .zero; btnStop = .zero
        let rightEdge = r.maxX - 11

        if state.alerting {
            // 타이머 정지 표시
            let px = tx + sz.width + 6
            NSColor(white: 1, alpha: 0.5).setFill()
            NSRect(x: px, y: r.midY - 5, width: 2.5, height: 10).fill()
            NSRect(x: px + 4.5, y: r.midY - 5, width: 2.5, height: 10).fill()
            let l = "멈춤"
            let la: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1)]
            let ls = l.size(withAttributes: la)
            l.draw(at: NSPoint(x: rightEdge - ls.width, y: r.midY - ls.height/2), withAttributes: la)
        } else if state.hovering {
            let sd: CGFloat = 24
            btnStop    = NSRect(x: rightEdge - sd,           y: r.midY - sd/2, width: sd, height: sd)
            btnReset   = NSRect(x: btnStop.minX - sd - 1,    y: r.midY - sd/2, width: sd, height: sd)
            btnPrimary = NSRect(x: btnReset.minX - sd - 1,   y: r.midY - sd/2, width: sd, height: sd)
            glyph(state.phase == .focusing ? "pause.fill" : "play.fill", btnPrimary, NSColor(white: 0.95, alpha: 1), 11)
            glyph("arrow.counterclockwise", btnReset, NSColor(white: 0.62, alpha: 1), 11)
            glyph("xmark", btnStop, NSColor(white: 0.62, alpha: 1), 10)
        } else if state.sessionWarnings > 0 && state.phase == .focusing {
            let l = "흔들림 \(state.sessionWarnings)"
            let la: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor(white: 0.55, alpha: 1)]
            let ls = l.size(withAttributes: la)
            l.draw(at: NSPoint(x: rightEdge - ls.width, y: r.midY - ls.height/2), withAttributes: la)
        }
    }

    /// 손그림 느낌의 뭉실뭉실한 덩어리 — 반지름을 각도에 따라 흔들어 털 실루엣을 만든다
    private func fluff(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                       bumps: Int = 9, amp: CGFloat = 0.085, phase: CGFloat = 0) -> NSBezierPath {
        let p = NSBezierPath()
        let n = 56
        for i in 0...n {
            let th = CGFloat(i) / CGFloat(n) * .pi * 2
            let k = 1 + amp * sin(CGFloat(bumps) * th + phase)
            let pt = NSPoint(x: cx + cos(th) * rx * k, y: cy + sin(th) * ry * k)
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        p.close()
        return p
    }

    // ── 캐릭터 (전신) ── 흰 강아지, 스티커풍
    private func drawPet(in box: NSRect, mood: Mood, t: Double) {
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch mood {
        case .working:  dy = CGFloat(sin(t * 2.4)) * 1.4
        case .angry:    dx = CGFloat(sin(t * 32)) * 2.4
                        dy = CGFloat(abs(sin(t * 7))) * 2.0
        case .happy:    dy = CGFloat(abs(sin(t * 4.5))) * 6.0
        case .sleeping: dy = CGFloat(sin(t * 1.2)) * 1.0
        }
        let cx = box.midX + dx
        let base = box.minY + dy
        let lw: CGFloat = 2.0

        func draw(_ p: NSBezierPath, _ fill: NSColor = furC, _ width: CGFloat = 2.0) {
            fill.setFill(); p.fill()
            ink.setStroke(); p.lineWidth = width; p.lineJoinStyle = .round; p.stroke()
        }

        // 바닥 그림자
        let shrink = 1 - min(0.45, dy / 12)
        NSColor(white: 0, alpha: 0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: box.midX - 25 * shrink, y: box.minY - 2,
                                    width: 50 * shrink, height: 8)).fill()

        // ── 뒷다리 / 발 ──
        for sx in [-13.0, 13.0] {
            draw(fluff(cx + CGFloat(sx), base + 6, 11, 7, bumps: 6, amp: 0.10, phase: 1.2), furC, lw)
        }

        // ── 몸통 ──
        let bodyCY = base + 26
        draw(fluff(cx, bodyCY, 22, 20, bumps: 10, amp: 0.09), furC, lw)

        // ── 앞발 (일할 땐 번갈아 움직임 = 타자 치는 느낌) ──
        var pawL: CGFloat = 0, pawR: CGFloat = 0
        switch mood {
        case .working: pawL = CGFloat(sin(t * 9)) * 3;  pawR = CGFloat(sin(t * 9 + .pi)) * 3
        case .angry:   pawL = 16; pawR = 16          // 만세하듯 번쩍
        case .happy:   pawL = 18; pawR = 18
        case .sleeping: break
        }
        for (sx, off) in [(-20.0, pawL), (20.0, pawR)] {
            draw(fluff(cx + CGFloat(sx), bodyCY + 2 + off, 9, 8, bumps: 6, amp: 0.11, phase: 2.0), furC, lw)
        }

        // ── 머리 ──
        let headCY = base + 62
        draw(fluff(cx, headCY, 27, 25, bumps: 11, amp: 0.075, phase: 0.6), furC, lw)

        // ── 귀 (양옆으로 축 늘어짐, 화나거나 신나면 들림) ──
        var earLift: CGFloat = 0, earOut: CGFloat = 0
        switch mood {
        case .angry:  earLift = 13; earOut = 4
        case .happy:  earLift = 15; earOut = 5
        case .working: earLift = CGFloat(sin(t * 2.4)) * 1.5
        case .sleeping: earLift = CGFloat(sin(t * 1.2)) * 1.0
        }
        for side in [-1.0, 1.0] {
            let sg = CGFloat(side)
            draw(fluff(cx + sg * (26 + earOut), headCY - 6 + earLift, 9, 18,
                       bumps: 7, amp: 0.12, phase: 1.5), furC, lw)
        }

        // ── 얼굴 ──
        let eyeY = headCY + 4
        let eyeDX: CGFloat = 8.5
        ink.setFill(); ink.setStroke()

        func nose() {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 3.5, y: eyeY - 11, width: 7, height: 5.5)).fill()
        }
        /// ω 모양 입
        func smallMouth() {
            ink.setStroke()
            let m = NSBezierPath()
            m.appendArc(withCenter: NSPoint(x: cx - 3, y: eyeY - 15), radius: 3.2,
                        startAngle: 200, endAngle: 340)
            m.appendArc(withCenter: NSPoint(x: cx + 3, y: eyeY - 15), radius: 3.2,
                        startAngle: 200, endAngle: 340)
            m.lineWidth = 1.7; m.lineCapStyle = .round; m.stroke()
        }
        /// 헤벌린 입 + 혀
        func openMouth(_ w: CGFloat, _ h: CGFloat) {
            let r = NSRect(x: cx - w/2, y: eyeY - 12 - h, width: w, height: h)
            let p = NSBezierPath(roundedRect: r, xRadius: w/2, yRadius: h/2)
            ink.setFill(); p.fill()
            tongue.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - w*0.28, y: r.minY + 1.5,
                                        width: w*0.56, height: h*0.45)).fill()
        }

        switch mood {
        case .sleeping:
            for sx in [-eyeDX, eyeDX] {          // 감은 눈
                let p = NSBezierPath()
                p.appendArc(withCenter: NSPoint(x: cx + sx, y: eyeY + 3), radius: 4.5,
                            startAngle: 200, endAngle: 340)
                p.lineWidth = 2.0; p.lineCapStyle = .round; p.stroke()
            }
            nose(); smallMouth()
            let za: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
                .foregroundColor: NSColor(white: 0.99, alpha: 0.9)]
            ("z" as NSString).draw(at: NSPoint(x: cx + 27, y: headCY + 16 + CGFloat(sin(t * 1.5)) * 2),
                                   withAttributes: za)

        case .working:
            let blink = t.truncatingRemainder(dividingBy: 4.1) < 0.14
            for sx in [-eyeDX, eyeDX] {
                if blink {
                    let p = NSBezierPath()
                    p.appendArc(withCenter: NSPoint(x: cx + sx, y: eyeY + 3), radius: 4.5,
                                startAngle: 200, endAngle: 340)
                    p.lineWidth = 2.0; p.lineCapStyle = .round; p.stroke()
                } else {
                    ink.setFill()
                    NSBezierPath(ovalIn: NSRect(x: cx + sx - 3.2, y: eyeY - 2,
                                                width: 6.4, height: 7.6)).fill()
                }
            }
            nose(); smallMouth()

        case .angry:
            for sx in [-eyeDX, eyeDX] {
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx + sx - 3.4, y: eyeY - 2,
                                            width: 6.8, height: 7.2)).fill()
            }
            ink.setStroke()
            for side in [-1.0, 1.0] {            // 치켜올린 눈썹
                let sg = CGFloat(side)
                let p = NSBezierPath()
                p.move(to: NSPoint(x: cx + sg * 15, y: eyeY + 13))
                p.line(to: NSPoint(x: cx + sg * 4.5, y: eyeY + 6.5))
                p.lineWidth = 2.3; p.lineCapStyle = .round; p.stroke()
            }
            nose(); openMouth(15, 11)
            // 분노 마크
            let ax = cx + 22, ay = headCY + 19
            NSColor(srgbRed: 0.93, green: 0.22, blue: 0.20, alpha: 1).setStroke()
            for a in stride(from: 0.0, to: 180.0, by: 45.0) {
                let rad = a * .pi / 180
                let p = NSBezierPath()
                p.move(to: NSPoint(x: ax - cos(rad) * 6, y: ay - sin(rad) * 6))
                p.line(to: NSPoint(x: ax + cos(rad) * 6, y: ay + sin(rad) * 6))
                p.lineWidth = 2.0; p.lineCapStyle = .round; p.stroke()
            }

        case .happy:
            ink.setStroke()
            for sx in [-eyeDX, eyeDX] {          // ^ ^
                let p = NSBezierPath()
                p.appendArc(withCenter: NSPoint(x: cx + sx, y: eyeY), radius: 5,
                            startAngle: 30, endAngle: 150)
                p.lineWidth = 2.2; p.lineCapStyle = .round; p.stroke()
            }
            nose(); openMouth(17, 12)
        }
    }

    private func glyph(_ name: String, _ rect: NSRect, _ color: NSColor, _ size: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: rect.midX - s.width/2, y: rect.midY - s.height/2,
                            width: s.width, height: s.height))
    }

    // ── 드래그 + 클릭 ──
    override func mouseDown(with e: NSEvent) { dragOrigin = NSEvent.mouseLocation; dragged = false }
    override func mouseDragged(with e: NSEvent) {
        guard let start = dragOrigin, let win = window else { return }
        let now = NSEvent.mouseLocation
        if abs(now.x - start.x) + abs(now.y - start.y) > 3 { dragged = true }
        var o = win.frame.origin
        o.x += e.deltaX; o.y -= e.deltaY
        win.setFrameOrigin(o)
    }
    override func mouseUp(with e: NSEvent) {
        defer { dragOrigin = nil }
        if dragged { savePosition(); return }
        let p = convert(e.locationInWindow, from: nil)
        if btnPrimary.contains(p) { onPrimary() }
        else if btnReset.contains(p) { onReset() }
        else if btnStop.contains(p) { onStop() }
        else if petRect.contains(p) { onPrimary() }      // 얘를 누르면 시작/정지
    }
    private func savePosition() {
        guard let f = window?.frame else { return }
        try? JSONEncoder().encode(["x": f.origin.x, "y": f.origin.y]).write(to: posURL)
    }
}

// ───────────────────────── App ─────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var cfg = Config.load()
    let watcher = Watcher()
    var panel: NSPanel!
    var pet: PetView!
    var statusItem: NSStatusItem!
    var ticker: Timer?

    // timing
    var endDate: Date?
    var lastTick = Date()
    var badSince: Date?          // 유예 카운트 시작
    var lastLoggedHost = ""      // logAllSites용 중복 제거
    var frame = 0
    var tickHz: Double = 0

    /// 상태에 따라 타이머 주기를 바꾼다.
    /// 화났을 땐 부들부들 떨어야 하니 30Hz, 자고 있을 땐 8Hz면 충분하다.
    /// (상시 실행 앱이라 안 깨우는 게 배터리에 제일 낫다)
    func retimeIfNeeded() {
        let hz: Double
        if s.alerting                                       { hz = 30 }
        else if s.phase == .focusing || pet?.state.hovering == true { hz = 20 }
        else                                                { hz = 8 }
        guard hz != tickHz else { return }
        tickHz = hz
        ticker?.invalidate()
        let t = Timer(timeInterval: 1.0/hz, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 1.0 / hz * 0.15
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }
    var sayText = ""
    var sayUntil = Date.distantPast
    var saidHalf = false, saidLast5 = false

    func say(_ line: String, for d: TimeInterval = 5) {
        sayText = line; sayUntil = Date().addingTimeInterval(d)
    }

    static let idleLines = ["오늘도 해볼까?", "준비되면 눌러", "같이 하자", "나 여기 있어"]
    static let workLines = ["집중 중…", "잘하고 있어", "나도 하는 중", "이대로 가자", "옆에 있을게"]

    /// 지금 말풍선에 띄울 대사
    func currentBubble() -> String {
        if s.alerting { return angryLine }
        switch s.phase {
        case .finished:
            return s.sessionWarnings == 0 ? "한 번도 안 흔들렸어!" : "끝! 흔들림 \(s.sessionWarnings)회"
        case .idle:
            let i = Int(Date().timeIntervalSince1970 / 20) % AppDelegate.idleLines.count
            return AppDelegate.idleLines[i]
        case .paused:
            return "기다릴게"
        case .focusing:
            if Date() < sayUntil { return sayText }
            let i = Int(Date().timeIntervalSince1970 / 25) % AppDelegate.workLines.count
            return AppDelegate.workLines[i]
        }
    }
    var lastMenuTitle = ""

    /// 화났을 때 굴러가는 대사
    static let angryLines = [
        "야.", "어디 가", "지금 뭐 하는데", "보고 있다", "돌아와",
        "나 혼자 일하는데", "진심이야?", "시간 안 가는 거 보이지"
    ]
    var angryLine: String {  // 화났을 때
        guard s.alerting else { return "" }
        let target = s.alertDetail.isEmpty ? s.alertApp : s.alertDetail
        if s.alertRunSeconds < 3.5 { return "\(target)?!" }
        let i = Int((s.alertRunSeconds - 3.5) / 2.5) % AppDelegate.angryLines.count
        return AppDelegate.angryLines[i]
    }
    var alertStart: Date?        // 실제 딴짓 판정된 시각
    var sessionStart: Date?

    var s = PetState()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        s.total = cfg.focusMinutes * 60
        s.remaining = s.total
        loadToday()
        buildPanel()
        buildStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appSwitched(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        retimeIfNeeded()
        refresh()
    }

    @objc func appSwitched(_ n: Notification) {
        watcher.sample(cfg, active: s.phase == .focusing)
        evaluate()
    }

    // ── panel ──
    func buildPanel() {
        let W = PetView.winW, H = PetView.winH
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver                       // 풀스크린 앱 위에도 뜬다
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false   // 그림자는 캐릭터 발밑에 직접 그린다
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false

        pet = PetView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        pet.wantsLayer = true
        pet.onPrimary = { [weak self] in self?.togglePrimary() }
        pet.onReset   = { [weak self] in self?.resetSession() }
        pet.onStop    = { [weak self] in self?.endSession(completed: false) }
        p.contentView = pet

        // 위치 복원, 없으면 화면 상단 중앙
        var origin: NSPoint
        if let d = try? Data(contentsOf: posURL),
           let m = try? JSONDecoder().decode([String: CGFloat].self, from: d),
           let x = m["x"], let y = m["y"] {
            origin = NSPoint(x: x, y: y)
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: vf.midX - W / 2, y: vf.maxY - H - 6)
        }
        // 예전에 저장된 좌표가 화면 밖이면 끌어온다 (창 크기가 바뀌었을 수 있음)
        let vf2 = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        origin.x = min(max(origin.x, vf2.minX + 4), vf2.maxX - W - 4)
        origin.y = min(max(origin.y, vf2.minY + 4), vf2.maxY - H - 4)
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        panel = p
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    /// 메뉴는 열릴 때마다 다시 만든다 — "지금 앞에 있는 앱/사이트"가 계속 바뀌니까.
    func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        @discardableResult
        func add(_ title: String, _ sel: Selector?, tag: Int = 0, indent: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.tag = tag
            i.indentationLevel = indent
            menu.addItem(i)
            return i
        }

        let startTitle: String
        switch s.phase {
        case .focusing: startTitle = "일시정지"
        case .paused:   startTitle = "다시 시작"
        default:        startTitle = "집중 시작 (\(Int(cfg.focusMinutes))분)"
        }
        add(startTitle, #selector(togglePrimary))
        if s.phase != .idle {
            add("세션 초기화", #selector(resetSession))
            add("세션 중단", #selector(stopFromMenu))
        }
        menu.addItem(.separator())

        let today = add("오늘 흔들림 \(s.todayWarnings)회 · \(compactDuration(s.todayDistracted))", nil)
        today.isEnabled = false

        menu.addItem(.separator())

        // ── 지금 앞에 있는 것 바로 추가 ──
        let bid = watcher.frontBundle
        let host = watcher.currentHost
        if !bid.isEmpty {
            let already = cfg.distractionApps.contains { $0.caseInsensitiveCompare(bid) == .orderedSame }
            let it = add(already ? "✓ \(watcher.frontName) — 이미 딴짓 목록에 있음"
                                 : "＋ 딴짓에 추가:  \(watcher.frontName)",
                         already ? nil : #selector(addCurrentApp))
            it.isEnabled = !already
        }
        if !host.isEmpty {
            let already = cfg.distractionSites.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
            let it = add(already ? "✓ \(host) — 이미 딴짓 목록에 있음"
                                 : "＋ 딴짓에 추가:  \(host)",
                         already ? nil : #selector(addCurrentSite))
            it.isEnabled = !already
        }

        // ── 목록 관리 (클릭하면 제거) ──
        let manage = NSMenuItem(title: "딴짓 목록 관리", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let hint = NSMenuItem(title: "클릭하면 목록에서 뺍니다", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        sub.addItem(hint)
        sub.addItem(.separator())

        func section(_ title: String, _ items: [String], kind: String) {
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            h.isEnabled = false
            sub.addItem(h)
            if items.isEmpty {
                let e = NSMenuItem(title: "(비어 있음)", action: nil, keyEquivalent: "")
                e.isEnabled = false; e.indentationLevel = 1
                sub.addItem(e)
            }
            for v in items {
                let i = NSMenuItem(title: v, action: #selector(removeEntry(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = [kind, v]
                i.indentationLevel = 1
                i.state = .on
                sub.addItem(i)
            }
        }
        section("앱", cfg.distractionApps, kind: "app")
        sub.addItem(.separator())
        section("사이트", cfg.distractionSites, kind: "site")
        manage.submenu = sub
        menu.addItem(manage)

        menu.addItem(.separator())
        add("기록 파일 열기", #selector(openLog))
        add("설정 파일 열기 (JSON)", #selector(openConfig))
        add("설정 다시 읽기", #selector(reloadConfig))

        menu.addItem(.separator())
        let login = add("로그인 시 자동 실행", #selector(toggleLogin))
        login.state = loginEnabled ? .on : .off
        add("알약 위치 초기화", #selector(recenter))
        add("종료", #selector(quit))
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    // ── 딴짓 목록 편집 ──
    @objc func addCurrentApp() {
        let bid = watcher.frontBundle
        guard !bid.isEmpty,
              !cfg.distractionApps.contains(where: { $0.caseInsensitiveCompare(bid) == .orderedSame })
        else { return }
        cfg.distractionApps.append(bid)
        cfg.save()
        refresh()
    }
    @objc func addCurrentSite() {
        let host = watcher.currentHost
        guard !host.isEmpty,
              !cfg.distractionSites.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame })
        else { return }
        cfg.distractionSites.append(host)
        cfg.save()
        refresh()
    }
    @objc func removeEntry(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let (kind, value) = (pair[0], pair[1])
        if kind == "app" {
            cfg.distractionApps.removeAll { $0 == value }
        } else {
            cfg.distractionSites.removeAll { $0 == value }
        }
        cfg.save()
        refresh()
    }

    // ── 로그인 항목 ──
    var loginEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    @objc func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "자동 실행 등록에 실패했어"
            a.informativeText = "시스템 설정 → 일반 → 로그인 항목에서 AttentionTimer.app을 직접 추가해줘.\n\n\(error.localizedDescription)"
            a.runModal()
        }
    }

    // ── control ──
    @objc func togglePrimary() {
        switch s.phase {
        case .idle, .finished:
            cfg = Config.load()
            s.total = cfg.focusMinutes * 60
            s.remaining = s.total
            s.sessionDistracted = 0
            s.sessionWarnings = 0
            sessionStart = Date()
            endDate = Date().addingTimeInterval(s.remaining)
            lastLoggedHost = ""
            saidHalf = false; saidLast5 = false
            say("좋아, 시작하자", for: 4)
            s.phase = .focusing
        case .focusing:
            s.phase = .paused
            endDate = nil
            clearAlert()
        case .paused:
            endDate = Date().addingTimeInterval(s.remaining)
            say("다시 가보자", for: 3)
            s.phase = .focusing
        }
        refresh()
    }
    @objc func resetSession() {
        s.phase = .idle; endDate = nil
        s.total = cfg.focusMinutes * 60; s.remaining = s.total
        s.sessionDistracted = 0; s.sessionWarnings = 0
        sessionStart = nil
        clearAlert(); refresh()
    }
    @objc func stopFromMenu() { endSession(completed: false) }
    @objc func openLog()    { NSWorkspace.shared.open(logURL) }
    @objc func openConfig() { NSWorkspace.shared.open(configURL) }
    @objc func reloadConfig() {
        cfg = Config.load()
        if s.phase == .idle { s.total = cfg.focusMinutes * 60; s.remaining = s.total }
        refresh()
    }
    @objc func recenter() {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.maxY - panel.frame.height - 6))
        try? fm.removeItem(at: posURL)
    }
    @objc func quit() {
        if s.phase == .focusing || s.phase == .paused { endSession(completed: false) }
        NSApp.terminate(nil)
    }

    func endSession(completed: Bool) {
        guard let start = sessionStart else { s.phase = .idle; refresh(); return }
        let elapsed = Date().timeIntervalSince(start)
        log([
            "type": "session",
            "completed": completed,
            "planned_sec": Int(s.total),
            "elapsed_sec": Int(elapsed),
            "distracted_sec": Int(s.sessionDistracted),
            "warnings": s.sessionWarnings
        ])
        clearAlert()
        lastLoggedHost = ""
        sessionStart = nil
        endDate = nil
        s.phase = completed ? .finished : .idle
        if !completed { s.remaining = s.total }
        refresh()
    }

    // ── tick ── 30fps. 애니메이션은 매 프레임, 무거운 판정은 0.2초마다.
    func tick() {
        frame &+= 1
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        s.anim = now.timeIntervalSince1970

        let heavy = (frame % 6 == 0)
        if heavy { watcher.sample(cfg, active: s.phase == .focusing) }

        if s.phase == .focusing, var end = endDate {
            if heavy { evaluate() }

            if s.alerting {
                // 딴짓하는 동안엔 시간이 줄지 않는다 — 종료 시각을 그만큼 뒤로 민다.
                // 돌아오지 않으면 세션은 끝나지 않는다.
                end = end.addingTimeInterval(dt)
                endDate = end
                s.sessionDistracted += dt
                s.todayDistracted += dt
                s.alertRunSeconds += dt
            }
            s.remaining = end.timeIntervalSinceNow

            if !s.alerting {
                if !saidHalf, s.remaining <= s.total / 2 { saidHalf = true; say("절반 왔다") }
                if !saidLast5, s.remaining <= 300 { saidLast5 = true; say("5분 남았어, 조금만") }
            }
            if s.remaining <= 0 {
                s.remaining = 0
                NSSound(named: "Glass")?.play()
                endSession(completed: true)
                return
            }
        }
        s.bubble = currentBubble()
        retimeIfNeeded()
        refresh()
    }

    /// 딴짓 판정 — 유예시간을 넘겨야 실제 경고
    func evaluate() {
        guard s.phase == .focusing else { clearAlert(); return }
        let v = watcher.check(cfg)

        // 방문 사이트 기록 (opt-in). 호스트가 바뀔 때만 한 줄.
        if cfg.logAllSites, cfg.watchBrowserURL,
           let host = URL(string: watcher.cachedURL)?.host, !host.isEmpty {
            if host != lastLoggedHost {
                lastLoggedHost = host
                log(["type": "site", "host": host, "app": v.app])
            }
        }

        if v.bad {
            if badSince == nil { badSince = Date() }
            if !s.alerting, Date().timeIntervalSince(badSince!) >= cfg.graceSeconds {
                s.alerting = true
                s.alertApp = v.app
                s.alertDetail = v.detail
                s.alertRunSeconds = cfg.graceSeconds
                s.sessionWarnings += 1
                s.todayWarnings += 1
                alertStart = Date()
                log(["type": "distraction_start", "app": v.app, "detail": v.detail])
                panel.orderFrontRegardless()
            } else if s.alerting {
                s.alertApp = v.app
                if !v.detail.isEmpty { s.alertDetail = v.detail }
            }
        } else {
            if s.alerting, let a = alertStart {
                log(["type": "distraction_end",
                     "app": s.alertApp, "detail": s.alertDetail,
                     "seconds": Int(Date().timeIntervalSince(a))])
            }
            clearAlert()
        }
    }
    func clearAlert() {
        s.alerting = false; badSince = nil; alertStart = nil
        s.alertApp = ""; s.alertDetail = ""; s.alertRunSeconds = 0
    }

    // ── render ──
    // 상시 떠있는 앱이라 매 프레임 다 하면 CPU를 잡아먹는다.
    // 재그리기 / 윈도우 최상단 재요청 / 메뉴바 갱신을 각각 필요한 만큼만.
    func refresh() {
        let every = s.alerting ? 1 : 2      // 30Hz→30fps / 20Hz→10fps / 8Hz→4fps

        if frame % every == 0 {
            pet.state.phase = s.phase
            pet.state.remaining = s.remaining
            pet.state.total = s.total
            pet.state.alerting = s.alerting
            pet.state.alertApp = s.alertApp
            pet.state.alertDetail = s.alertDetail
            pet.state.alertRunSeconds = s.alertRunSeconds
            pet.state.bubble = s.bubble
            pet.state.sessionDistracted = s.sessionDistracted
            pet.state.sessionWarnings = s.sessionWarnings
            pet.state.todayWarnings = s.todayWarnings
            pet.state.todayDistracted = s.todayDistracted
            pet.state.anim = s.anim
            pet.needsDisplay = true
        }

        // 최상단 재요청은 1초에 한 번이면 충분
        if frame % 30 == 0, s.phase == .focusing || s.phase == .paused {
            panel.orderFrontRegardless()
        }

        // 메뉴바는 글자가 실제로 바뀔 때만
        let txt: String
        switch s.phase {
        case .focusing: txt = s.alerting ? "🔴 \(mmss(s.remaining))" : mmss(s.remaining)
        case .paused:   txt = "⏸ \(mmss(s.remaining))"
        case .finished: txt = "✓"
        case .idle:     txt = "◷"
        }
        if txt != lastMenuTitle {
            lastMenuTitle = txt
            statusItem?.button?.attributedTitle = NSAttributedString(string: txt, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            ])
        }
    }

    // ── log ──
    func log(_ fields: [String: Any]) {
        var d = fields
        d["t"] = iso.string(from: Date())
        d["day"] = dayFmt.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    func loadToday() {
        guard let txt = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let today = dayFmt.string(from: Date())
        for line in txt.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["day"] as? String) == today else { continue }
            if (o["type"] as? String) == "distraction_start" { s.todayWarnings += 1 }
            if (o["type"] as? String) == "distraction_end" {
                s.todayDistracted += TimeInterval((o["seconds"] as? Int) ?? 0)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
