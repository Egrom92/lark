// Чистая логика Lark без окон и звука: короткие имена устройств, наборы, версии, тексты AppleScript и JavaScript,
// разбор их ответов. Её проверяют тесты (Tests/), поэтому здесь нет обращений к системе.
import Foundation
import CoreAudio

enum Dir {
    case output, input
    var scope: AudioObjectPropertyScope { self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput }
    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
    var pinKey: String { self == .output ? "pinnedOutputUID" : "pinnedInputUID" }
    var keepKey: String { self == .output ? "keepOutput" : "keepInput" }
}

struct Device: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
}

/// «Микрофон MacBook Air» в колонке «Микрофон» → «MacBook Air»; «Микрофон (iPhone (Roma))» → «iPhone (Roma)».
func displayName(_ name: String, _ dir: Dir) -> String {
    var n = name
    for p in (dir == .input ? ["Микрофон ", "Microphone ", "Mikrofon "] : ["Динамики ", "Speakers ", "Kõlarid "]) where n.hasPrefix(p) {
        n = String(n.dropFirst(p.count))
    }
    if n.hasPrefix("("), n.hasSuffix(")") { n = String(n.dropFirst().dropLast()) }
    return n.trimmingCharacters(in: .whitespaces).isEmpty ? name : n
}

func symbol(for d: Device, _ dir: Dir) -> String {
    switch d.transport {
    case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
        let n = d.name.lowercased()
        if n.contains("airpods") || n.contains("buds") || n.contains("headphone") || n.contains("наушник") { return "airpods" }
        return dir == .input ? "mic" : "hifispeaker"
    case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
    case kAudioDeviceTransportTypeUSB: return dir == .input ? "mic" : "hifispeaker"
    case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "square.stack.3d.up"
    case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
    default: return dir == .input ? "mic" : "speaker.wave.2"
    }
}

/// Скрытые устройства не показываем, кроме выбранного сейчас (иначе не видно, куда идёт звук).
func visibleDevices(_ all: [Device], hidden: Set<String>, current: AudioDeviceID) -> [Device] {
    all.filter { !hidden.contains($0.uid) || $0.id == current }
}

// MARK: - Наборы «выход + микрофон»

/// Запомненная пара устройств, например «Звонок» = AirPods на выход + микрофон Mac. Устройства — по UID, имена — для подсказки,
/// когда устройство не подключено. Одна из сторон может быть не задана (набор только для выхода).
struct Preset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var output: String?
    var input: String?
    var outputName: String?
    var inputName: String?
}

enum Presets {
    static let key = "presets"
    static let maxHotkeys = 9

    static func decode(_ data: Data?) -> [Preset] {
        guard let data, let list = try? JSONDecoder().decode([Preset].self, from: data) else { return [] }
        return list
    }
    static func encode(_ list: [Preset]) -> Data { (try? JSONEncoder().encode(list)) ?? Data("[]".utf8) }

    /// Набор сейчас включён: все его заданные стороны совпадают с текущими устройствами.
    static func isActive(_ p: Preset, outUID: String?, inUID: String?) -> Bool {
        (p.output == nil || p.output == outUID) && (p.input == nil || p.input == inUID) && (p.output != nil || p.input != nil)
    }

    /// Каких устройств набора сейчас нет (имена для подсказки).
    static func missing(_ p: Preset, outputs: [Device], inputs: [Device]) -> [String] {
        var m: [String] = []
        if let o = p.output, !outputs.contains(where: { $0.uid == o }) { m.append(p.outputName ?? o) }
        if let i = p.input, !inputs.contains(where: { $0.uid == i }) { m.append(p.inputName ?? i) }
        return m
    }

    /// Следующее свободное имя: «Набор 1», «Набор 2»…
    static func defaultName(_ list: [Preset]) -> String {
        let base = tr("Набор", "Preset", "Komplekt")
        var n = list.count + 1
        while list.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }

