// Lark — звук, микрофон и «что сейчас играет» из строки меню.
// Щелчок по значку открывает панель: слева выходы звука, справа микрофоны (с громкостью),
// ниже — что играет сейчас: Spotify, Музыка и отдельные вкладки Chrome/Safari с кнопкой паузы у каждой.
// «Держать»: если macOS сама переключит устройство (например, при подключении AirPods),
// Lark сразу вернёт выбранное. Когда закреплённое устройство отключено, macOS выбирает сама,
// а как только оно снова появится — Lark вернёт его.
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

// MARK: - Скрытые устройства и короткие имена

enum Hidden {
    static let key = "hiddenUIDs"
    static var uids: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func set(_ s: Set<String>) { UserDefaults.standard.set(Array(s), forKey: key) }
}

// MARK: - Модель устройств

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
    func keeps(_ dir: Dir) -> Bool { dir == .output ? keepOut : keepIn }
    func volume(_ dir: Dir) -> Float? { dir == .output ? outVol : inVol }

    /// Скрытые не показываем, кроме выбранного сейчас.
    func visible(_ dir: Dir) -> [Device] {
        visibleDevices(all(dir), hidden: hidden, current: current(dir))
    }

    func choose(_ dir: Dir, _ d: Device) {
        keeper.choose(dir, d)
        UserDefaults.standard.set(d.name, forKey: dir.pinKey + ".name")
        refresh()
    }

    func setVolume(_ dir: Dir, _ v: Float) {
        Audio.setVolume(current(dir), dir, v)
        if dir == .output { outVol = v } else { inVol = v }
    }

    func toggleKeep(_ dir: Dir) { keeper.setKeeps(dir, !keeper.keeps(dir)); refresh() }

    func hide(_ d: Device) { var h = Hidden.uids; h.insert(d.uid); Hidden.set(h); refresh() }
    func unhideAll() { Hidden.set([]); refresh() }

    /// «AirPods Pro не подключены — вернутся сами»
    func missingNote(_ dir: Dir) -> String? {
        guard keeps(dir), let uid = keeper.pinnedUID(dir), !all(dir).contains(where: { $0.uid == uid }) else { return nil }
        let name = UserDefaults.standard.string(forKey: dir.pinKey + ".name") ?? "Выбранное устройство"
        return "\(name) не подключено — вернётся само"
    }

    func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        refresh()
    }
}

// MARK: - Что сейчас играет: запуск скриптов, программы со звуком, выключение звука

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
        for p in processes() {
            guard let app = owner(p.pid), let b = app.bundleIdentifier else { continue }
            let name = (app.localizedName ?? b).trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202C}").union(.whitespaces))
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

/// Выключает звук программы: Core Audio tap с muteBehavior = .muted на всех её процессах.
/// Пока tap жив (и прокручивается через приватное устройство), программа играет «в тишину».
/// Нужен доступ «Запись системного звука»; при закрытии Lark звук возвращается сам.
final class SoundMute {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    let objs: [AudioObjectID]

    init?(objs: [AudioObjectID]) {
        self.objs = objs
        let desc = CATapDescription(stereoMixdownOfProcesses: objs)
        desc.uuid = UUID()
        desc.name = "Lark mute"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != kAudioObjectUnknown else { return nil }
        let out = Audio.defaultDevice(.output)
        guard let clock = Audio.string(out, kAudioDevicePropertyDeviceUID) else { stop(); return nil }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lark mute",
            kAudioAggregateDeviceUIDKey: "Lark-mute-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clock,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clock]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { stop(); return nil }
        let st = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) { _, _, _, outData, _ in
            for b in UnsafeMutableAudioBufferListPointer(outData) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        }
        guard st == noErr, AudioDeviceStart(aggID, ioProc) == noErr else { stop(); return nil }
    }

    func stop() {
        if let ioProc { AudioDeviceStop(aggID, ioProc); AudioDeviceDestroyIOProcID(aggID, ioProc) }
        ioProc = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    deinit { stop() }
}

enum MediaProbe {
    static func running(_ bundle: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }

