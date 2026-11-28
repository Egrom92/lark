// Журнал Lark: что нажали, что открылось и закрылось, что играет, куда идёт звук, сколько заняло и какие были ошибки.
// Только на этом Mac, никуда не отправляется: ~/Library/Logs/Lark/lark.log (5 МБ, потом lark.1.log … lark.3.log).
// Строка: «время [раздел] событие». Разделы: app, panel, menu, ui, device, volume, media, osa, tap, route, perf, error.
import AppKit
import Darwin
import Foundation
import os

enum Log {
    static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Lark")
    static let file = folder.appendingPathComponent("lark.log")
    private static let maxSize: UInt64 = 5 * 1024 * 1024
    private static let keep = 3
    private static let queue = DispatchQueue(label: "lark.log")
    private static let os = Logger(subsystem: "local.lark", category: "lark")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var written: UInt64 = 0
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Записать событие. Можно с любого потока: запись идёт по очереди в фоне.
    static func put(_ cat: String, _ msg: @autoclosure () -> String) {
        let now = Date()
        let text = msg()
        let main = Thread.isMainThread ? "" : " ·bg"
        queue.async {
            let line = "\(stamp.string(from: now)) [\(cat)]\(main) \(text)\n"
            write(line)
            if cat == "error" { os.error("\(text, privacy: .public)") }
        }
    }

    static func error(_ msg: @autoclosure () -> String) { put("error", msg()) }

    /// Код ошибки Core Audio: записать, если не noErr. Возвращает status, чтобы можно было обернуть вызов.
    @discardableResult
    static func check(_ status: OSStatus, _ what: @autoclosure () -> String) -> OSStatus {
        if status != noErr { error("\(what()) → OSStatus \(status) (\(fourCC(status)))") }
        return status
    }

    static func fourCC(_ s: OSStatus) -> String {
        let n = UInt32(bitPattern: s)
        let bytes = [n >> 24, n >> 16, n >> 8, n].map { UInt8($0 & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "\(s)" }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }

    /// Сколько миллисекунд прошло с t0 — для «заняло N мс».
    static func ms(_ t0: Date) -> String { "\(Int((Date().timeIntervalSince(t0) * 1000).rounded())) мс" }

    /// Длинный текст (названия вкладок, ответы скриптов) — укоротить, переводы строк — в «⏎».
    static func short(_ s: String, _ n: Int = 120) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    private static func write(_ line: String) {
        if handle == nil { open() }
        guard let h = handle, let data = line.data(using: .utf8) else { return }
        h.write(data)
        written += UInt64(data.count)
        if written > maxSize { rotate() }
    }

    private static func open() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: file)
        written = (try? handle?.seekToEnd()) ?? 0
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        func url(_ i: Int) -> URL { folder.appendingPathComponent("lark.\(i).log") }
        try? fm.removeItem(at: url(keep))
        for i in stride(from: keep - 1, through: 1, by: -1) { try? fm.moveItem(at: url(i), to: url(i + 1)) }
        try? fm.moveItem(at: file, to: url(1))
        open()
    }

    /// Дописать всё, что в очереди (перед выходом).
    static func flush() { queue.sync { try? handle?.synchronize() } }

    static func reveal() {
        flush()
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}

/// Ползунки и колесо: не сотни строк при перетаскивании, а одна — «с 30% до 75%, 42 шага за 900 мс».
@MainActor
enum Drag {
    private struct State { var from: Double; var to: Double; var steps: Int; var started: Date; var work: DispatchWorkItem? }
    private static var states: [String: State] = [:]

    static func value(_ key: String, _ v: Double, from old: Double? = nil, detail: String = "") {
        var s = states[key] ?? State(from: old ?? v, to: v, steps: 0, started: Date())
        if states[key] == nil { Log.put("ui", "\(key): начали менять (было \(pct(s.from)))\(detail.isEmpty ? "" : " " + detail)") }
        s.to = v; s.steps += 1
        s.work?.cancel()
        let w = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let f = states.removeValue(forKey: key) else { return }
                Log.put("ui", "\(key): \(pct(f.from)) → \(pct(f.to)), \(f.steps) шаг(ов) за \(Log.ms(f.started))")
            }
        }
        s.work = w
        states[key] = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

/// Сторож: замечает, когда главный поток (интерфейс) завис дольше 250 мс, и раз в минуту пишет нагрузку на процессор.
enum Watchdog {
    nonisolated(unsafe) private static var lastCPU: Double = 0
    nonisolated(unsafe) private static var lastAt = Date()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pong = Date()
    nonisolated(unsafe) private static var stallStart: Date?
    nonisolated(unsafe) private static var lastSample = Date.distantPast
    nonisolated(unsafe) private static var samples = 0

    /// Раз в 0.1 с фоновый поток стучится в главный. Не отвечает дольше 0.4 с — сразу снимок того, чем он занят
    /// (/usr/bin/sample, 1 с, файл hang-….txt рядом с журналом; не чаще раза в 20 с и не больше 15 за запуск).
    static func start(panelShown: @escaping @MainActor () -> Bool) {
        let q = DispatchQueue(label: "lark.watchdog", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 0.1)
        t.setEventHandler {
            lock.lock(); let last = pong; lock.unlock()
            let now = Date(), lag = now.timeIntervalSince(last)
            if lag > 0.4, stallStart == nil {
                stallStart = last
                if now.timeIntervalSince(lastSample) > 20, samples < 15 { sample() }
            }
            DispatchQueue.main.async {
                lock.lock(); pong = Date(); lock.unlock()
                if let s = stallStart {
                    stallStart = nil
                    Log.put("perf", "главный поток был занят \(Int(Date().timeIntervalSince(s) * 1000)) мс — интерфейс подвисал")
                }
            }
        }
        t.resume()
        timer = t
        lastCPU = cpuSeconds(); lastAt = Date()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let c = cpuSeconds(), now = Date()
                let pct = (c - lastCPU) / max(now.timeIntervalSince(lastAt), 0.001) * 100
                lastCPU = c; lastAt = now
                Log.put("perf", String(format: "процессор %.1f%% за минуту, память %.0f МБ, панель %@", pct, memoryMB(),
                                       panelShown() ? "открыта" : "закрыта"))
            }
        }
    }

    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    private static func sample() {
        lastSample = Date(); samples += 1
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        let path = Log.folder.appendingPathComponent("hang-\(f.string(from: Date())).txt").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(getpid())", "1", "-mayDie", "-file", path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); Log.put("perf", "главный поток не отвечает — снимаю, чем он занят: \(path)") }
        catch { Log.error("не удалось запустить sample: \(error)") }
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    static func memoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
