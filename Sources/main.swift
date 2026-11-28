// Lark — звук, микрофон и всё, что играет, из строки меню.
// Панель: слева выходы звука, справа микрофоны (с громкостью), под ними наборы «выход + микрофон» (⌃⌥1…9),
// ниже — что играет: Spotify, Музыка, вкладки браузеров (обложка, время, перемотка, громкость), Telegram/Zoom и др.
// «Держать»: если macOS сама переключит устройство (например, при подключении AirPods), Lark вернёт выбранное.
import AppKit
import CoreAudio
import AudioToolbox
import ServiceManagement
import SwiftUI

// MARK: - CoreAudio

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ sel: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

enum Audio {
    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = address(sel)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v)
        return v
    }

    static func allIDs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasStreams(_ id: AudioDeviceID, _ dir: Dir) -> Bool {
        var a = address(kAudioDevicePropertyStreams, dir.scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static func devices(_ dir: Dir) -> [Device] {
        allIDs().compactMap { id in
            guard hasStreams(id, dir), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            // Служебные устройства, которые macOS не показывает в своих настройках
            if uid.hasPrefix("CADefaultDeviceAggregate") { return nil }
            // Своё устройство перехвата звука программ («Lark volume»): его видит только сам Lark, в списках ему не место
            if uid.hasPrefix(AppVolume.uidPrefix) { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? tr("Без названия", "Untitled", "Nimetu")
            return Device(id: id, uid: uid, name: name, transport: uint32(id, kAudioDevicePropertyTransportType))
        }
    }

    static func defaultDevice(_ dir: Dir) -> AudioDeviceID {
        uint32(systemObject, dir.defaultSelector)
    }

    static func setDefault(_ dir: Dir, _ id: AudioDeviceID) {
        var a = address(dir.defaultSelector)
        var v = id
        let name = string(id, kAudioObjectPropertyName) ?? "#\(id)"
        let t0 = Date()
        Log.check(AudioObjectSetPropertyData(systemObject, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v),
                  "сделать основным (\(dir == .output ? "выход" : "микрофон")) \(name)")
        if dir == .output {   // звуки системы — туда же, как в настройках macOS по умолчанию
            var s = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            Log.check(AudioObjectSetPropertyData(systemObject, &s, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v),
                      "звуки системы → \(name)")
        }
        Log.put("device", "\(dir == .output ? "выход" : "микрофон") → \(name), заняло \(Log.ms(t0))")
    }

    /// Громкость 0…1 или nil, если устройство не даёт её менять (например, HDMI).
    static func volume(_ id: AudioDeviceID, _ dir: Dir) -> Float? {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, dir.scope)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    static func setVolume(_ id: AudioDeviceID, _ dir: Dir, _ value: Float) {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, dir.scope)
        var v = Float32(max(0, min(1, value)))
        Log.check(AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v),
                  "громкость устройства #\(id) → \(v)")
        var m = address(kAudioDevicePropertyMute, dir.scope)   // подняли громкость — снять «без звука»
        if v > 0, AudioObjectHasProperty(id, &m) {
            var off: UInt32 = 0
            Log.check(AudioObjectSetPropertyData(id, &m, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off),
                      "снять «без звука» у устройства #\(id)")
        }
    }

    static func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ block: @escaping () -> Void) {
        var a = address(sel)
        Log.check(AudioObjectAddPropertyListenerBlock(obj, &a, DispatchQueue.main) { _, _ in block() },
                  "подписка на \(Log.fourCC(OSStatus(bitPattern: sel)))")
    }
}

// MARK: - Закрепление

final class Keeper {
    let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [Dir.input.keepKey: true, Dir.output.keepKey: false])
        // Первый запуск: закрепить микрофон, выбранный сейчас (не переключать человека молча на другой);
        // если его не определить — встроенный.
        if defaults.string(forKey: Dir.input.pinKey) == nil {
            let inputs = Audio.devices(.input)
            let pick = inputs.first { $0.id == Audio.defaultDevice(.input) }
                ?? inputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            if let p = pick { defaults.set(p.uid, forKey: Dir.input.pinKey) }
        }
        if defaults.string(forKey: Dir.output.pinKey) == nil,
           let cur = Audio.devices(.output).first(where: { $0.id == Audio.defaultDevice(.output) }) {
            defaults.set(cur.uid, forKey: Dir.output.pinKey)
        }
    }

    func keeps(_ dir: Dir) -> Bool { defaults.bool(forKey: dir.keepKey) }
    func pinnedUID(_ dir: Dir) -> String? { defaults.string(forKey: dir.pinKey) }

    func setKeeps(_ dir: Dir, _ on: Bool) {
        Log.put("ui", "«Держать» \(dir == .output ? "выход" : "микрофон"): \(on ? "вкл" : "выкл")")
        defaults.set(on, forKey: dir.keepKey)
        if on, let cur = Audio.devices(dir).first(where: { $0.id == Audio.defaultDevice(dir) }) {
            defaults.set(cur.uid, forKey: dir.pinKey)   // закрепляем то, что выбрано сейчас
        }
    }

    func blocked(_ dir: Dir) -> Set<String> { Set(defaults.stringArray(forKey: dir.blockedKey) ?? []) }

    func setBlocked(_ dir: Dir, _ uid: String, _ on: Bool) {
        Log.put("ui", "\(on ? "заблокировать" : "разблокировать") \(dir == .output ? "выход" : "микрофон") \(uid)")
        var b = blocked(dir)
        if on { b.insert(uid) } else { b.remove(uid) }
        defaults.set(Array(b), forKey: dir.blockedKey)
        if on { enforce(dir) }   // заблокировали выбранное сейчас — сразу уйти с него
    }

    /// Выбор пользователя в меню: сделать основным и запомнить. Выбрал заблокированное сам — значит, оно ему нужно: блокировку снять.
    func choose(_ dir: Dir, _ d: Device) {
        Log.put("device", "выбор пользователя: \(dir == .output ? "выход" : "микрофон") \(d.name)\(blocked(dir).contains(d.uid) ? " (был заблокирован — снимаю блок)" : "")")
        if blocked(dir).contains(d.uid) { setBlocked(dir, d.uid, false) }
        defaults.set(d.uid, forKey: dir.pinKey)
        // Уже выбрано — macOS не трогаем: повторная установка Bluetooth-колонки выходом заставляла macOS
        // молча перекинуть на неё и микрофон (без уведомления), и заблокированный микрофон оставался выбранным.
        if Audio.defaultDevice(dir) == d.id { Log.put("device", "\(d.name) уже выбрано — ничего не меняю"); return }
        Audio.setDefault(dir, d.id)
    }

    /// Уйти с заблокированного устройства; вернуть закреплённое, если macOS переключила на другое.
    func enforce(_ dir: Dir) {
        let b = blocked(dir)
        if !b.isEmpty, let r = replacementDevice(Audio.devices(dir), blocked: b, current: Audio.defaultDevice(dir), pinned: pinnedUID(dir)) {
            if let p = pinnedUID(dir), b.contains(p) { defaults.set(r.uid, forKey: dir.pinKey) }   // закреплено было заблокированное
            Log.put("device", "сейчас выбрано заблокированное (\(dir == .output ? "выход" : "микрофон")) — переключаю на \(r.name)")
            Audio.setDefault(dir, r.id)
            return
        }
        guard keeps(dir), let uid = pinnedUID(dir), !b.contains(uid),
              let d = Audio.devices(dir).first(where: { $0.uid == uid }),
              Audio.defaultDevice(dir) != d.id else { return }
        let cur = Audio.string(Audio.defaultDevice(dir), kAudioObjectPropertyName) ?? "?"
        Log.put("device", "«Держать»: macOS переключила \(dir == .output ? "выход" : "микрофон") на \(cur) — возвращаю \(d.name)")
        Audio.setDefault(dir, d.id)
    }

    func enforceAll() { enforce(.input); enforce(.output) }

    /// Сторож блокировки на своей очереди, не на главном потоке. Замер: после выбора Bluetooth-колонки выходом
    /// macOS сама через 3–40 мс ставит её и микрофоном. Через главный поток Lark возвращал микрофон за 40–60 мс
    /// (столько он был выбран на самом деле, и столько панель его показывала); отсюда — за 3–10 мс.
    func startGuard() {
        let q = DispatchQueue(label: "lark.block-guard", qos: .userInteractive)
        for dir in [Dir.input, .output] {
            var a = address(dir.defaultSelector)
            Log.check(AudioObjectAddPropertyListenerBlock(systemObject, &a, q) { [weak self] _, _ in
                guard let self else { return }
                let b = self.blocked(dir)
                guard !b.isEmpty else { return }
                let all = Audio.devices(dir), cur = Audio.defaultDevice(dir)
                guard let r = replacementDevice(all, blocked: b, current: cur, pinned: self.pinnedUID(dir)) else { return }
                let t0 = Date()
                Audio.setDefault(dir, r.id)
                let was = all.first { $0.id == cur }?.name ?? "?"
                Log.put("device", "сторож: macOS выбрала заблокированное \(dir == .output ? "выходом" : "микрофоном") \(was) — сразу вернул \(r.name) (\(Log.ms(t0)))")
            }, "сторож блокировки")
        }
    }
}
// MARK: - Скрытые устройства

enum Hidden {
    static let key = "hiddenUIDs"
    static var uids: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func set(_ s: Set<String>) { UserDefaults.standard.set(Array(s), forKey: key) }
}

// MARK: - Модель устройств и наборов

@MainActor
final class AudioModel: ObservableObject {
    let keeper = Keeper()
    @Published var outputs: [Device] = []
    @Published var inputs: [Device] = []
    @Published var curOut: AudioDeviceID = 0
    @Published var curIn: AudioDeviceID = 0
    @Published var outVol: Float?
    @Published var inVol: Float?
    @Published var keepOut = false
    @Published var keepIn = false
    @Published var hidden: Set<String> = Hidden.uids
    @Published var blockedOut: Set<String> = []
    @Published var blockedIn: Set<String> = []
    @Published var loginOn = false
    @Published var presets: [Preset] = Presets.decode(UserDefaults.standard.data(forKey: Presets.key))
    @Published var langTick = 0                  // смена языка — перерисовать панель
    @Published var update: String? = Updater.available
    @Published var updateNote: String?           // «У вас последняя версия», «Обновляю…»
    var onPresetsChanged: () -> Void = {}

    func refresh() {
        outputs = Audio.devices(.output)
        inputs = Audio.devices(.input)
        curOut = Audio.defaultDevice(.output)
        curIn = Audio.defaultDevice(.input)
        // macOS могла только что выбрать заблокированное, а сторож вот-вот вернёт своё. Заблокированное выбранным
        // не показываем ни на кадр: рисуем то, на что Lark переключает.
        for dir in [Dir.output, .input] {
            let b = keeper.blocked(dir)
            if let r = replacementDevice(all(dir), blocked: b, current: current(dir), pinned: keeper.pinnedUID(dir)) {
                Log.put("device", "панель: \(dir == .output ? "выход" : "микрофон") сейчас заблокированный — показываю \(r.name)")
                keeper.enforce(dir)
                if dir == .output { curOut = r.id } else { curIn = r.id }
            }
        }
        outVol = Audio.volume(curOut, .output)
        inVol = Audio.volume(curIn, .input)
        keepOut = keeper.keeps(.output)
        keepIn = keeper.keeps(.input)
        hidden = Hidden.uids
        blockedOut = keeper.blocked(.output)
        blockedIn = keeper.blocked(.input)
        loginOn = SMAppService.mainApp.status == .enabled
        for dir in [Dir.output, .input] {   // запомнить имя закреплённого, чтобы показать его, когда оно отключено
            if let uid = keeper.pinnedUID(dir), let d = all(dir).first(where: { $0.uid == uid }) {
                UserDefaults.standard.set(d.name, forKey: dir.pinKey + ".name")
            }
        }
    }

    /// Громкость могли сменить клавишами или в настройках macOS, пока панель открыта, — подтянуть ползунки.
    /// Заодно ловим тихую смену устройства: macOS иногда переключает микрофон, не присылая уведомления.
    func syncVolumes() {
        let o0 = Audio.defaultDevice(.output), i0 = Audio.defaultDevice(.input)
        if o0 != curOut || i0 != curIn {
            Log.put("device", "macOS тихо сменила устройство: выход \(Audio.string(o0, kAudioObjectPropertyName) ?? "?"), микрофон \(Audio.string(i0, kAudioObjectPropertyName) ?? "?") — проверяю блокировки")
            keeper.enforceAll()
            refresh()
        }
        let o = Audio.volume(curOut, .output), i = Audio.volume(curIn, .input)
        if o != outVol { outVol = o }
        if i != inVol { inVol = i }
    }

    func all(_ dir: Dir) -> [Device] { dir == .output ? outputs : inputs }
    func current(_ dir: Dir) -> AudioDeviceID { dir == .output ? curOut : curIn }
    func currentDevice(_ dir: Dir) -> Device? { all(dir).first { $0.id == current(dir) } }
    func keeps(_ dir: Dir) -> Bool { dir == .output ? keepOut : keepIn }
    func volume(_ dir: Dir) -> Float? { dir == .output ? outVol : inVol }

