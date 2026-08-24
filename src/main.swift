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

struct PillState {
    var phase: Phase = .idle
    var remaining: TimeInterval = 25 * 60
    var total: TimeInterval = 25 * 60
    var alerting = false                 // 지금 딴짓 중 (빨간 상태)
    var alertApp = ""
    var alertDetail = ""
    var alertRunSeconds: TimeInterval = 0    // 이번 딴짓이 이어진 시간
    var sessionDistracted: TimeInterval = 0  // 이번 세션 누적 딴짓
    var sessionWarnings = 0
    var todayWarnings = 0
    var todayDistracted: TimeInterval = 0
    var hovering = false
    var pulse: Double = 0
}

// ───────────────────────── Pill view ─────────────────────────

final class PillView: NSView {
    var state = PillState()
    var onPrimary: () -> Void = {}
    var onReset:   () -> Void = {}
    var onStop:    () -> Void = {}

    private var dragOrigin: NSPoint?
    private var dragged = false
    private var btnPrimary = NSRect.zero
    private var btnReset   = NSRect.zero
    private var btnStop    = NSRect.zero
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { state.hovering = true;  needsDisplay = true; window?.invalidateShadow() }
    override func mouseExited(with e: NSEvent)  { state.hovering = false; needsDisplay = true; window?.invalidateShadow() }