    /// Подпись горячей клавиши набора по его месту: ⌃⌥1 … ⌃⌥9, дальше без клавиши.
    static func hotkeyLabel(_ index: Int) -> String? { index < maxHotkeys ? "⌃⌥\(index + 1)" : nil }
}

// MARK: - Куда выводить звук программы

/// Программа → устройство вывода (UID). Хранится в настройках и применяется, как только программа появляется.
enum Routes {
    static let key = "routes"

    static func decode(_ any: Any?) -> [String: String] { (any as? [String: String]) ?? [:] }

    /// В какое устройство выводить сейчас: выбранное, если оно подключено и это не текущий выход; иначе nil — как у всех.
    static func target(_ route: String?, outputs: [Device], defaultUID: String?) -> String? {
        guard let r = route, r != defaultUID, outputs.contains(where: { $0.uid == r }) else { return nil }
        return r
    }

    /// Нужен ли перехват звука: выключен, громкость не 100 % или свой выход.
    static func needsTap(muted: Bool, gain: Double, target: String?) -> Bool { muted || gain < 0.999 || target != nil }
}

// MARK: - Метка «куда выведена вкладка»

/// Расширение «Lark для Chrome» пишет на страницу не название устройства (его прочитал бы любой сайт, а в названии
/// часто имя владельца: «AirPods Pro (Roman)»), а короткий ключ от названия. Тот же расчёт — в content.js.
func sinkKey(_ name: String) -> String {
    var h: UInt32 = 2166136261   // FNV-1a по единицам UTF-16, как charCodeAt в JavaScript
    for u in name.utf16 { h = (h ^ UInt32(u)) &* 16777619 }
    return "#" + String(h, radix: 16)
}

/// Ключ со страницы → название подключённого выхода. Старое расширение писало само название — его тоже понимаем.
/// Неизвестный ключ (устройство уже отключено) — nil.
func resolveSink(_ key: String, _ names: [String]) -> String? {
    names.first { sinkKey($0) == key } ?? (key.hasPrefix("#") ? nil : key)
}

// MARK: - Версии и время

/// «2.10» новее «2.9»: сравнение по числам через точку.
func isNewer(_ remote: String, than local: String) -> Bool {
    let r = remote.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map { Int($0) ?? 0 }
    let l = local.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map { Int($0) ?? 0 }
    guard !r.isEmpty else { return false }
    for i in 0..<max(r.count, l.count) {
        let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
        if a != b { return a > b }
    }
    return false
}

/// 75 → «1:15», 3725 → «1:02:05».
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
    let h = s / 3600, m = (s % 3600) / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
}

/// Число из AppleScript: в русской macOS дробная часть через запятую.
func number(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard let v = Double(t), v.isFinite, v >= 0 else { return nil }
    return v
}

// MARK: - Что играет

/// Программа, которая сейчас выводит звук (по данным Core Audio), уже сведённая к самой программе:
/// у Chrome звук идёт из «Google Chrome Helper», но в списке он — Chrome.
struct SoundApp: Equatable {
    let bundle: String
    let name: String
    let outputting: Bool
}

struct MediaItem: Identifiable, Equatable {
    enum Source: Equatable {
        case player(bundle: String)                              // Spotify, Музыка: целиком через AppleScript
        case chromeTab(bundle: String, window: Int, tab: Int)     // Chrome и родственники: по id окна и вкладки
        case safariTab(window: Int, index: Int)                   // у вкладок Safari нет id — по номеру
        case sound(bundle: String)                                // любая программа со звуком (Telegram, Zoom…): громкость и «без звука»
    }
    let id: String
    let source: Source
    let appBundle: String
    let appName: String
    let title: String
    var subtitle: String
    var playing: Bool
    var iconURL: String? = nil      // фавикон сайта для вкладок
    var muted = false               // звук программы выключен через Lark
    var artworkURL: String? = nil   // обложка трека или превью видео
    var position: Double? = nil     // секунды от начала
    var duration: Double? = nil     // длина, секунды (нет — прямой эфир или неизвестно)
    var volume: Double? = nil       // 0…1: своя громкость строки (вкладка, плеер, программа)
    var fetchedAt = Date()          // когда узнали position — между опросами время идёт само
    var routeName: String? = nil    // звук программы выводится в это устройство (Lark)
    var sinkName: String? = nil     // звук вкладки выводится в это устройство (расширение «Lark для Chrome»)
    var hasExtension = false        // во вкладке работает «Lark для Chrome»