    /// Всё, что играет: треки плееров, вкладки браузеров, остальные программы со звуком.
    static func collect(muted: Set<String>) -> (items: [MediaItem], hints: [Hint], sound: [(app: SoundApp, objs: [AudioObjectID])]) {
        var items: [MediaItem] = [], hints: [Hint] = []
        for p in Media.players where running(p.bundle) {
            let r = OSA.run(Media.playerScript(p.bundle))
            if Media.notPermitted(r.err) { hints.append(Media.deniedHint(p.name)); continue }
            if let item = Media.parsePlayer(r.out, bundle: p.bundle, name: p.name) { items.append(item) }
        }
        for b in Media.browsers where running(b.bundle) {
            let r = OSA.run(Media.probeScript(b))
            if Media.notPermitted(r.err) { hints.append(Media.deniedHint(b.name)); continue }
            let parsed = Media.parseTabs(r.out, b)
            items += parsed.items
            if parsed.jsOff { hints.append(Media.jsHint(b)) }
        }
        let sound = SoundApps.list()
        var extra = soundItems(sound.map(\.app), detailed: items, muted: muted, me: Bundle.main.bundleIdentifier ?? "local.lark")
        for i in extra.indices where extra[i].title == extra[i].appBundle {   // выключенная и замолчавшая — имя по бандлу
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: extra[i].appBundle) {
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                let e = extra[i]
                extra[i] = MediaItem(id: e.id, source: e.source, appBundle: e.appBundle, appName: name, title: name,
                                     subtitle: e.subtitle, playing: e.playing, iconURL: nil, muted: e.muted)
            }
        }
        return (playingFirst(items + extra), hints, sound)
    }

    static func setPlaying(_ item: MediaItem, _ play: Bool) { _ = OSA.run(Media.setPlayingScript(item, play)) }
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
    private var mutes: [String: SoundMute] = [:]    // программа → её tap «без звука»
    private var soundObjs: [String: [AudioObjectID]] = [:]
    private var muteHint: Hint?

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
        let muted = Set(mutes.keys)
        queue.async {
            let r = MediaProbe.collect(muted: muted)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if gen == self.generation {
                        self.items = r.items
                        self.hints = r.hints + (self.muteHint.map { [$0] } ?? [])
                        self.soundObjs = Dictionary(r.sound.map { ($0.app.bundle, $0.objs) }, uniquingKeysWith: { a, _ in a })
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    private func mark(_ id: String, _ playing: Bool) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].playing = playing }
    }

    func toggle(_ item: MediaItem) {
        if item.isSoundOnly { toggleMute(item); return }
        let play = !item.playing
        mark(item.id, play)
        act { MediaProbe.setPlaying(item, play) }
    }

    /// Выключить или вернуть звук программы, которой нельзя поставить паузу (Telegram, WhatsApp, игры…).
    func toggleMute(_ item: MediaItem) {
        let b = item.appBundle
        if let m = mutes.removeValue(forKey: b) {
            m.stop()
        } else if let objs = soundObjs[b], let m = SoundMute(objs: objs) {
            mutes[b] = m
            muteHint = nil
        } else {
            muteHint = Hint(id: "mute", text: "Чтобы выключать звук программ, разрешите Lark «Запись экрана и системного звука → Только системный звук».", openPrivacy: true)
        }
        generation += 1
        refresh()
    }

    /// Пауза (или «без звука») на всём остальном, играет только это.
    func solo(_ item: MediaItem) {
        let others = items.filter { $0.playing && $0.id != item.id }
        for o in others where o.isSoundOnly { toggleMute(o) }
        if item.isSoundOnly, item.muted { toggleMute(item) }
        let pausable = others.filter { !$0.isSoundOnly }
        for o in pausable { mark(o.id, false) }
        if !item.isSoundOnly { mark(item.id, true) }
        act {
            for o in pausable { MediaProbe.setPlaying(o, false) }
            if !item.isSoundOnly { MediaProbe.setPlaying(item, true) }
        }
    }

    func pauseAll() {
        let playing = items.filter(\.playing)
        for p in playing where p.isSoundOnly { toggleMute(p) }
        let pausable = playing.filter { !$0.isSoundOnly }
        for p in pausable { mark(p.id, false) }
        act { for p in pausable { MediaProbe.setPlaying(p, false) } }
    }

    var onReveal: () -> Void = {}

    func reveal(_ item: MediaItem) {
        onReveal()
        queue.async { MediaProbe.reveal(item) }
    }

    func unmuteAll() { for m in mutes.values { m.stop() }; mutes.removeAll() }

    var anyPlaying: Bool { items.contains(where: \.playing) }
}

