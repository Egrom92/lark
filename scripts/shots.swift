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
    for u in [yt, fb] { _ = Favicons.shared.image(u) }
    let end = Date().addingTimeInterval(6)
    while Date() < end && (Favicons.shared.image(yt) == nil || Favicons.shared.image(fb) == nil) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    @MainActor func media(_ items: [MediaItem]) -> MediaModel { let m = MediaModel(); m.loaded = true; m.items = items; return m }
    let spotify = MediaItem(id: "s", source: .player(bundle: "com.spotify.client"), appBundle: "com.spotify.client", appName: "Spotify",
                            title: "Утренняя песня", subtitle: "Жаворонки · Spotify", playing: true)
    let tabYT = MediaItem(id: "y", source: .chromeTab(bundle: "com.google.Chrome", window: 1, tab: 1), appBundle: "com.google.Chrome",
                          appName: "Chrome", title: "Как сварить идеальный кофе дома", subtitle: "youtube.com · Chrome", playing: true, iconURL: yt)
    let tabFB = MediaItem(id: "f", source: .chromeTab(bundle: "com.google.Chrome", window: 1, tab: 2), appBundle: "com.google.Chrome",
                          appName: "Chrome", title: "Видео · Facebook", subtitle: "facebook.com · Chrome", playing: false, iconURL: fb)
    let tg = MediaItem(id: "t", source: .sound(bundle: "com.tdesktop.Telegram"), appBundle: "com.tdesktop.Telegram", appName: "Telegram",
                       title: "Telegram", subtitle: "Играет звук", playing: true)
    let tgMuted = MediaItem(id: "t", source: .sound(bundle: "com.tdesktop.Telegram"), appBundle: "com.tdesktop.Telegram", appName: "Telegram",
                            title: "Telegram", subtitle: "Звук выключен в Lark", playing: false, muted: true)
    let spotifyPaused = MediaItem(id: "s", source: spotify.source, appBundle: spotify.appBundle, appName: "Spotify",
                                  title: spotify.title, subtitle: spotify.subtitle, playing: false)

    snapshot(PanelView(audio: audio, media: media([spotify, tabYT, tg, tabFB])), "\(dir)/panel-playing.png")
    snapshot(PanelView(audio: audio, media: media([tabYT, spotifyPaused, tabFB, tgMuted])), "\(dir)/panel-solo.png")
    audio.outputs.removeFirst(); audio.inputs.removeFirst()      // AirPods отключены, Lark ждёт их
    UserDefaults.standard.set("i1", forKey: Dir.input.pinKey)
    UserDefaults.standard.set("AirPods Pro", forKey: Dir.input.pinKey + ".name")
    snapshot(PanelView(audio: audio, media: media([spotify])), "\(dir)/panel-keep.png")
    print("ok")
}