    var isSoundOnly: Bool { if case .sound = source { return true } else { return false } }
    var isPlayer: Bool { if case .player = source { return true } else { return false } }
    var isTab: Bool { !isSoundOnly && !isPlayer }
    var canSeek: Bool { (duration ?? 0) > 1 && position != nil }

    /// Позиция сейчас: между опросами, пока играет, прибавляем прошедшее время.
    func livePosition(at now: Date) -> Double? {
        guard let p = position else { return nil }
        let v = playing ? p + now.timeIntervalSince(fetchedAt) : p
        return min(v, duration ?? v)
    }

    static func == (a: MediaItem, b: MediaItem) -> Bool {
        a.id == b.id && a.source == b.source && a.title == b.title && a.subtitle == b.subtitle && a.playing == b.playing
            && a.iconURL == b.iconURL && a.muted == b.muted && a.artworkURL == b.artworkURL && a.position == b.position
            && a.duration == b.duration && a.volume == b.volume && a.routeName == b.routeName && a.sinkName == b.sinkName
            && a.hasExtension == b.hasExtension
    }
}

/// Действия над строкой «Сейчас играет».
enum MediaAction: Equatable {
    case play, pause
    case seek(Double)      // перейти на секунду
    case skip(Double)      // ±секунд от текущей
    case next, previous    // трек (у плееров)
    case volume(Double)    // 0…1
}

struct Hint: Identifiable, Equatable {
    let id: String
    let text: String
    let openPrivacy: Bool
}

struct Browser: Equatable {
    let bundle: String
    let name: String
    var isSafari: Bool { bundle == Media.safari }
}


/// Строки «программа издаёт звук» для тех, кого Lark не умеет ставить на паузу по-своему (Telegram, Zoom, Teams, игры).
/// covered — программы, которые Lark уже показывает по-своему: плеер со своей строкой или браузер, чьи вкладки удалось
/// опросить. Для них общей строки нет: Chrome после паузы ещё долго держит звуковой поток открытым, и macOS считает,
/// что он «играет», — вышла бы непонятная строка «Google Chrome — играет звук». Выключенные или приглушённые Lark-ом
/// видны всегда, иначе звук нельзя было бы вернуть.
func soundItems(_ apps: [SoundApp], detailed: [MediaItem], covered: Set<String> = [], muted: Set<String>, gains: [String: Double] = [:],
                me: String) -> [MediaItem] {
    let busy = Set(detailed.filter(\.playing).map(\.appBundle)).union(covered)
    let touched = muted.union(gains.filter { $0.value != 1 }.keys)
    var seen = Set<String>(), out: [MediaItem] = []
    func make(_ b: String, _ name: String, outputting: Bool) -> MediaItem {
        let isMuted = muted.contains(b)
        let sub = isMuted ? tr("Звук выключен в Lark", "Muted in Lark", "Larkis vaigistatud")
                          : (outputting ? tr("Играет звук", "Playing sound", "Mängib heli") : tr("Молчит", "Silent", "Vaikne"))
        return MediaItem(id: "sound:\(b)", source: .sound(bundle: b), appBundle: b, appName: name, title: name, subtitle: sub,
                         playing: outputting && !isMuted, muted: isMuted, volume: gains[b] ?? 1)
    }
    for a in apps where a.bundle != me && !seen.contains(a.bundle) {
        guard touched.contains(a.bundle) || (a.outputting && !busy.contains(a.bundle)) else { continue }
        seen.insert(a.bundle)
        out.append(make(a.bundle, a.name, outputting: a.outputting))
    }
    for b in touched.sorted() where !seen.contains(b) && b != me {   // программа сейчас молчит или закрылась — всё равно показать
        out.append(make(b, b, outputting: false))
    }
    return out
}

