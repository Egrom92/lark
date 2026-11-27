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
Lang.current = .ru   // тексты проверяем по-русски

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
let mac = Device(id: 4, uid: "mac", name: "Mac", transport: kAudioDeviceTransportTypeBuiltIn)
let withMac = devs + [mac]
eq(replacementDevice(withMac, blocked: ["b"], current: 1, pinned: nil)?.uid, nil, "выбрано незаблокированное — не трогаем")
eq(replacementDevice(withMac, blocked: ["b"], current: 2, pinned: "c")?.uid, "c", "заблокированное → закреплённое")
eq(replacementDevice(withMac, blocked: ["b", "c"], current: 2, pinned: "c")?.uid, "mac", "закреплённое тоже заблокировано → встроенное")
eq(replacementDevice(withMac, blocked: ["b"], current: 2, pinned: "zz")?.uid, "mac", "закреплённое не подключено → встроенное")
eq(replacementDevice(devs, blocked: ["b"], current: 2, pinned: nil)?.uid, "a", "встроенного нет → первое разрешённое")
eq(replacementDevice(devs, blocked: ["a", "b", "c"], current: 2, pinned: nil)?.uid, nil, "всё заблокировано — оставить как есть")
eq(symbol(for: Device(id: 1, uid: "x", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth), .output), "airpods", "значок AirPods")
eq(symbol(for: Device(id: 1, uid: "x", name: "Mac", transport: kAudioDeviceTransportTypeBuiltIn), .input), "laptopcomputer", "значок Mac")

// MARK: - Порядок строк

func item(_ id: String, _ playing: Bool, bundle: String = "b") -> MediaItem {
    MediaItem(id: id, source: .player(bundle: bundle), appBundle: bundle, appName: "", title: id, subtitle: "", playing: playing)
}
var order = StableOrder()
eq(order.sort([item("1", false), item("2", true), item("3", false)]).map(\.id), ["1", "2", "3"], "порядок — как пришли")
eq(order.sort([item("3", true), item("1", true), item("2", false)]).map(\.id), ["1", "2", "3"], "play/pause не двигает строки")
eq(order.sort([item("4", true), item("2", false), item("1", false)]).map(\.id), ["1", "2", "4"], "новая строка — в конец, пропавшая — убрана")
eq(order.sort([item("3", false), item("1", false)]).map(\.id), ["1", "3"], "вернувшаяся строка — на своё место")

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
let full = Media.parsePlayer(["playing", "Wasted", "NXT", "https://i.scdn.co/image/ab", "42,5", "180000", "65"].joined(separator: F),
                             bundle: Media.spotify, name: "Spotify")
eq(full?.artworkURL, "https://i.scdn.co/image/ab", "обложка Spotify")
eq(full?.position, 42.5, "позиция с запятой (русская macOS)")
eq(full?.duration, 180, "длина Spotify в миллисекундах → секунды")
eq(full?.volume, 0.65, "громкость плеера 0–100 → 0–1")
let music = Media.parsePlayer(["paused", "Song", "A", "", "10.0", "200.5", "100"].joined(separator: F), bundle: "com.apple.Music", name: "Музыка")
eq(music?.duration, 200.5, "длина Музыки — уже секунды")
eq(music?.artworkURL, nil, "без обложки")

// MARK: - Разбор вкладок