/// open -n -W --stdout log.txt -a Lark --args --selftest
/// Проверяет паузу и запуск на настоящих Spotify/Музыке и вкладке браузера (громкость на время проверки почти ноль)
/// и что macOS даёт создать «выключатель звука». Пишет ✓/✗ по каждому шагу.
enum SelfTest {
    static func say(_ ok: Bool, _ s: String) { print("\(ok ? "✓" : "✗") \(s)"); fflush(stdout) }
    static func wait() { Thread.sleep(forTimeInterval: 1.2) }

    static func run() {
        let r = MediaProbe.collect(muted: [])
        say(true, "найдено: \(r.items.count) строк, подсказок: \(r.hints.count), программ со звуком в Core Audio: \(r.sound.count)")
        for h in r.hints { print("  ℹ︎ \(h.text)") }

        if let it = r.items.first(where: { if case .player = $0.source { return !$0.playing } else { return false } }),
           case .player(let b) = it.source {
            let vol = OSA.run("tell application id \"\(b)\" to get sound volume").out
            _ = OSA.run("tell application id \"\(b)\" to set sound volume to 0")
            MediaProbe.setPlaying(it, true); wait()
            let on = Media.parsePlayer(OSA.run(Media.playerScript(b)).out, bundle: b, name: it.appName)?.playing == true
            MediaProbe.setPlaying(it, false); wait()
            let off = Media.parsePlayer(OSA.run(Media.playerScript(b)).out, bundle: b, name: it.appName)?.playing == false
            _ = OSA.run("tell application id \"\(b)\" to set sound volume to \(Int(vol) ?? 50)")
            say(on, "\(it.appName): кнопка «играть»")
            say(off, "\(it.appName): кнопка «пауза»")
        } else { print("— плеер на паузе не найден, пропускаю") }

        if let it = r.items.first(where: { !$0.playing && !$0.isSoundOnly && { if case .player = $0.source { return false }; return true }($0) }) {
            let b = Media.browsers.first { $0.bundle == it.appBundle }!
            func tabJS(_ js: String) -> String {
                switch it.source {
                case .chromeTab(let bb, let w, let t): return OSA.run("tell application id \"\(bb)\" to execute tab id \(t) of window id \(w) javascript \"\(js)\"").out
                case .safariTab(let w, let i): return OSA.run("tell application id \"\(Media.safari)\" to do JavaScript \"\(js)\" in tab \(i) of window id \(w)").out
                default: return ""
                }
            }
            func state() -> String? {
                Media.parseTabs(OSA.run(Media.probeScript(b)).out, b).items.first { $0.id == it.id }.map { $0.playing ? "1" : "0" }
            }
            _ = tabJS("[].slice.call(document.querySelectorAll('video,audio')).forEach(function(e){e.setAttribute('data-lark-vol',e.volume);e.volume=0.001});''")
            MediaProbe.setPlaying(it, true); wait()
            let on = state()
            MediaProbe.setPlaying(it, false); wait()
            let off = state()
            _ = tabJS("[].slice.call(document.querySelectorAll('video,audio')).forEach(function(e){var v=e.getAttribute('data-lark-vol');if(v!==null){e.volume=parseFloat(v);e.removeAttribute('data-lark-vol')}});''")
            say(on == "1", "вкладка «\(it.title.prefix(40))»: кнопка «играть» (\(on ?? "нет строки"))")
            say(off == "0", "вкладка: кнопка «пауза» (\(off ?? "нет строки"))")
        } else { print("— вкладка на паузе не найдена, пропускаю") }

        // Переход к вкладке (двойной щелчок): только на тестовой странице Lark, чтобы не трогать ваши вкладки.
        if let t = r.items.first(where: { $0.title.hasPrefix("Lark: тестовая страница") }), case .chromeTab(let bb, let w, _) = t.source {
            MediaProbe.reveal(t); wait()
            let active = OSA.run("tell application id \"\(bb)\" to get title of active tab of window id \(w)").out
            say(active.hasPrefix("Lark: тестовая страница"), "двойной щелчок открывает нужную вкладку (активна: «\(active.prefix(40))»)")
        } else { print("— тестовой вкладки нет, переход не проверяю") }

        // «Выключить звук» на самом Lark: проверяем, что macOS разрешает создать tap и он держится.
        if let me = SoundApps.processes().first(where: { $0.pid == getpid() }) ?? {
            NSSound(named: "Tink")?.volume = 0.0; NSSound(named: "Tink")?.play(); Thread.sleep(forTimeInterval: 0.3)
            return SoundApps.processes().first(where: { $0.pid == getpid() })
        }() {
            let m = SoundMute(objs: [me.obj])
            say(m != nil, m != nil ? "выключатель звука создаётся (доступ к системному звуку есть)"
                                   : "выключатель звука не создаётся — нет доступа «Запись системного звука» для Lark")
            m?.stop()
        } else { print("— у Lark нет объекта звука, пропускаю выключатель") }
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

/// Фавиконы вкладок: качаются один раз и живут в памяти, пока Lark запущен.
@MainActor
final class Favicons: ObservableObject {
    static let shared = Favicons()
    @Published private(set) var images: [String: NSImage] = [:]
    private var requested: Set<String> = []

    func image(_ url: String?) -> NSImage? {
        guard let url, !url.isEmpty else { return nil }
        if let i = images[url] { return i }
        load(url)
        return nil
    }

    private func load(_ s: String) {
        guard !requested.contains(s), let url = URL(string: s), ["http", "https", "data"].contains(url.scheme ?? "") else { return }
        requested.insert(s)
        var tries = [url]   // не вышло со значком из страницы — пробуем сайт/favicon.ico
        if let host = url.host, url.path != "/favicon.ico", let fb = URL(string: "https://\(host)/favicon.ico") { tries.append(fb) }
        Self.fetch(tries) { img in Favicons.shared.images[s] = img }
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

/// Значок строки: фавикон сайта с маленьким значком браузера в углу; без фавикона — значок приложения.
struct MediaIcon: View {
    let item: MediaItem
    @ObservedObject private var favicons = Favicons.shared
    var body: some View {
        if let fav = favicons.image(item.iconURL) {
            Image(nsImage: fav).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 26, height: 26)
                .overlay(alignment: .bottomTrailing) {
                    Image(nsImage: Icons.app(item.appBundle)).resizable().frame(width: 13, height: 13)
                        .offset(x: 3, y: 3)
                }
        } else {
            Image(nsImage: Icons.app(item.appBundle)).resizable().frame(width: 26, height: 26)
        }
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
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.2) : (hover ? Color.primary.opacity(0.07) : .clear))
            )
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
                Text(dir == .output ? "Звук" : "Микрофон").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { audio.toggleKeep(dir) } label: {
                    Label("Держать", systemImage: audio.keeps(dir) ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(audio.keeps(dir) ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06)))
                        .foregroundStyle(audio.keeps(dir) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(dir == .output
                      ? "Не давать macOS самой переключать выход (например, на подключившиеся AirPods)"
                      : "Не давать macOS самой переключать микрофон (например, на подключившиеся AirPods)")
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
                Text("Нет устройств").foregroundStyle(.secondary).padding(.horizontal, 8)
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
                    if !sel { Button("Скрыть из списка") { audio.hide(d) } }
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

struct MediaRow: View {
    let item: MediaItem
    @ObservedObject var media: MediaModel
    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    MediaIcon(item: item)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1).truncationMode(.tail)
                        Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { media.reveal(item) }   // двойной щелчок — перейти к программе и вкладке
                .help("Двойной щелчок — открыть \(item.isSoundOnly ? item.appName : "там, где играет")")

                if item.playing {
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
                .help(item.isSoundOnly ? (item.muted ? "Вернуть звук" : "Выключить звук") : (item.playing ? "Пауза" : "Играть"))
            }
        }
        .contextMenu {
            Button("Играть только это") { media.solo(item) }
            Button(item.isSoundOnly ? (item.muted ? "Вернуть звук" : "Выключить звук") : (item.playing ? "Пауза" : "Играть")) { media.toggle(item) }
            Button("Открыть") { media.reveal(item) }
        }
    }
}