    // ── palette ──
    private var calm: Bool { !state.alerting }
    private var accent: NSColor {
        if state.alerting { return .white }
        switch state.phase {
        case .paused:   return NSColor(srgbRed: 0.99, green: 0.76, blue: 0.30, alpha: 1)
        case .finished: return NSColor(srgbRed: 0.45, green: 0.87, blue: 0.65, alpha: 1)
        case .idle:     return NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1)
        case .focusing: return NSColor(srgbRed: 0.42, green: 0.85, blue: 0.62, alpha: 1)
        }
    }

    override func draw(_ dirty: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.clear(bounds)

        // 딴짓 중이면 알약이 살짝 커지며 숨쉰다
        let breathe = state.alerting ? (sin(state.pulse * .pi * 2) * 0.5 + 0.5) : 0
        let inset: CGFloat = state.alerting ? 4 - CGFloat(breathe) * 3.0 : 5
        let pill = bounds.insetBy(dx: inset, dy: inset)
        let radius = pill.height / 2
        let path = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)

        // 배경
        if state.alerting {
            let hot = 0.58 + breathe * 0.22
            NSColor(srgbRed: CGFloat(hot), green: 0.10, blue: 0.13, alpha: 0.97).setFill()
        } else {
            NSColor(srgbRed: 0.06, green: 0.06, blue: 0.075, alpha: 0.90).setFill()
        }
        path.fill()

        // 테두리
        path.lineWidth = state.alerting ? 1.5 : 0.75
        (state.alerting
            ? NSColor(white: 1, alpha: 0.35 + CGFloat(breathe) * 0.35)
            : NSColor(white: 1, alpha: 0.13)).setStroke()
        path.stroke()

        // 바닥 진행 바 (알약 모양으로 클립)
        ctx.saveGState()
        path.addClip()
        let frac = state.total > 0 ? max(0, min(1, 1 - state.remaining / state.total)) : 0
        let barH: CGFloat = 3
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: pill.minX, y: pill.minY, width: pill.width, height: barH).fill()
        accent.withAlphaComponent(state.alerting ? 0.95 : 0.75).setFill()
        NSRect(x: pill.minX, y: pill.minY, width: pill.width * CGFloat(frac), height: barH).fill()
        ctx.restoreGState()

        // ── 링 ──
        let ringR: CGFloat = 11
        let ringC = NSPoint(x: pill.minX + 15 + ringR, y: pill.midY)
        NSColor(white: 1, alpha: 0.14).setStroke()
        let bg = NSBezierPath(); bg.appendArc(withCenter: ringC, radius: ringR, startAngle: 0, endAngle: 360)
        bg.lineWidth = 2.5; bg.stroke()

        let left = state.total > 0 ? max(0, min(1, state.remaining / state.total)) : 0
        if left > 0.001 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: ringC, radius: ringR,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(left), clockwise: true)
            arc.lineWidth = 2.5; arc.lineCapStyle = .round
            accent.setStroke(); arc.stroke()
        }
        if state.phase == .paused {
            accent.setFill()
            NSRect(x: ringC.x - 4, y: ringC.y - 4, width: 2.5, height: 8).fill()
            NSRect(x: ringC.x + 1.5, y: ringC.y - 4, width: 2.5, height: 8).fill()
        } else if state.alerting {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: ringC.x - 3.5, y: ringC.y - 3.5, width: 7, height: 7)).fill()
        }

        // ── 시간 ──
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        let timeStr = state.phase == .finished ? "완료" : mmss(state.remaining)
        let timeAttr: [NSAttributedString.Key: Any] = [
            .font: state.phase == .finished ? NSFont.systemFont(ofSize: 19, weight: .semibold) : timeFont,
            .foregroundColor: state.alerting ? NSColor.white : NSColor(white: 0.97, alpha: 1)
        ]
        let timeSize = timeStr.size(withAttributes: timeAttr)
        let timeX = ringC.x + ringR + 12
        timeStr.draw(at: NSPoint(x: timeX, y: pill.midY - timeSize.height / 2 + 0.5), withAttributes: timeAttr)

        // ── 오른쪽: 호버 시 버튼, 아니면 상태 텍스트 ──
        let rightEdge = pill.maxX - 13
        btnPrimary = .zero; btnReset = .zero; btnStop = .zero

        if state.hovering && !state.alerting {
            let s: CGFloat = 24
            btnStop    = NSRect(x: rightEdge - s,           y: pill.midY - s/2, width: s, height: s)
            btnReset   = NSRect(x: btnStop.minX - s - 2,    y: pill.midY - s/2, width: s, height: s)
            btnPrimary = NSRect(x: btnReset.minX - s - 2,   y: pill.midY - s/2, width: s, height: s)
            let primaryName = (state.phase == .focusing) ? "pause.fill" : "play.fill"
            drawGlyph(primaryName, in: btnPrimary, color: NSColor(white: 0.95, alpha: 1), size: 11)
            drawGlyph("arrow.counterclockwise", in: btnReset, color: NSColor(white: 0.65, alpha: 1), size: 11)
            drawGlyph("xmark", in: btnStop, color: NSColor(white: 0.65, alpha: 1), size: 10)
        } else {
            let label = statusText()
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: state.alerting ? .bold : .medium),
                .foregroundColor: state.alerting
                    ? NSColor(white: 1, alpha: 0.95)
                    : NSColor(white: 0.62, alpha: 1)
            ]
            let sz = label.size(withAttributes: attr)
            let maxX = rightEdge
            let x = max(timeX + timeSize.width + 10, maxX - sz.width)
            label.draw(at: NSPoint(x: x, y: pill.midY - sz.height / 2), withAttributes: attr)
        }
    }

    private func statusText() -> String {
        if state.alerting {
            let what = state.alertDetail.isEmpty ? state.alertApp : state.alertDetail
            return "\(what) · \(mmss(state.alertRunSeconds)) 흘림"
        }
        switch state.phase {
        case .idle:
            if state.todayWarnings > 0 {
                return "오늘 흔들림 \(state.todayWarnings)회 · \(compactDuration(state.todayDistracted))"
            }
            return "시작하려면 ▶"
        case .focusing:
            if state.sessionWarnings > 0 {
                return "집중 중 · 흔들림 \(state.sessionWarnings)회"
            }
            return "집중 중"
        case .paused:
            return "일시정지"
        case .finished:
            return state.sessionWarnings == 0
                ? "흔들림 없이 완주"
                : "흔들림 \(state.sessionWarnings)회 · \(compactDuration(state.sessionDistracted))"
        }
    }

    private func drawGlyph(_ name: String, in rect: NSRect, color: NSColor, size: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: rect.midX - s.width/2, y: rect.midY - s.height/2,
                            width: s.width, height: s.height))
    }

    // ── 드래그 이동 + 클릭 ──
    override func mouseDown(with e: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        dragged = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard let start = dragOrigin, let win = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if abs(dx) + abs(dy) > 3 { dragged = true }
        var o = win.frame.origin
        o.x += e.deltaX
        o.y -= e.deltaY
        win.setFrameOrigin(o)
    }
    override func mouseUp(with e: NSEvent) {
        defer { dragOrigin = nil }
        if dragged { savePosition(); return }
        let p = convert(e.locationInWindow, from: nil)
        if btnPrimary.contains(p) { onPrimary() }
        else if btnReset.contains(p) { onReset() }
        else if btnStop.contains(p) { onStop() }
        else if !state.hovering { onPrimary() }
    }
    private func savePosition() {
        guard let f = window?.frame else { return }
        let d = ["x": f.origin.x, "y": f.origin.y]
        try? JSONEncoder().encode(d).write(to: posURL)
    }
}

