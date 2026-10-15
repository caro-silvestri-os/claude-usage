import Cocoa
import ServiceManagement
import WebKit

// MARK: - Datos

struct Msg {
    let ts: Date, project: String, model: String, session: String
    let input: Int, cached: Int, output: Int
    var tokens: Int { input + cached + output }
}

/// Lee ~/.claude/projects, deduplica por message.id y cachea por archivo (mtime + tamaño).
final class UsageStore {
    private let root = NSString(string: "~/.claude/projects").expandingTildeInPath
    private let prefix = ProcessInfo.processInfo.environment["CLAUDE_USAGE_PREFIX"] ?? "pic"
    private var cache: [String: (mtime: Date, size: Int, msgs: [String: Msg])] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    func load() -> [Msg] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var seen = Set<String>()
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let path = root + "/" + rel
            seen.insert(path)
            guard let at = try? fm.attributesOfItem(atPath: path),
                  let mtime = at[.modificationDate] as? Date, let size = at[.size] as? Int else { continue }
            if let c = cache[path], c.mtime == mtime, c.size == size { continue }
            let project = String(rel.split(separator: "/").first ?? "")
            cache[path] = (mtime, size, parse(path, folder: project))
        }
        for k in cache.keys where !seen.contains(k) { cache[k] = nil }
        var all: [String: Msg] = [:]
        for c in cache.values { all.merge(c.msgs) { _, new in new } }
        return Array(all.values)
    }

    private func project(from folder: String) -> String {
        let home = NSHomeDirectory().replacingOccurrences(of: "/", with: "-")
        let p = folder.hasPrefix(home) ? String(folder.dropFirst(home.count)) : folder
        let t = p.drop(while: { $0 == "-" })
        return t.isEmpty ? "~ (home)" : String(t)
    }

    private func parse(_ path: String, folder: String) -> [String: Msg] {
        let name = project(from: folder)
        let session = (path as NSString).lastPathComponent
        if !prefix.isEmpty && !name.hasPrefix(prefix) { return [:] }
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        var out: [String: Msg] = [:]
        let needle = Data("\"usage\"".utf8)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            let n = bytes.count
            while start < n {
                var end = start
                while end < n && bytes[end] != 10 { end += 1 }
                let line = Data(bytes: bytes.baseAddress! + start, count: end - start)
                start = end + 1
                guard line.range(of: needle) != nil,
                      let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      o["type"] as? String == "assistant",
                      let m = o["message"] as? [String: Any],
                      let model = m["model"] as? String, model != "<synthetic>",
                      let u = m["usage"] as? [String: Any],
                      let tss = o["timestamp"] as? String,
                      let ts = iso.date(from: tss) ?? isoPlain.date(from: tss) else { continue }
                func i(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                let id = (m["id"] as? String) ?? (o["uuid"] as? String) ?? UUID().uuidString
                out[id] = Msg(ts: ts, project: name, model: model, session: session,
                              input: i("input_tokens") + i("cache_creation_input_tokens"),
                              cached: i("cache_read_input_tokens"), output: i("output_tokens"))
            }
        }
        return out
    }
}

func fmt(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.1fk", d / 1e3) }
    return "\(n)"
}

/// Mismo formato que genera generate.py: un registro por (día, proyecto, modelo).
func dashboardJSON(_ msgs: [Msg]) -> String {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    var agg: [String: (day: String, project: String, model: String, input: Int, cached: Int, output: Int, sessions: Set<String>)] = [:]
    for m in msgs {
        let day = df.string(from: m.ts), key = "\(day)|\(m.project)|\(m.model)"
        var a = agg[key] ?? (day, m.project, m.model, 0, 0, 0, [])
        a.input += m.input; a.cached += m.cached; a.output += m.output; a.sessions.insert(m.session)
        agg[key] = a
    }
    let rows: [[String: Any]] = agg.values.map {
        ["day": $0.day, "project": $0.project, "model": $0.model, "input": $0.input, "cached": $0.cached,
         "output": $0.output, "total": $0.input + $0.cached + $0.output, "sessions": $0.sessions.sorted()]
    }
    let d = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
    return String(decoding: d, as: UTF8.self)
}

struct Period { let today: Int, week: Int, month: Int, total: Int }

func periods(_ msgs: [Msg]) -> Period {
    let cal = Calendar.current, now = Date()
    let t0 = cal.startOfDay(for: now)
    let w0 = cal.date(byAdding: .day, value: -6, to: t0)!
    let m0 = cal.date(from: cal.dateComponents([.year, .month], from: now))!
    var p = (0, 0, 0, 0)
    for m in msgs {
        p.3 += m.tokens
        if m.ts >= m0 { p.2 += m.tokens }
        if m.ts >= w0 { p.1 += m.tokens }
        if m.ts >= t0 { p.0 += m.tokens }
    }
    return Period(today: p.0, week: p.1, month: p.2, total: p.3)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = UsageStore()
    let queue = DispatchQueue(label: "usage", qos: .utility)
    let popover = NSPopover()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 860, height: 700))
    var timer: Timer?
    var snapshot: [Msg] = []
    lazy var template: String = {
        let candidates = [Bundle.main.path(forResource: "template", ofType: "html"), repoDir + "/template.html"].compactMap { $0 }
        for p in candidates { if let t = try? String(contentsOfFile: p, encoding: .utf8) { return t } }
        return "<body style='font-family:sans-serif'>No encuentro template.html</body>"
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        if let b = item.button {
            let img = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Claude usage")
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeading
            b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            b.title = " …"
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        web.setValue(false, forKey: "drawsBackground")
        let vc = NSViewController(); vc.view = web
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 860, height: 700)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Click izquierdo: dashboard. Click derecho (o ctrl-click): menú con opciones.
    @objc func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true { showOptions() }
        else if popover.isShown { popover.performClose(nil) }
        else if let b = item.button {
            loadDashboard()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func loadDashboard() {
        web.loadHTMLString(template.replacingOccurrences(of: "__DATA__", with: dashboardJSON(snapshot)), baseURL: nil)
    }

    @objc func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let msgs = self.store.load()
            DispatchQueue.main.async {
                self.snapshot = msgs
                self.item.button?.title = " " + fmt(periods(msgs).today)
                if self.popover.isShown { self.loadDashboard() }
            }
        }
    }

    func showOptions() {
        let menu = NSMenu()
        let p = periods(snapshot)
        let head = NSMenuItem(title: "Hoy \(fmt(p.today)) · mes \(fmt(p.month))", action: nil, keyEquivalent: ""); head.isEnabled = false
        let ref = NSMenuItem(title: "Actualizar ahora", action: #selector(refresh), keyEquivalent: "r"); ref.target = self
        let browser = NSMenuItem(title: "Abrir en el navegador", action: #selector(openInBrowser), keyEquivalent: "d"); browser.target = self
        let login = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [head, .separator(), ref, browser, login, .separator(), quit].forEach { menu.addItem($0) }
        item.menu = menu
        item.button?.performClick(nil)   // muestra el menú una vez
        item.menu = nil                  // y vuelve al modo click -> popover
    }

    /// El .app vive en <repo>/ClaudeUsage.app; el repo tiene generate.py e index.html.
    var repoDir: String {
        ProcessInfo.processInfo.environment["CLAUDE_USAGE_DIR"] ?? (Bundle.main.bundlePath as NSString).deletingLastPathComponent
    }

    @objc func openInBrowser() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "claude-usage.html")
        try? template.replacingOccurrences(of: "__DATA__", with: dashboardJSON(snapshot)).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item: \(error)") }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