    func visible(_ dir: Dir) -> [Device] { visibleDevices(all(dir), hidden: hidden, current: current(dir)) }

    func choose(_ dir: Dir, _ d: Device) {
        keeper.choose(dir, d)
        UserDefaults.standard.set(d.name, forKey: dir.pinKey + ".name")
        refresh()
        // Bluetooth-гарнитура перехватывает микрофон с задержкой — проверить ещё раз.
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self.keeper.enforceAll(); self.syncVolumes() } }
        }
    }

    func setVolume(_ dir: Dir, _ v: Float) {
        Drag.value("ползунок громкости \(dir == .output ? "выхода" : "микрофона") (\(currentDevice(dir)?.name ?? "?"))", Double(v), from: volume(dir).map(Double.init))
        Audio.setVolume(current(dir), dir, v)
        if dir == .output { outVol = v } else { inVol = v }
    }

    /// Колесо над значком: шаг как у клавиш громкости (1/16) для мыши, плавно для трекпада. Возвращает новую громкость.
    func nudgeOutput(_ delta: Float) -> Float? {
        guard let v = Audio.volume(Audio.defaultDevice(.output), .output) else { return nil }
        let n = max(0, min(1, v + delta))
        Drag.value("колесо над значком: громкость выхода", Double(n), from: Double(v))
        Audio.setVolume(Audio.defaultDevice(.output), .output, n)
        outVol = n
        return n
    }

    func toggleKeep(_ dir: Dir) { keeper.setKeeps(dir, !keeper.keeps(dir)); refresh() }

    func hide(_ d: Device) { Log.put("ui", "скрыть устройство \(d.name)"); var h = Hidden.uids; h.insert(d.uid); Hidden.set(h); refresh() }
    func isBlocked(_ dir: Dir, _ d: Device) -> Bool { (dir == .output ? blockedOut : blockedIn).contains(d.uid) }
    func setBlocked(_ dir: Dir, _ d: Device, _ on: Bool) { keeper.setBlocked(dir, d.uid, on); refresh() }
    func unhide(_ d: Device) { Log.put("ui", "показать устройство \(d.name)"); var h = Hidden.uids; h.remove(d.uid); Hidden.set(h); refresh() }
    func unhideAll() { Log.put("ui", "показать все скрытые устройства"); Hidden.set([]); refresh() }
    /// Скрытые устройства этой колонки, которые сейчас подключены (выбранное и так видно в списке).
    func hiddenDevices(_ dir: Dir) -> [Device] { all(dir).filter { hidden.contains($0.uid) && $0.id != current(dir) } }

    func missingNote(_ dir: Dir) -> String? {
        guard keeps(dir), let uid = keeper.pinnedUID(dir), !all(dir).contains(where: { $0.uid == uid }) else { return nil }
        let name = UserDefaults.standard.string(forKey: dir.pinKey + ".name") ?? tr("Выбранное устройство", "Your device", "Valitud seade")
        return tr("\(name) не подключено — вернётся само", "\(name) is disconnected — Lark will switch back when it returns",
                  "\(name) pole ühendatud — Lark lülitub tagasi, kui see ilmub")
    }

    func toggleLogin() {
        let on = SMAppService.mainApp.status == .enabled
        Log.put("ui", "запуск при входе: \(on ? "выключить" : "включить")")
        do { if on { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { Log.error("запуск при входе: \(error)") }
        refresh()
    }

    // MARK: Наборы

    private func savePresets() {
        Log.put("ui", "наборы: " + presets.map { "«\($0.name)» (\($0.outputName ?? "—") + \($0.inputName ?? "—"))" }.joined(separator: ", "))
        UserDefaults.standard.set(Presets.encode(presets), forKey: Presets.key)
        onPresetsChanged()
    }

    func addPreset(_ name: String) {
        let o = currentDevice(.output), i = currentDevice(.input)
        let n = name.trimmingCharacters(in: .whitespaces)
        presets.append(Preset(id: UUID().uuidString, name: n.isEmpty ? Presets.defaultName(presets) : n,
                              output: o?.uid, input: i?.uid, outputName: o?.name, inputName: i?.name))
        savePresets()
    }

    func overwritePreset(_ p: Preset) {
        guard let k = presets.firstIndex(where: { $0.id == p.id }) else { return }
        let o = currentDevice(.output), i = currentDevice(.input)
        presets[k].output = o?.uid; presets[k].outputName = o?.name
        presets[k].input = i?.uid; presets[k].inputName = i?.name
        savePresets()
    }

    func renamePreset(_ p: Preset, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let k = presets.firstIndex(where: { $0.id == p.id }) else { return }
        presets[k].name = n
        savePresets()
    }

    func deletePreset(_ p: Preset) { Log.put("ui", "удалить набор «\(p.name)»"); presets.removeAll { $0.id == p.id }; savePresets() }

    func movePreset(_ p: Preset, by d: Int) {
        guard let k = presets.firstIndex(where: { $0.id == p.id }), presets.indices.contains(k + d) else { return }
        presets.swapAt(k, k + d)
        savePresets()
    }

    /// Включить набор: выход и микрофон (то, что подключено). Возвращает, чего не хватило.
    @discardableResult
    func applyPreset(_ p: Preset) -> [String] {
        refresh()
        let missing = Presets.missing(p, outputs: outputs, inputs: inputs)
        Log.put("ui", "включить набор «\(p.name)»\(missing.isEmpty ? "" : ", не подключено: " + missing.joined(separator: ", "))")
        if let o = p.output, let d = outputs.first(where: { $0.uid == o }) { keeper.choose(.output, d) }
        if let i = p.input, let d = inputs.first(where: { $0.uid == i }) { keeper.choose(.input, d) }
        refresh()
        return missing
    }

    func isActive(_ p: Preset) -> Bool {
        Presets.isActive(p, outUID: currentDevice(.output)?.uid, inUID: currentDevice(.input)?.uid)
    }
}

// MARK: - Что сейчас играет: запуск скриптов, программы со звуком

/// AppleScript через osascript: отдельный процесс, не подвешивает Lark, если браузер думает.
enum OSA {
    static func run(_ source: String, timeout: TimeInterval = 8) -> (out: String, err: String) {
        guard !source.isEmpty else { return ("", "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input; p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { Log.error("osascript не запустился: \(error)"); return ("", "\(error)") }
        input.fileHandleForWriting.write(source.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()
        let t0 = Date()
        let killer = DispatchWorkItem {
            if p.isRunning { Log.error("osascript не ответил за \(Int(timeout)) с — остановлен: \(Log.short(source, 160))"); p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let res = (String(decoding: o, as: UTF8.self).trimmingCharacters(in: .newlines),
                   String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let took = Date().timeIntervalSince(t0)
        if p.terminationStatus != 0 || took > 3 {
            Log.put("osa", "код \(p.terminationStatus), \(Int(took * 1000)) мс, ошибка: \(Log.short(res.1, 200)) ← \(Log.short(source, 120))")
        }
        return res
    }
}

/// Какие программы выводят звук — по объектам процессов Core Audio (macOS 14.2+). Разрешений не требует.
enum SoundApps {
    struct Proc { let obj: AudioObjectID; let pid: pid_t; let outputting: Bool }

    static func processes() -> [Proc] {
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { Proc(obj: $0, pid: pid_t(Audio.uint32($0, kAudioProcessPropertyPID)),
                              outputting: Audio.uint32($0, kAudioProcessPropertyIsRunningOutput) != 0) }
    }

    /// Обычная программа с окнами, которой принадлежит процесс (для помощников — внешняя .app).
    static func owner(_ pid: pid_t) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, let appPath = outerAppPath(String(cString: buf)),
              let bundle = Bundle(path: appPath)?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { $0.activationPolicy == .regular }
    }

    /// Программы и объекты их процессов: (программа, все её процессы со звуком).
    static func list() -> [(app: SoundApp, objs: [AudioObjectID])] {
        var order: [String] = [], byBundle: [String: (app: SoundApp, objs: [AudioObjectID])] = [:]
        let invisible = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202C}").union(.whitespaces)
        for p in processes() {
            guard let app = owner(p.pid), let b = app.bundleIdentifier else { continue }
            let name = (app.localizedName ?? b).trimmingCharacters(in: invisible)
            if let cur = byBundle[b] {
                byBundle[b] = (SoundApp(bundle: b, name: name, outputting: cur.app.outputting || p.outputting), cur.objs + [p.obj])
            } else {
                order.append(b)
                byBundle[b] = (SoundApp(bundle: b, name: name, outputting: p.outputting), [p.obj])
            }
        }
        return order.compactMap { byBundle[$0] }
    }
}

extension MediaItem {
    /// Как строка называется в журнале: программа, вид и укороченное название.
    var logName: String {
        let kind: String
        switch source {
        case .player: kind = "плеер"
        case .chromeTab(_, let w, let t): kind = "вкладка w\(w)/t\(t)"
        case .safariTab(let w, let i): kind = "вкладка Safari w\(w)/#\(i)"
        case .sound: kind = "программа"
        }
        return "\(appName) [\(kind)] «\(Log.short(title, 50))»"
    }
}

enum MediaProbe {
    /// Какие программы запущены. Только с главного потока: список NSWorkspace обновляется там, а из фонового потока
    /// (особенно сразу после запуска Lark) бывает неполным — тогда Chrome «не запущен» и вкладки пропадают.
    @MainActor static func runningBundles() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Всё, что играет: треки плееров, вкладки браузеров, остальные программы со звуком.
    static func collect(muted: Set<String>, gains: [String: Double] = [:], running: Set<String>)
        -> (items: [MediaItem], hints: [Hint], sound: [(app: SoundApp, objs: [AudioObjectID])]) {
        var items: [MediaItem] = [], hints: [Hint] = [], covered: Set<String> = []
        var timing: [String] = []
        let all0 = Date()
        for p in Media.players where running.contains(p.bundle) {
            let t0 = Date()
            let r = OSA.run(Media.playerScript(p.bundle))
            timing.append("\(p.name) \(Log.ms(t0))")
            if !r.err.isEmpty { Log.put("osa", "\(p.name): опрос плеера — \(Log.short(r.err, 200))") }
            if Media.notPermitted(r.err) { Log.error("\(p.name): нет разрешения «Автоматизация»"); hints.append(Media.deniedHint(p.name)); continue }
            if let item = Media.parsePlayer(r.out, bundle: p.bundle, name: p.name) { items.append(item); covered.insert(p.bundle) }
        }
        for b in Media.browsers where running.contains(b.bundle) {
            let t0 = Date()
            let r = OSA.run(Media.probeScript(b))
            if !r.err.isEmpty { Log.put("osa", "\(b.name): опрос вкладок — \(Log.short(r.err, 200))") }
            if Media.notPermitted(r.err) { Log.error("\(b.name): нет разрешения «Автоматизация»"); hints.append(Media.deniedHint(b.name)); continue }
            let parsed = Media.parseTabs(r.out, b)
            timing.append("\(b.name) \(Log.ms(t0)) (вкладок с медиа: \(parsed.items.count)\(parsed.jsOff ? ", JavaScript из Apple Events выключен" : ""))")
            items += parsed.items
            if parsed.answered > 0 { covered.insert(b.bundle) }   // вкладки видны — общая строка браузера не нужна
            if parsed.jsOff { hints.append(Media.jsHint(b)) }
        }
        let sound = SoundApps.list()
        var extra = soundItems(sound.map(\.app), detailed: items, covered: covered, muted: muted, gains: gains,
                               me: Bundle.main.bundleIdentifier ?? "local.lark")
        for i in extra.indices where extra[i].title == extra[i].appBundle {   // программа закрылась — имя по бандлу
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: extra[i].appBundle) {
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                let e = extra[i]
                extra[i] = MediaItem(id: e.id, source: e.source, appBundle: e.appBundle, appName: name, title: name,
                                     subtitle: e.subtitle, playing: e.playing, muted: e.muted, volume: e.volume)
            }
        }
        timing.append("программы со звуком: \(sound.count)")
        Log.put("media", "опрос за \(Log.ms(all0)): " + timing.joined(separator: ", "))
        return (items + extra, hints, sound)
    }

    static func perform(_ item: MediaItem, _ a: MediaAction, quiet: Bool = false) {
        let t0 = Date()
        let r = OSA.run(Media.actionScript(item, a))
        if quiet, r.err.isEmpty, Date().timeIntervalSince(t0) < 0.5 { return }
        Log.put("osa", "\(item.logName): \(a) выполнено за \(Log.ms(t0))\(r.err.isEmpty ? "" : ", ошибка: " + Log.short(r.err, 200))\(r.out.isEmpty ? "" : ", ответ: " + Log.short(r.out, 80))")
    }
    static func setPlaying(_ item: MediaItem, _ play: Bool) { perform(item, play ? .play : .pause) }
    static func reveal(_ item: MediaItem) {
        let r = OSA.run(Media.revealScript(item))
        Log.put("osa", "открыть \(item.logName)\(r.err.isEmpty ? "" : ", ошибка: " + Log.short(r.err, 200))")
    }
}

@MainActor
final class MediaModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var hints: [Hint] = []
    @Published var loaded = false
    private let queue = DispatchQueue(label: "lark.media")       // опрос «Сейчас играет» (до секунды на Chrome)
    private let actions = DispatchQueue(label: "lark.actions")   // нажатия и громкость: не ждут опроса
    private var volumeWant: [String: Double] = [:]   // строка → громкость, которую ещё надо отправить
    private var volumeBusy: Set<String> = []         // строки, у которых громкость сейчас отправляется
    private var timer: Timer?
    private var busy = false
    private var pending = false
    private var generation = 0                      // действие пользователя делает старые ответы опроса устаревшими
    private var muted: Set<String> = []             // программы, выключенные кнопкой с динамиком
    private var gains: [String: Double] = [:]       // своя громкость программ (Zoom, Teams…)
    private var taps: [String: AppVolume] = [:]     // программа → её перехват звука
    private var routes = Routes.decode(UserDefaults.standard.dictionary(forKey: Routes.key))   // программа → UID устройства
    @Published var outputs: [Device] = []           // куда можно вывести звук программы (обновляет AppDelegate)
    private var soundObjs: [String: [AudioObjectID]] = [:]
    private var tapHint: Hint?
    private var order = StableOrder()               // строки не прыгают при play/pause
    private var lastOutputting: Bool?

    /// Что поменялось в «Сейчас играет» между опросами: появилось, пропало, заиграло, встало, громкость, куда выводится.
    private func logChanges(_ old: [MediaItem], _ new: [MediaItem]) {
        let o = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let n = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = []
        for it in new where o[it.id] == nil {
            lines.append("+ \(it.logName) \(it.playing ? "играет" : "пауза")\(it.volume.map { ", громкость " + Drag.pct($0) } ?? "")\(it.hasExtension ? ", есть «Lark для Chrome»" : "")\((it.sinkName ?? it.routeName).map { ", → " + $0 } ?? "")")
        }
        for it in old where n[it.id] == nil { lines.append("− \(it.logName) пропала") }
        for it in new {
            guard let was = o[it.id] else { continue }
            var d: [String] = []
            if was.playing != it.playing { d.append(it.playing ? "заиграло" : "встало на паузу") }
            if was.muted != it.muted { d.append(it.muted ? "без звука" : "звук вернулся") }
            if let a = was.volume, let b = it.volume, abs(a - b) > 0.005 { d.append("громкость \(Drag.pct(a)) → \(Drag.pct(b))") }
            if was.sinkName != it.sinkName || was.routeName != it.routeName {
                d.append("выход \((was.sinkName ?? was.routeName) ?? "как у всех") → \((it.sinkName ?? it.routeName) ?? "как у всех")")
            }
            if was.title != it.title { d.append("теперь «\(Log.short(it.title, 60))»") }
            if !d.isEmpty { lines.append("~ \(it.logName): " + d.joined(separator: ", ")) }
        }
        if !lines.isEmpty { Log.put("media", "Сейчас играет: " + lines.joined(separator: " | ")) }
    }
    var onReveal: () -> Void = {}

    func start() {
        Log.put("media", "опрос «Сейчас играет» каждые 2 с — включён")
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        Log.put("media", "опрос «Сейчас играет» — выключен")
        timer?.invalidate(); timer = nil
        sinkHint = nil; hints.removeAll { $0.id == "tabsink" }
    }

    func refresh() {
        guard !busy else {
            if !pending { Log.put("media", "опрос ещё идёт — следующий встанет в очередь") }
            pending = true; return
        }
        busy = true
        let gen = generation
        let m = muted, g = gains, run = MediaProbe.runningBundles()
        queue.async {
            let r = MediaProbe.collect(muted: m, gains: g, running: run)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if gen == self.generation {
                        let newItems = self.labelRoutes(self.order.sort(r.items))
                        self.logChanges(self.items, newItems)
                        if newItems != self.items { self.items = newItems }   // без изменений — панель не перерисовывать
                        let newHints = r.hints + (self.tapHint.map { [$0] } ?? []) + (self.sinkHint.map { [$0] } ?? [])
                        if newHints.map(\.id) != self.hints.map(\.id) {
                            Log.put("media", "подсказки в панели: " + (newHints.isEmpty ? "нет" : newHints.map { Log.short($0.text, 90) }.joined(separator: " | ")))
                        }
                        self.hints = newHints
                        for s in r.sound { self.soundObjs[s.app.bundle] = s.objs }
                        for b in self.routes.keys where self.taps[b] == nil { self.applyTap(b) }
                        self.loaded = true
                    } else {
                        Log.put("media", "ответ опроса устарел (пока он шёл, было действие) — отброшен")
                    }
                    self.busy = false
                    if self.pending { self.pending = false; self.refresh() }
                }
            }
        }
    }

    private func act(_ what: String, _ work: @escaping () -> Void) {
        generation += 1
        let queued = Date()
        actions.async {
            let waited = Date().timeIntervalSince(queued)
            if waited > 0.1 { Log.put("perf", "\(what): ждало других действий \(Int(waited * 1000)) мс") }
            work()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    private func update(_ id: String, _ change: (inout MediaItem) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    /// Действие над строкой: сразу показываем результат, потом шлём программе и перепроверяем.
    func perform(_ item: MediaItem, _ a: MediaAction) {
        if item.isSoundOnly {
            switch a {
            case .volume(let v): setAppGain(item.appBundle, v)
            case .play, .pause: toggleMute(item)
            default: break
            }
            return
        }
        let now = Date()
        update(item.id) { it in
            let live = it.livePosition(at: now)
            switch a {
            case .play: it.position = live; it.playing = true
            case .pause: it.position = live; it.playing = false
            case .seek(let s): it.position = max(0, min(s, it.duration ?? s))
            case .skip(let d): it.position = max(0, min((live ?? 0) + d, it.duration ?? .infinity))
            case .volume(let v): it.volume = v
            case .next, .previous: break
            }
            it.fetchedAt = now
        }
        act("\(item.logName): \(a)") { MediaProbe.perform(item, a) }
    }

    func toggle(_ item: MediaItem) {
        Log.put("ui", "кнопка ▶︎/⏸/🔇 у \(item.logName) (сейчас: \(item.isSoundOnly ? (item.muted ? "без звука" : "со звуком") : (item.playing ? "играет" : "пауза")))")
        perform(item, item.isSoundOnly ? .pause : (item.playing ? .pause : .play)) }

    /// Ползунок громкости строки: сразу на экране и сразу программе, пока рука ещё двигает ползунок.
    /// Скрипт идёт ~0.1 с: пока он идёт, новые значения не копятся — отправляется только последнее.
    func setVolume(_ item: MediaItem, _ v: Double) {
        Drag.value("громкость строки \(item.logName)", v, from: items.first { $0.id == item.id }?.volume ?? item.volume)
        if item.isSoundOnly { setAppGain(item.appBundle, v); return }
        generation += 1
        update(item.id) { $0.volume = v }
        volumeWant[item.id] = v
        sendVolume(item)
    }

    private func sendVolume(_ item: MediaItem) {
        guard !volumeBusy.contains(item.id), let v = volumeWant.removeValue(forKey: item.id) else { return }
        volumeBusy.insert(item.id)
        generation += 1
        let t0 = Date()
        actions.async {
            let waited = Date().timeIntervalSince(t0)
            MediaProbe.perform(item, .volume(v), quiet: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.volumeBusy.remove(item.id)
                    Log.put("volume", "\(item.logName): громкость \(Drag.pct(v)) применена через \(Log.ms(t0))\(waited > 0.1 ? " (ждала других действий \(Int(waited * 1000)) мс)" : "")")
                    self.generation += 1
                    if self.volumeWant[item.id] != nil { self.sendVolume(item); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { self.refresh() } }
                }
            }
        }
    }

    // MARK: Звук программ (Telegram, Zoom, Teams…)

    private var defaultOutputUID: String? { Audio.string(Audio.defaultDevice(.output), kAudioDevicePropertyDeviceUID) }

    /// Привести перехват звука программы к нужному: громкость, «без звука», своё устройство вывода.
    /// Пересоздаёт перехват, только если сменились процессы программы или устройство.
    @discardableResult
    private func applyTap(_ b: String) -> Bool {
        let isMuted = muted.contains(b), gain = gains[b] ?? 1
        let target = Routes.target(routes[b], outputs: outputs, defaultUID: defaultOutputUID)
        guard Routes.needsTap(muted: isMuted, gain: gain, target: target) else {
            if let t = taps.removeValue(forKey: b) { Log.put("tap", "\(b): перехват не нужен (громкость 100%, без своего выхода) — убираю"); t.stop() }
            return true
        }
        let eff = Float(isMuted ? 0 : gain)
        let wantUID = target ?? defaultOutputUID
        let objs = soundObjs[b] ?? []
        if let t = taps[b], t.outputUID == wantUID, Set(t.objs) == Set(objs) {
            if t.gain != eff { Log.put("tap", "\(b): громкость перехвата \(Drag.pct(Double(t.gain))) → \(Drag.pct(Double(eff))) (сразу)") }
            t.gain = eff; return true
        }
        // Старый перехват убираем только после того, как готов новый: иначе в промежутке звук программы
        // на мгновение уходит в основной выход (YouTube «прыгает» в колонку и обратно).
        let old = taps.removeValue(forKey: b)
        if let old {
            Log.put("tap", "\(b): пересоздаю перехват — \(old.outputUID != wantUID ? "сменился выход \(old.outputUID) → \(wantUID ?? "?")" : "сменились процессы \(old.objs) → \(objs)")")
        }
        guard !objs.isEmpty else {   // программа пока без звука — применим, когда появится
            old?.stop()
            Log.put("tap", "\(b): у программы сейчас нет звуковых процессов — применю, когда появятся")
            return true
        }
        let t0 = Date()
        defer { old?.stop() }
        guard let t = AppVolume(objs: objs, gain: eff, deviceUID: target) else {
            Log.error("\(b): перехват звука не создался за \(Log.ms(t0)) (выход \(target ?? "как у всех")) — скорее всего нет разрешения «Запись системного звука»")
            tapHint = Hint(id: "tap", text: tr("Чтобы менять громкость и выход программ, разрешите Lark «Запись экрана и системного звука → Только системный звук».",
                                               "To control app volume and output, allow Lark in Screen & System Audio Recording → System Audio Recording Only.",
                                               "Programmide helitugevuse ja väljundi muutmiseks lubage Lark jaotises Ekraani ja süsteemiheli salvestamine → Ainult süsteemiheli."),
                           openPrivacy: true)
            hints.removeAll { $0.id == "tap" }
            hints.append(tapHint!)
            return false
        }
        Log.put("tap", "\(b): перехват создан за \(Log.ms(t0)): процессы \(objs), громкость \(Drag.pct(Double(eff))), выход \(target.flatMap { u in outputs.first { $0.uid == u }?.name } ?? "как у всех")")
        tapHint = nil
        hints.removeAll { $0.id == "tap" }
        taps[b] = t
        return true
    }

    /// Куда выводить звук программы: UID устройства или nil — как у всех. Запоминается.
    func setRoute(_ b: String, _ uid: String?) {
        let t0 = Date()
        Log.put("route", "\(b): выводить в \(uid.flatMap { u in outputs.first { $0.uid == u }?.name } ?? "как у всех")")
        routes[b] = uid
        UserDefaults.standard.set(routes, forKey: Routes.key)
        if !applyTap(b) {
            Log.error("\(b): выход не применён, выбор сброшен")
            routes[b] = nil; UserDefaults.standard.set(routes, forKey: Routes.key)
        }
        Log.put("route", "\(b): готово за \(Log.ms(t0))")
        let live = Routes.target(routes[b], outputs: outputs, defaultUID: defaultOutputUID)
        let name = live.flatMap { u in outputs.first { $0.uid == u }?.name }
        for i in items.indices where items[i].appBundle == b { items[i].routeName = name }
        generation += 1
    }

    func route(_ b: String) -> String? { routes[b] }

    /// Вывести одну вкладку в устройство через «Lark для Chrome». Ответ расширения (data-lark-result) ждём до 3 с.
    /// Не вышло — подсказка в панели держится, пока не получится или панель не закроют (опрос её не стирает).
    func setTabSink(_ item: MediaItem, _ deviceName: String?) {
        Log.put("route", "\(item.logName): только эта вкладка → \(deviceName ?? "как у всех") (через «Lark для Chrome»)")
        let before = item.sinkName
        update(item.id) { $0.sinkName = deviceName }
        generation += 1
        let queued = Date()
        actions.async {
            let t0 = Date()
            _ = OSA.run(Self.tabJS(item, "document.documentElement.removeAttribute('data-lark-result')"))
            let s = OSA.run(Media.tabSinkScript(item, deviceName ?? "default"))
            Log.put("route", "\(item.logName): просьба вкладке отправлена за \(Log.ms(t0)) (ждала \(Int(t0.timeIntervalSince(queued) * 1000)) мс)\(s.err.isEmpty ? "" : ", ошибка скрипта: " + Log.short(s.err, 200))")
            var result = ""
            for _ in 0..<15 {   // ответ расширения: «ok» или «error: …»
                Thread.sleep(forTimeInterval: 0.2)
                result = OSA.run(Self.tabJS(item, "document.documentElement.getAttribute('data-lark-result')||''")).out
                if !result.isEmpty, result != "missing value" { break }
            }
            if result.isEmpty || result == "missing value" {   // старое расширение без data-lark-result
                let e = OSA.run(Media.tabErrorScript(item)).out
                result = e.isEmpty ? "нет ответа (расширение старое или не загружено — перезагрузите его в chrome://extensions)" : "error: " + e
            }
            let ok = result.hasPrefix("ok")
            var extLog = ""
            if !ok { extLog = OSA.run(Self.tabJS(item, "document.documentElement.getAttribute('data-lark-log')||''")).out }
            Log.put("route", "\(item.logName): ответ расширения за \(Log.ms(t0)): \(ok ? "получилось" : "НЕ ПОЛУЧИЛОСЬ — " + Log.short(result, 300))")
            if !extLog.isEmpty, extLog != "missing value" { Log.put("route", "журнал «Lark для Chrome»: \(Log.short(extLog, 1500))") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        self.sinkHint = nil
                    } else {
                        self.update(item.id) { $0.sinkName = before }
                        self.sinkHint = Self.sinkFailureHint(result)
                    }
                    self.hints.removeAll { $0.id == "tabsink" }
                    if let h = self.sinkHint { self.hints.append(h) }
                    self.generation += 1
                    self.refresh()
                }
            }
        }
    }

    private var sinkHint: Hint?

    /// Скрипт для одной вкладки Chrome: выполнить JavaScript и вернуть ответ.
    nonisolated static func tabJS(_ item: MediaItem, _ js: String) -> String {
        guard case .chromeTab(let b, let w, let t) = item.source else { return "" }
        let q = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application id \"\(b)\" to execute tab id \(t) of window id \(w) javascript \"\(q)\""
    }

    /// Почему вкладку не перевести — понятными словами.
    static func sinkFailureHint(_ result: String) -> Hint {
        let r = result.lowercased()
        let firstTime = r.contains("invoked") || r.contains("activetab") || r.contains("capture") || r.contains("permission")
        let text: String
        if firstTime {
            text = tr("Chrome пока не даёт Lark перевести эту вкладку: один раз выберите устройство в самом Chrome — правый щелчок по странице → «Lark: звук этой вкладки». Потом можно отсюда. Весь Chrome можно перевести сразу — пунктами выше.",
                      "Chrome doesn’t let Lark move this tab yet: choose the device once in Chrome itself — right-click the page → Lark: this tab’s sound. After that, you can do it from here. All of Chrome can be moved right away with the items above.",
                      "Chrome ei luba Larkil seda vahekaarti veel suunata: valige seade üks kord Chrome’is — paremklõps lehel → „Lark: selle vahekaardi heli“. Edaspidi saab siit. Kogu Chrome’i saab suunata kohe ülemiste valikutega.")
        } else {
            text = tr("Вкладку не удалось перевести: \(Log.short(result, 120)). Попробуйте один раз в самом Chrome — правый щелчок по странице → «Lark: звук этой вкладки».",
                      "Couldn’t move the tab: \(Log.short(result, 120)). Try once in Chrome itself — right-click the page → Lark: this tab’s sound.",
                      "Vahekaarti ei õnnestunud suunata: \(Log.short(result, 120)). Proovige üks kord Chrome’is — paremklõps lehel → „Lark: selle vahekaardi heli“.")
        }
        return Hint(id: "tabsink", text: text, openPrivacy: false)
    }

    /// Звуковые процессы изменились (программа запустилась, заиграла, закрылась) или сменились устройства:
    /// обновить список процессов и применить сохранённые маршруты — даже когда панель закрыта.
    func reconcile() {
        let list = SoundApps.list()
        let before = soundObjs.filter { !$0.value.isEmpty }.keys.sorted()
        for s in list { soundObjs[s.app.bundle] = s.objs }
        let now = list.map(\.app.bundle).sorted()
        if Set(now) != Set(before) || list.contains(where: { $0.app.outputting }) != lastOutputting {
            Log.put("media", "программы со звуком: " + (list.isEmpty ? "нет" : list.map { "\($0.app.name)\($0.app.outputting ? " ▶︎" : "")" }.joined(separator: ", ")))
            lastOutputting = list.contains(where: { $0.app.outputting })
        }
        for b in Set(routes.keys).union(taps.keys) { applyTap(b) }
    }

    /// Подписать строки: куда выведен звук их программы.
    private func labelRoutes(_ list: [MediaItem]) -> [MediaItem] {
        list.map { it in
            var x = it
            if let key = it.sinkName { x.sinkName = resolveSink(key, outputs.map(\.name)) }
            if let uid = Routes.target(routes[it.appBundle], outputs: outputs, defaultUID: defaultOutputUID) {
                x.routeName = outputs.first { $0.uid == uid }?.name
            }
            return x
        }
    }

    func setAppGain(_ b: String, _ v: Double) {
        gains[b] = v
        let t0 = Date()
        if v > 0.001 { muted.remove(b) }
        update("sound:\(b)") { $0.volume = v; if v > 0.001 { $0.muted = false } }
        if !applyTap(b) { Log.error("\(b): громкость программы не применилась — вернул 100%"); gains[b] = 1; update("sound:\(b)") { $0.volume = 1 } }
        let took = Date().timeIntervalSince(t0)
        if took > 0.05 { Log.put("perf", "\(b): громкость программы применялась \(Int(took * 1000)) мс") }
        generation += 1
    }

    /// Выключить или вернуть звук программы, которой нельзя поставить паузу.
    func toggleMute(_ item: MediaItem) {
        let b = item.appBundle
        Log.put("ui", "\(muted.contains(b) ? "вернуть звук" : "выключить звук") у \(item.logName)")
        if muted.contains(b) { muted.remove(b) } else { muted.insert(b) }
        if !applyTap(b) { Log.error("\(b): «без звука» не применилось"); muted.remove(b) }
        let isMuted = muted.contains(b)
        update(item.id) {
            $0.muted = isMuted
            $0.playing = !isMuted && $0.subtitle != tr("Молчит", "Silent", "Vaikne")
            $0.subtitle = isMuted ? tr("Звук выключен в Lark", "Muted in Lark", "Larkis vaigistatud") : tr("Играет звук", "Playing sound", "Mängib heli")
        }
        generation += 1
        refresh()
    }

    /// Выход звука сменился: перехваты «как у всех» привязаны к старому устройству — пересоздать на новом.
    /// Перехваты со своим устройством (Chrome → динамики Mac) не трогаем: applyTap пересоздаёт только то,
    /// у чего на самом деле сменилось устройство или процессы.
    func rebuildTaps() {
        let list = Array(Set(taps.keys).union(routes.keys))
        if !list.isEmpty { Log.put("tap", "выход сменился — проверяю перехваты: \(list.joined(separator: ", "))") }
        for b in list { applyTap(b) }
    }

    /// Список выходов сменился (подключили или отключили устройство) — пересобрать перехваты. Если список тот же,
    /// ничего не делаем: создание самого перехвата тоже меняет список устройств macOS, и пересборка шла бы по кругу.
    func setOutputs(_ new: [Device]) {
        guard new != outputs else { return }
        Log.put("device", "выходы для программ: " + new.map(\.name).joined(separator: ", "))
        outputs = new
        rebuildTaps()
    }

    func unmuteAll() { Log.put("tap", "выход из Lark: убираю все перехваты (\(taps.count))"); for t in taps.values { t.stop() }; taps.removeAll(); muted.removeAll(); gains.removeAll() }

    /// Пауза (или «без звука») на всём остальном, играет только это.
    func solo(_ item: MediaItem) {
        Log.put("ui", "«Играть только это»: \(item.logName)")
        for o in items where o.playing && o.id != item.id { o.isSoundOnly ? toggleMute(o) : perform(o, .pause) }
        if item.isSoundOnly { if item.muted { toggleMute(item) } } else if !item.playing { perform(item, .play) }
    }

    /// «Пауза везде». Второе нажатие (пока ничего не играет) — вернуть то, что было поставлено на паузу этой кнопкой.
    private var pausedByAll: [MediaItem] = []
    func pauseAll() {
        let playing = items.filter(\.playing)
        Log.put("ui", playing.isEmpty ? "«Вернуть всё»: \(pausedByAll.map(\.logName).joined(separator: ", "))"
                                      : "«Пауза везде»: \(playing.map(\.logName).joined(separator: ", "))")
        if playing.isEmpty {
            for p in pausedByAll {   // только то, что до сих пор стоит: включённое вручную не трогаем
                guard let cur = items.first(where: { $0.id == p.id }) else { continue }
                if cur.isSoundOnly { if cur.muted { toggleMute(cur) } } else if !cur.playing { perform(cur, .play) }
            }
            pausedByAll = []
            return
        }
        pausedByAll = playing
        for p in playing { p.isSoundOnly ? toggleMute(p) : perform(p, .pause) }
    }
    var canResumeAll: Bool { !anyPlaying && !pausedByAll.isEmpty }

    func reveal(_ item: MediaItem) {
        Log.put("ui", "двойной щелчок — открыть \(item.logName)")
        onReveal()
        actions.async { MediaProbe.reveal(item) }
    }

    var anyPlaying: Bool { items.contains(where: \.playing) }
}

/// open -n -W --stdout log.txt -a Lark --args --selftest
/// Проверяет кнопки на настоящих Spotify/Музыке и вкладке браузера (громкость на время проверки почти ноль)
/// и что macOS даёт перехватить звук программы. Пишет ✓/✗ по каждому шагу.
enum SelfTest {
    static func say(_ ok: Bool, _ s: String) { print("\(ok ? "✓" : "✗") \(s)"); fflush(stdout) }
    static func wait(_ s: Double = 1.2) { Thread.sleep(forTimeInterval: s) }

    static func run(running: Set<String>) {
        let r = MediaProbe.collect(muted: [], running: running)
        say(true, "найдено: \(r.items.count) строк, подсказок: \(r.hints.count), программ со звуком в Core Audio: \(r.sound.count)")
        for h in r.hints { print("  ℹ︎ \(h.text)") }
        for it in r.items {
            print("  · \(it.title.prefix(40)) | \(it.subtitle) | обложка: \(it.artworkURL == nil ? "нет" : "есть") | \(it.position.map { clock($0) } ?? "—")/\(it.duration.map { clock($0) } ?? "—") | громкость: \(it.volume.map { String(format: "%.2f", $0) } ?? "—")")
        }

        if let it = r.items.first(where: { $0.isPlayer && !$0.playing }), case .player(let b) = it.source {
            func now() -> MediaItem? { Media.parsePlayer(OSA.run(Media.playerScript(b)).out, bundle: b, name: it.appName) }
            let vol = it.volume ?? 0.5
            MediaProbe.perform(it, .volume(0)); wait(0.5)
            say((now()?.volume ?? 1) < 0.02, "\(it.appName): громкость строки (0)")
            MediaProbe.perform(it, .play); wait()
            say(now()?.playing == true, "\(it.appName): играть")
            MediaProbe.perform(it, .seek(30)); wait(0.6)
            let p1 = now()?.position ?? -1
            say(abs(p1 - 30) < 3, "\(it.appName): перемотка на 0:30 (сейчас \(clock(p1)))")
            MediaProbe.perform(it, .skip(-10)); wait(0.6)
            let p2 = now()?.position ?? -1
            say(abs(p2 - 21) < 4, "\(it.appName): −10 секунд (сейчас \(clock(p2)))")
            MediaProbe.perform(it, .pause); wait()
            say(now()?.playing == false, "\(it.appName): пауза")
            if let p = it.position { MediaProbe.perform(it, .seek(p)) }
            MediaProbe.perform(it, .volume(vol)); wait(0.5)
            say(abs((now()?.volume ?? 0) - vol) < 0.03, "\(it.appName): громкость вернулась (\(Int(vol * 100)))")
        } else { print("— плеер на паузе не найден, пропускаю") }

        if let it = r.items.first(where: { $0.isTab && !$0.playing }), let b = Media.browsers.first(where: { $0.bundle == it.appBundle }) {
            func now() -> MediaItem? { Media.parseTabs(OSA.run(Media.probeScript(b)).out, b).items.first { $0.id == it.id } }
            let vol = it.volume ?? 1, pos = it.position ?? 0
            MediaProbe.perform(it, .volume(0.01)); wait(0.4)
            say(abs((now()?.volume ?? 1) - 0.01) < 0.005, "вкладка «\(it.title.prefix(30))»: громкость строки")
            MediaProbe.perform(it, .play); wait()
            say(now()?.playing == true, "вкладка: играть")
            if (it.duration ?? 0) > 60 {
                MediaProbe.perform(it, .seek(40)); wait(0.4)
                let p = now()?.position ?? -1
                say(abs(p - 40) < 3, "вкладка: перемотка на 0:40 (сейчас \(clock(p)))")
                MediaProbe.perform(it, .skip(10)); wait(0.4)
                let q = now()?.position ?? -1
                say(abs(q - 50) < 3, "вкладка: +10 секунд (сейчас \(clock(q)))")
            }
            MediaProbe.perform(it, .pause); wait()
            say(now()?.playing == false, "вкладка: пауза")
            MediaProbe.perform(it, .seek(pos))
            MediaProbe.perform(it, .volume(vol)); wait(0.4)
            say(abs((now()?.volume ?? 0) - vol) < 0.02, "вкладка: громкость вернулась")
        } else { print("— вкладка на паузе не найдена, пропускаю") }

        if let t = r.items.first(where: { $0.title.hasPrefix("Lark: тестовая страница") }), case .chromeTab(let bb, let w, _) = t.source {
            MediaProbe.reveal(t); wait()
            let active = OSA.run("tell application id \"\(bb)\" to get title of active tab of window id \(w)").out
            say(active.hasPrefix("Lark: тестовая страница"), "двойной щелчок открывает нужную вкладку")
        }

        // Громкость программы на самом Lark: macOS разрешает перехватить звук, громкость меняется на лету.
        NSSound(named: "Tink")?.volume = 0
        NSSound(named: "Tink")?.play()
        Thread.sleep(forTimeInterval: 0.3)
        if let me = SoundApps.processes().first(where: { $0.pid == getpid() }) {
            let v = AppVolume(objs: [me.obj], gain: 0.3)
            say(v != nil, v != nil ? "громкость программы: перехват звука создаётся (доступ есть)"
                                   : "громкость программы: нет доступа «Запись системного звука» для Lark")
            v?.gain = 0.7
            say(v.map { abs($0.gain - 0.7) < 0.001 } ?? false, "громкость программы меняется на лету")
            v?.stop()
            let def = Audio.string(Audio.defaultDevice(.output), kAudioDevicePropertyDeviceUID)
            if let other = Audio.devices(.output).first(where: { $0.uid != def }) {
                let r = AppVolume(objs: [me.obj], gain: 0.5, deviceUID: other.uid)
                say(r?.outputUID == other.uid, "звук программы выводится в выбранное устройство (\(other.name))")
                r?.stop()
            }
        } else { print("— у Lark нет объекта звука, пропускаю перехват") }
    }
}

// MARK: - Интерфейс

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func app(_ bundle: String) -> NSImage {
        if let i = cache[bundle] { return i }
        let img: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)!
        }
        cache[bundle] = img
        return img
    }
}

