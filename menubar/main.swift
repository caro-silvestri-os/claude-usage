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
        let (i, o): (Double, Double) = ["claude-opus-5-5": (4, 20), "claude-opus-5": (5, 25), "claude-haiku-5-5": (0.1, 0.5)][model] ?? (2, 10)
        return (Double(input) * i + Double(cacheWrite) * i * 1.25 + Double(cached) * i * 0.1 + Double(output) * o) / 1e6
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = UsageStore()
    let queue = DispatchQueue(label: "usage", qos: .utility)
    let popover = NSPopover()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 860, height: 700))
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
        web.loadHTMLString(template.replacingOccurrences(of: "__DATA__", with: dashboardJSON(history)), baseURL: nil)
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
        let head = NSMenuItem(title: "Hoy \(fmt(p.today)) (~$\(Int(p.todayCost.rounded())) est.) · mes ~$\(Int(p.monthCost.rounded())) est.", action: nil, keyEquivalent: ""); head.isEnabled = false
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
