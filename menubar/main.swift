import Cocoa
import ServiceManagement
import WebKit

// MARK: - Datos

struct Msg {
    let ts: Date, project: String, model: String
    let input: Int, cacheWrite: Int, cached: Int, output: Int
    var tokens: Int { input + cacheWrite + cached + output }
    /// Costo estimado a precio de lista de la API (USD por 1M tokens). Cache write = 1.25x input, cache read = 0.1x input.
    var cost: Double {
        // (input, output, multiplicador de cache read). Fuente: https://platform.claude.com/docs/en/about-claude/pricing
        let (i, o, r): (Double, Double, Double) = ["claude-sonnet-5-5": (2, 10, 0.05), "claude-opus-5-5": (4, 20, 0.05), "claude-opus-5": (5, 25, 0.1),
                                                   "claude-haiku-5-5": (0.1, 0.5, 0.1)][model] ?? (2, 10, 0.1)
        return (Double(input) * i + Double(cacheWrite) * i * 1.25 + Double(cached) * i * r + Double(output) * o) / 1e6
    }
}

/// Lee ~/.claude/projects, deduplica por message.id y cachea por archivo (mtime + tamaño).
final class UsageStore {
    private let root = NSString(string: "~/.claude/projects").expandingTildeInPath
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
        let home = NSHomeDirectory().replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let p = folder.hasPrefix(home) ? String(folder.dropFirst(home.count)) : folder
        let t = p.drop(while: { $0 == "-" })
        return t.isEmpty ? "~ (home)" : String(t)
    }

    private func parse(_ path: String, folder: String) -> [String: Msg] {
        let name = project(from: folder)
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
                out[id] = Msg(ts: ts, project: name, model: model,
                              input: i("input_tokens"), cacheWrite: i("cache_creation_input_tokens"),
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

let prefixFilter = ProcessInfo.processInfo.environment["CLAUDE_USAGE_PREFIX"] ?? "pic"
func shown(_ project: String) -> Bool { prefixFilter.isEmpty || project.hasPrefix(prefixFilter) }

/// Totales de un (día, proyecto, modelo): el mismo formato que genera generate.py.
struct Rec {
    let day: String, project: String, model: String
    var input = 0, cacheWrite = 0, cached = 0, output = 0
    var total: Int { input + cacheWrite + cached + output }
    var key: String { "\(day)|\(project)|\(model)" }
    var json: [String: Any] {
        ["day": day, "project": project, "model": model, "input": input, "cache_write": cacheWrite,
         "cached": cached, "output": output, "total": total]
    }
}

func aggregate(_ msgs: [Msg]) -> [String: Rec] {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    var out: [String: Rec] = [:]
    for m in msgs {
        var r = Rec(day: df.string(from: m.ts), project: m.project, model: m.model)
        r = out[r.key] ?? r
        r.input += m.input; r.cacheWrite += m.cacheWrite; r.cached += m.cached; r.output += m.output
        out[r.key] = r
    }
    return out
}

/// Claude Code borra los logs viejos (por defecto ~30 días); guardamos los totales diarios aparte para tener histórico.
/// Se comparte con generate.py (mismo archivo y formato). De cada (día, proyecto, modelo) se conserva el registro más grande.
enum History {
    static let url: URL = {
        if let p = ProcessInfo.processInfo.environment["CLAUDE_USAGE_HISTORY"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-usage/history.json")
    }()

    static func load() -> [String: Rec] {
        guard let d = try? Data(contentsOf: url), let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [:] }
        var out: [String: Rec] = [:]
        for o in a {
            guard let day = o["day"] as? String, let p = o["project"] as? String, let m = o["model"] as? String else { continue }
            func i(_ k: String) -> Int { (o[k] as? NSNumber)?.intValue ?? 0 }
            let r = Rec(day: day, project: p, model: m, input: i("input"), cacheWrite: i("cache_write"), cached: i("cached"), output: i("output"))
            out[r.key] = r
        }
        return out
    }

    static func merge(_ live: [String: Rec]) -> [String: Rec] {
        var all = load()
        let before = all.mapValues { $0.total }
        for (k, r) in live where r.total >= (all[k]?.total ?? -1) { all[k] = r }
        if all.mapValues({ $0.total }) != before {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rows = all.keys.sorted().map { all[$0]!.json }
            if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) { try? d.write(to: url, options: .atomic) }
        }
        return all
    }
}

func dashboardJSON(_ recs: [Rec]) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: recs.map { $0.json })) ?? Data("[]".utf8)
    return String(decoding: d, as: UTF8.self)
}

struct Period { let today: Int, week: Int, month: Int, total: Int, monthCost: Double, todayCost: Double }

func periods(_ msgs: [Msg]) -> Period {
    let cal = Calendar.current, now = Date()
    let t0 = cal.startOfDay(for: now)
    let w0 = cal.date(byAdding: .day, value: -6, to: t0)!
    let m0 = cal.date(from: cal.dateComponents([.year, .month], from: now))!
    var p = (0, 0, 0, 0), c = (0.0, 0.0)
    for m in msgs {
        p.3 += m.tokens
        if m.ts >= m0 { p.2 += m.tokens; c.0 += m.cost }
        if m.ts >= w0 { p.1 += m.tokens }
        if m.ts >= t0 { p.0 += m.tokens; c.1 += m.cost }
    }
    return Period(today: p.0, week: p.1, month: p.2, total: p.3, monthCost: c.0, todayCost: c.1)
}

// MARK: - Vista compacta de hoy

