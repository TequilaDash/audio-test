//
//  AudioTestApp.swift
//  audio-test
//
//  音频通路测试 App：录音(输入) + 播放(输出) + 实时电平。
//  用途：在 zContainer 容器里验证访客进程能否拿到麦克风输入、能否把声音播出来。
//  设计要点：
//   · 录音用 AVAudioRecorder，采样 44.1kHz 单声道 PCM，写到 Documents。
//   · 播放用 AVAudioPlayer 播刚录的文件（也可播系统提示音）。
//   · 电平用 AVAudioRecorder 的 peakPowerForChannel:，每 0.1s 刷新一次。
//   · 麦克风授权走 requestRecordPermission，App 自身处理，不依赖任何外部桥。
//

import SwiftUI
import AVFoundation
import AudioToolbox

@main
struct AudioTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AudioTestModel()

    var body: some View {
        VStack(spacing: 18) {
            Text("audio-test")
                .font(.largeTitle.bold())

            // 授权状态
            Text(model.permissionText)
                .font(.footnote)
                .foregroundStyle(model.permissionGranted ? Color.green : Color.orange)
                .multilineTextAlignment(.center)

            if !model.permissionGranted {
                Button("申请麦克风权限") { model.requestPermission() }
                    .buttonStyle(.borderedProminent)
            }

            // 录音控制
            HStack(spacing: 24) {
                Button(model.isRecording ? "停止录音" : "开始录音") {
                    model.isRecording ? model.stopRecording() : model.startRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? Color.red : Color.accentColor)
                .disabled(!model.permissionGranted)

                Button("播放录音") { model.playRecording() }
                    .buttonStyle(.bordered)
                    .disabled(model.recordingURL == nil || model.isRecording)

                Button("播提示音") { model.playBeep() }
                    .buttonStyle(.bordered)
            }

            // 电平表
            VStack(spacing: 4) {
                Text(model.isRecording ? "输入电平" : "（录音中显示电平）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.25))
                        Capsule()
                            .fill(Color.green)
                            .frame(width: max(2, geo.size.width * model.level))
                    }
                }
                .frame(height: 14)

                Text(String(format: "peak %.4f", model.level))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // 诊断信息
            VStack(alignment: .leading, spacing: 4) {
                Text("会话: \(model.sessionSummary)")
                    .font(.system(.caption2, design: .monospaced))
                Text("输入: \(model.inputSummary)")
                    .font(.system(.caption2, design: .monospaced))
                Text("输出: \(model.outputSummary)")
                    .font(.system(.caption2, design: .monospaced))
                if let err = model.lastError {
                    Text("错误: \(err)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding()
        .onAppear { model.refresh() }
    }
}

final class AudioTestModel: ObservableObject {
    @Published var permissionGranted = false
    @Published var isRecording = false
    @Published var level: CGFloat = 0
    @Published var recordingURL: URL?
    @Published var lastError: String?
    @Published var sessionSummary = "-"
    @Published var inputSummary = "-"
    @Published var outputSummary = "-"

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?

    var permissionText: String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "麦克风权限: 已授权"
        case .denied: return "麦克风权限: 已拒绝（去设置里打开）"
        case .undetermined: return "麦克风权限: 未询问"
        @unknown default: return "麦克风权限: 未知"
        }
    }

    func requestPermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.permissionGranted = granted
                self?.refresh()
            }
        }
    }

    func refresh() {
        permissionGranted = AVAudioSession.sharedInstance().recordPermission == .granted
        let session = AVAudioSession.sharedInstance()
        sessionSummary = "cat=\(session.category.rawValue) mode=\(session.mode.rawValue) active=\(session.isOtherAudioPlaying ? "other" : "-")"
        inputSummary = session.currentRoute.inputs.map {
            "\($0.portType.rawValue)/\(String(describing: $0.portName))"
        }.joined(separator: ",")
        outputSummary = session.currentRoute.outputs.map {
            "\($0.portType.rawValue)/\(String(describing: $0.portName))"
        }.joined(separator: ",")
    }

    func startRecording() {
        lastError = nil
        let session = AVAudioSession.sharedInstance()
        do {
            // playAndRecord: 既能录也能播, 适合"边播边录"的通路测试.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
        } catch {
            lastError = "setActive 失败: \(error.localizedDescription)"
            refresh()
            return
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audiotest-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                lastError = "record() 返回 false"
                refresh()
                return
            }
            recorder = rec
            recordingURL = url
            isRecording = true
            startMetering()
            refresh()
        } catch {
            lastError = "录音失败: \(error.localizedDescription)"
            refresh()
        }
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        stopMetering()
        refresh()
    }

    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorder else { return }
            rec.updateMeters()
            let peak = rec.peakPower(forChannel: 0)
            // dBFS -> 0..1 线性刻度 (-60dB 底)
            let normalized = max(0.0, min(1.0, pow(10, Double(peak) / 20.0)))
            DispatchQueue.main.async { self.level = CGFloat(normalized) }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    func playRecording() {
        guard let url = recordingURL, FileManager.default.fileExists(atPath: url.path) else {
            lastError = "没有可播放的录音"
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
            lastError = nil
        } catch {
            lastError = "播放失败: \(error.localizedDescription)"
        }
        refresh()
    }

    func playBeep() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            // 系统提示音: 不需要资源文件, 任何环境都能出声, 用于验证输出通路.
            AudioServicesPlaySystemSound(1057)
            lastError = nil
        } catch {
            lastError = "播提示音失败: \(error.localizedDescription)"
        }
        refresh()
    }
}
