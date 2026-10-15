import Cocoa
import ServiceManagement

// MARK: - Datos

struct Msg { let ts: Date; let project: String; let tokens: Int }

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
                let tokens = i("input_tokens") + i("cache_creation_input_tokens") + i("cache_read_input_tokens") + i("output_tokens")
                let id = (m["id"] as? String) ?? (o["uuid"] as? String) ?? UUID().uuidString
                out[id] = Msg(ts: ts, project: name, tokens: tokens)
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
    var timer: Timer?
    var snapshot: [Msg] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        if let b = item.button {
            let img = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Claude usage")
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeading
            b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            b.title = " …"
        }
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let msgs = self.store.load()
            DispatchQueue.main.async {
                self.snapshot = msgs
                self.item.button?.title = " " + fmt(periods(msgs).today)
                self.rebuildMenu()
            }
        }
    }

    func line(_ title: String, bold: Bool = false) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: #selector(noop), keyEquivalent: "")
        m.target = self
        if bold { m.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        return m
    }
    @objc func noop() {}

    func rebuildMenu() {
        let menu = NSMenu()
        let p = periods(snapshot)
        menu.addItem(line("Claude Code · tokens", bold: true))
        menu.addItem(line("Hoy: \(fmt(p.today))"))
        menu.addItem(line("Últimos 7 días: \(fmt(p.week))"))
        menu.addItem(line("Este mes: \(fmt(p.month))"))
        menu.addItem(line("Total: \(fmt(p.total))"))
        menu.addItem(.separator())
        menu.addItem(line("Por proyecto (este mes)", bold: true))
        let byProject = Dictionary(grouping: snapshot, by: { $0.project })
        let rows = byProject.map { (name: $0.key, p: periods($0.value)) }.sorted { $0.p.month > $1.p.month }
        for r in rows where r.p.total > 0 {
            let mi = NSMenuItem(title: "\(r.name) — \(fmt(r.p.month))", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(line("Hoy: \(fmt(r.p.today))"))
            sub.addItem(line("Últimos 7 días: \(fmt(r.p.week))"))
            sub.addItem(line("Este mes: \(fmt(r.p.month))"))
            sub.addItem(line("Total: \(fmt(r.p.total))"))
            mi.submenu = sub
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Abrir dashboard", action: #selector(openDashboard), keyEquivalent: "d"); open.target = self
        let ref = NSMenuItem(title: "Actualizar ahora", action: #selector(refresh), keyEquivalent: "r"); ref.target = self
        let login = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [open, ref, login, .separator(), quit].forEach { menu.addItem($0) }
        item.menu = menu
    }

    /// El .app vive en <repo>/ClaudeUsage.app; el repo tiene generate.py e index.html.
    var repoDir: String {
        let env = ProcessInfo.processInfo.environment["CLAUDE_USAGE_DIR"]
        return env ?? (Bundle.main.bundlePath as NSString).deletingLastPathComponent
    }

    @objc func openDashboard() {
        let dir = repoDir
        queue.async {
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            pr.arguments = [dir + "/generate.py"]
            try? pr.run(); pr.waitUntilExit()
            DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: dir + "/index.html")) }
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item: \(error)") }
        rebuildMenu()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