/// Путь к программе по пути процесса: первая «.app» в пути (помощники Chrome лежат внутри Google Chrome.app).
func outerAppPath(_ executable: String) -> String? {
    guard let r = executable.range(of: ".app/") else { return executable.hasSuffix(".app") ? executable : nil }
    return String(executable[..<r.lowerBound]) + ".app"
}

enum Media {
    static let sep = "\u{1F}"
    static let spotify = "com.spotify.client"
    static var players: [(bundle: String, name: String)] { [(spotify, "Spotify"), ("com.apple.Music", tr("Музыка", "Music", "Muusika"))] }
    static let safari = "com.apple.Safari"
    static let browsers: [Browser] = [
        Browser(bundle: "com.google.Chrome", name: "Chrome"), Browser(bundle: "company.thebrowser.Browser", name: "Arc"),
        Browser(bundle: "com.brave.Browser", name: "Brave"), Browser(bundle: "com.microsoft.edgemac", name: "Edge"),
        Browser(bundle: "ru.yandex.desktop.yandex-browser", name: "Yandex"),
        Browser(bundle: "com.vivaldi.Vivaldi", name: "Vivaldi"), Browser(bundle: "com.operasoftware.Opera", name: "Opera"),
        Browser(bundle: safari, name: "Safari"),
    ]

    // JS внутри вкладки. Без двойных кавычек и обратных слэшей: он вставляется в строку AppleScript (это проверяет тест).
    // Главный ролик страницы — играющий, а из остальных самый длинный. Вкладка попадает в список, если в ней звучит
    // видео/аудио или есть начатое и поставленное на паузу.
    // Ответ: 1/0 ␟ сайт ␟ значок ␟ обложка ␟ позиция ␟ длина (0 — эфир) ␟ громкость ␟ есть расширение ␟ его устройство ␟ название.
    // Расширение «Lark для Chrome» помечает страницу атрибутами data-lark-ext и data-lark-sink (куда выведен звук вкладки).
    static let pickJS = "var m=[].slice.call(document.querySelectorAll('video,audio'));function d(x){return isFinite(x.duration)?x.duration:0}m.sort(function(a,b){return (a.paused-b.paused)||(d(b)-d(a))});var e=m[0];"
    static let probeJS = "(function(){var F=String.fromCharCode(31);" + pickJS
        + "var on=m.some(function(x){return !x.paused&&!x.ended&&!x.muted&&x.volume>0&&x.readyState>1});"
        + "var can=m.some(function(x){return x.currentTime>1&&!x.ended&&d(x)>5});if(!on&&!can)return '';"
        + "var md=navigator.mediaSession&&navigator.mediaSession.metadata;"
        + "var t=md&&md.title?md.title+(md.artist?' — '+md.artist:''):document.title;"
        + "var h=location.hostname;if(h.indexOf('www.')==0)h=h.slice(4);"
        + "var ic='',best=-1;[].slice.call(document.querySelectorAll('link[rel~=icon],link[rel=apple-touch-icon]')).forEach(function(l){var z=l.getAttribute('sizes')||'';var n=z=='any'?512:(parseInt(z)||(l.rel.indexOf('apple')>=0?180:16));if(n>best&&l.href){best=n;ic=l.href}});if(!ic)ic=location.origin+'/favicon.ico';"
        + "var art='',ab=-1;if(md&&md.artwork){[].slice.call(md.artwork).forEach(function(a){var n=parseInt(a.sizes||'')||1;if(n>ab&&a.src){ab=n;art=a.src}})}"
        + "if(!art){var og='',ot='';[].slice.call(document.getElementsByTagName('meta')).forEach(function(x){var p=x.getAttribute('property');if(p=='og:image')og=x.content;if(p=='og:type')ot=x.content||''});if(og&&ot.indexOf('video')>=0)art=og}"
        + "try{if(art)art=new URL(art,location.href).href}catch(err){art=''}"
        + "var de=document.documentElement;"
        + "return (on?'1':'0')+F+h+F+ic+F+art+F+e.currentTime.toFixed(1)+F+d(e).toFixed(1)+F+(e.muted?0:e.volume).toFixed(2)+F+(de.getAttribute('data-lark-ext')?'1':'0')+F+(de.getAttribute('data-lark-sink')||'')+F+t;})()"
    static let pauseJS = "(function(){[].slice.call(document.querySelectorAll('video,audio')).forEach(function(e){e.pause()});return ''})()"
    static let playJS = "(function(){var m=[].slice.call(document.querySelectorAll('video,audio')).filter(function(e){return e.currentTime>1&&!e.ended});m.sort(function(a,b){return (b.duration||0)-(a.duration||0)});if(m[0]){m[0].muted=false;m[0].play()}return ''})()"

