// Тесты Lark: ./scripts/test.sh
// Чистая логика (Sources/Logic.swift), компиляция всех AppleScript для установленных программ
// и JavaScript вкладок в настоящем движке WebKit (страница с играющим звуком).
import AppKit
import CoreAudio
import WebKit

var failures = 0, passed = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { passed += 1 } else { failures += 1; print("✗ \(what)  (строка \(line))") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    check(a == b, "\(what): ждали \(b), получили \(a)", line: line)
}
let F = Media.sep

// MARK: - Имена и устройства

eq(displayName("Микрофон MacBook Air", .input), "MacBook Air", "префикс микрофона")
eq(displayName("Микрофон (iPhone (Roma))", .input), "iPhone (Roma)", "скобки вокруг iPhone")
eq(displayName("Динамики MacBook Air", .output), "MacBook Air", "префикс динамиков")
eq(displayName("MacBook Air Speakers", .output), "MacBook Air Speakers", "суффикс не трогаем")
eq(displayName("Микрофон MacBook Air", .output), "Микрофон MacBook Air", "у выхода префикс микрофона не убираем")
eq(displayName("Микрофон ", .input), "Микрофон ", "пустое имя после обрезки — оставить как было")
eq(displayName("HK GO + PLAY", .input), "HK GO + PLAY", "обычное имя")

let devs = [Device(id: 1, uid: "a", name: "A", transport: 0), Device(id: 2, uid: "b", name: "B", transport: 0),
            Device(id: 3, uid: "c", name: "C", transport: 0)]
eq(visibleDevices(devs, hidden: ["b"], current: 1).map(\.uid), ["a", "c"], "скрытое не видно")
eq(visibleDevices(devs, hidden: ["b"], current: 2).map(\.uid), ["a", "b", "c"], "выбранное видно, даже если скрыто")
eq(symbol(for: Device(id: 1, uid: "x", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth), .output), "airpods", "значок AirPods")
eq(symbol(for: Device(id: 1, uid: "x", name: "Mac", transport: kAudioDeviceTransportTypeBuiltIn), .input), "laptopcomputer", "значок Mac")

// MARK: - Порядок строк

func item(_ id: String, _ playing: Bool, bundle: String = "b") -> MediaItem {
    MediaItem(id: id, source: .player(bundle: bundle), appBundle: bundle, appName: "", title: id, subtitle: "", playing: playing)
}
eq(playingFirst([item("1", false), item("2", true), item("3", false), item("4", true)]).map(\.id), ["2", "4", "1", "3"],
   "играющее сверху, порядок внутри групп сохранён")

// MARK: - Разбор ответа плеера

let sp = Media.parsePlayer("playing\(F)Wasted\(F)NXT GXNXRXTION", bundle: "com.spotify.client", name: "Spotify")
eq(sp?.title, "Wasted", "трек Spotify")
eq(sp?.subtitle, "NXT GXNXRXTION · Spotify", "исполнитель")
eq(sp?.playing, true, "играет")
eq(Media.parsePlayer("paused\(F)Song\(F)", bundle: "m", name: "Музыка")?.subtitle, "Музыка", "без исполнителя — имя программы")
eq(Media.parsePlayer("paused\(F)Song\(F)", bundle: "m", name: "Музыка")?.playing, false, "пауза")
check(Media.parsePlayer("stopped\(F)\(F)", bundle: "m", name: "M") == nil, "остановленный плеер не показываем")
check(Media.parsePlayer("playing\(F)\(F)x", bundle: "m", name: "M") == nil, "без названия трека не показываем")
check(Media.parsePlayer("", bundle: "m", name: "M") == nil, "пустой ответ")

// MARK: - Разбор вкладок

