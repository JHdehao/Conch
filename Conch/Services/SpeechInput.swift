import AVFoundation
import Foundation
import Speech

/// Dictation into a text field with Apple's speech recognizer: live partial
/// results, automatic punctuation, on-device when the language supports it.
@MainActor
@Observable
final class SpeechInput {
    private(set) var isRecording = false
    private(set) var error: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var stopTimer: Task<Void, Never>?

    /// Starts dictation, or stops it if already running. `text` is what's in the
    /// field now; dictated words are appended to it and handed to `update` as they arrive.
    func toggle(appendingTo text: String, update: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else {
            Task { await start(appendingTo: text, update: update) }
        }
    }

    func stop() {
        stopTimer?.cancel()
        stopTimer = nil
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func start(appendingTo base: String, update: @escaping (String) -> Void) async {
        error = nil
        guard await Self.requestPermissions() else {
            error = String(localized: "需要麦克风和语音识别权限。请在系统设置里允许 Conch。")
            return
        }
        let locale = SpeechLanguage.locale
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            #if os(iOS)
            error = String(localized: "\(SpeechLanguage.displayName(locale.identifier)) 暂时无法识别，可能需要联网。长按麦克风可以换一种识别语言。")
            #else
            error = String(localized: "\(SpeechLanguage.displayName(locale.identifier)) 暂时无法识别，可能需要联网。右键点按麦克风可以换一种识别语言。")
            #endif
            return
        }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            // Keep audio on the device when the language model is available locally.
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true

            let prefix = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? base : base + " "
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        update(prefix + result.bestTranscription.formattedString)
                        if result.isFinal { self.stop() }
                    }
                    if error != nil, self.isRecording { self.stop() }
                }
            }
            // Apple limits a recognition request to about a minute.
            stopTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(58))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            stop()
            self.error = String(localized: "无法开始录音：\(error.localizedDescription)")
        }
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}

import SwiftUI

/// A microphone button that dictates into `text`.
struct DictationButton: View {
    @Binding var text: String
    var size: CGFloat = 18
    /// Start listening as soon as the button appears.
    var startsImmediately = false
    @State private var speech = SpeechInput()
    @AppStorage(SpeechLanguage.key) private var language = ""
    @State private var choosingLanguage = false

    var body: some View {
        Button {
            speech.toggle(appendingTo: text) { text = $0 }
        } label: {
            Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                .font(.system(size: size))
                .foregroundStyle(speech.isRecording ? Color.red : Color.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: speech.isRecording)
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(speech.isRecording ? String(localized: "停止语音输入") : String(localized: "语音输入：\(SpeechLanguage.displayName(SpeechLanguage.locale.identifier))"))
        .accessibilityLabel(speech.isRecording ? String(localized: "停止语音输入") : String(localized: "语音输入"))
        .popover(isPresented: Binding(get: { speech.error != nil }, set: { if !$0 { speech.clearError() } })) {
            Text(speech.error ?? "")
                .font(.callout)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
        .contextMenu {
            // Quick switch for people who dictate in more than one language.
            Picker("识别语言", selection: $language) {
                Text("跟随界面语言").tag("")
                ForEach(SpeechLanguage.suggested, id: \.self) { Text(SpeechLanguage.displayName($0)).tag($0) }
            }
            .pickerStyle(.inline)
            Button("更多语言…", systemImage: "globe") { choosingLanguage = true }
        }
        .sheet(isPresented: $choosingLanguage) {
            NavigationStack {
                SpeechLanguageList(selection: $language)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { choosingLanguage = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(width: 380, height: 520)
            #endif
        }
        .onChange(of: language) {
            speech.stop()
            SpeechLanguage.remember(language)
        }
        .onAppear {
            if startsImmediately { speech.toggle(appendingTo: text) { text = $0 } }
        }
        .onDisappear { speech.stop() }
    }
}

extension SpeechInput {
    func clearError() { error = nil }
}