    /// JS над главным роликом вкладки (e) и всеми роликами (m).
    static func onMainJS(_ body: String) -> String { "(function(){" + pickJS + "if(!e)return '';" + body + ";return ''})()" }
    static func num(_ v: Double) -> String { String(format: "%.2f", v) }

    static func tabJS(_ a: MediaAction) -> String {
        switch a {
        case .play: return playJS
        case .pause: return pauseJS
        case .seek(let s): return onMainJS("e.currentTime=\(num(max(0, s)))")
        case .skip(let s): return onMainJS("e.currentTime=Math.max(0,e.currentTime+(\(num(s))))")
        case .next, .previous: return ""
        case .volume(let v):
            let x = num(min(1, max(0, v)))
            return onMainJS("m.forEach(function(x){x.volume=\(x);if(\(x)>0)x.muted=false})")
        }
    }

    // MARK: Скрипты

    /// Состояние плеера: ␟-разделённые состояние, название, исполнитель, обложка, позиция, длина, громкость 0–100.
    static func playerScript(_ bundle: String) -> String {
        let art = bundle == spotify ? "\n        try\n            set art to artwork url of current track\n        end try" : ""
        return """
        if application id "\(bundle)" is not running then return ""
        set sep to character id 31
        tell application id "\(bundle)"
            set s to player state as text
            set n to ""
            set a to ""
            set art to ""
            set pos to ""
            set dur to ""
            set vol to ""
            try
                set n to name of current track
                set a to artist of current track
            end try
            try
                set pos to (player position) as text
            end try
            try
                set dur to (duration of current track) as text
            end try
            try
                set vol to (sound volume) as text
            end try\(art)
        end tell
        return s & sep & n & sep & a & sep & art & sep & pos & sep & dur & sep & vol
        """
    }

    /// Обходит все вкладки браузера и спрашивает каждую через probeJS. В конце строка «!успешных␟последняя ошибка».
    static func probeScript(_ b: Browser) -> String {
        let run = b.isSafari ? "do JavaScript \"\(probeJS)\" in t" : "execute t javascript \"\(probeJS)\""
        let tabKey = b.isSafari ? "(i as text)" : "((id of t) as text)"
        return """
        if application id "\(b.bundle)" is not running then return ""
        set sep to character id 31
        set out to ""
        set lastErr to ""
        set okCount to 0
        tell application id "\(b.bundle)"
            repeat with w in windows
                try
                    set wid to id of w
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        try
                            set res to \(run)
                            set okCount to okCount + 1
                            if res is not missing value and res is not "" then set out to out & (wid as text) & sep & \(tabKey) & sep & res & linefeed
                        on error e
                            set lastErr to e
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return out & "!" & okCount & sep & lastErr
        """
    }