let chrome = Browser(bundle: "com.google.Chrome", name: "Chrome")
let safari = Browser(bundle: Media.safari, name: "Safari")
let tabsOut = [
    "11\(F)101\(F)1\(F)youtube.com\(F)https://y/icon.png\(F)Видео — Автор",
    "11\(F)102\(F)0\(F)facebook.com\(F)\(F)",
    "12\(F)7\(F)1\(F)site.ee\(F)https://s/i.png\(F)A\(F)B",      // разделитель внутри названия
    "мусор",
    "x\(F)1\(F)1\(F)h\(F)i\(F)t",                                  // окно не число
    "!3\(F)",
].joined(separator: "\n")
let tabs = Media.parseTabs(tabsOut, chrome)
eq(tabs.items.count, 3, "три вкладки")
eq(tabs.jsOff, false, "JS работает")
eq(tabs.items[0].source, .chromeTab(bundle: "com.google.Chrome", window: 11, tab: 101), "источник вкладки")
eq(tabs.items[0].subtitle, "youtube.com · Chrome", "подпись вкладки")
eq(tabs.items[0].iconURL, "https://y/icon.png", "значок вкладки")
eq(tabs.items[1].title, "facebook.com", "без названия — сайт")
eq(tabs.items[1].iconURL, nil, "пустой значок")
eq(tabs.items[1].playing, false, "на паузе")
eq(tabs.items[2].title, "A\(F)B", "название с разделителем целиком")
let st = Media.parseTabs("3\(F)2\(F)1\(F)ex.com\(F)\(F)T\n!1\(F)", safari)
eq(st.items.first?.source, .safariTab(window: 3, index: 2), "вкладка Safari по номеру")
let local = Media.parseTabs("1\(F)2\(F)1\(F)\(F)\(F)Файл", chrome).items.first
eq(local?.subtitle, "Chrome", "страница без сайта (файл) — без лишней точки")
eq(Media.parseTabs("!0\(F)Executing JavaScript through AppleScript is turned off.", chrome).jsOff, true, "JS выключен в Chrome")
eq(Media.parseTabs("!0\(F)Вы должны включить «Разрешить JavaScript из Apple Events»", safari).jsOff, true, "JS выключен в Safari (по-русски)")
eq(Media.parseTabs("!4\(F)JavaScript error in one tab", chrome).jsOff, false, "часть вкладок ответила — подсказка не нужна")
eq(Media.parseTabs("!0\(F)", chrome).jsOff, false, "нет вкладок — подсказка не нужна")
check(Media.jsHint(safari).text.contains("Разработка"), "подсказка Safari ведёт в меню «Разработка»")
check(Media.jsHint(chrome).text.contains("Вид → Разработчик"), "подсказка Chrome ведёт в «Вид → Разработчик»")
check(Media.notPermitted("execution error: Not authorized to send Apple events to Spotify. (-1743)"), "отказ в доступе")
check(!Media.notPermitted("execution error: something (-1728)"), "другая ошибка — не отказ")

// MARK: - Программы со звуком

let apps = [SoundApp(bundle: "org.telegram", name: "Telegram", outputting: true),
            SoundApp(bundle: "com.google.Chrome", name: "Chrome", outputting: true),
            SoundApp(bundle: "local.lark", name: "Lark", outputting: true),
            SoundApp(bundle: "net.whatsapp", name: "WhatsApp", outputting: false),
            SoundApp(bundle: "org.telegram", name: "Telegram", outputting: true)]
let playingTab = MediaItem(id: "t", source: .chromeTab(bundle: "com.google.Chrome", window: 1, tab: 1), appBundle: "com.google.Chrome",
                           appName: "Chrome", title: "", subtitle: "", playing: true)
var si = soundItems(apps, detailed: [playingTab], muted: [], me: "local.lark")
eq(si.map(\.appBundle), ["org.telegram"], "Telegram виден; Chrome уже есть вкладкой; Lark и молчащий WhatsApp — нет; без повторов")
eq(si.first?.source, .sound(bundle: "org.telegram"), "строка «звук программы»")
check(si.first?.isSoundOnly == true && si.first?.playing == true && si.first?.muted == false, "играет, звук не выключен")
si = soundItems(apps, detailed: [MediaItem(id: "t", source: playingTab.source, appBundle: "com.google.Chrome", appName: "", title: "",
                                           subtitle: "", playing: false)], muted: [], me: "local.lark")