// ───────────────────────── App ─────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var cfg = Config.load()
    let watcher = Watcher()
    var panel: NSPanel!
    var pill: PillView!
    var statusItem: NSStatusItem!
    var ticker: Timer?

    // timing
    var endDate: Date?
    var lastTick = Date()
    var badSince: Date?          // 유예 카운트 시작
    var lastLoggedHost = ""      // logAllSites용 중복 제거
    var alertStart: Date?        // 실제 딴짓 판정된 시각
    var sessionStart: Date?

    var s = PillState()

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
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
        refresh()
    }

    @objc func appSwitched(_ n: Notification) { evaluate(force: true) }

    // ── panel ──
    func buildPanel() {
        let W: CGFloat = 344, H: CGFloat = 52
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver                       // 풀스크린 앱 위에도 뜬다
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false

        pill = PillView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        pill.wantsLayer = true
        pill.onPrimary = { [weak self] in self?.togglePrimary() }
        pill.onReset   = { [weak self] in self?.resetSession() }
        pill.onStop    = { [weak self] in self?.endSession(completed: false) }
        p.contentView = pill

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
            s.phase = .focusing
        case .focusing:
            s.phase = .paused
            endDate = nil
            clearAlert()
        case .paused:
            endDate = Date().addingTimeInterval(s.remaining)
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

    // ── tick ──
    func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        watcher.sample(cfg, active: s.phase == .focusing)

        if s.phase == .focusing, let end = endDate {
            s.remaining = end.timeIntervalSinceNow
            if s.remaining <= 0 {
                s.remaining = 0
                NSSound(named: "Glass")?.play()
                endSession(completed: true)
                return
            }
            evaluate(force: false)
            if s.alerting {
                s.sessionDistracted += dt
                s.todayDistracted += dt
                s.alertRunSeconds += dt
            }
        }
        s.pulse = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1.7) / 1.7
        refresh()
    }

    /// 딴짓 판정 — 유예시간을 넘겨야 실제 경고
    func evaluate(force: Bool) {
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
    func refresh() {
        pill.state.phase = s.phase
        pill.state.remaining = s.remaining
        pill.state.total = s.total
        pill.state.alerting = s.alerting
        pill.state.alertApp = s.alertApp
        pill.state.alertDetail = s.alertDetail
        pill.state.alertRunSeconds = s.alertRunSeconds
        pill.state.sessionDistracted = s.sessionDistracted
        pill.state.sessionWarnings = s.sessionWarnings
        pill.state.todayWarnings = s.todayWarnings
        pill.state.todayDistracted = s.todayDistracted
        pill.state.pulse = s.pulse
        pill.needsDisplay = true

        // 항상 또렷하게. 딴짓 중에는 특히 절대 흐려지지 않는다.
        if s.phase == .focusing || s.phase == .paused { panel.orderFrontRegardless() }

        // 메뉴바
        if let b = statusItem.button {
            let txt: String
            switch s.phase {
            case .focusing: txt = s.alerting ? "🔴 \(mmss(s.remaining))" : mmss(s.remaining)
            case .paused:   txt = "⏸ \(mmss(s.remaining))"
            case .finished: txt = "✓"
            case .idle:     txt = "◷"
            }
            b.attributedTitle = NSAttributedString(string: txt, attributes: [
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
