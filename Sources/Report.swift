// Отчёты разработчику, как в 2pic: счётчики функций, падения, зависания и ошибки — на СВОЙ сервер (server/lark_server.py).
// По умолчанию выключено и ничего не копится в очередь: адрес и ключ вводятся вручную (шестерёнка с зажатым ⌥ → «Отчёты…»).
// Счётчики функций ведутся всегда, но лежат только на этом Mac: ~/Library/Application Support/Lark/usage.json.
//
// Что уходит, если включено: ошибки с последними строками журнала перед ними (названия треков и вкладок в «…» вырезаны),
// падения со сводкой отчёта macOS, зависания дольше 2 с, счётчики функций, версии Lark и macOS, модель Mac,
// анонимный номер установки. Протокол — как у 2pic: POST <адрес>/v1/ingest, Authorization: Bearer <ключ>.
import AppKit
import Foundation

enum ReportPaths {
    static let support = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Lark")
    static let crashReports = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports")
}

// MARK: - Счётчики функций

/// Сколько раз пользовались каждой функцией: всего и по месяцам, плюс измерения (среднее и максимум).
/// Можно звать с любого потока.
enum Usage {
    struct Stat: Codable, Equatable { var count = 0; var sum = 0.0; var max = 0.0 }
    struct Store: Codable, Equatable {
        var since = Date()
        var counts: [String: Int] = [:]
        var months: [String: [String: Int]] = [:]
        var stats: [String: Stat] = [:]
    }

    nonisolated(unsafe) static var fileURL = ReportPaths.support.appendingPathComponent("usage.json")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var store: Store = load()
    nonisolated(unsafe) private static var lastOnce: [String: Date] = [:]
    nonisolated(unsafe) private static var saveQueued = false

    static func count(_ key: String, _ n: Int = 1) {
        lock.lock()
        store.counts[key, default: 0] += n
        store.months[month(), default: [:]][key, default: 0] += n
        lock.unlock()
        scheduleSave()
    }

    /// Ползунки и колесо: одно «использование» на серию движений, а не на каждый шаг.
    static func once(_ key: String, per seconds: TimeInterval = 2) {
        lock.lock()
        let now = Date(), fresh = now.timeIntervalSince(lastOnce[key] ?? .distantPast) > seconds
        lastOnce[key] = now
        lock.unlock()
        if fresh { count(key) }
    }

    static func measure(_ key: String, _ value: Double) {
        lock.lock()
        var s = store.stats[key] ?? Stat()
        s.count += 1; s.sum += value; s.max = Swift.max(s.max, value)
        store.stats[key] = s
        lock.unlock()
        scheduleSave()
    }

    static func value(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return store.counts[key] ?? 0 }
    static func snapshot() -> Store { lock.lock(); defer { lock.unlock() }; return store }

    /// Самое частое — для окна «Отчёты…».
    static func top(_ n: Int) -> [(String, Int)] {
        snapshot().counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map { ($0.key, $0.value) }
    }

    static func save() {
        let s = snapshot()
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(s) { try? d.write(to: fileURL, options: .atomic) }
    }

    /// Для тестов: начать с чистого листа или перечитать файл.
    static func reset() { lock.lock(); store = Store(); lastOnce = [:]; lock.unlock() }
    static func reload() { let s = load(); lock.lock(); store = s; lock.unlock() }

    private static func load() -> Store {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: fileURL), let s = try? dec.decode(Store.self, from: d) else { return Store() }
        return s
    }

    private static func scheduleSave() {
        lock.lock()
        let queued = saveQueued
        saveQueued = true
        lock.unlock()
        guard !queued else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            lock.lock(); saveQueued = false; lock.unlock()
            save()
        }
    }

    private static func month() -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

// MARK: - Падения

/// Прошлый запуск не закрылся как положено (падение, зависание, «Завершить принудительно») — сказать об этом
/// при следующем запуске вместе со сводкой отчёта macOS о падении.
enum CrashWatch {
    nonisolated(unsafe) static var marker = ReportPaths.support.appendingPathComponent("running")
    nonisolated(unsafe) private static var ownsMarker = false
    nonisolated(unsafe) private static var termSource: DispatchSourceSignal?