/// Картинки из сети: фавиконы вкладок, обложки треков, превью видео. Качаются один раз, живут в памяти, пока Lark запущен.
@MainActor
final class Images: ObservableObject {
    static let shared = Images()
    @Published private(set) var images: [String: NSImage] = [:]
    private var requested: Set<String> = []

    /// Положить готовую картинку (снимки для README).
    func preload(_ url: String, _ img: NSImage) { images[url] = img; requested.insert(url) }

    func image(_ url: String?) -> NSImage? {
        guard let url, !url.isEmpty else { return nil }
        if let i = images[url] { return i }
        load(url)
        return nil
    }

    private func load(_ s: String) {
        guard !requested.contains(s), let url = URL(string: s), ["http", "https", "data"].contains(url.scheme ?? "") else { return }
        requested.insert(s)
        var tries = [url]   // фавикон не скачался — пробуем сайт/favicon.ico
        if url.path.contains("icon"), let host = url.host, url.path != "/favicon.ico", let fb = URL(string: "https://\(host)/favicon.ico") {
            tries.append(fb)
        }
        Self.fetch(tries) { img in Images.shared.store(s, img) }
    }

    /// Хранить уменьшенную копию (строке нужно 38 точек, а превью видео бывает на несколько мегабайт) и не копить без конца.
    private func store(_ key: String, _ img: NSImage) {
        if images.count >= 300 { images.removeAll(); requested.removeAll() }
        requested.insert(key)
        images[key] = Self.small(img)
    }