    /// Скрипт действия над строкой. Пусто — действие не через AppleScript (звук программ) или неприменимо.
    static func actionScript(_ item: MediaItem, _ a: MediaAction) -> String {
        switch item.source {
        case .player(let b):
            let cmd: String
            switch a {
            case .play: cmd = "play"
            case .pause: cmd = "pause"
            case .seek(let s): cmd = "set player position to \(num(max(0, s)))"
            case .skip(let s): cmd = "set player position to ((player position) + (\(num(s))))"
            case .next: cmd = "next track"
            case .previous: cmd = "previous track"
            case .volume(let v): cmd = "set sound volume to \(Int((min(1, max(0, v)) * 100).rounded()))"
            }
            return "tell application id \"\(b)\" to \(cmd)"
        case .chromeTab(let b, let w, let t):
            let js = tabJS(a)
            return js.isEmpty ? "" : "tell application id \"\(b)\" to execute tab id \(t) of window id \(w) javascript \"\(js)\""
        case .safariTab(let w, let i):
            let js = tabJS(a)
            return js.isEmpty ? "" : "tell application id \"\(safari)\" to do JavaScript \"\(js)\" in tab \(i) of window id \(w)"
        case .sound:
            return ""   // звук программ — через Core Audio, не скриптом
        }
    }

    static func setPlayingScript(_ item: MediaItem, _ play: Bool) -> String { actionScript(item, play ? .play : .pause) }

    /// Попросить «Lark для Chrome» вывести вкладку в устройство (по названию; "default" — как у всех).
    /// Название — в процентной записи: в строке AppleScript не должно быть кавычек и обратных слэшей.
    static func tabSinkJS(_ deviceName: String) -> String {
        let enc = deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "(function(){document.documentElement.removeAttribute('data-lark-error');document.documentElement.setAttribute('data-lark-want','\(enc)');return ''})()"
    }

    static func tabSinkScript(_ item: MediaItem, _ deviceName: String) -> String {
        let js = tabSinkJS(deviceName)
        switch item.source {
        case .chromeTab(let b, let w, let t): return "tell application id \"\(b)\" to execute tab id \(t) of window id \(w) javascript \"\(js)\""
        default: return ""
        }
    }

    /// Ответ расширения после просьбы: ошибка (пусто — всё хорошо).
    static func tabErrorScript(_ item: MediaItem) -> String {
        let js = "(document.documentElement.getAttribute('data-lark-error')||'')"
        switch item.source {
        case .chromeTab(let b, let w, let t): return "tell application id \"\(b)\" to execute tab id \(t) of window id \(w) javascript \"\(js)\""
        default: return ""
        }
    }

    static func revealScript(_ item: MediaItem) -> String {
        switch item.source {
        case .player(let b), .sound(let b):
            return "tell application id \"\(b)\" to activate"
        case .chromeTab(let b, let w, let t):
            return """
            tell application id "\(b)"
                set w to window id \(w)
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if (id of t) as text is "\(t)" then
                        set active tab index of w to i
                        exit repeat
                    end if
                end repeat
                set index of w to 1
                activate
            end tell
            """
        case .safariTab(let w, let i):
            return """
            tell application id "\(safari)"
                set current tab of window id \(w) to tab \(i) of window id \(w)
                set index of window id \(w) to 1
                activate
            end tell
            """
        }
    }

    // MARK: Разбор ответов

    /// Нет доступа: пользователь не разрешил Lark управлять программой (или запрос ещё висит).
    static func notPermitted(_ err: String) -> Bool { err.contains("-1743") || err.contains("-10004") }

    static func deniedHint(_ name: String) -> Hint {
        Hint(id: "deny-\(name)",
             text: tr("Нет доступа к \(name): разрешите Lark в «Конфиденциальность → Автоматизация».",
                      "No access to \(name): allow Lark in Privacy & Security → Automation.",
                      "Puudub ligipääs programmile \(name): lubage Lark jaotises Privaatsus ja turvalisus → Automatiseerimine."),
             openPrivacy: true)
    }

    static func jsHint(_ b: Browser) -> Hint {
        let path = b.isSafari
            ? tr("«Разработка → Разрешить JavaScript из Apple Events»", "Develop → Allow JavaScript from Apple Events",
                 "Develop → Allow JavaScript from Apple Events")
            : tr("«Вид → Разработчик → Разрешить JavaScript из Apple Events»", "View → Developer → Allow JavaScript from Apple Events",
                 "View → Developer → Allow JavaScript from Apple Events")
        return Hint(id: "js-\(b.bundle)",
                    text: tr("Чтобы видеть вкладки \(b.name): в \(b.name) меню \(path).",
                             "To see \(b.name) tabs, in \(b.name) choose \(path).",
                             "\(b.name) vahekaartide nägemiseks valige \(b.name) menüüs \(path)."),
                    openPrivacy: false)
    }

