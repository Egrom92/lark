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
            let name = string(id, kAudioObjectPropertyName) ?? "Без названия"
            return Device(id: id, uid: uid, name: name, transport: uint32(id, kAudioDevicePropertyTransportType))
        }
    }

    static func defaultDevice(_ dir: Dir) -> AudioDeviceID {
        uint32(systemObject, dir.defaultSelector)
    }

    static func setDefault(_ dir: Dir, _ id: AudioDeviceID) {
        var a = address(dir.defaultSelector)
        var v = id
        AudioObjectSetPropertyData(systemObject, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
        if dir == .output {   // звуки системы — туда же, как в настройках macOS по умолчанию
            var s = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(systemObject, &s, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
        }
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
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        var m = address(kAudioDevicePropertyMute, dir.scope)   // подняли громкость — снять «без звука»
        if v > 0, AudioObjectHasProperty(id, &m) {
            var off: UInt32 = 0
            AudioObjectSetPropertyData(id, &m, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
        }
    }

    static func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ block: @escaping () -> Void) {
        var a = address(sel)
        AudioObjectAddPropertyListenerBlock(obj, &a, DispatchQueue.main) { _, _ in block() }
    }
}

// MARK: - Закрепление

final class Keeper {
    let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [Dir.input.keepKey: true, Dir.output.keepKey: false])
        // Первый запуск: закрепить встроенный микрофон Mac, если он есть.
        if defaults.string(forKey: Dir.input.pinKey) == nil {
            let inputs = Audio.devices(.input)
            let pick = inputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
                ?? inputs.first { $0.id == Audio.defaultDevice(.input) }
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
        defaults.set(on, forKey: dir.keepKey)
        if on, let cur = Audio.devices(dir).first(where: { $0.id == Audio.defaultDevice(dir) }) {
            defaults.set(cur.uid, forKey: dir.pinKey)   // закрепляем то, что выбрано сейчас
        }
    }

    /// Выбор пользователя в меню: сделать основным и запомнить.
    func choose(_ dir: Dir, _ d: Device) {
        defaults.set(d.uid, forKey: dir.pinKey)
        Audio.setDefault(dir, d.id)
    }

    /// Вернуть закреплённое устройство, если macOS переключила на другое.
    func enforce(_ dir: Dir) {
        guard keeps(dir), let uid = pinnedUID(dir),
              let d = Audio.devices(dir).first(where: { $0.uid == uid }),
              Audio.defaultDevice(dir) != d.id else { return }
        Audio.setDefault(dir, d.id)
    }

    func enforceAll() { enforce(.input); enforce(.output) }
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
        outVol = Audio.volume(curOut, .output)
        inVol = Audio.volume(curIn, .input)
        keepOut = keeper.keeps(.output)
        keepIn = keeper.keeps(.input)
        hidden = Hidden.uids
        loginOn = SMAppService.mainApp.status == .enabled
        for dir in [Dir.output, .input] {   // запомнить имя закреплённого, чтобы показать его, когда оно отключено
            if let uid = keeper.pinnedUID(dir), let d = all(dir).first(where: { $0.uid == uid }) {
                UserDefaults.standard.set(d.name, forKey: dir.pinKey + ".name")
            }
        }
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
    }

    func setVolume(_ dir: Dir, _ v: Float) {
        Audio.setVolume(current(dir), dir, v)
        if dir == .output { outVol = v } else { inVol = v }
    }

    /// Колесо над значком: шаг как у клавиш громкости (1/16) для мыши, плавно для трекпада. Возвращает новую громкость.
    func nudgeOutput(_ delta: Float) -> Float? {
        guard let v = Audio.volume(Audio.defaultDevice(.output), .output) else { return nil }
        let n = max(0, min(1, v + delta))
        Audio.setVolume(Audio.defaultDevice(.output), .output, n)
        outVol = n
        return n
    }

    func toggleKeep(_ dir: Dir) { keeper.setKeeps(dir, !keeper.keeps(dir)); refresh() }

    func hide(_ d: Device) { var h = Hidden.uids; h.insert(d.uid); Hidden.set(h); refresh() }
    func unhideAll() { Hidden.set([]); refresh() }

    func missingNote(_ dir: Dir) -> String? {
        guard keeps(dir), let uid = keeper.pinnedUID(dir), !all(dir).contains(where: { $0.uid == uid }) else { return nil }
        let name = UserDefaults.standard.string(forKey: dir.pinKey + ".name") ?? tr("Выбранное устройство", "Your device", "Valitud seade")
        return tr("\(name) не подключено — вернётся само", "\(name) is disconnected — Lark will switch back when it returns",
                  "\(name) pole ühendatud — Lark lülitub tagasi, kui see ilmub")
    }

    func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        refresh()
    }

    // MARK: Наборы

    private func savePresets() {
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

    func deletePreset(_ p: Preset) { presets.removeAll { $0.id == p.id }; savePresets() }

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
        do { try p.run() } catch { return ("", "\(error)") }
        input.fileHandleForWriting.write(source.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (String(decoding: o, as: UTF8.self).trimmingCharacters(in: .newlines),
                String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
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
        for p in Media.players where running.contains(p.bundle) {
            let r = OSA.run(Media.playerScript(p.bundle))
            if Media.notPermitted(r.err) { hints.append(Media.deniedHint(p.name)); continue }
            if let item = Media.parsePlayer(r.out, bundle: p.bundle, name: p.name) { items.append(item); covered.insert(p.bundle) }
        }
        for b in Media.browsers where running.contains(b.bundle) {
            let r = OSA.run(Media.probeScript(b))
            if Media.notPermitted(r.err) { hints.append(Media.deniedHint(b.name)); continue }
            let parsed = Media.parseTabs(r.out, b)
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
        return (items + extra, hints, sound)
    }

    static func perform(_ item: MediaItem, _ a: MediaAction) { _ = OSA.run(Media.actionScript(item, a)) }
    static func setPlaying(_ item: MediaItem, _ play: Bool) { perform(item, play ? .play : .pause) }
    static func reveal(_ item: MediaItem) { _ = OSA.run(Media.revealScript(item)) }
}

@MainActor
final class MediaModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var hints: [Hint] = []
    @Published var loaded = false
    private let queue = DispatchQueue(label: "lark.media")
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
    private var volumeSends: [String: DispatchWorkItem] = [:]
    private var order = StableOrder()               // строки не прыгают при play/pause
    var onReveal: () -> Void = {}

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard !busy else { pending = true; return }
        busy = true
        let gen = generation
        let m = muted, g = gains, run = MediaProbe.runningBundles()
        queue.async {
            let r = MediaProbe.collect(muted: m, gains: g, running: run)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if gen == self.generation {
                        self.items = self.labelRoutes(self.order.sort(r.items))
                        self.hints = r.hints + (self.tapHint.map { [$0] } ?? [])
                        for s in r.sound { self.soundObjs[s.app.bundle] = s.objs }
                        for b in self.routes.keys where self.taps[b] == nil { self.applyTap(b) }
                        self.loaded = true
                    }
                    self.busy = false
                    if self.pending { self.pending = false; self.refresh() }
                }
            }
        }
    }

    private func act(_ work: @escaping () -> Void) {
        generation += 1
        queue.async {
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
        act { MediaProbe.perform(item, a) }
    }

    func toggle(_ item: MediaItem) { perform(item, item.isSoundOnly ? .pause : (item.playing ? .pause : .play)) }

    /// Ползунок громкости строки: сразу на экране, программе — когда рука остановилась (не сотни скриптов в секунду).
    func setVolume(_ item: MediaItem, _ v: Double) {
        if item.isSoundOnly { setAppGain(item.appBundle, v); return }
        generation += 1
        update(item.id) { $0.volume = v }
        volumeSends[item.id]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.perform(item, .volume(v)) }
        volumeSends[item.id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
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
            taps.removeValue(forKey: b)?.stop()
            return true
        }
        let eff = Float(isMuted ? 0 : gain)
        let wantUID = target ?? defaultOutputUID
        let objs = soundObjs[b] ?? []
        if let t = taps[b], t.outputUID == wantUID, Set(t.objs) == Set(objs) { t.gain = eff; return true }
        taps.removeValue(forKey: b)?.stop()
        guard !objs.isEmpty else { return true }   // программа пока без звука — применим, когда появится
        guard let t = AppVolume(objs: objs, gain: eff, deviceUID: target) else {
            tapHint = Hint(id: "tap", text: tr("Чтобы менять громкость и выход программ, разрешите Lark «Запись экрана и системного звука → Только системный звук».",
                                               "To control app volume and output, allow Lark in Screen & System Audio Recording → System Audio Recording Only.",
                                               "Programmide helitugevuse ja väljundi muutmiseks lubage Lark jaotises Ekraani ja süsteemiheli salvestamine → Ainult süsteemiheli."),
                           openPrivacy: true)
            hints.removeAll { $0.id == "tap" }
            hints.append(tapHint!)
            return false
        }
        tapHint = nil
        hints.removeAll { $0.id == "tap" }
        taps[b] = t
        return true
    }

    /// Куда выводить звук программы: UID устройства или nil — как у всех. Запоминается.
    func setRoute(_ b: String, _ uid: String?) {
        routes[b] = uid
        UserDefaults.standard.set(routes, forKey: Routes.key)
        if !applyTap(b) { routes[b] = nil; UserDefaults.standard.set(routes, forKey: Routes.key) }
        let name = uid.flatMap { u in outputs.first { $0.uid == u }?.name }
        for i in items.indices where items[i].appBundle == b { items[i].routeName = name }
        generation += 1
    }

    func route(_ b: String) -> String? { routes[b] }

    /// Звуковые процессы изменились (программа запустилась, заиграла, закрылась) или сменились устройства:
    /// обновить список процессов и применить сохранённые маршруты — даже когда панель закрыта.
    func reconcile() {
        for s in SoundApps.list() { soundObjs[s.app.bundle] = s.objs }
        for b in Set(routes.keys).union(taps.keys) { applyTap(b) }
    }

    /// Подписать строки: куда выведен звук их программы.
    private func labelRoutes(_ list: [MediaItem]) -> [MediaItem] {
        list.map { it in
            var x = it
            if let uid = Routes.target(routes[it.appBundle], outputs: outputs, defaultUID: defaultOutputUID) {
                x.routeName = outputs.first { $0.uid == uid }?.name
            }
            return x
        }
    }

    func setAppGain(_ b: String, _ v: Double) {
        gains[b] = v
        if v > 0.001 { muted.remove(b) }
        update("sound:\(b)") { $0.volume = v; if v > 0.001 { $0.muted = false } }
        if !applyTap(b) { gains[b] = 1; update("sound:\(b)") { $0.volume = 1 } }
        generation += 1
    }

    /// Выключить или вернуть звук программы, которой нельзя поставить паузу.
    func toggleMute(_ item: MediaItem) {
        let b = item.appBundle
        if muted.contains(b) { muted.remove(b) } else { muted.insert(b) }
        if !applyTap(b) { muted.remove(b) }
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
    func rebuildTaps() {
        let list = Array(Set(taps.keys).union(routes.keys))
        for b in list { taps.removeValue(forKey: b)?.stop() }
        for b in list { applyTap(b) }
    }

    func unmuteAll() { for t in taps.values { t.stop() }; taps.removeAll(); muted.removeAll(); gains.removeAll() }

    /// Пауза (или «без звука») на всём остальном, играет только это.
    func solo(_ item: MediaItem) {
        for o in items where o.playing && o.id != item.id { o.isSoundOnly ? toggleMute(o) : perform(o, .pause) }
        if item.isSoundOnly { if item.muted { toggleMute(item) } } else if !item.playing { perform(item, .play) }
    }

    /// «Пауза везде». Второе нажатие (пока ничего не играет) — вернуть то, что было поставлено на паузу этой кнопкой.
    private var pausedByAll: [MediaItem] = []
    func pauseAll() {
        let playing = items.filter(\.playing)
        if playing.isEmpty {
            for p in pausedByAll { p.isSoundOnly ? toggleMute(p) : perform(p, .play) }
            pausedByAll = []
            return
        }
        pausedByAll = playing
        for p in playing { p.isSoundOnly ? toggleMute(p) : perform(p, .pause) }
    }
    var canResumeAll: Bool { !anyPlaying && !pausedByAll.isEmpty }

    func reveal(_ item: MediaItem) {
        onReveal()
        queue.async { MediaProbe.reveal(item) }
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
        Self.fetch(tries) { img in Images.shared.images[s] = img }
    }

    nonisolated private static func fetch(_ urls: [URL], _ done: @escaping @MainActor (NSImage) -> Void) {
        guard let url = urls.first else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            if ok, let data, let img = NSImage(data: data), img.isValid, img.size.width > 0 {
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
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowBackground(selected: selected, hover: hover))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct DeviceColumn: View {
    let dir: Dir
    @ObservedObject var audio: AudioModel

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
            ForEach(devs, id: \.uid) { d in
                let sel = d.id == audio.current(dir)
                Button { audio.choose(dir, d) } label: {
                    HoverRow(selected: sel) {
                        HStack(spacing: 8) {
                            Image(systemName: symbol(for: d, dir))
                                .frame(width: 18)
                                .foregroundStyle(sel ? Color.accentColor : Color.secondary)
                            Text(displayName(d.name, dir)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if sel { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(d.name)
                .contextMenu {
                    if !sel { Button(tr("Скрыть из списка", "Hide from list", "Peida loendist")) { audio.hide(d) } }
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
                            .onExitCommand { adding = false }
                        Button(tr("Сохранить", "Save", "Salvesta"), action: save).controlSize(.small)
                        Button { adding = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
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
        audio.addPreset(name)
        adding = false
    }

    private func chip(_ p: Preset, _ i: Int) -> some View {
        let active = audio.isActive(p)
        let missing = Presets.missing(p, outputs: audio.outputs, inputs: audio.inputs)
        let devices = [p.outputName.map { "🔊 \($0)" }, p.inputName.map { "🎙 \($0)" }].compactMap { $0 }.joined(separator: "  ")
        var help = devices
        if let k = Presets.hotkeyLabel(i) { help += "\n" + tr("Сочетание: \(k)", "Shortcut: \(k)", "Kiirklahv: \(k)") }
        if !missing.isEmpty { help += "\n" + tr("Не подключено: ", "Not connected: ", "Pole ühendatud: ") + missing.joined(separator: ", ") }
        return Button { audio.applyPreset(p) } label: {
            HStack(spacing: 5) {
                Text(p.name).lineLimit(1)
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
        .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
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
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            Button { media.toggle(item) } label: {
                Image(systemName: item.isSoundOnly ? (item.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                                   : (item.playing ? "pause.fill" : "play.fill"))
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(item.playing ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(item.isSoundOnly ? (item.muted ? tr("Вернуть звук", "Unmute", "Taasta heli") : tr("Выключить звук", "Mute", "Vaigista"))
                                   : (item.playing ? tr("Пауза", "Pause", "Paus") : tr("Играть", "Play", "Mängi")))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RowBackground(hover: hover))
        .onHover { hover = $0 }
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
            RouteMenuItems(item: item, media: media)
            Divider()
            Button(tr("Открыть", "Open", "Ava")) { media.reveal(item) }
        }
    }
}

/// Пункты «Куда выводить звук»: программа целиком — через Lark; отдельная вкладка — через расширение в Chrome.
struct RouteMenuItems: View {
    let item: MediaItem
    @ObservedObject var media: MediaModel

    var body: some View {
        let current = media.route(item.appBundle)
        let whole = item.isTab ? tr("Весь \(item.appName)", "All of \(item.appName)", "Kogu \(item.appName)") : item.appName
        Menu(tr("Куда выводить: \(whole)", "Output for \(whole)", "Väljund: \(whole)")) {
            Button((current == nil ? "✓ " : "") + tr("Как у всех", "Same as everything", "Nagu kõik")) { media.setRoute(item.appBundle, nil) }
            Divider()
            ForEach(media.outputs, id: \.uid) { d in
                Button((current == d.uid ? "✓ " : "") + d.name) { media.setRoute(item.appBundle, d.uid) }
            }
        }
        if item.isTab {
            Button(item.hasExtension
                   ? tr("Только эта вкладка: правый щелчок по странице → Lark", "Only this tab: right-click the page → Lark", "Ainult see vahekaart: paremklõps lehel → Lark")
                   : tr("Только эта вкладка: поставить «Lark для Chrome»…", "Only this tab: install Lark for Chrome…", "Ainult see vahekaart: paigalda „Lark Chrome’ile“…")) {
                if item.hasExtension { media.reveal(item) } else { ChromeExtension.openInstall() }
            }
        }
    }
}

/// Кнопка-меню «куда выводить» в строке (при наведении).
struct RouteMenu: View {
    let item: MediaItem
    @ObservedObject var media: MediaModel
    var body: some View {
        Menu { RouteMenuItems(item: item, media: media) } label: {
            Image(systemName: "airplayaudio")
                .symbolRenderingMode(.monochrome)
                .renderingMode(.template)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle((item.routeName ?? item.sinkName) != nil ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24)
        .foregroundStyle((item.routeName ?? item.sinkName) != nil ? Color.accentColor : Color.secondary)
        .help(tr("Куда выводить звук", "Where to send the sound", "Kuhu heli saata"))
    }
}

/// «Lark для Chrome»: расширение лежит рядом с программой; ставится вручную через chrome://extensions → «Загрузить распакованное».
enum ChromeExtension {
    static var folder: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Lark/Chrome") }

    static func openInstall() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
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
            ForEach(media.items) { MediaRow(item: $0, media: media) }

            ForEach(media.hints) { h in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(h.text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if h.openPrivacy {
                        Spacer(minLength: 0)
                        Button(tr("Открыть", "Open", "Ava")) {
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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageLeading

        makePanel()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        media.onReveal = { [weak self] in self?.popover.performClose(nil) }
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

        let changed: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.audio.keeper.enforceAll()
                self?.audio.refresh()
                self?.updateIcon()
            }
        }
        Audio.listen(systemObject, kAudioHardwarePropertyDefaultInputDevice, changed)
        Audio.listen(systemObject, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            changed()
            MainActor.assumeIsolated { self?.media.rebuildTaps() }   // громкость программ — на новый выход
        }
        Audio.listen(systemObject, kAudioHardwarePropertyDevices) { [weak self] in
            changed()
            MainActor.assumeIsolated {   // устройство подключили или отключили — выходы программ пересобрать
                if let self { self.media.outputs = self.audio.outputs; self.media.rebuildTaps() }
            }
            // Bluetooth-устройства иногда «перехватывают» вход с задержкой после подключения
            for delay in [0.7, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self?.audio.keeper.enforceAll() } }
            }
        }
        audio.keeper.enforceAll()
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
        if let l { UserDefaults.standard.set(l.rawValue, forKey: "language") } else { UserDefaults.standard.removeObject(forKey: "language") }
        Lang.current = Lang.detect()
        audio.langTick += 1
        updateIcon()
        media.refresh()
    }

    private func checkUpdate(force: Bool, report: Bool = false) {
        if report { audio.updateNote = tr("Проверяю…", "Checking…", "Kontrollin…") }
        Updater.check(force: force) { [weak self] v in
            guard let self else { return }
            self.audio.update = v
            if report {
                self.audio.updateNote = v == nil ? tr("У вас последняя версия", "You have the latest version", "Teil on uusim versioon") : nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { self.audio.updateNote = nil } }
            }
        }
    }

    private func runUpdate() {
        audio.updateNote = tr("Обновляю… Lark перезапустится сам", "Updating… Lark will restart", "Uuendan… Lark käivitub uuesti")
        Updater.install()
    }

    private func registerHotkeys() {
        let list = audio.presets.prefix(Presets.maxHotkeys).map { p in
            { [weak self] in
                guard let self else { return }
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

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = statusItem.button else { return }
        audio.refresh()
        media.outputs = audio.outputs
        media.start()
        NSApp.activate()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // Щелчок мимо панели (в другой программе, на рабочем столе, в строке меню) — закрыть.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        media.stop()
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
    }

    func applicationWillTerminate(_ notification: Notification) { media.unmuteAll() }

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