let chrome = Browser(bundle: "com.google.Chrome", name: "Chrome")
let safari = Browser(bundle: Media.safari, name: "Safari")
/// Строка ответа вкладки: окно ␟ вкладка ␟ играет ␟ сайт ␟ значок ␟ обложка ␟ позиция ␟ длина ␟ громкость ␟ название.
func tab(_ w: String, _ t: String, _ on: String, _ host: String, _ icon: String = "", _ art: String = "",
         _ pos: String = "0.0", _ dur: String = "0.0", _ vol: String = "1.00", ext: String = "0", sink: String = "", title: String) -> String {
    [w, t, on, host, icon, art, pos, dur, vol, ext, sink, title].joined(separator: F)
}
let tabsOut = [
    tab("11", "101", "1", "youtube.com", "https://y/icon.png", "https://i.ytimg.com/vi/x/hq.jpg", "75.5", "300.0", "0.40", ext: "1", sink: "JBL Flip 6", title: "Видео — Автор"),
    tab("11", "102", "0", "facebook.com", title: ""),
    tab("12", "7", "1", "site.ee", "https://s/i.png", title: "A\(F)B"),      // разделитель внутри названия
    "мусор",
    tab("x", "1", "1", "h", title: "t"),                                     // окно не число
    "11\(F)103\(F)1\(F)old\(F)i\(F)Старый формат",                          // мало полей — пропустить
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
eq(tabs.items[0].artworkURL, "https://i.ytimg.com/vi/x/hq.jpg", "превью видео")
eq(tabs.items[0].position, 75.5, "позиция видео")
eq(tabs.items[0].duration, 300, "длина видео")
eq(tabs.items[0].volume, 0.4, "громкость вкладки")
check(tabs.items[0].hasExtension, "во вкладке есть «Lark для Chrome»")
eq(tabs.items[0].sinkName, "JBL Flip 6", "звук вкладки выведен в колонку")
check(!tabs.items[1].hasExtension && tabs.items[1].sinkName == nil, "без расширения — без устройства")
check(tabs.items[0].canSeek, "видео можно перематывать")
eq(tabs.items[1].duration, nil, "длина 0 (эфир) — без полоски")
check(!tabs.items[1].canSeek, "эфир не перематывается")
let t0 = Date(timeIntervalSince1970: 1000)
let live = Media.parseTabs(tab("1", "1", "1", "a.ee", "", "", "10.0", "20.0", "1.00", title: "T"), chrome, at: t0).items[0]
eq(live.livePosition(at: t0.addingTimeInterval(4)), 14, "между опросами время идёт само")
eq(live.livePosition(at: t0.addingTimeInterval(60)), 20, "но не дальше конца")
let st = Media.parseTabs(tab("3", "2", "1", "ex.com", title: "T") + "\n!1\(F)", safari)
eq(st.items.first?.source, .safariTab(window: 3, index: 2), "вкладка Safari по номеру")
let local = Media.parseTabs(tab("1", "2", "1", "", title: "Файл"), chrome).items.first
eq(local?.subtitle, "Chrome", "страница без сайта (файл) — без лишней точки")
eq(Media.parseTabs("!0\(F)Executing JavaScript through AppleScript is turned off.", chrome).jsOff, true, "JS выключен в Chrome")
eq(Media.parseTabs("!0\(F)Вы должны включить «Разрешить JavaScript из Apple Events»", safari).jsOff, true, "JS выключен в Safari (по-русски)")
eq(Media.parseTabs("!4\(F)JavaScript error in one tab", chrome).jsOff, false, "часть вкладок ответила — подсказка не нужна")
eq(Media.parseTabs("!0\(F)", chrome).jsOff, false, "нет вкладок — подсказка не нужна")
eq(Media.parseTabs("!16\(F)", chrome).answered, 16, "сколько вкладок ответило")
eq(Media.parseTabs("!0\(F)Executing JavaScript through AppleScript is turned off.", chrome).answered, 0, "JS выключен — ни одна не ответила")
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
si = soundItems(apps, detailed: [], covered: ["com.google.Chrome"], muted: [], me: "local.lark")
eq(si.map(\.appBundle), ["org.telegram"], "вкладки Chrome видны — общей строки «Google Chrome» нет (после паузы поток ещё открыт)")
si = soundItems(apps, detailed: [], covered: ["com.google.Chrome"], muted: ["com.google.Chrome"], me: "local.lark")
check(si.contains { $0.appBundle == "com.google.Chrome" }, "но если звук Chrome выключен в Lark — строка есть, чтобы вернуть")
si = soundItems(apps, detailed: [], muted: ["net.whatsapp", "com.gone"], me: "local.lark")
eq(si.map(\.appBundle), ["org.telegram", "com.google.Chrome", "net.whatsapp", "com.gone"], "выключенные видны всегда")
check(si[2].muted && !si[2].playing && si[2].subtitle.contains("выключен"), "выключенная программа помечена")
check(soundItems([], detailed: [], muted: [], me: "x").isEmpty, "тишина — пусто")
si = soundItems(apps, detailed: [], muted: [], gains: ["net.whatsapp": 0.3, "org.telegram": 1], me: "local.lark")
eq(si.map(\.appBundle), ["org.telegram", "com.google.Chrome", "net.whatsapp"], "приглушённая молчащая программа видна, чтобы вернуть громкость")
eq(si.last?.volume, 0.3, "своя громкость программы")
eq(si.first?.volume, 1, "по умолчанию 100%")

// MARK: - Наборы, версии, время

let outs = [Device(id: 1, uid: "air", name: "AirPods", transport: 0), Device(id: 2, uid: "jbl", name: "JBL", transport: 0)]
let ins = [Device(id: 3, uid: "mac", name: "Mac", transport: 0)]
let call = Preset(id: "1", name: "Звонок", output: "air", input: "mac", outputName: "AirPods", inputName: "Mac")
let music2 = Preset(id: "2", name: "Музыка", output: "jbl", input: nil, outputName: "JBL", inputName: nil)
check(Presets.isActive(call, outUID: "air", inUID: "mac"), "набор включён")
check(!Presets.isActive(call, outUID: "jbl", inUID: "mac"), "другой выход — не включён")
check(Presets.isActive(music2, outUID: "jbl", inUID: "anything"), "набор только для выхода")
check(!Presets.isActive(Preset(id: "3", name: "", output: nil, input: nil), outUID: "a", inUID: "b"), "пустой набор не бывает включён")
eq(Presets.missing(call, outputs: outs, inputs: ins), [], "всё подключено")
eq(Presets.missing(call, outputs: [outs[1]], inputs: []), ["AirPods", "Mac"], "чего не хватает — по именам")
eq(Presets.decode(Presets.encode([call, music2])), [call, music2], "наборы сохраняются и читаются")
eq(Presets.decode(Data("мусор".utf8)), [], "битые настройки — без наборов")
eq(Presets.defaultName([]), "Набор 1", "имя по умолчанию")
eq(Presets.defaultName([Preset(id: "x", name: "Набор 2")]), "Набор 3", "имя не повторяется")
eq(Presets.hotkeyLabel(0), "⌃⌥1", "первый набор — ⌃⌥1")
eq(Presets.hotkeyLabel(9), nil, "десятому клавиши не хватило")

check(isNewer("2.10", than: "2.9"), "2.10 новее 2.9")
check(!isNewer("2.1", than: "2.1"), "та же версия")
check(!isNewer("2.0.9", than: "2.1"), "старее")
check(isNewer("3", than: "2.9.9"), "3 новее 2.9.9")
check(!isNewer("", than: "1"), "пустой ответ — не обновление")
check(isNewer("2.2\n", than: "2.1"), "перевод строки в файле VERSION")
eq(clock(75), "1:15", "минуты")
eq(clock(3725), "1:02:05", "часы")
eq(clock(-3), "0:00", "отрицательное — ноль")
eq(clock(.infinity), "0:00", "бесконечность — ноль")
eq(number("12,5"), 12.5, "запятая")
eq(number("missing value"), nil, "не число")

// MARK: - Куда выводить

let outs2 = [Device(id: 1, uid: "air", name: "AirPods", transport: 0), Device(id: 2, uid: "jbl", name: "JBL", transport: 0)]
eq(Routes.target("jbl", outputs: outs2, defaultUID: "air"), "jbl", "своё устройство подключено — туда")
eq(Routes.target("air", outputs: outs2, defaultUID: "air"), nil, "своё устройство и так текущее — перехват не нужен")
eq(Routes.target("gone", outputs: outs2, defaultUID: "air"), nil, "устройство отключено — как у всех")
eq(Routes.target(nil, outputs: outs2, defaultUID: "air"), nil, "без выбора — как у всех")
check(!Routes.needsTap(muted: false, gain: 1, target: nil), "ничего не меняли — без перехвата")
check(Routes.needsTap(muted: false, gain: 1, target: "jbl"), "свой выход — перехват")
check(Routes.needsTap(muted: false, gain: 0.5, target: nil), "громкость — перехват")
check(Routes.needsTap(muted: true, gain: 1, target: nil), "без звука — перехват")
eq(Routes.decode(["com.spotify.client": "air"]), ["com.spotify.client": "air"], "маршруты читаются из настроек")
eq(Routes.decode(nil), [:], "нет настроек — пусто")

// MARK: - Языки

Lang.current = .en
eq(Media.players[1].name, "Music", "Музыка по-английски")
check(Media.jsHint(chrome).text.contains("View → Developer"), "подсказка по-английски")
eq(soundItems([apps[0]], detailed: [], muted: [], me: "x").first?.subtitle, "Playing sound", "подпись по-английски")
Lang.current = .et
eq(soundItems([apps[0]], detailed: [], muted: ["org.telegram"], me: "x").first?.subtitle, "Larkis vaigistatud", "подпись по-эстонски")
eq(Presets.defaultName([]), "Komplekt 1", "имя набора по-эстонски")
Lang.current = .ru

eq(outerAppPath("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
   "/Applications/Google Chrome.app", "помощник Chrome → Chrome")
eq(outerAppPath("/Applications/Telegram.app/Contents/MacOS/Telegram"), "/Applications/Telegram.app", "Telegram")
eq(outerAppPath("/usr/sbin/coreaudiod"), nil, "служба без .app")

// MARK: - Скрипты

check(!Media.tabSinkJS("Динамики MacBook Air").contains("\"") && !Media.tabSinkJS("It's \"odd\" \\").contains("\\"), "просьба вкладке без кавычек и слэшей")
check(Media.tabSinkJS("HK GO + PLAY").contains("HK%20GO%20%2B%20PLAY"), "название устройства в процентной записи")
let actions: [MediaAction] = [.play, .pause, .seek(42.5), .skip(-10), .skip(10), .next, .previous, .volume(0.37), .volume(2)]
for js in [Media.probeJS, Media.pauseJS, Media.playJS] + actions.map(Media.tabJS) {
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
    for a in actions { compiles(Media.actionScript(it, a), "\(p.name) \(a)") }
    compiles(Media.revealScript(it), "\(p.name) открыть")
}
for b in Media.browsers where installed(b.bundle) {
    checkedApps.append(b.name)
    compiles(Media.probeScript(b), "вкладки \(b.name)")
    let src: MediaItem.Source = b.isSafari ? .safariTab(window: 1, index: 2) : .chromeTab(bundle: b.bundle, window: 1, tab: 2)
    let it = MediaItem(id: "x", source: src, appBundle: b.bundle, appName: b.name, title: "", subtitle: "", playing: true)
    for a in actions where !Media.actionScript(it, a).isEmpty { compiles(Media.actionScript(it, a), "\(b.name) \(a)") }
    eq(Media.actionScript(it, .next), "", "у вкладки нет «следующего трека»")
    compiles(Media.revealScript(it), "\(b.name) открыть вкладку")
}
eq(Media.setPlayingScript(MediaItem(id: "s", source: .sound(bundle: "t"), appBundle: "t", appName: "", title: "", subtitle: "",
                                    playing: true), false), "", "звук программ — не скриптом")
check(Media.actionScript(item("p", true, bundle: Media.spotify), .volume(2)).hasSuffix("to 100"), "громкость не больше 100")
check(Media.actionScript(item("p", true, bundle: Media.spotify), .seek(-5)).hasSuffix("to 0.00"), "перемотка не раньше начала")
check(Media.playerScript(Media.spotify).contains("artwork url"), "обложку спрашиваем только у Spotify")
check(!Media.playerScript("com.apple.Music").contains("artwork url"), "у Музыки такого свойства нет")
check(Media.playerScript(Media.spotify).hasPrefix("if application id \"com.spotify.client\" is not running then return"),
      "опрос не запускает закрытый плеер")
check(Media.probeScript(Media.browsers[0]).hasPrefix("if application id \"com.google.Chrome\" is not running then return"),
      "опрос не запускает закрытый браузер")

// MARK: - Метка «куда выведена вкладка»: ключ вместо названия (такой же расчёт в chrome-extension/content.js)
eq(sinkKey("AirPods Pro (Roman)"), "#f9f63474", "ключ устройства совпадает с расширением")
eq(sinkKey("Динамики MacBook Air"), "#9ebc6d38", "ключ для кириллицы совпадает с расширением")
eq(sinkKey("JBL Flip 6"), "#1be2478", "ключ без ведущих нулей, как toString(16)")
eq(resolveSink("#1be2478", ["AirPods Pro", "JBL Flip 6"]), "JBL Flip 6", "ключ → подключённое устройство")
eq(resolveSink("#1be2478", ["AirPods Pro"]), nil, "устройство отключено — подписи нет")
eq(resolveSink("JBL Flip 6", ["AirPods Pro"]), "JBL Flip 6", "старое расширение пишет название — показываем как есть")

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
    <script>navigator.mediaSession.metadata = new MediaMetadata({title: 'Песня', artist: 'Певец',
      artwork: [{src: '/cover-96.jpg', sizes: '96x96'}, {src: '/cover-512.jpg', sizes: '512x512'}]});</script></body></html>
    """)
    // В тестовом окне звук «играет», но время не идёт (вывода звука нет) — перематываем вручную, как будто послушали 5 секунд
    w.wait(5) { w.js("var a=document.getElementById('a');a.play();a.currentTime=5;a.paused?'':'y'") == "y" }
    var r = w.js(Media.probeJS).components(separatedBy: F)
    eq(r.count, 10, "ответ вкладки из 10 частей (\(r))")
    if r.count == 10 {
        eq(r[0], "1", "звук играет")
        eq(r[1], "example.com", "сайт без www")
        eq(r[2], "https://www.example.com/apple.png", "выбран самый крупный значок (apple-touch-icon 180 > 96)")
        eq(r[3], "https://www.example.com/cover-512.jpg", "обложка — самая крупная из mediaSession")
        eq(r[4], "5.0", "позиция")
        eq(r[5], "30.0", "длина")
        eq(r[6], "1.00", "громкость")
        eq(r[7], "0", "расширения нет")
        eq(r[8], "", "устройства нет")
        eq(r[9], "Песня — Певец", "название из mediaSession")
    }
    @MainActor func t(_ id: String) -> Double { Double(w.js("String(document.getElementById('\(id)').currentTime)")) ?? -1 }
    _ = w.js(Media.tabJS(.seek(12)))
    check(abs(t("a") - 12) < 0.5, "перемотка во вкладке (\(t("a")))")
    _ = w.js(Media.tabJS(.skip(10)))
    check(abs(t("a") - 22) < 0.5, "+10 секунд (\(t("a")))")
    _ = w.js(Media.tabJS(.skip(-30)))
    check(t("a") < 0.5, "−30 не раньше начала (\(t("a")))")
    _ = w.js(Media.tabJS(.volume(0.25)))
    eq(w.js(Media.probeJS).components(separatedBy: F).dropFirst(6).first, "0.25", "громкость вкладки")
    _ = w.js(Media.tabJS(.volume(1)))
    _ = w.js("document.documentElement.setAttribute('data-lark-ext','1');document.documentElement.setAttribute('data-lark-sink','AirPods Pro');''")
    r = w.js(Media.probeJS).components(separatedBy: F)
    eq(r.count == 10 ? r[7] + "|" + r[8] : "", "1|AirPods Pro", "метки расширения читаются со страницы")
    _ = w.js("document.getElementById('a').currentTime=5;''")
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
    eq(r.count == 10 ? r[2] : "", "https://www.example.com/favicon.ico", "запасной значок /favicon.ico")
    eq(r.count == 10 ? r[3] : "x", "", "без mediaSession и og:image — без обложки")
    eq(r.count == 10 ? r[9] : "", "Видео", "название — заголовок страницы")

    // Страница видео с og:image (как YouTube без mediaSession) — превью; og:image у статьи — не превью
    w.load("""
    <html><head><title>Ролик</title><meta property="og:type" content="video.other"><meta property="og:image" content="/thumb.jpg"></head>
    <body><video id="v" src="\(wav)"></video></body></html>
    """)
    w.wait(5) { w.js("var v=document.getElementById('v');v.currentTime=5;v.paused&&v.currentTime>1?'y':''") == "y" }
    r = w.js(Media.probeJS).components(separatedBy: F)
    eq(r.count == 10 ? r[3] : "", "https://www.example.com/thumb.jpg", "превью видео из og:image")
    w.load("""
    <html><head><title>Статья</title><meta property="og:type" content="article"><meta property="og:image" content="/logo.jpg"></head>
    <body><video id="v" src="\(wav)"></video></body></html>
    """)
    w.wait(5) { w.js("var v=document.getElementById('v');v.currentTime=5;v.paused&&v.currentTime>1?'y':''") == "y" }
    r = w.js(Media.probeJS).components(separatedBy: F)
    eq(r.count == 10 ? r[3] : "x", "", "картинка статьи — не превью")

    // Два ролика: главный — играющий, а не самый длинный на паузе
    w.load("""
    <html><body><video id="long" src="\(wav)"></video><audio id="short" src="\(silentWav(seconds: 10))" autoplay></audio></body></html>
    """)
    w.wait(5) { w.js("var s=document.getElementById('short');s.play();s.paused?'':'y'") == "y" }
    _ = w.js(Media.tabJS(.volume(0.5)))
    eq(w.js("String(document.getElementById('long').volume)"), "0.5", "громкость — всем роликам вкладки")
    _ = w.js(Media.tabJS(.seek(3)))
    check(abs(t("short") - 3) < 0.5, "перемотка — играющему ролику (\(t("short")))")

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