    private static func small(_ img: NSImage, side: CGFloat = 160) -> NSImage {
        let s = img.size, k = side / max(s.width, s.height, 1)
        guard k < 1 else { return img }
        let w = max(1, Int((s.width * k).rounded())), h = max(1, Int((s.height * k).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return img }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: w, height: h))
        out.addRepresentation(rep)
        return out
    }

    nonisolated private static func fetch(_ urls: [URL], _ done: @escaping @MainActor (NSImage) -> Void) {
        guard let url = urls.first else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            if ok, let data, data.count < 12_000_000, let img = NSImage(data: data), img.isValid, img.size.width > 0 {
                DispatchQueue.main.async { MainActor.assumeIsolated { done(img) } }
            } else {
                fetch(Array(urls.dropFirst()), done)
            }
        }.resume()
    }
}

/// Картинка строки: обложка или превью (со значком сайта или программы в углу); без них — фавикон с браузером в углу;
/// без фавикона — значок программы.
struct MediaArt: View {
    let item: MediaItem
    @ObservedObject private var images = Images.shared
    private let size: CGFloat = 38

    var body: some View {
        if let art = images.image(item.artworkURL) {
            Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .overlay(alignment: .bottomTrailing) { badge(images.image(item.iconURL) ?? Icons.app(item.appBundle)) }
        } else if let fav = images.image(item.iconURL) {
            Image(nsImage: fav).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) { badge(Icons.app(item.appBundle)) }
        } else {
            Image(nsImage: Icons.app(item.appBundle)).resizable().frame(width: size - 4, height: size - 4).frame(width: size, height: size)
        }
    }

    private func badge(_ img: NSImage) -> some View {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 15, height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .offset(x: 4, y: 4)
    }
}

