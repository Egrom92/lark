// Громкость и выход отдельной программы (Zoom, Teams, Telegram, Spotify, плеер): Core Audio tap с muteBehavior = .muted
// забирает её звук, а Lark выводит его в выбранное устройство (по умолчанию — в текущий выход), умножив на громкость строки.
// Громкость 0 — тишина («выключить звук»).
// Нужен доступ «Запись системного звука» (macOS 14.2+). Звук никуда не записывается. Закрыли Lark — звук как был.
import CoreAudio
import AudioToolbox
import Foundation

final class AppVolume {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    /// Громкость читает аудиопоток, пишет главный поток: одно число Float, гонка безвредна.
    private let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let objs: [AudioObjectID]
    let outputUID: String

    var gain: Float {
        get { gainPtr.pointee }
        set { gainPtr.pointee = max(0, min(1, newValue)) }
    }

    /// deviceUID — куда выводить; nil — в текущий выход системы.
    init?(objs: [AudioObjectID], gain: Float, deviceUID: String? = nil) {
        self.objs = objs
        gainPtr.initialize(to: max(0, min(1, gain)))
        guard let clock = deviceUID ?? Audio.string(Audio.defaultDevice(.output), kAudioDevicePropertyDeviceUID) else { return nil }
        outputUID = clock

        let desc = CATapDescription(stereoMixdownOfProcesses: objs)
        desc.uuid = UUID()
        desc.name = "Lark volume"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != kAudioObjectUnknown else { return nil }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lark volume",
            kAudioAggregateDeviceUIDKey: "Lark-volume-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clock,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clock]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { stop(); return nil }
        let g = gainPtr
        let st = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) { _, inData, _, outData, _ in
            AppVolume.render(inData, outData, gain: g.pointee)
        }
        guard st == noErr, AudioDeviceStart(aggID, ioProc) == noErr else { stop(); return nil }
    }

    /// Звук tap (последний входной поток агрегата: перед ним — входы самого устройства, если есть) → выход, умноженный на gain.
    /// Выход может быть с чередованием каналов (один буфер) или без (буфер на канал) — каналы раскладываются по порядку.
    private static func render(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        for o in outs { if let d = o.mData { memset(d, 0, Int(o.mDataByteSize)) } }
        guard gain > 0, let tapBuf = ins.last, let tapData = tapBuf.mData else { return }
        let tapCh = max(Int(tapBuf.mNumberChannels), 1)
        let tap = tapData.assumingMemoryBound(to: Float.self)
        let tapFrames = Int(tapBuf.mDataByteSize) / 4 / tapCh
        var channelBase = 0
        for o in outs {
            guard let od = o.mData else { continue }
            let out = od.assumingMemoryBound(to: Float.self)
            let outCh = max(Int(o.mNumberChannels), 1)
            let frames = min(tapFrames, Int(o.mDataByteSize) / 4 / outCh)
            for fr in 0..<frames {
                for c in 0..<outCh {
                    out[fr * outCh + c] = tap[fr * tapCh + min(channelBase + c, tapCh - 1)] * gain
                }
            }
            channelBase += outCh
        }
    }

    func stop() {
        if let ioProc { AudioDeviceStop(aggID, ioProc); AudioDeviceDestroyIOProcID(aggID, ioProc) }
        ioProc = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    deinit { stop(); gainPtr.deallocate() }
}