    @MainActor static func start() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: marker.path), let since = attrs[.modificationDate] as? Date {
            let reports = self.reports(since: since)
            Usage.count("crash.previous")
            if reports.isEmpty {
                Log.put("crash", "прошлый запуск (с \(Log.describe(since))) закончился не выходом из меню: падение, зависание или принудительное завершение")
            }
            for r in reports { Log.put("crash", "\(r.name): \(r.summary)") }
        }
        try? fm.createDirectory(at: ReportPaths.support, withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: Data("\(getpid())".utf8))
        ownsMarker = true

        NSSetUncaughtExceptionHandler { e in
            Log.put("crash", "необработанное исключение \(e.name.rawValue): \(e.reason ?? "")\n    "
                    + e.callStackSymbols.prefix(25).joined(separator: "\n    "))
            Log.flush()
        }
        // pkill (установщик при обновлении) — это обычный выход, а не падение
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            Log.put("app", "SIGTERM: выхожу")
            NSApp.terminate(nil)
        }
        src.resume()
        termSource = src
    }

    static func cleanExit() {
        guard ownsMarker else { return }
        try? FileManager.default.removeItem(at: marker)
    }

    /// Отчёты macOS о падениях Lark, записанные после `since`, — по строке на каждый.
    static func reports(since: Date) -> [(name: String, summary: String)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: ReportPaths.crashReports.path) else { return [] }
        return names.filter { ($0.hasPrefix("Lark-") || $0.hasPrefix("Lark_")) && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .compactMap { n in
                let url = ReportPaths.crashReports.appendingPathComponent(n)
                guard let d = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      d >= since.addingTimeInterval(-5) else { return nil }
                return (n, summarizeCrash((try? String(contentsOf: url, encoding: .utf8)) ?? ""))
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Отправка

@MainActor
enum Telemetry {
    struct Event: Codable, Equatable {
        var id = UUID().uuidString
        var kind: String              // session, error, warning, stats, test
        var time = Date()
        var level: String?
        var category: String?
        var message: String?
        var context: [String]?        // строки журнала перед ошибкой (без названий)
        var info: [String: String]?   // подробности запуска
        var stats: Usage.Store?       // снимок счётчиков
    }

    struct Envelope: Encodable {
        var schema = 1
        let install: String
        let app: [String: String]
        let system: [String: String]
        let sentAt: Date
        let events: [Event]
        enum CodingKeys: String, CodingKey { case schema, install, app, system, sentAt = "sent_at", events }
    }

    // MARK: настройки

    private static var d: UserDefaults { .standard }
    static var enabled: Bool {
        get { d.bool(forKey: "reportsEnabled") }
        set { d.set(newValue, forKey: "reportsEnabled") }
    }
    static var endpoint: String {
        get { d.string(forKey: "reportsURL") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "reportsURL") }
    }
    static var token: String {
        get { d.string(forKey: "reportsToken") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "reportsToken") }
    }
    /// Анонимный номер этой установки — чтобы сервер отличал Mac друг от друга.
    static var installID: String {
        if let id = d.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "installID")
        return id
    }

    static var ingestURL: URL? { ingestURL(from: endpoint) }
    static var isOn: Bool { enabled && ingestURL != nil && !token.isEmpty }

    nonisolated static func ingestURL(from endpoint: String) -> URL? { reportIngestURL(endpoint) }

    // MARK: очередь

    static let maxEvents = 2000
    static let batchSize = 200
    static var outboxURL: URL { ReportPaths.support.appendingPathComponent("outbox.json") }
    private static var outbox: [Event] = loadOutbox()
    private static var sending = false
    private static var retryDelay: TimeInterval = 60
    private static var nextTry = Date.distantPast
    private static var pendingFlush: DispatchWorkItem?
    private static var timer: Timer?
    private static var lastStats = Date.distantPast

    static var queued: Int { outbox.count }

    /// При запуске: что за Mac и счётчики; дальше — отправка раз в 10 минут, ошибки — через несколько секунд.
    static func start() {
        if isOn {
            record(Event(kind: "session", info: sessionInfo()))
            snapshotStats()
            Log.put("report", "отчёты на \(ingestURL?.host ?? "?"), в очереди \(outbox.count)")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated {
                if Date().timeIntervalSince(lastStats) > 6 * 3600 { snapshotStats() }
                flush()
            }
        }
        scheduleFlush(after: 10)
    }

    /// Журнал зовёт это для каждой ошибки и падения.
    static func logged(category: String, message: String, context: [String]) {
        guard isOn, category != "report" else { return }   // свои сбои отправки — не по кругу
        record(Event(kind: "error", level: "ERROR", category: category, message: String(scrubTitles(message).prefix(4000)),
                     context: context.map(scrubTitles)))
        scheduleFlush(after: 5)
    }

    /// Предупреждение: на сервере хранится, в Telegram не приходит.
    static func warning(category: String, message: String) {
        guard isOn else { return }
        record(Event(kind: "warning", level: "WARN", category: category, message: scrubTitles(message)))
    }

    static func snapshotStats() {
        guard isOn else { return }
        lastStats = Date()
        outbox.removeAll { $0.kind == "stats" }
        record(Event(kind: "stats", stats: Usage.snapshot()))
    }

    private static func record(_ e: Event) {
        outbox.append(e)
        if outbox.count > maxEvents { outbox.removeFirst(outbox.count - maxEvents) }   // долго без сети — держим новые
        saveOutbox()
    }

    static func scheduleFlush(after seconds: TimeInterval) {
        pendingFlush?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { flush() } }
        pendingFlush = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// Отправить очередь пачками. Не вышло — события остаются, следующая попытка позже (1 мин … 1 ч).
    static func flush(force: Bool = false) {
        guard isOn, !sending, !outbox.isEmpty, force || Date() >= nextTry else { return }
        let batch = Array(outbox.prefix(batchSize))
        sending = true
        Task { @MainActor in
            let result = await send(batch)
            sending = false
            let ids = Set(batch.map(\.id))
            switch result {
            case .success:
                outbox.removeAll { ids.contains($0.id) }
                saveOutbox()
                retryDelay = 60
                nextTry = .distantPast
                Log.put("report", "отправлено событий: \(batch.count)")
                if !outbox.isEmpty { scheduleFlush(after: 1) }
            case .failure(.http(let code, let body)) where code == 400 || code == 413 || code == 422:
                outbox.removeAll { ids.contains($0.id) }   // сервер эту пачку не примет никогда
                saveOutbox()
                Log.put("report", "сервер отказал (\(code): \(body)) — \(batch.count) событий выброшено")
            case .failure(let e):
                nextTry = Date().addingTimeInterval(retryDelay)
                Log.put("report", "не отправилось (\(e)), следующая попытка через \(Int(retryDelay)) с")
                retryDelay = min(retryDelay * 2, 3600)
            }
        }
    }

    enum SendError: Error, CustomStringConvertible {
        case notConfigured, encode, http(Int, String), transport(String)
        var description: String {
            switch self {
            case .notConfigured: return "не настроено"
            case .encode: return "не удалось собрать"
            case .http(let c, let b): return "HTTP \(c) \(b)"
            case .transport(let m): return m
            }
        }
        var code: Int { if case .http(let c, _) = self { return c }; return 0 }
    }

    static func send(_ events: [Event]) async -> Result<Void, SendError> {
        guard let url = ingestURL, !token.isEmpty else { return .failure(.notConfigured) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let envelope = Envelope(
            install: installID,
            app: ["version": Updater.local, "build": appBuild()],
            system: ["macos": ProcessInfo.processInfo.operatingSystemVersionString, "model": hardwareModel(),
                     "locale": Locale.preferredLanguages.first ?? "?"],
            sentAt: Date(), events: events)
        guard let body = try? enc.encode(envelope) else { return .failure(.encode) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Lark/\(Updater.local)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return .failure(.http(code, String(decoding: data.prefix(300), as: UTF8.self))) }
            return .success(())
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// «Проверить соединение»: тестовое событие сразу. Сервер отвечает на него сообщением в Telegram — проверена вся цепочка.
    static func test() async -> (ok: Bool, text: String) {
        guard enabled else { return (false, tr("Сначала включите отправку", "Turn sending on first", "Lülitage saatmine esmalt sisse")) }
        guard ingestURL != nil else { return (false, tr("Адрес должен начинаться с https://", "The address must start with https://", "Aadress peab algama https://")) }
        guard !token.isEmpty else { return (false, tr("Укажите ключ доступа", "Enter the access key", "Sisestage juurdepääsuvõti")) }
        let r = await send([Event(kind: "test", message: "Проверка соединения из Lark", info: sessionInfo())])
        switch r {
        case .success:
            Log.put("report", "проверка соединения прошла")
            start()
            flush(force: true)
            return (true, tr("Работает: сервер принял тестовое событие, в Telegram должно прийти сообщение",
                             "Works: the server took the test event, a Telegram message should arrive",
                             "Töötab: server võttis testsündmuse vastu, Telegrami peaks tulema sõnum"))
        case .failure(let e):
            Log.put("report", "проверка соединения не прошла: \(e)")
            switch e {
            case .http(401, _), .http(403, _): return (false, tr("Сервер не принял ключ (\(e.code))", "The server refused the key (\(e.code))", "Server ei võtnud võtit vastu (\(e.code))"))
            case .http(404, _): return (false, tr("По этому адресу нет приёмника отчётов (404)", "No report receiver at this address (404)", "Sellel aadressil pole aruannete vastuvõtjat (404)"))
            case .http(let c, _): return (false, tr("Сервер ответил ошибкой \(c)", "The server answered with error \(c)", "Server vastas veaga \(c)"))
            case .transport(let m): return (false, tr("Сервер недоступен: \(m)", "Server unreachable: \(m)", "Server pole kättesaadav: \(m)"))
            default: return (false, "\(e)")
            }
        }
    }

    // MARK: подробности

    static func sessionInfo() -> [String: String] {
        let dd = UserDefaults.standard
        return [
            "keep_output": dd.bool(forKey: Dir.output.keepKey) ? "yes" : "no",
            "keep_input": dd.bool(forKey: Dir.input.keepKey) ? "yes" : "no",
            "blocked": "\((dd.stringArray(forKey: Dir.output.blockedKey) ?? []).count) / \((dd.stringArray(forKey: Dir.input.blockedKey) ?? []).count)",
            "hidden": "\((dd.stringArray(forKey: Hidden.key) ?? []).count)",
            "presets": "\(Presets.decode(dd.data(forKey: Presets.key)).count)",
            "language": Lang.current.rawValue,
        ]
    }

    nonisolated static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func appBuild() -> String {
        Bundle.main.infoDictionary?["LarkBuild"] as? String ?? "local build"
    }

    private static func loadOutbox() -> [Event] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: outboxURL), let e = try? dec.decode([Event].self, from: d) else { return [] }
        return e
    }

    private static func saveOutbox() {
        try? FileManager.default.createDirectory(at: ReportPaths.support, withIntermediateDirectories: true)
        if outbox.isEmpty { try? FileManager.default.removeItem(at: outboxURL); return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(outbox) { try? d.write(to: outboxURL, options: .atomic) }
    }
}