    static func parsePlayer(_ out: String, bundle: String, name: String, at now: Date = Date()) -> MediaItem? {
        let f = out.components(separatedBy: sep)
        guard f.count >= 3, f[0] == "playing" || f[0] == "paused", !f[1].isEmpty else { return nil }
        var item = MediaItem(id: "app:\(bundle)", source: .player(bundle: bundle), appBundle: bundle, appName: name,
                             title: f[1], subtitle: f[2].isEmpty ? name : "\(f[2]) · \(name)", playing: f[0] == "playing")
        if f.count >= 7 {
            item.artworkURL = f[3].hasPrefix("http") ? f[3] : nil
            item.position = number(f[4])
            if var d = number(f[5]) {
                if bundle == spotify { d /= 1000 }   // Spotify отдаёт длину в миллисекундах
                item.duration = d > 0 ? d : nil
            }
            item.volume = number(f[6]).map { min(1, $0 / 100) }
            item.fetchedAt = now
        }
        return item
    }

    /// Строки вкладок → записи. jsOff: ни одна вкладка не ответила, и ошибка про JavaScript (выключен в браузере).
    /// answered: сколько вкладок ответило — больше нуля значит, вкладки браузера Lark видит.
    static func parseTabs(_ out: String, _ b: Browser, at now: Date = Date()) -> (items: [MediaItem], jsOff: Bool, answered: Int) {
        var items: [MediaItem] = [], jsOff = false, answered = 0
        for line in out.components(separatedBy: "\n") {
            if line.hasPrefix("!") {
                let f = line.dropFirst().components(separatedBy: sep)
                answered = Int(f.first ?? "") ?? 0
                jsOff = answered == 0 && f.count > 1 && f[1].contains("JavaScript")
                continue
            }
            let f = line.components(separatedBy: sep)
            guard f.count >= 12, let w = Int(f[0]), let t = Int(f[1]), f[2] == "0" || f[2] == "1" else { continue }
            let host = f[3]
            let title = f[11...].joined(separator: sep)
            let source: MediaItem.Source = b.isSafari ? .safariTab(window: w, index: t) : .chromeTab(bundle: b.bundle, window: w, tab: t)
            var item = MediaItem(id: "tab:\(b.bundle):\(w):\(t)", source: source, appBundle: b.bundle, appName: b.name,
                                 title: title.isEmpty ? (host.isEmpty ? b.name : host) : title,
                                 subtitle: host.isEmpty ? b.name : "\(host) · \(b.name)",
                                 playing: f[2] == "1", iconURL: f[4].isEmpty ? nil : f[4])
            item.artworkURL = f[5].isEmpty ? nil : f[5]
            item.position = number(f[6])
            item.duration = number(f[7]).flatMap { $0 > 0 ? $0 : nil }
            item.volume = number(f[8]).map { min(1, $0) }
            item.hasExtension = f[9] == "1"
            item.sinkName = f[10].isEmpty ? nil : f[10]
            item.fetchedAt = now
            items.append(item)
        }
        return (items, jsOff, max(answered, items.isEmpty ? 0 : 1))
    }
}

/// Постоянный порядок строк: место строки — когда она впервые появилась. Играет или на паузе — строка не прыгает.
struct StableOrder {
    private var rank: [String: Int] = [:]
    private var next = 0

    mutating func sort(_ items: [MediaItem]) -> [MediaItem] {
        for it in items where rank[it.id] == nil { rank[it.id] = next; next += 1 }
        return items.enumerated().sorted { (rank[$0.element.id] ?? 0, $0.offset) < (rank[$1.element.id] ?? 0, $1.offset) }.map(\.element)
    }
}