struct MediaSection: View {
    @ObservedObject var media: MediaModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Сейчас играет").font(.system(size: 13, weight: .semibold))
                Spacer()
                if media.anyPlaying {
                    Button { media.pauseAll() } label: {
                        Label("Пауза везде", systemImage: "pause.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            if !media.loaded {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Смотрю, что играет…").foregroundStyle(.secondary) }
                    .padding(.horizontal, 8).padding(.vertical, 4)
            } else if media.items.isEmpty {
                Text("Ничего не играет").foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            }
            ForEach(media.items) { MediaRow(item: $0, media: media) }

            ForEach(media.hints) { h in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(h.text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if h.openPrivacy {
                        Spacer(minLength: 0)
                        Button("Открыть") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(u) }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                DeviceColumn(dir: .output, audio: audio)
                Divider()
                DeviceColumn(dir: .input, audio: audio)
            }
            .padding(10)

            Divider()
            MediaSection(media: media).padding(10)
            Divider()

            HStack(spacing: 12) {
                Button("Настройки звука macOS…") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Toggle("Запускать при входе в систему", isOn: Binding(get: { audio.loginOn }, set: { _ in audio.toggleLogin() }))
                    if !audio.hidden.isEmpty {
                        Button("Показать скрытые устройства (\(audio.hidden.count))") { audio.unhideAll() }
                    }
                    Divider()
                    Button("Выйти из Lark") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Настройки Lark")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .font(.system(size: 13))
        .frame(width: 580)
    }
}

// MARK: - Приложение

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let audio = AudioModel()
    let media = MediaModel()
    var statusItem: NSStatusItem!
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login") {   // нужно для uninstall.sh
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--selftest") {   // проверка кнопок на настоящих программах, без звука
            DispatchQueue.global().async { SelfTest.run(); DispatchQueue.main.async { NSApp.terminate(nil) } }
            return
        }
        if CommandLine.arguments.contains("--probe") {   // диагностика: что Lark видит сейчас (open -a Lark --args --probe)
            DispatchQueue.global().async {
                let r = MediaProbe.collect(muted: [])
                var lines = r.items.map { "\($0.playing ? "▶" : "⏸") \($0.title) — \($0.subtitle)\($0.iconURL.map { " [\($0)]" } ?? "")" }
                lines += r.hints.map { "ℹ︎ \($0.text)" }
                lines += r.sound.map { "♪ \($0.app.name) (\($0.app.bundle)) звук: \($0.app.outputting ? "да" : "нет"), процессов: \($0.objs.count)" }
                print(lines.isEmpty ? "Ничего не играет" : lines.joined(separator: "\n"))
                fflush(stdout)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let host = NSHostingController(rootView: PanelView(audio: audio, media: media))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        media.onReveal = { [weak self] in self?.popover.performClose(nil) }

        audio.refresh()
        updateIcon()

        let changed: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.audio.keeper.enforceAll()
                self?.audio.refresh()
                self?.updateIcon()
            }
        }
        Audio.listen(systemObject, kAudioHardwarePropertyDefaultInputDevice, changed)
        Audio.listen(systemObject, kAudioHardwarePropertyDefaultOutputDevice, changed)
        Audio.listen(systemObject, kAudioHardwarePropertyDevices) { [weak self] in
            changed()
            // Bluetooth-устройства иногда «перехватывают» вход с задержкой после подключения
            for delay in [0.7, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self?.audio.keeper.enforceAll() } }
            }
        }
        audio.keeper.enforceAll()
        enableLoginItemOnce()
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = statusItem.button else { return }
        audio.refresh()
        media.start()
        NSApp.activate()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // Щелчок мимо панели (в другой программе, на рабочем столе, в строке меню) — закрыть.
        // Сам macOS закрывает «временную» панель, только если Lark стал активным, а это срабатывает не всегда.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private var outsideClicks: Any?

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
        img.accessibilityDescription = "Lark: звук и микрофон"
        return img
    }()

    // Значок в строке меню; подсказка при наведении показывает текущие выход и микрофон
    private func updateIcon() {
        statusItem.button?.image = statusIcon
        let out = audio.outputs.first { $0.id == audio.curOut }?.name ?? "—"
        let inp = audio.inputs.first { $0.id == audio.curIn }?.name ?? "—"
        statusItem.button?.toolTip = "Звук: \(out)\nМикрофон: \(inp)"
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