/// Фон строки: выбранная — цветом, под мышью — чуть светлее.
struct RowBackground: View {
    var selected = false
    var hover = false
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.2) : (hover ? Color.primary.opacity(0.07) : .clear))
    }
}

struct HoverRow<Content: View>: View {
    var selected = false
    var hovered = false      // нарисовать «под мышью» без мыши (снимки)
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowBackground(selected: selected, hover: hover || hovered))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// Маленькая кнопка-значок в строке устройства: «скрыть», «заблокировать», «показать».
struct RowIcon: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 18)
                .foregroundStyle(active ? Color.accentColor : (hover ? Color.primary : Color.secondary))
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hover ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Строка устройства. При наведении справа появляются значки «Заблокировать» и «Скрыть» (то же — правым щелчком).
struct DeviceRow: View {
    let dir: Dir
    let d: Device
    @ObservedObject var audio: AudioModel
    @State private var hover = false
    static var previewHover: String?   // снимки для README и сайта: строка с этим UID нарисована «под мышью»

    var body: some View {
        let sel = d.id == audio.current(dir)
        let locked = audio.isBlocked(dir, d)
        let shown = hover || Self.previewHover == d.uid
        let blockTitle = dir == .output
            ? tr("Заблокировать как выход: Lark не даст выбрать его автоматически",
                 "Block as output: Lark won’t let it be chosen automatically",
                 "Blokeeri väljundina: Lark ei lase seda automaatselt valida")
            : tr("Заблокировать как микрофон: Lark не даст выбрать его автоматически",
                 "Block as microphone: Lark won’t let it be chosen automatically",
                 "Blokeeri mikrofonina: Lark ei lase seda automaatselt valida")
        let unblockTitle = tr("Разблокировать", "Unblock", "Eemalda blokk")
        let hideTitle = tr("Скрыть из списка", "Hide from list", "Peida loendist")
        Button { audio.choose(dir, d) } label: {
            HoverRow(selected: sel, hovered: Self.previewHover == d.uid) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: d, dir))
                        .frame(width: 18)
                        .foregroundStyle(sel ? Color.accentColor : Color.secondary)
                    Text(displayName(d.name, dir)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if shown {
                        Color.clear.frame(width: sel ? 20 : 44, height: 1)   // место под значки поверх строки
                    } else if locked {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if sel { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor) }
                }
                .opacity(locked && !sel && !shown ? 0.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if shown {
                HStack(spacing: 4) {
                    RowIcon(symbol: locked ? "lock.fill" : "lock.open", help: locked ? unblockTitle : blockTitle, active: locked) {
                        audio.setBlocked(dir, d, !locked)
                    }
                    if !sel { RowIcon(symbol: "eye.slash", help: hideTitle) { audio.hide(d) } }
                }
                .padding(.trailing, sel ? 27 : 6)
            }
        }
        .onHover { hover = $0 }
        .help(locked
              ? (dir == .output
                 ? tr("\(d.name): заблокировано — Lark не даст выбрать его выходом автоматически. Щелчок — выбрать и разблокировать",
                      "\(d.name): blocked — Lark won’t let it become the output automatically. Click to choose and unblock",
                      "\(d.name): blokeeritud — Lark ei lase seda automaatselt väljundiks valida. Klõps valib ja eemaldab bloki")
                 : tr("\(d.name): заблокировано — Lark не даст выбрать его микрофоном автоматически. Щелчок — выбрать и разблокировать",
                      "\(d.name): blocked — Lark won’t let it become the microphone automatically. Click to choose and unblock",
                      "\(d.name): blokeeritud — Lark ei lase seda automaatselt mikrofoniks valida. Klõps valib ja eemaldab bloki"))
              : d.name)
        .contextMenu {
            Button(locked ? unblockTitle : blockTitle) { audio.setBlocked(dir, d, !locked) }
            if !sel { Button(hideTitle) { audio.hide(d) } }
        }
    }
}