eq(si.map(\.appBundle), ["org.telegram", "com.google.Chrome"], "вкладка на паузе, а Chrome звучит (например, JS выключен) — показать Chrome")
si = soundItems(apps, detailed: [], muted: ["net.whatsapp", "com.gone"], me: "local.lark")
eq(si.map(\.appBundle), ["org.telegram", "com.google.Chrome", "net.whatsapp", "com.gone"], "выключенные видны всегда")
check(si[2].muted && !si[2].playing && si[2].subtitle.contains("выключен"), "выключенная программа помечена")
check(soundItems([], detailed: [], muted: [], me: "x").isEmpty, "тишина — пусто")

eq(outerAppPath("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
   "/Applications/Google Chrome.app", "помощник Chrome → Chrome")
eq(outerAppPath("/Applications/Telegram.app/Contents/MacOS/Telegram"), "/Applications/Telegram.app", "Telegram")
eq(outerAppPath("/usr/sbin/coreaudiod"), nil, "служба без .app")

// MARK: - Скрипты

for js in [Media.probeJS, Media.pauseJS, Media.playJS] {
    check(!js.contains("\"") && !js.contains("\\"), "в JS нет двойных кавычек и обратных слэшей (он внутри строки AppleScript)")
}

func installed(_ bundle: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil }
func compiles(_ src: String, _ what: String) {
    var err: NSDictionary?
    let ok = NSAppleScript(source: src)?.compileAndReturnError(&err) ?? false
    check(ok, "AppleScript компилируется: \(what) \(err?[NSAppleScript.errorMessage] ?? "")")
}
var checkedApps: [String] = []
for p in Media.players where installed(p.bundle) {
    checkedApps.append(p.name)
    compiles(Media.playerScript(p.bundle), "плеер \(p.name)")
    let it = item("p", true, bundle: p.bundle)
    compiles(Media.setPlayingScript(it, true), "\(p.name) play")
    compiles(Media.setPlayingScript(it, false), "\(p.name) pause")
    compiles(Media.revealScript(it), "\(p.name) открыть")
}
for b in Media.browsers where installed(b.bundle) {
    checkedApps.append(b.name)
    compiles(Media.probeScript(b), "вкладки \(b.name)")
    let src: MediaItem.Source = b.isSafari ? .safariTab(window: 1, index: 2) : .chromeTab(bundle: b.bundle, window: 1, tab: 2)
    let it = MediaItem(id: "x", source: src, appBundle: b.bundle, appName: b.name, title: "", subtitle: "", playing: true)
    compiles(Media.setPlayingScript(it, true), "\(b.name) play")
    compiles(Media.setPlayingScript(it, false), "\(b.name) pause")
    compiles(Media.revealScript(it), "\(b.name) открыть вкладку")
}
eq(Media.setPlayingScript(MediaItem(id: "s", source: .sound(bundle: "t"), appBundle: "t", appName: "", title: "", subtitle: "",
                                    playing: true), false), "", "звук программ — не скриптом")

// MARK: - JavaScript в настоящем WebKit

/// Тихий WAV на 30 секунд: элемент «играет», но в колонках ничего не слышно.
func silentWav(seconds: Int) -> String {
    let rate = 8000, n = rate * seconds
    var d = Data()
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append("RIFF".data(using: .ascii)!); u32(36 + n); d.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(1); u32(rate); u32(rate); u16(1); u16(8)
    d.append("data".data(using: .ascii)!); u32(n); d.append(Data(repeating: 128, count: n))
    return "data:audio/wav;base64," + d.base64EncodedString()
}

@MainActor
final class Web: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var loaded = false
    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        super.init()
        view.navigationDelegate = self
        // WebKit не запускает медиа в представлении без окна — держим его в прозрачном окне за краем экрана
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        win.alphaValue = 0
        win.contentView = view
        win.orderFrontRegardless()
        window = win
    }
    private var window: NSWindow?
    func load(_ html: String) {
        loaded = false
        view.loadHTMLString(html, baseURL: URL(string: "https://www.example.com/watch"))
        wait(10) { self.loaded }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func js(_ src: String) -> String {
        var result: String?, done = false
        view.evaluateJavaScript(src) { r, e in result = (r as? String) ?? (e.map { "ERROR \($0)" } ?? ""); done = true }
        wait(10) { done }
        return result ?? "TIMEOUT"
    }
    func wait(_ seconds: Double, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    func sleep(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let w = Web()
    let wav = silentWav(seconds: 30)
    w.load("""
    <html><head><title>Страница</title>
    <link rel="icon" href="/fav-16.png" sizes="16x16"><link rel="icon" href="/fav-96.png" sizes="96x96">
    <link rel="apple-touch-icon" href="/apple.png"></head>
    <body><audio id="a" src="\(wav)" autoplay></audio>
    <script>navigator.mediaSession.metadata = new MediaMetadata({title: 'Песня', artist: 'Певец'});</script></body></html>
    """)
    // В тестовом окне звук «играет», но время не идёт (вывода звука нет) — перематываем вручную, как будто послушали 5 секунд
    w.wait(5) { w.js("var a=document.getElementById('a');a.play();a.currentTime=5;a.paused?'':'y'") == "y" }
    var r = w.js(Media.probeJS).components(separatedBy: F)
    eq(r.count, 4, "ответ вкладки из 4 частей (\(r))")
    if r.count == 4 {
        eq(r[0], "1", "звук играет")
        eq(r[1], "example.com", "сайт без www")
        eq(r[2], "https://www.example.com/apple.png", "выбран самый крупный значок (apple-touch-icon 180 > 96)")
        eq(r[3], "Песня — Певец", "название из mediaSession")
    }
    _ = w.js(Media.pauseJS)
    w.sleep(0.3)
    eq(w.js(Media.probeJS).components(separatedBy: F).first, "0", "после паузы — на паузе, но в списке")
    _ = w.js(Media.playJS)
    w.wait(5) { w.js("document.getElementById('a').paused ? '' : 'y'") == "y" }
    eq(w.js(Media.probeJS).components(separatedBy: F).first, "1", "после play снова играет")

    // Без значков, без mediaSession: значок — /favicon.ico, название — заголовок страницы
    w.load("""
    <html><head><title>Видео</title></head><body><video id="v" src="\(wav)" autoplay></video></body></html>
    """)
    w.wait(5) { w.js("var v=document.getElementById('v');v.currentTime=5;v.pause();v.paused&&v.currentTime>1?'y':''") == "y" }
    r = w.js(Media.probeJS).components(separatedBy: F)
    eq(r.first, "0", "начатое видео на паузе — в списке, можно продолжить")
    eq(r.count == 4 ? r[2] : "", "https://www.example.com/favicon.ico", "запасной значок /favicon.ico")
    eq(r.count == 4 ? r[3] : "", "Видео", "название — заголовок страницы")

    // Беззвучный ролик (как превью в ленте Facebook) и страница без медиа — не показываем
    w.load("""
    <html><body><video id="m" src="\(wav)" autoplay muted></video></body></html>
    """)
    w.sleep(0.5)
    eq(w.js(Media.probeJS), "", "беззвучное автовидео, только что началось — не в списке")
    w.load("<html><head><title>Текст</title></head><body>Просто статья</body></html>")
    eq(w.js(Media.probeJS), "", "страница без звука — не в списке")
}

print("Программы для проверки AppleScript: \(checkedApps.isEmpty ? "не установлены" : checkedApps.joined(separator: ", "))")
print(failures == 0 ? "✅ Все проверки прошли: \(passed)" : "❌ Не прошло: \(failures) из \(passed + failures)")
exit(failures == 0 ? 0 : 1)
