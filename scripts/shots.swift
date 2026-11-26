// Снимки панели для README и сайта (с придуманными устройствами и треками). Собирается make-docs.sh
// вместе с Sources/*.swift вместо запуска приложения. Пишет PNG панели в папку из аргумента.
import AppKit
import SwiftUI

@MainActor
func snapshot(_ view: some View, _ path: String) {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark)
        .background(Color(red: 0.165, green: 0.165, blue: 0.185)))
    host.appearance = NSAppearance(named: .darkAqua)
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                       styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = host
    win.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))   // на Retina — 2×
    win.orderOut(nil)
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let dir = CommandLine.arguments[1]

    Lang.current = Lang(rawValue: ProcessInfo.processInfo.environment["LARK_LANG"] ?? "ru") ?? .ru
    let audio = AudioModel()
    audio.outputs = [
        Device(id: 11, uid: "o1", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
        Device(id: 12, uid: "o2", name: "JBL Flip 6", transport: kAudioDeviceTransportTypeBluetooth),
        Device(id: 13, uid: "o3", name: "Динамики MacBook Air", transport: kAudioDeviceTransportTypeBuiltIn),
    ]
    audio.inputs = [
        Device(id: 21, uid: "i1", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
        Device(id: 22, uid: "i2", name: "Микрофон MacBook Air", transport: kAudioDeviceTransportTypeBuiltIn),
        Device(id: 23, uid: "i3", name: "Микрофон (iPhone)", transport: kAudioDeviceTransportTypeContinuityCaptureWireless),
    ]
    audio.curOut = 12; audio.curIn = 22
    audio.outVol = 0.55; audio.inVol = 0.7
    audio.keepOut = false; audio.keepIn = true
    audio.hidden = []

    let yt = "https://www.youtube.com/s/desktop/c52980d1/img/favicon_144x144.png"
    let fb = "https://www.facebook.com/favicon.ico"
    // Обложки рисуем сами (градиент и значок), чтобы не показывать чужие обложки и превью
    let cover = "https://example.invalid/cover-song", thumb = "https://example.invalid/cover-video"
    @MainActor func art(_ a: NSColor, _ b: NSColor, _ symbol: String) -> NSImage {
        NSImage(size: NSSize(width: 160, height: 160), flipped: false) { r in
            NSGradient(starting: a, ending: b)!.draw(in: NSBezierPath(rect: r), angle: -60)
            let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .semibold).applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.92)]))
            if let s = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                s.draw(in: NSRect(x: (160 - s.size.width) / 2, y: (160 - s.size.height) / 2, width: s.size.width, height: s.size.height))
            }
            return true
        }
    }
    UserDefaults.standard.set(Presets.encode([
        Preset(id: "p1", name: "Звонок", output: "o1", input: "i2", outputName: "AirPods Pro", inputName: "Микрофон MacBook Air"),
        Preset(id: "p2", name: "Музыка", output: "o2", input: "i2", outputName: "JBL Flip 6", inputName: "Микрофон MacBook Air"),
    ]), forKey: Presets.key)
    audio.presets = Presets.decode(UserDefaults.standard.data(forKey: Presets.key))
    for u in [yt, fb] { _ = Images.shared.image(u) }
    let end = Date().addingTimeInterval(6)
    while Date() < end && (Images.shared.image(yt) == nil || Images.shared.image(fb) == nil) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    Images.shared.preload(cover, art(NSColor(srgbRed: 0.98, green: 0.62, blue: 0.34, alpha: 1), NSColor(srgbRed: 0.75, green: 0.30, blue: 0.55, alpha: 1), "music.note"))
    Images.shared.preload(thumb, art(NSColor(srgbRed: 0.45, green: 0.30, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.85, green: 0.62, blue: 0.40, alpha: 1), "cup.and.saucer.fill"))

    @MainActor func media(_ items: [MediaItem]) -> MediaModel { let m = MediaModel(); m.loaded = true; m.items = items; return m }
    var spotify = MediaItem(id: "s", source: .player(bundle: "com.spotify.client"), appBundle: "com.spotify.client", appName: "Spotify",
                            title: "Утренняя песня", subtitle: "Жаворонки · Spotify", playing: true)
    spotify.artworkURL = cover; spotify.position = 74; spotify.duration = 213; spotify.volume = 0.8
    var tabYT = MediaItem(id: "y", source: .chromeTab(bundle: "com.google.Chrome", window: 1, tab: 1), appBundle: "com.google.Chrome",
                          appName: "Chrome", title: "Как сварить идеальный кофе дома", subtitle: "youtube.com · Chrome", playing: true, iconURL: yt)
    tabYT.artworkURL = thumb; tabYT.position = 312; tabYT.duration = 1046; tabYT.volume = 1
    var tabFB = MediaItem(id: "f", source: .chromeTab(bundle: "com.google.Chrome", window: 1, tab: 2), appBundle: "com.google.Chrome",
                          appName: "Chrome", title: "Видео · Facebook", subtitle: "facebook.com · Chrome", playing: false, iconURL: fb)
    tabFB.position = 41; tabFB.duration = 95; tabFB.volume = 1
    let zoom = MediaItem(id: "z", source: .sound(bundle: "us.zoom.xos"), appBundle: "us.zoom.xos", appName: "Zoom",
                         title: "Zoom", subtitle: "Играет звук", playing: true, volume: 0.3)
    let tg = MediaItem(id: "t", source: .sound(bundle: "com.tdesktop.Telegram"), appBundle: "com.tdesktop.Telegram", appName: "Telegram",
                       title: "Telegram", subtitle: "Играет звук", playing: true, volume: 1)
    let tgMuted = MediaItem(id: "t", source: .sound(bundle: "com.tdesktop.Telegram"), appBundle: "com.tdesktop.Telegram", appName: "Telegram",
                            title: "Telegram", subtitle: "Звук выключен в Lark", playing: false, muted: true, volume: 1)
    var spotifyPaused = spotify; spotifyPaused.playing = false

    snapshot(PanelView(audio: audio, media: media([spotify, tabYT, tg, tabFB])), "\(dir)/panel-playing.png")
    snapshot(PanelView(audio: audio, media: media([tabYT, zoom, spotifyPaused, tgMuted])), "\(dir)/panel-solo.png")
    MediaRow.showControls = true
    snapshot(PanelView(audio: audio, media: media([spotify, tabYT, zoom])), "\(dir)/panel-controls.png")
    MediaRow.showControls = false
    audio.outputs.removeFirst(); audio.inputs.removeFirst()      // AirPods отключены, Lark ждёт их
    UserDefaults.standard.set("i1", forKey: Dir.input.pinKey)
    UserDefaults.standard.set("AirPods Pro", forKey: Dir.input.pinKey + ".name")
    snapshot(PanelView(audio: audio, media: media([spotify])), "\(dir)/panel-keep.png")
    print("ok")
}