// MARK: - Окно «Отчёты…»

@MainActor
enum ReportsDialog {
    static func show() {
        Usage.count("reports.dialog")
        let a = NSAlert()
        a.messageText = tr("Отчёты на свой сервер", "Reports to your own server", "Aruanded oma serverisse")
        let top = Usage.top(6).map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        a.informativeText = tr(
            "Ошибки, падения, зависания и счётчики функций уходят на ваш сервер (server/lark_server.py в репозитории Lark), ошибки приходят в Telegram. Названия треков и вкладок не отправляются.\n\nНа этом Mac с \(Log.describeDay(Usage.snapshot().since)): \(top.isEmpty ? "пока ничего" : top). В очереди: \(Telemetry.queued).",
            "Errors, crashes, hangs and feature counters go to your server (server/lark_server.py in the Lark repository); errors arrive in Telegram. Track and tab titles are not sent.\n\nOn this Mac since \(Log.describeDay(Usage.snapshot().since)): \(top.isEmpty ? "nothing yet" : top). Queued: \(Telemetry.queued).",
            "Vead, krahhid, hangumised ja funktsioonide loendurid lähevad teie serverisse (server/lark_server.py Larki hoidlas), vead jõuavad Telegrami. Lugude ja vahekaartide nimesid ei saadeta.\n\nSelles Macis alates \(Log.describeDay(Usage.snapshot().since)): \(top.isEmpty ? "veel mitte midagi" : top). Järjekorras: \(Telemetry.queued).")
        let box = NSButton(checkboxWithTitle: tr("Отправлять на сервер", "Send to the server", "Saada serverisse"), target: nil, action: nil)
        box.state = Telemetry.enabled ? .on : .off
        let url = NSTextField(string: Telemetry.endpoint)
        url.placeholderString = "https://lark.example.com"
        let key = NSSecureTextField(string: Telemetry.token)
        key.placeholderString = tr("Ключ доступа", "Access key", "Juurdepääsuvõti")
        let stack = NSStackView(views: [box, url, key])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for f in [url, key] { f.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 84)
        a.accessoryView = stack
        a.addButton(withTitle: tr("Сохранить", "Save", "Salvesta"))
        a.addButton(withTitle: tr("Отмена", "Cancel", "Loobu"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let was = Telemetry.isOn
        Telemetry.enabled = box.state == .on
        Telemetry.endpoint = url.stringValue
        Telemetry.token = key.stringValue
        Log.put("report", "отчёты: \(Telemetry.enabled ? "включены" : "выключены"), адрес \(Telemetry.ingestURL?.host ?? "—")")
        if Telemetry.isOn != was { Usage.count(Telemetry.isOn ? "reports.on" : "reports.off") }
        guard Telemetry.enabled else { return }
        Task { @MainActor in
            let r = await Telemetry.test()
            let b = NSAlert()
            b.alertStyle = r.ok ? .informational : .warning
            b.messageText = r.ok ? tr("Отчёты включены", "Reports are on", "Aruanded on sees") : tr("Не получилось", "Didn’t work", "Ei õnnestunud")
            b.informativeText = r.text
            NSApp.activate(ignoringOtherApps: true)
            b.runModal()
        }
    }
}

/// Зажат ли ⌥ — пункт «Отчёты…» в шестерёнке виден только с ним (или когда отчёты уже настроены).
@MainActor
final class OptionKey: ObservableObject {
    static let shared = OptionKey()
    @Published var down = false
    private var monitor: Any?
    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let d = e.modifierFlags.contains(.option)
            if self?.down != d { self?.down = d }
            return e
        }
    }
}
