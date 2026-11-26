// Чистая логика Lark без окон и звука: короткие имена устройств, тексты AppleScript и JavaScript,
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
    for p in (dir == .input ? ["Микрофон ", "Microphone "] : ["Динамики ", "Speakers "]) where n.hasPrefix(p) {
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

// MARK: - Что играет

/// Программа, которая сейчас выводит звук (по данным Core Audio), уже сведённая к самой программе:
/// у Chrome звук идёт из «Google Chrome Helper», но в списке он — Chrome.
struct SoundApp: Equatable {
    let bundle: String
    let name: String
    let outputting: Bool
}

/// Строки «программа издаёт звук» для тех, кого Lark не умеет ставить на паузу по-своему.
/// Программа не дублируется, если по ней уже есть играющая строка (вкладка, трек). Выключенные Lark-ом видны всегда,
/// иначе звук нельзя было бы вернуть.
func soundItems(_ apps: [SoundApp], detailed: [MediaItem], muted: Set<String>, me: String) -> [MediaItem] {
    let busy = Set(detailed.filter(\.playing).map(\.appBundle))
    var seen = Set<String>(), out: [MediaItem] = []
    for a in apps where a.bundle != me && !seen.contains(a.bundle) {
        let isMuted = muted.contains(a.bundle)
        guard isMuted || (a.outputting && !busy.contains(a.bundle)) else { continue }
        seen.insert(a.bundle)
        out.append(MediaItem(id: "sound:\(a.bundle)", source: .sound(bundle: a.bundle), appBundle: a.bundle, appName: a.name,
                             title: a.name, subtitle: isMuted ? "Звук выключен в Lark" : "Играет звук",
                             playing: a.outputting && !isMuted, muted: isMuted))
    }
    for b in muted where !seen.contains(b) {   // выключили, а программа сейчас молчит или закрыла звук — всё равно показать
        out.append(MediaItem(id: "sound:\(b)", source: .sound(bundle: b), appBundle: b, appName: b,
                             title: b, subtitle: "Звук выключен в Lark", playing: false, muted: true))
    }
    return out
}

/// Путь к программе по пути процесса: первая «.app» в пути (помощники Chrome лежат внутри Google Chrome.app).
func outerAppPath(_ executable: String) -> String? {
    guard let r = executable.range(of: ".app/") else { return executable.hasSuffix(".app") ? executable : nil }
    return String(executable[..<r.lowerBound]) + ".app"
}

struct MediaItem: Identifiable, Equatable {
    enum Source: Equatable {
        case player(bundle: String)                              // Spotify, Музыка: play/pause целиком
        case chromeTab(bundle: String, window: Int, tab: Int)     // Chrome и родственники: по id окна и вкладки
        case safariTab(window: Int, index: Int)                   // у вкладок Safari нет id — по номеру
        case sound(bundle: String)                                // любая программа со звуком (Telegram…): выключить звук
    }
    let id: String
    let source: Source
    let appBundle: String
    let appName: String
    let title: String
    let subtitle: String
    var playing: Bool
    var iconURL: String? = nil   // фавикон сайта для вкладок
    var muted = false            // звук программы выключен через Lark

    var isSoundOnly: Bool { if case .sound = source { return true } else { return false } }
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

/// Играющее — сверху; внутри групп порядок не меняется, чтобы строки не прыгали при обновлении.
func playingFirst(_ items: [MediaItem]) -> [MediaItem] {
    items.filter(\.playing) + items.filter { !$0.playing }
}

enum Media {
    static let sep = "\u{1F}"
    static let players: [(bundle: String, name: String)] = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Музыка")]
    static let safari = "com.apple.Safari"
    static let browsers: [Browser] = [
        Browser(bundle: "com.google.Chrome", name: "Chrome"), Browser(bundle: "company.thebrowser.Browser", name: "Arc"),
        Browser(bundle: "com.brave.Browser", name: "Brave"), Browser(bundle: "com.microsoft.edgemac", name: "Edge"),
        Browser(bundle: "ru.yandex.desktop.yandex-browser", name: "Яндекс Браузер"),
        Browser(bundle: "com.vivaldi.Vivaldi", name: "Vivaldi"), Browser(bundle: "com.operasoftware.Opera", name: "Opera"),
        Browser(bundle: safari, name: "Safari"),
    ]

    // JS внутри вкладки. Без двойных кавычек и обратных слэшей: он вставляется в строку AppleScript (это проверяет тест).
    // Вкладка попадает в список, если в ней звучит видео/аудио или есть начатое и поставленное на паузу.
    // Ответ: 1/0 (играет) ␟ сайт ␟ адрес самого крупного значка сайта ␟ название.
    static let probeJS = "(function(){var F=String.fromCharCode(31);var m=[].slice.call(document.querySelectorAll('video,audio'));var on=m.some(function(e){return !e.paused&&!e.ended&&!e.muted&&e.volume>0&&e.readyState>1});var can=m.some(function(e){return e.currentTime>1&&!e.ended&&e.duration>5});if(!on&&!can)return '';var md=navigator.mediaSession&&navigator.mediaSession.metadata;var t=md&&md.title?md.title+(md.artist?' — '+md.artist:''):document.title;var h=location.hostname;if(h.indexOf('www.')==0)h=h.slice(4);var ic='',best=-1;[].slice.call(document.querySelectorAll('link[rel~=icon],link[rel=apple-touch-icon]')).forEach(function(l){var z=l.getAttribute('sizes')||'';var n=z=='any'?512:(parseInt(z)||(l.rel.indexOf('apple')>=0?180:16));if(n>best&&l.href){best=n;ic=l.href}});if(!ic)ic=location.origin+'/favicon.ico';return (on?'1':'0')+F+h+F+ic+F+t;})()"
    static let pauseJS = "(function(){[].slice.call(document.querySelectorAll('video,audio')).forEach(function(e){e.pause()});return ''})()"
    static let playJS = "(function(){var m=[].slice.call(document.querySelectorAll('video,audio')).filter(function(e){return e.currentTime>1&&!e.ended});m.sort(function(a,b){return (b.duration||0)-(a.duration||0)});if(m[0]){m[0].muted=false;m[0].play()}return ''})()"

    // MARK: Скрипты

    static func playerScript(_ bundle: String) -> String {
        """
        set sep to character id 31
        tell application id "\(bundle)"
            set s to player state as text
            set n to ""
            set a to ""
            try
                set n to name of current track
                set a to artist of current track
            end try
        end tell
        return s & sep & n & sep & a
        """
    }

    /// Обходит все вкладки браузера и спрашивает каждую через probeJS. В конце строка «!успешных␟последняя ошибка».
    static func probeScript(_ b: Browser) -> String {
        let run = b.isSafari ? "do JavaScript \"\(probeJS)\" in t" : "execute t javascript \"\(probeJS)\""
        let tabKey = b.isSafari ? "(i as text)" : "((id of t) as text)"
        return """
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

    static func setPlayingScript(_ item: MediaItem, _ play: Bool) -> String {
        let js = play ? playJS : pauseJS
        switch item.source {
        case .player(let b):
            return "tell application id \"\(b)\" to \(play ? "play" : "pause")"
        case .chromeTab(let b, let w, let t):
            return "tell application id \"\(b)\" to execute tab id \(t) of window id \(w) javascript \"\(js)\""
        case .safariTab(let w, let i):
            return "tell application id \"\(safari)\" to do JavaScript \"\(js)\" in tab \(i) of window id \(w)"
        case .sound:
            return ""   // звук программ выключается через Core Audio, не скриптом
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
        Hint(id: "deny-\(name)", text: "Нет доступа к \(name): разрешите Lark в «Конфиденциальность → Автоматизация».", openPrivacy: true)
    }

    static func jsHint(_ b: Browser) -> Hint {
        let path = b.isSafari ? "«Разработка → Разрешить JavaScript из Apple Events»"
                              : "«Вид → Разработчик → Разрешить JavaScript из Apple Events»"
        return Hint(id: "js-\(b.bundle)", text: "Чтобы видеть вкладки \(b.name): в \(b.name) меню \(path).", openPrivacy: false)
    }

    static func parsePlayer(_ out: String, bundle: String, name: String) -> MediaItem? {
        let f = out.components(separatedBy: sep)
        guard f.count >= 3, f[0] == "playing" || f[0] == "paused", !f[1].isEmpty else { return nil }
        return MediaItem(id: "app:\(bundle)", source: .player(bundle: bundle), appBundle: bundle, appName: name,
                         title: f[1], subtitle: f[2].isEmpty ? name : "\(f[2]) · \(name)", playing: f[0] == "playing")
    }

    /// Строки вкладок → записи. jsOff: ни одна вкладка не ответила, и ошибка про JavaScript (выключен в браузере).
    static func parseTabs(_ out: String, _ b: Browser) -> (items: [MediaItem], jsOff: Bool) {
        var items: [MediaItem] = [], jsOff = false
        for line in out.components(separatedBy: "\n") {
            if line.hasPrefix("!") {
                let f = line.dropFirst().components(separatedBy: sep)
                jsOff = f.first == "0" && f.count > 1 && f[1].contains("JavaScript")
                continue
            }
            let f = line.components(separatedBy: sep)
            guard f.count >= 6, let w = Int(f[0]), let t = Int(f[1]), f[2] == "0" || f[2] == "1" else { continue }
            let title = f[5...].joined(separator: sep)
            let source: MediaItem.Source = b.isSafari ? .safariTab(window: w, index: t) : .chromeTab(bundle: b.bundle, window: w, tab: t)
            items.append(MediaItem(id: "tab:\(b.bundle):\(w):\(t)", source: source, appBundle: b.bundle, appName: b.name,
                                   title: title.isEmpty ? (f[3].isEmpty ? b.name : f[3]) : title, subtitle: f[3].isEmpty ? b.name : "\(f[3]) · \(b.name)",
                                   playing: f[2] == "1", iconURL: f[4].isEmpty ? nil : f[4]))
        }
        return (items, jsOff)
    }
}