struct DeviceColumn: View {
    let dir: Dir
    @ObservedObject var audio: AudioModel
    @State private var showHidden = false
    static var previewShowHidden = false   // снимки: список скрытых раскрыт

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(dir == .output ? tr("Звук", "Sound", "Heli") : tr("Микрофон", "Microphone", "Mikrofon"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { audio.toggleKeep(dir) } label: {
                    Label(tr("Держать", "Keep", "Hoia"), systemImage: audio.keeps(dir) ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(audio.keeps(dir) ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                        .foregroundStyle(audio.keeps(dir) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(dir == .output
                      ? tr("Не давать macOS самой переключать выход (например, на подключившиеся AirPods)",
                           "Don’t let macOS switch the output on its own (for example, to AirPods that just connected)",
                           "Ära lase macOS-il väljundit ise vahetada (näiteks äsja ühendatud AirPodsidele)")
                      : tr("Не давать macOS самой переключать микрофон (например, на подключившиеся AirPods)",
                           "Don’t let macOS switch the microphone on its own (for example, to AirPods that just connected)",
                           "Ära lase macOS-il mikrofoni ise vahetada (näiteks äsja ühendatud AirPodsidele)"))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            if let v = audio.volume(dir) {
                HStack(spacing: 8) {
                    Image(systemName: dir == .output ? "speaker.fill" : "mic.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                    Slider(value: Binding(get: { Double(v) }, set: { audio.setVolume(dir, Float($0)) }), in: 0...1)
                        .controlSize(.small)
                    Image(systemName: dir == .output ? "speaker.wave.3.fill" : "waveform")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }

            let devs = audio.visible(dir)
            if devs.isEmpty {
                Text(tr("Нет устройств", "No devices", "Seadmeid pole")).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            ForEach(devs, id: \.uid) { d in DeviceRow(dir: dir, d: d, audio: audio) }

            // Скрытые никуда не делись: свёрнуты здесь, у каждого — кнопка «Показать»
            let hiddenDevs = audio.hiddenDevices(dir)
            let expanded = showHidden || Self.previewShowHidden
            if !hiddenDevs.isEmpty {
                Button {
                    Log.put("ui", "«Скрытые» в колонке \(dir == .output ? "Звук" : "Микрофон"): \(showHidden ? "свернуть" : "раскрыть")")
                    withAnimation(.easeOut(duration: 0.15)) { showHidden.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text(tr("Скрытые: \(hiddenDevs.count)", "Hidden: \(hiddenDevs.count)", "Peidetud: \(hiddenDevs.count)"))
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(hiddenDevs, id: \.uid) { d in
                        HStack(spacing: 8) {
                            Image(systemName: symbol(for: d, dir)).frame(width: 18).foregroundStyle(.secondary)
                            Text(displayName(d.name, dir)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            RowIcon(symbol: "eye", help: tr("Показать в списке", "Show in list", "Näita loendis")) { audio.unhide(d) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .help(d.name)
                    }
                }
            }

            if let note = audio.missingNote(dir) {
                Label(note, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Наборы «выход + микрофон» одной кнопкой (⌃⌥1…⌃⌥9). «＋ Запомнить» сохраняет то, что выбрано сейчас.
struct PresetBar: View {
    @ObservedObject var audio: AudioModel
    @State private var adding = false
    @State private var renaming: Preset?     // поле названия открыто для этого набора, а не для нового
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 12)).foregroundStyle(.secondary)
                .help(tr("Наборы: выход и микрофон одной кнопкой", "Presets: output and microphone in one click", "Komplektid: väljund ja mikrofon ühe klõpsuga"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(audio.presets.enumerated()), id: \.element.id) { i, p in chip(p, i) }
                    if adding {
                        TextField(tr("Название", "Name", "Nimi"), text: $name)
                            .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 130)
                            .focused($focused)
                            .onSubmit(save)
                            .onExitCommand(perform: cancel)
                        Button(tr("Сохранить", "Save", "Salvesta"), action: save).controlSize(.small)
                        Button(action: cancel) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel(tr("Отмена", "Cancel", "Tühista"))
                    } else {
                        Button {
                            name = Presets.defaultName(audio.presets)
                            adding = true
                            DispatchQueue.main.async { focused = true }
                        } label: {
                            Label(tr("Запомнить", "Save current", "Salvesta praegune"), systemImage: "plus")
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Запомнить выбранные сейчас выход и микрофон как набор", "Save the current output and microphone as a preset",
                                 "Salvesta praegune väljund ja mikrofon komplektina"))
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func save() {
        if let r = renaming { audio.renamePreset(r, name) } else { audio.addPreset(name) }
        cancel()
    }

    private func cancel() { adding = false; renaming = nil }

    private func chip(_ p: Preset, _ i: Int) -> some View {
        let active = audio.isActive(p)
        let missing = Presets.missing(p, outputs: audio.outputs, inputs: audio.inputs)
        let devices = [p.outputName.map { "🔊 \($0)" }, p.inputName.map { "🎙 \($0)" }].compactMap { $0 }.joined(separator: "  ")
        var help = devices
        if let k = Presets.hotkeyLabel(i) { help += "\n" + tr("Сочетание: \(k)", "Shortcut: \(k)", "Kiirklahv: \(k)") }
        if !missing.isEmpty { help += "\n" + tr("Не подключено: ", "Not connected: ", "Pole ühendatud: ") + missing.joined(separator: ", ") }
        return Button { audio.applyPreset(p) } label: {
            HStack(spacing: 5) {
                Text(p.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150)
                if let k = Presets.hotkeyLabel(i) { Text(k).foregroundStyle(active ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.7)) }
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07)))
            .foregroundStyle(active ? Color.accentColor : (missing.isEmpty ? Color.primary : Color.secondary))
        }
        .buttonStyle(.plain)
        .help(help)
        .contextMenu {
            Button(tr("Переименовать…", "Rename…", "Nimeta ümber…")) {
                name = p.name
                renaming = p
                adding = true
                DispatchQueue.main.async { focused = true }
            }
            Button(tr("Обновить текущими устройствами", "Update with current devices", "Uuenda praeguste seadmetega")) { audio.overwritePreset(p) }
            if i > 0 { Button(tr("Сдвинуть левее", "Move left", "Liiguta vasakule")) { audio.movePreset(p, by: -1) } }
            if i < audio.presets.count - 1 { Button(tr("Сдвинуть правее", "Move right", "Liiguta paremale")) { audio.movePreset(p, by: 1) } }
            Divider()
            Button(tr("Удалить", "Delete", "Kustuta"), role: .destructive) { audio.deletePreset(p) }
        }
    }
}

/// Полоска времени: сколько прошло и сколько осталось; щелчок или перетаскивание — перемотка.
struct ProgressLine: View {
    let item: MediaItem
    @ObservedObject var media: MediaModel
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let dur = max(item.duration ?? 1, 1)
            let pos = dragFraction.map { $0 * dur } ?? (item.livePosition(at: ctx.date) ?? 0)
            HStack(spacing: 6) {
                Text(clock(pos)).frame(minWidth: 30, alignment: .trailing)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15)).frame(height: 3)
                        Capsule().fill(Color.accentColor).frame(width: max(3, g.size.width * CGFloat(min(1, pos / dur))), height: 3)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = Double(max(0, min(1, v.location.x / max(g.size.width, 1)))) }
                        .onEnded { v in
                            let f = Double(max(0, min(1, v.location.x / max(g.size.width, 1))))
                            dragFraction = nil
                            media.perform(item, .seek(f * dur))
                        })
                }
                .frame(height: 10)
                Text("−" + clock(dur - pos)).frame(minWidth: 34, alignment: .leading)
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .help(tr("Щёлкните, чтобы перемотать", "Click to seek", "Klõpsake kerimiseks"))
    }
}

struct MediaRow: View {
    let item: MediaItem
    @ObservedObject var media: MediaModel
    @State private var hover = false
    /// Для снимков в README: показать кнопки строки без наведения.
    nonisolated(unsafe) static var showControls = false

    private func small(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                MediaArt(item: item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 4) {
                        Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1)
                        if let dev = item.sinkName ?? item.routeName {
                            Label(dev, systemImage: "arrow.turn.down.right")
                                .labelStyle(.titleAndIcon).lineLimit(1)
                                .foregroundStyle(Color.accentColor)
                                .help(tr("Звук выводится в \(dev)", "Sound goes to \(dev)", "Heli läheb seadmesse \(dev)"))
                        }
                    }
                    .font(.system(size: 11))
                    if item.canSeek { ProgressLine(item: item, media: media).padding(.top, 2) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { media.reveal(item) }
            .help(tr("Двойной щелчок — открыть", "Double-click to open", "Topeltklõps avab"))

            if item.isSoundOnly, let v = item.volume, v < 0.999, !item.muted, !(hover || Self.showControls) {
                Text("\(Int((v * 100).rounded()))%").font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
            if hover || Self.showControls {
                HStack(spacing: 0) {
                    if item.isPlayer {
                        small("backward.fill", tr("Предыдущий трек", "Previous track", "Eelmine lugu")) { media.perform(item, .previous) }
                        small("forward.fill", tr("Следующий трек", "Next track", "Järgmine lugu")) { media.perform(item, .next) }
                    } else if item.canSeek {
                        small("gobackward.10", tr("Назад на 10 секунд", "Back 10 seconds", "10 sekundit tagasi")) { media.perform(item, .skip(-10)) }
                        small("goforward.10", tr("Вперёд на 10 секунд", "Forward 10 seconds", "10 sekundit edasi")) { media.perform(item, .skip(10)) }
                    }
                    RouteMenu(item: item, media: media)
                    if let v = item.volume {
                        Image(systemName: v < 0.01 ? "speaker.slash.fill" : (v < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 18).padding(.leading, 4)
                        Slider(value: Binding(get: { v }, set: { media.setVolume(item, $0) }), in: 0...1)
                            .controlSize(.mini).frame(width: 74)
                            .help(tr("Громкость: \(Int(v * 100))%", "Volume: \(Int(v * 100))%", "Helitugevus: \(Int(v * 100))%"))
                    }
                }
            } else if item.playing {
                // Без бесконечной анимации: она перерисовывала панель 60 раз в секунду (17–21% процессора,
                // интерфейс ждал WindowServer и подвисал до 3 с).
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
            }
            let toggleLabel = item.isSoundOnly ? (item.muted ? tr("Вернуть звук", "Unmute", "Taasta heli") : tr("Выключить звук", "Mute", "Vaigista"))
                                               : (item.playing ? tr("Пауза", "Pause", "Paus") : tr("Играть", "Play", "Mängi"))
            Button { media.toggle(item) } label: {
                Image(systemName: item.isSoundOnly ? (item.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                                   : (item.playing ? "pause.fill" : "play.fill"))
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(item.playing ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(toggleLabel)
            .accessibilityLabel(toggleLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RowBackground(hover: hover))
        .onHover { h in
            hover = h
            Log.put("ui", "мышь \(h ? "навели на" : "ушла со") строку \(item.logName)")
        }
        .contextMenu {
            Button(tr("Играть только это", "Play only this", "Mängi ainult seda")) { media.solo(item) }
            Button(item.isSoundOnly ? (item.muted ? tr("Вернуть звук", "Unmute", "Taasta heli") : tr("Выключить звук", "Mute", "Vaigista"))
                                    : (item.playing ? tr("Пауза", "Pause", "Paus") : tr("Играть", "Play", "Mängi"))) { media.toggle(item) }
            if item.isPlayer {
                Button(tr("Следующий трек", "Next track", "Järgmine lugu")) { media.perform(item, .next) }
                Button(tr("Предыдущий трек", "Previous track", "Eelmine lugu")) { media.perform(item, .previous) }
            }
            if item.canSeek {
                Button(tr("Вперёд на 10 секунд", "Forward 10 seconds", "10 sekundit edasi")) { media.perform(item, .skip(10)) }
                Button(tr("Назад на 10 секунд", "Back 10 seconds", "10 sekundit tagasi")) { media.perform(item, .skip(-10)) }
            }
            Divider()
            Button(tr("Куда выводить звук…", "Sound output…", "Heli väljund…")) {
                Log.put("ui", "правый щелчок → «Куда выводить звук…» у \(item.logName)")
                RouteNSMenu.show(item, media)
            }
            Divider()
            Button(tr("Открыть", "Open", "Ava")) { media.reveal(item) }
        }
    }
}

/// Кнопка «куда выводить» в строке (при наведении). Меню — системное NSMenu: SwiftUI Menu жил внутри кнопки, которая
/// видна только под мышью, и закрывался сам, как только мышь уходила на меню. NSMenu открывается щелчком, держит
/// себя само, а пока оно открыто, панель не перерисовывается (таймер опроса ждёт).
struct RouteMenu: View {
    let item: MediaItem
    @ObservedObject var media: MediaModel
    var body: some View {
        Button {
            Log.put("ui", "кнопка «Куда выводить» у \(item.logName)")
            RouteNSMenu.show(item, media)
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle((item.routeName ?? item.sinkName) != nil ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Куда выводить звук", "Where to send the sound", "Kuhu heli saata"))
        .accessibilityLabel(tr("Куда выводить звук", "Where to send the sound", "Kuhu heli saata"))
    }
}

/// Пункт меню с замыканием.
final class MenuAction: NSObject {
    let run: () -> Void
    let title: String
    init(_ title: String = "", _ run: @escaping () -> Void) { self.title = title; self.run = run }
    @objc func fire() {
        Log.put("menu", "выбран пункт «\(title)»")
        MainActor.assumeIsolated { RouteNSMenu.picked = true }
        run()
    }
}

/// Следит за меню «Куда выводить»: открылось, открылось подменю, закрылось — с выбором или без.
@MainActor
final class MenuWatcher: NSObject, NSMenuDelegate {
    static let shared = MenuWatcher()
    func menuWillOpen(_ menu: NSMenu) {
        Log.put("menu", "открылось \(menu.supermenu == nil ? "меню" : "подменю") «\(menu.title)»: " + menu.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓" : "") + $0.title + ($0.submenu != nil ? " ▸" : "") + ($0.action == nil && $0.submenu == nil && !$0.isSectionHeader ? " (без действия)" : "") }.joined(separator: " | "))
    }
    func menuDidClose(_ menu: NSMenu) {
        let p = RouteNSMenu.picked
        DispatchQueue.main.async {   // выбор пункта приходит после закрытия меню
            MainActor.assumeIsolated {
                if menu.supermenu == nil {
                    Log.put("menu", "меню «\(menu.title)» закрылось \(RouteNSMenu.picked || p ? "с выбором" : "БЕЗ выбора (щёлкнули мимо, Esc или по пункту без действия)")")
                } else {
                    Log.put("menu", "подменю «\(menu.title)» закрылось")
                }
            }
        }
    }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let item, !item.isSeparatorItem { Log.put("menu", "подсвечен «\(item.title)»\(item.submenu != nil ? " ▸" : "")") }
    }
}

@MainActor
enum RouteNSMenu {
    private static func item(_ title: String, on: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(title, run)
        let i = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        i.target = a
        i.representedObject = a   // держит замыкание живым, пока живёт пункт
        i.state = on ? .on : .off
        return i
    }

    private static func devices(into m: NSMenu, outputs: [Device], isOn: (Device?) -> Bool, pick: @escaping (Device?) -> Void) {
        m.addItem(item(tr("Как у всех", "Same as everything", "Nagu kõik"), on: isOn(nil)) { pick(nil) })
        m.addItem(.separator())
        for d in outputs { m.addItem(item(d.name, on: isOn(d)) { pick(d) }) }
    }

    static var picked = false

    static func build(_ it: MediaItem, _ media: MediaModel) -> NSMenu {
        let m = NSMenu(title: "Куда выводить: \(it.logName)")
        m.delegate = MenuWatcher.shared
        m.autoenablesItems = false
        let route = media.route(it.appBundle)
        let appPick: (Device?) -> Void = { media.setRoute(it.appBundle, $0?.uid) }
        let appOn: (Device?) -> Bool = { d in d.map { $0.uid == route } ?? (route == nil) }
        guard it.isTab else {
            m.addItem(.sectionHeader(title: tr("Куда выводить \(it.appName)", "Output for \(it.appName)", "\(it.appName) väljund")))
            devices(into: m, outputs: media.outputs, isOn: appOn, pick: appPick)
            return m
        }
        // Сначала то, что работает всегда, — весь браузер; одна вкладка — подменю (ей нужно «Lark для Chrome»).
        m.addItem(.sectionHeader(title: tr("Весь \(it.appName)", "All of \(it.appName)", "Kogu \(it.appName)")))
        devices(into: m, outputs: media.outputs, isOn: appOn, pick: appPick)
        m.addItem(.separator())
        if it.hasExtension {
            let title = tr("Только эта вкладка", "Only this tab", "Ainult see vahekaart") + (it.sinkName.map { " → \($0)" } ?? "")
            let one = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            sub.delegate = MenuWatcher.shared
            devices(into: sub, outputs: media.outputs, isOn: { d in d.map { $0.name == it.sinkName } ?? (it.sinkName == nil) },
                    pick: { media.setTabSink(it, $0?.name) })
            one.submenu = sub
            m.addItem(one)
        } else if it.appBundle != Media.safari {   // в Safari расширение Chrome не поставить
            m.addItem(item(tr("Только эта вкладка: поставить «Lark для Chrome»…", "Only this tab: install Lark for Chrome…",
                              "Ainult see vahekaart: paigalda „Lark Chrome’ile“…")) { ChromeExtension.openInstall(it.appBundle) })
        }
        return m
    }

    /// Открыть меню у мыши. Если Lark ещё не стал активной программой (панель только что открылась поверх другой),
    /// macOS закрыла бы меню в момент переключения — поэтому сначала дождаться активности, потом открыть.
    static func show(_ it: MediaItem, _ media: MediaModel) {
        let at = NSEvent.mouseLocation
        let t0 = Date()
        let open = {
            picked = false
            Log.put("menu", "открываю меню у \(it.logName) (Lark активна: \(NSApp.isActive), ждали \(Log.ms(t0)), выходов: \(media.outputs.count))")
            let r = build(it, media).popUp(positioning: nil, at: at, in: nil)
            Log.put("menu", "меню у \(it.logName) отпустило управление (popUp → \(r))")
            return r
        }
        if NSApp.isActive { _ = open(); return }
        Log.put("menu", "Lark не активна — сначала активирую, потом открою меню")
        NSApp.activate(ignoringOtherApps: true)
        func wait(_ left: Int) {
            if NSApp.isActive || left == 0 {
                if left == 0 { Log.error("Lark так и не стала активной за 600 мс — открываю меню как есть") }
                DispatchQueue.main.async { _ = open() }   // после того как macOS закончит переключение
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { wait(left - 1) }
            }
        }
        wait(20)
    }
}

/// «Lark для Chrome»: расширение лежит рядом с программой; ставится вручную через chrome://extensions → «Загрузить распакованное».
enum ChromeExtension {
    static var folder: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Lark/Chrome") }

    /// browser — в каком браузере открыть страницу расширений (Brave, Edge, Arc и другие родственники Chrome её тоже понимают).
    static func openInstall(_ browser: String = "com.google.Chrome") {
        Log.put("ui", "инструкция «Lark для Chrome» (\(browser))")
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
           let u = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([u], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
        let a = NSAlert()
        a.messageText = tr("Как поставить «Lark для Chrome»", "How to install Lark for Chrome", "Kuidas paigaldada „Lark Chrome’ile“")
        a.informativeText = tr("1. В открывшейся странице Chrome включите «Режим разработчика» (справа вверху).\n2. Нажмите «Загрузить распакованное расширение» и выберите папку Chrome, которую показал Finder.\n3. Готово: правый щелчок по странице → «Lark: звук этой вкладки» → устройство.",
                               "1. On the Chrome page that opened, turn on Developer mode (top right).\n2. Click Load unpacked and choose the Chrome folder shown in Finder.\n3. Done: right-click a page → Lark: this tab’s sound → device.",
                               "1. Lülitage avanenud Chrome’i lehel sisse arendaja režiim (üleval paremal).\n2. Klõpsake „Laadi lahtipakitud“ ja valige Finderis näidatud kaust Chrome.\n3. Valmis: paremklõps lehel → „Lark: selle vahekaardi heli“ → seade.")
        NSApp.activate()
        a.runModal()
    }
}

struct MediaSection: View {
    @ObservedObject var media: MediaModel
    static let maxRows = 6
    /// Высота прокручиваемого списка: шесть с половиной строк (половина подсказывает, что ниже есть ещё),
    /// на маленьком экране меньше — чтобы панель целиком помещалась.
    @MainActor static var scrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, min(376, screen - 500))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("Сейчас играет", "Now playing", "Praegu mängib")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if media.anyPlaying || media.canResumeAll {
                    Button { media.pauseAll() } label: {
                        Label(media.anyPlaying ? tr("Пауза везде", "Pause all", "Paus kõikjal") : tr("Вернуть всё", "Resume all", "Jätka kõike"),
                              systemImage: media.anyPlaying ? "pause.circle" : "play.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help(media.anyPlaying
                          ? tr("Поставить на паузу всё; второе нажатие вернёт как было", "Pause everything; click again to resume what was playing",
                               "Pane kõik pausile; teine klõps jätkab seda, mis mängis")
                          : tr("Включить то, что было на паузе этой кнопкой", "Resume what this button paused", "Jätka seda, mis selle nupuga peatati"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            if !media.loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Смотрю, что играет…", "Looking for what’s playing…", "Otsin, mis mängib…")).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            } else if media.items.isEmpty {
                Text(tr("Ничего не играет", "Nothing is playing", "Midagi ei mängi")).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            // Много строк (десяток вкладок с начатыми видео) — список прокручивается, иначе панель выше экрана.
            let rows = VStack(alignment: .leading, spacing: 4) { ForEach(media.items) { MediaRow(item: $0, media: media) } }
            if media.items.count > Self.maxRows {
                ScrollView { rows }.frame(height: Self.scrollHeight)
            } else {
                rows
            }

            ForEach(media.hints) { h in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(h.text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if h.openPrivacy {
                        Spacer(minLength: 0)
                        Button(tr("Открыть", "Open", "Ava")) {
                            Log.put("ui", "подсказка «\(h.id)» → «Открыть» настройки конфиденциальности")
                            let pane = h.id == "tap" ? "Privacy_ScreenCapture" : "Privacy_Automation"
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 4)
            }
        }
    }
}

struct PanelView: View {
    @ObservedObject var audio: AudioModel
    @ObservedObject var media: MediaModel
    var onLanguage: (Lang?) -> Void = { _ in }
    var onCheckUpdate: () -> Void = {}
    var onUpdate: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                DeviceColumn(dir: .output, audio: audio)
                Divider()
                DeviceColumn(dir: .input, audio: audio)
            }
            .padding(10)

            Divider()
            PresetBar(audio: audio)
            Divider()
            MediaSection(media: media).padding(10)
            Divider()

            HStack(spacing: 12) {
                Button(tr("Настройки звука macOS…", "macOS Sound Settings…", "macOS-i heliseaded…")) {
                    Log.put("ui", "«Настройки звука macOS…»")
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if let note = audio.updateNote {
                    Text(note).foregroundStyle(.secondary)
                } else if let v = audio.update {
                    Button(action: onUpdate) {
                        Label(tr("Обновить до \(v)", "Update to \(v)", "Uuenda versioonile \(v)"), systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                Menu {
                    Toggle(tr("Запускать при входе в систему", "Open at login", "Ava sisselogimisel"),
                           isOn: Binding(get: { audio.loginOn }, set: { _ in audio.toggleLogin() }))
                    Menu(tr("Язык", "Language", "Keel")) {
                        let forced = UserDefaults.standard.string(forKey: "language")
                        Button((forced == nil ? "✓ " : "") + tr("Как в системе", "Same as system", "Nagu süsteemis")) { onLanguage(nil) }
                        ForEach(Lang.allCases, id: \.self) { l in
                            Button((forced == l.rawValue ? "✓ " : "") + l.selfName) { onLanguage(l) }
                        }
                    }
                    Button(tr("Lark для Chrome: звук отдельной вкладки…", "Lark for Chrome: sound of a single tab…", "Lark Chrome’ile: ühe vahekaardi heli…")) {
                        ChromeExtension.openInstall()
                    }
                    if !audio.hidden.isEmpty {
                        Button(tr("Показать скрытые устройства (\(audio.hidden.count))", "Show hidden devices (\(audio.hidden.count))",
                                  "Näita peidetud seadmeid (\(audio.hidden.count))")) { audio.unhideAll() }
                    }
                    Button(tr("Показать журнал Lark", "Show Lark log", "Näita Larki logi")) {
                        Log.put("ui", "«Показать журнал»")
                        Log.reveal()
                    }
                    Divider()
                    if let v = audio.update {
                        Button(tr("Обновить до \(v)", "Update to \(v)", "Uuenda versioonile \(v)"), action: onUpdate)
                    } else {
                        Button(tr("Проверить обновления", "Check for updates", "Kontrolli uuendusi"), action: onCheckUpdate)
                    }
                    Text("Lark \(Updater.local)")
                    Divider()
                    Button(tr("Выйти из Lark", "Quit Lark", "Sulge Lark")) { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .overlay(alignment: .topTrailing) {
                    if audio.update != nil { Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                }
                .help(tr("Настройки Lark", "Lark settings", "Larki seaded"))
                .accessibilityLabel(tr("Настройки Lark", "Lark settings", "Larki seaded"))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .font(.system(size: 13))
        .frame(width: 600)
        .id(audio.langTick)
    }
}

// MARK: - Приложение

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let audio = AudioModel()
    let media = MediaModel()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    private var outsideClicks: Any?
    private var flashWork: DispatchWorkItem?
    private var previousApp: NSRunningApplication?   // кто был активен до открытия панели — ему вернём клавиатуру
    private var volumeTimer: Timer?
    private var closeReason: String?                 // кто закрыл панель — для журнала
    private var openedAt = Date()

    /// Текущее событие мыши или клавиатуры: что именно нажали, где и в каком окне.
    static func eventInfo(_ given: NSEvent? = nil) -> String {
        guard let e = given ?? NSApp.currentEvent else { return "без события" }
        let kinds: [NSEvent.EventType: String] = [.leftMouseDown: "щелчок", .leftMouseUp: "отпускание кнопки", .rightMouseDown: "правый щелчок",
                                                  .rightMouseUp: "отпускание правой", .otherMouseDown: "средняя кнопка", .keyDown: "клавиша",
                                                  .appKitDefined: "системное событие", .systemDefined: "системное событие", .scrollWheel: "колесо"]
        let kind = kinds[e.type] ?? "тип \(e.type.rawValue)"
        let key = e.type == .keyDown ? " код \(e.keyCode)" : ""
        let win = e.window.map { w in w.className + (w.title.isEmpty ? "" : " «\(w.title)»") } ?? "вне окон Lark"
        let p = NSEvent.mouseLocation
        return "\(kind)\(key) в (\(Int(p.x)), \(Int(p.y))), окно: \(win)"
    }

    /// Начало журнала: версия, macOS, устройства и настройки — чтобы было понятно, с чего всё начиналось.
    private func logSession() {
        let v = ProcessInfo.processInfo.operatingSystemVersionString
        Log.put("app", "════ Lark \(Updater.local) запущен, macOS \(v), pid \(getpid()), \(Bundle.main.bundlePath)")
        let d = UserDefaults.standard
        for dir in [Dir.output, .input] {
            let all = Audio.devices(dir), cur = Audio.defaultDevice(dir)
            Log.put("app", "\(dir == .output ? "выходы" : "микрофоны"): " + all.map { ($0.id == cur ? "●" : "") + $0.name + " [\($0.uid)]" }.joined(separator: ", "))
            Log.put("app", "\(dir == .output ? "выход" : "микрофон"): держать \(audio.keeper.keeps(dir)), закреплён \(audio.keeper.pinnedUID(dir) ?? "—"), заблокированы \(audio.keeper.blocked(dir).sorted())")
        }
        Log.put("app", "скрыты: \(Hidden.uids.sorted()), выходы программ: \(d.dictionary(forKey: Routes.key) ?? [:]), наборов: \(audio.presets.count), язык: \(d.string(forKey: "language") ?? "как в системе")")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login") {   // нужно для uninstall.sh
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--selftest") {   // проверка кнопок на настоящих программах, без звука
            afterLaunch { running in SelfTest.run(running: running) }
            return
        }
        if CommandLine.arguments.contains("--probe") {   // диагностика: что Lark видит сейчас (open -a Lark --args --probe)
            afterLaunch { running in
                let r = MediaProbe.collect(muted: [], running: running)
                var lines = r.items.map { "\($0.playing ? "▶" : "⏸") \($0.title) — \($0.subtitle)\($0.iconURL.map { " [\($0)]" } ?? "")" }
                lines += r.hints.map { "ℹ︎ \($0.text)" }
                lines += r.sound.map { "♪ \($0.app.name) (\($0.app.bundle)) звук: \($0.app.outputting ? "да" : "нет"), процессов: \($0.objs.count)" }
                for b in Media.browsers where running.contains(b.bundle) {   // сырой ответ браузера: сколько вкладок ответило, последняя ошибка
                    let t0 = Date()
                    let o = OSA.run(Media.probeScript(b))
                    let tail = o.out.components(separatedBy: "\n").last ?? ""
                    if CommandLine.arguments.contains("--ext"), !b.isSafari {   // метки «Lark для Chrome» на вкладках
                        let js = "(document.documentElement.getAttribute('data-lark-ext')||'-')+'|'+(document.documentElement.getAttribute('data-lark-sink')||'')+'|'+document.querySelectorAll('video,audio').length+'|'+(document.documentElement.getAttribute('data-lark-diag')||'')"
                        let d = OSA.run("tell application id \"\(b.bundle)\"\nset out to \"\"\nrepeat with w in windows\nrepeat with t in tabs of w\ntry\nset out to out & (execute t javascript \"\(js)\") & \" :: \" & (title of t) & linefeed\nend try\nend repeat\nend repeat\nreturn out\nend tell")
                        lines.append("🧩\n" + d.out + d.err)
                    }
                    if CommandLine.arguments.contains("--tabs"), !b.isSafari {   // каждая вкладка с медиа: состояние роликов
                        let dbg = "(function(){try{var v=[].slice.call(document.querySelectorAll('video,audio'));if(!v.length)return '';var r=" + Media.probeJS + ";return location.hostname+' n='+v.length+' '+v.map(function(x){return (x.paused?'P':'p')+(x.muted?'M':'m')+x.volume+'/rs'+x.readyState+'/t'+Math.round(x.currentTime)+'/d'+Math.round(x.duration)+'/src'+((x.currentSrc||'').slice(0,5))}).join(',')+' => '+(r===''?'EMPTY':r.slice(0,1))}catch(err){return 'ERR '+err.message}})()"
                        let d = OSA.run("tell application id \"\(b.bundle)\"\nset out to \"\"\nrepeat with w in windows\nrepeat with t in tabs of w\ntry\nset r to execute t javascript \"\(dbg)\"\nif r is not missing value and r is not \"\" then set out to out & (title of t) & \" :: \" & r & linefeed\non error e\nset out to out & (title of t) & \" :: ERROR \" & e & linefeed\nend try\nend repeat\nend repeat\nreturn out\nend tell")
                        lines.append("🐞\n" + d.out + d.err)
                    }
                    lines.append("🔎 \(b.name) за \(String(format: "%.1f", Date().timeIntervalSince(t0))) с: \(tail.replacingOccurrences(of: Media.sep, with: " | "))\(o.err.isEmpty ? "" : " | " + o.err)")
                }
                print(lines.isEmpty ? "Ничего не играет" : lines.joined(separator: "\n"))
                fflush(stdout)
            }
            return
        }

        logSession()
        Watchdog.start { [weak self] in self?.popover.isShown ?? false }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Log.put("app", "Lark стала активной программой")
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            Log.put("app", "Lark перестала быть активной (впереди теперь \(front))")
        }
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { n in
            Log.put("menu", "начало работы с меню «\((n.object as? NSMenu)?.title ?? "?")»")
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { n in
            Log.put("menu", "конец работы с меню «\((n.object as? NSMenu)?.title ?? "?")»")
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { n in
            if let w = n.object as? NSWindow { Log.put("panel", "окно \(w.className) потеряло фокус клавиатуры") }
        }
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            if let w = n.object as? NSWindow { Log.put("panel", "окно \(w.className) получило фокус клавиатуры") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { Log.put("app", "запущена программа \(a.localizedName ?? "?") (\(a.bundleIdentifier ?? "?"))") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { Log.put("app", "закрыта программа \(a.localizedName ?? "?") (\(a.bundleIdentifier ?? "?"))") }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageLeading

        makePanel()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // Закрыть после того, как двойной щелчок доработает: закрытие посреди жеста ломало приём щелчков панелью.
        media.onReveal = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.closePanel("открыли программу двойным щелчком") } }
        }
        audio.onPresetsChanged = { [weak self] in self?.registerHotkeys() }

        audio.refresh()
        media.outputs = audio.outputs
        media.reconcile()
        updateIcon()
        registerHotkeys()
        // Программа начала или перестала работать со звуком — применить её сохранённый выход (и при закрытой панели).
        Audio.listen(systemObject, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated { self?.media.reconcile() }
        }

        var lastDevs = Set(Audio.allIDs())
        let changed: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.audio.keeper.enforceAll()
                self?.audio.refresh()
                self?.updateIcon()
            }
        }
        Audio.listen(systemObject, kAudioHardwarePropertyDefaultInputDevice) {
            Log.put("device", "macOS: основной микрофон теперь \(Audio.string(Audio.defaultDevice(.input), kAudioObjectPropertyName) ?? "?")")
            changed()
        }
        Audio.listen(systemObject, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            Log.put("device", "macOS: основной выход теперь \(Audio.string(Audio.defaultDevice(.output), kAudioObjectPropertyName) ?? "?")")
            changed()
            MainActor.assumeIsolated { self?.media.rebuildTaps() }   // громкость программ — на новый выход
        }
        Audio.listen(systemObject, kAudioHardwarePropertyDevices) { [weak self] in
            let now = Set(Audio.allIDs())
            func names(_ ids: Set<AudioDeviceID>) -> String {
                ids.map { id in (Audio.string(id, kAudioObjectPropertyName) ?? "#\(id)") + ((Audio.string(id, kAudioDevicePropertyDeviceUID) ?? "").hasPrefix(AppVolume.uidPrefix) ? " (служебное Lark)" : "") }.joined(separator: ", ")
            }
            let added = now.subtracting(lastDevs), removed = lastDevs.subtracting(now)
            Log.put("device", "список устройств изменился\(added.isEmpty ? "" : ", добавлены: " + names(added))\(removed.isEmpty ? "" : ", убраны: #" + removed.map(String.init).joined(separator: ", #"))")
            lastDevs = now
            changed()
            MainActor.assumeIsolated {   // устройство подключили или отключили — выходы программ пересобрать
                if let self { self.media.setOutputs(self.audio.outputs) }
            }
            // Bluetooth-устройства иногда «перехватывают» вход с задержкой после подключения
            for delay in [0.7, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self?.audio.keeper.enforceAll() } }
            }
        }
        audio.keeper.enforceAll()
        audio.keeper.startGuard()
        enableLoginItemOnce()

        // Колесо мыши или два пальца над значком — громкость выхода.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, let w = self.statusItem.button?.window, e.window === w else { return e }
            let dy = Float(e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY)
            guard dy != 0 else { return nil }
            let delta = e.hasPreciseScrollingDeltas ? dy * 0.004 : (dy > 0 ? 1 : -1) / 16
            if let v = self.audio.nudgeOutput(delta) { self.flash("\(Int((v * 100).rounded()))%") }
            return nil
        }

        // Новая версия: при запуске и раз в день смотрим, не прошла ли неделя с прошлой проверки.
        checkUpdate(force: false)
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUpdate(force: false) }
        }
    }

    /// Для --probe/--selftest: дать главному потоку получить список запущенных программ, работу — в фоне, потом выйти.
    private func afterLaunch(_ work: @escaping (Set<String>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let running = MediaProbe.runningBundles()
            DispatchQueue.global().async {
                work(running)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    private func makePanel() {
        let view = PanelView(audio: audio, media: media,
                             onLanguage: { [weak self] l in self?.setLanguage(l) },
                             onCheckUpdate: { [weak self] in self?.checkUpdate(force: true, report: true) },
                             onUpdate: { [weak self] in self?.runUpdate() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    private func setLanguage(_ l: Lang?) {
        Log.put("ui", "язык: \(l?.rawValue ?? "как в системе")")
        if let l { UserDefaults.standard.set(l.rawValue, forKey: "language") } else { UserDefaults.standard.removeObject(forKey: "language") }
        Lang.current = Lang.detect()
        audio.langTick += 1
        updateIcon()
        media.refresh()
    }

    private func checkUpdate(force: Bool, report: Bool = false) {
        if report { Log.put("ui", "«Проверить обновления»") }
        if report { audio.updateNote = tr("Проверяю…", "Checking…", "Kontrollin…") }
        Updater.check(force: force) { [weak self] v, reached in
            guard let self else { return }
            Log.put("app", "проверка обновлений: \(v.map { "есть \($0)" } ?? (reached ? "последняя версия" : "GitHub недоступен"))")
            self.audio.update = v
            if report {
                self.audio.updateNote = v != nil ? nil
                    : reached ? tr("У вас последняя версия", "You have the latest version", "Teil on uusim versioon")
                    : tr("Не удалось проверить — нет связи с GitHub", "Couldn’t check — GitHub is unreachable", "Kontroll ebaõnnestus — GitHub pole kättesaadav")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { self.audio.updateNote = nil } }
            }
        }
    }

    private func runUpdate() {
        Log.put("ui", "«Обновить» — запускаю установщик (журнал: ~/Library/Logs/Lark-update.log)")
        Log.flush()
        audio.updateNote = tr("Обновляю… Lark перезапустится сам", "Updating… Lark will restart", "Uuendan… Lark käivitub uuesti")
        Updater.install { [weak self] in
            MainActor.assumeIsolated {
                Log.error("обновление не удалось — подробности в ~/Library/Logs/Lark-update.log")
                self?.audio.updateNote = tr("Обновить не удалось — попробуйте позже", "Update failed — try again later", "Uuendamine ebaõnnestus — proovige hiljem")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { self?.audio.updateNote = nil } }
            }
        }
    }

    private func registerHotkeys() {
        let list = audio.presets.prefix(Presets.maxHotkeys).map { p in
            { [weak self] in
                guard let self else { return }
                Log.put("ui", "сочетание клавиш для набора «\(p.name)»")
                let missing = self.audio.applyPreset(p)
                self.flash(missing.isEmpty ? p.name : "\(p.name): " + tr("нет ", "missing ", "puudub ") + missing.joined(separator: ", "))
            }
        }
        Hotkeys.shared.setDigits(Array(list))
    }

    /// Короткая надпись рядом со значком (громкость колесом, включённый набор).
    private func flash(_ text: String) {
        statusItem.button?.title = " " + text
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.statusItem.button?.title = "" }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    /// Закрыть панель и записать почему.
    private func closePanel(_ why: String) {
        closeReason = why
        popover.performClose(nil)
    }

    @objc private func togglePopover() {
        if popover.isShown { closePanel("щелчок по значку в строке меню (\(Self.eventInfo()))"); return }
        guard let b = statusItem.button else { return }
        openedAt = Date()
        Log.put("panel", "открываю панель (\(Self.eventInfo())), впереди была \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        audio.refresh()
        media.outputs = audio.outputs
        media.start()
        volumeTimer?.invalidate()
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.audio.syncVolumes() }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { previousApp = front }
        NSApp.activate(ignoringOtherApps: true)   // сразу активной: иначе первое меню в панели закрылось бы при переключении
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Log.put("panel", "панель открыта за \(Log.ms(openedAt))")
        // Щелчок мимо панели (в другой программе, на рабочем столе, в строке меню) — закрыть.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            MainActor.assumeIsolated {
                // После того как Lark открыла другую программу (двойной щелчок по строке), macOS присылала сюда
                // и щелчки по самой панели — и панель закрывалась от любого нажатия. Щелчок по своему окну — не «мимо».
                let p = NSEvent.mouseLocation
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(p) }) {
                    Log.put("panel", "щелчок по своему окну \(w.className) пришёл как «чужой» — панель не закрываю, делаю Lark активной")
                    NSApp.activate(ignoringOtherApps: true)
                    return
                }
                self?.closePanel("щелчок вне Lark (\(Self.eventInfo(e)))")
            }
        }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if closeReason == nil {
            closeReason = "macOS закрыла панель сама (transient): \(Self.eventInfo()), Lark активна: \(NSApp.isActive), окно ключевое: \(popover.contentViewController?.view.window?.isKeyWindow ?? false)"
        }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        Log.put("panel", "панель закрыта через \(Log.ms(openedAt)). Причина: \(closeReason ?? "неизвестно (Esc или macOS)")")
        closeReason = nil
        media.stop()
        volumeTimer?.invalidate(); volumeTimer = nil
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        // Панель закрыли значком или Esc: Lark остаётся активной программой без окон, и клавиатура не попадает никуда.
        // Вернуть активность тому, кто был до панели. Если закрыли щелчком в другой программе, Lark уже не активна —
        // ничего не делаем; не мешаем и своему окну с инструкцией.
        let prev = previousApp
        previousApp = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if NSApp.isActive, NSApp.modalWindow == nil, !self.popover.isShown, let prev, !prev.isTerminated { prev.activate() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.put("app", "════ Lark закрывается")
        media.unmuteAll()
        Log.flush()
    }

    /// Колонка и микрофон рядом: не путается с системным значком громкости (динамик с волнами).
    private lazy var statusIcon: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let l = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
        let r = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
        let gap: CGFloat = 1.5, h = max(l.size.height, r.size.height)
        let img = NSImage(size: NSSize(width: l.size.width + gap + r.size.width, height: h), flipped: false) { _ in
            l.draw(in: NSRect(x: 0, y: (h - l.size.height) / 2, width: l.size.width, height: l.size.height))
            r.draw(in: NSRect(x: l.size.width + gap, y: (h - r.size.height) / 2, width: r.size.width, height: r.size.height))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Lark"
        return img
    }()

    // Значок в строке меню; подсказка при наведении показывает текущие выход и микрофон
    private func updateIcon() {
        statusItem.button?.image = statusIcon
        let out = audio.outputs.first { $0.id == audio.curOut }?.name ?? "—"
        let inp = audio.inputs.first { $0.id == audio.curIn }?.name ?? "—"
        statusItem.button?.toolTip = tr("Звук: \(out)\nМикрофон: \(inp)\nКолесо мыши — громкость",
                                        "Sound: \(out)\nMicrophone: \(inp)\nScroll to change volume",
                                        "Heli: \(out)\nMikrofon: \(inp)\nKerige helitugevuse muutmiseks")
    }

    private func enableLoginItemOnce() {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(true, forKey: "loginItemConfigured") }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