func usdText(_ n: Double) -> String { n >= 100 ? "~$\(Int(n.rounded()))" : String(format: "~$%.2f", n) }
func esc(_ t: String) -> String { t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }

/// HTML chico del popover: solo el día de hoy. El histórico completo se abre en la web (link usage://history).
func todayHTML(_ msgs: [Msg]) -> String {
    let cal = Calendar.current, t0 = cal.startOfDay(for: Date())
    let today = msgs.filter { $0.ts >= t0 }
    let df = DateFormatter(); df.locale = Locale(identifier: "es"); df.dateFormat = "EEEE d 'de' MMMM"
    let cost = today.reduce(0) { $0 + $1.cost }
    let out = today.reduce(0) { $0 + $1.output }
    let input = today.reduce(0) { $0 + $1.input + $1.cacheWrite }
    let cacheRead = today.reduce(0) { $0 + $1.cached }
    let tokens = today.reduce(0) { $0 + $1.tokens }
    let byProject = Dictionary(grouping: today, by: { $0.project })
        .map { (name: $0.key, tokens: $0.value.reduce(0) { $0 + $1.tokens }, cost: $0.value.reduce(0) { $0 + $1.cost }) }
        .sorted { $0.cost > $1.cost }
    let mx = max(byProject.first?.cost ?? 0, 0.0001)
    let rows = byProject.isEmpty ? "<div class=mu style='padding:12px 0'>Todavía no usaste Claude Code hoy.</div>" :
        byProject.map { r in
            "<div class=r><div class=n>\(esc(r.name))</div><div class=v>\(usdText(r.cost))<span class=mu> · \(fmt(r.tokens))</span></div><div class=b><i style='width:\(r.cost / mx * 100)%'></i></div></div>"
        }.joined()
    return """
    <!doctype html><meta charset=utf-8><style>
    :root{--card:#161b22;--bd:#30363d;--tx:#e6edf3;--mu:#8b949e;--acc:#1A66FC;--acc2:#FF6332}
    *{box-sizing:border-box}body{margin:0;padding:18px;background:#0d1117;color:var(--tx);font:13px -apple-system,system-ui,sans-serif}
    .mu{color:var(--mu)}h1{font-size:12px;font-weight:500;color:var(--mu);margin:0 0 2px}h1::first-letter{text-transform:uppercase}
    .big{font-size:34px;font-weight:700;color:var(--acc2);letter-spacing:-.5px}.sub{color:var(--mu);margin-top:2px}
    .tiles{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:14px 0}
    .tiles div{background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:8px 10px}.tiles b{display:block;font-size:15px;margin-top:2px}
    h2{font-size:12px;font-weight:600;margin:16px 0 4px}.r{padding:6px 0;border-bottom:1px solid var(--bd);position:relative}
    .r .n{font-weight:500}.r .v{position:absolute;right:0;top:6px}.b{height:4px;background:#0d1117;border-radius:2px;margin-top:5px}.b i{display:block;height:4px;background:var(--acc);border-radius:2px;min-width:2px}
    a{display:block;margin-top:16px;text-align:center;background:var(--acc);color:#fff;text-decoration:none;padding:9px;border-radius:8px;font-weight:600}
    </style>
    <h1>\(df.string(from: Date()))</h1>
    <div class=big>\(usdText(cost))</div><div class=sub>costo estimado de hoy</div>
    <div class=tiles><div><span class=mu>Tokens totales</span><b>\(fmt(tokens))</b></div><div><span class=mu>Output</span><b>\(fmt(out))</b></div><div><span class=mu>Input</span><b>\(fmt(input))</b></div><div><span class=mu>Cache read</span><b>\(fmt(cacheRead))</b></div></div>
    <h2>Hoy por proyecto</h2>\(rows)
    <a href="usage://history">Ver histórico en la web →</a>
    """
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = UsageStore()
    let queue = DispatchQueue(label: "usage", qos: .utility)
    let popover = NSPopover()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 520))
    var timer: Timer?
    var snapshot: [Msg] = []
    var history: [Rec] = []
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
        web.navigationDelegate = self
        let vc = NSViewController(); vc.view = web
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 380, height: 520)
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
        web.loadHTMLString(todayHTML(snapshot), baseURL: nil)
    }

    /// El botón "Ver histórico en la web" del popover abre el dashboard completo en el navegador.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.request.url?.scheme == "usage" {
            decisionHandler(.cancel)
            popover.performClose(nil)
            openInBrowser()
        } else {
            decisionHandler(.allow)
        }
    }

    @objc func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let all = self.store.load()
            let hist = History.merge(aggregate(all)).values.filter { shown($0.project) }
            let msgs = all.filter { shown($0.project) }
            DispatchQueue.main.async {
                self.snapshot = msgs
                self.history = Array(hist)
                self.item.button?.title = " " + fmt(periods(msgs).today)
                if self.popover.isShown { self.loadDashboard() }
            }
        }
    }

    func showOptions() {
        let menu = NSMenu()
        let p = periods(snapshot)
        let head = NSMenuItem(title: "Hoy \(fmt(p.today)) (~$\(Int(p.todayCost.rounded())) est.)", action: nil, keyEquivalent: ""); head.isEnabled = false
        let ref = NSMenuItem(title: "Actualizar ahora", action: #selector(refresh), keyEquivalent: "r"); ref.target = self
        let browser = NSMenuItem(title: "Ver histórico en la web", action: #selector(openInBrowser), keyEquivalent: "d"); browser.target = self
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
        try? template.replacingOccurrences(of: "__DATA__", with: dashboardJSON(history)).write(to: url, atomically: true, encoding: .utf8)
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
