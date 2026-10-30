import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var client: TranscriptClient
    @State private var exportFolder = ExportSettings.folderURL
    @State private var userDisplayName = UserProfile.displayName
    @State private var selectedModel = ModelSettings.current
    @State private var saveMarkdown = ExportSettings.saveMarkdown
    @State private var encrypt = ExportSettings.encrypt
    @State private var openedTranscript: OpenedTranscript?
    /// 「相手1」などのラベルごとに入力中の名前
    @State private var speakerNames: [String: String] = [:]

    private var otherSpeakerLabels: [String] {
        TranscriptFormatter.otherSpeakerLabels(in: client.transcript)
    }

    init(appState: AppState) {
        self.appState = appState
        self.client = appState.client
    }

    private var displayedTranscript: String {
        let live = client.confirmedText + client.unconfirmedText
        if client.isRecording {
            return client.transcript.isEmpty ? live : client.transcript + "\n" + live
        }
        return client.transcript
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("MeetingScribe")
                .font(.title2).bold()

            Text(client.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let warning = client.warningText {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 420)
            }

            Button(action: {
                appState.toggleRecording()
            }) {
                Label(client.isRecording ? "停止する" : "録音を開始",
                      systemImage: client.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title3)
            }
            .disabled(client.isModelLoading || client.isDiarizing)
            .buttonStyle(.borderedProminent)
            .tint(client.isRecording ? .red : .accentColor)

            Picker("UI表示", selection: Binding(
                get: { appState.showOverlay },
                set: { appState.setOverlayVisible($0) }
            )) {
                Text("通常のみ").tag(false)
                Text("字幕オーバーレイも表示").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            if appState.showOverlay {
                HStack {
                    Text("字幕の濃さ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $client.overlayOpacity, in: 0.1...0.95)
                }
                .frame(maxWidth: 320)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayedTranscript.isEmpty ? "ここに文字起こし結果が表示されます。" : displayedTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                        .id("transcriptBottom")
                }
                .onChange(of: displayedTranscript) { _, _ in
                    withAnimation {
                        proxy.scrollTo("transcriptBottom", anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)

            HStack {
                Button("保存…") { saveTranscript(client.transcript) }
                    .disabled(client.transcript.isEmpty)
                Button("議事録を開く…") { openTranscript() }
                Spacer()
                Button("クリア") { client.transcript = "" }
                    .disabled(client.transcript.isEmpty)
            }

            if !client.isRecording && !otherSpeakerLabels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("相手の名前")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(otherSpeakerLabels, id: \.self) { label in
                        HStack {
                            Text(label)
                                .font(.caption)
                                .frame(width: 48, alignment: .leading)
                            TextField("名前", text: Binding(
                                get: { speakerNames[label] ?? "" },
                                set: { speakerNames[label] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                    Button("名前を反映") {
                        client.renameSpeakers(speakerNames)
                        speakerNames = [:]
                    }
                    .disabled(speakerNames.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
                .frame(maxWidth: 320)
            }

            HStack {
                Text("あなたの名前")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("自分", text: $userDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: userDisplayName) { _, newValue in
                        UserProfile.displayName = newValue
                    }
            }
            .frame(maxWidth: 320)

            Picker("文字起こしモデル", selection: $selectedModel) {
                ForEach(WhisperModelOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .font(.caption)
            .frame(maxWidth: 360)
            .disabled(client.isRecording || client.isDiarizing)
            .onChange(of: selectedModel) { _, newValue in
                ModelSettings.current = newValue
                client.reloadModel()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("議事録の自動保存先")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(exportFolder.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("変更…") { chooseExportFolder() }
                }
                Toggle("暗号化して保存 (.txt.enc)", isOn: $encrypt)
                    .font(.caption)
                    .onChange(of: encrypt) { _, newValue in
                        ExportSettings.encrypt = newValue
                    }
                Toggle("Markdown (.md) でも保存", isOn: $saveMarkdown)
                    .font(.caption)
                    .disabled(encrypt)
                    .onChange(of: saveMarkdown) { _, newValue in
                        ExportSettings.saveMarkdown = newValue
                    }
                if encrypt {
                    Text("暗号化した議事録は「議事録を開く…」で読み、そこから .md にも書き出せます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 480)
        .sheet(item: $openedTranscript) { transcript in
            TranscriptViewer(transcript: transcript)
        }
    }

    private func openTranscript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = exportFolder
        panel.prompt = "開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            openedTranscript = OpenedTranscript(url: url, text: try TranscriptFiles.read(url))
        } catch {
            client.statusText = "議事録を開けませんでした: \(error.localizedDescription)"
        }
    }

    private func saveTranscript(_ text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "議事録.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportFolder
        panel.prompt = "このフォルダに保存"
        if panel.runModal() == .OK, let url = panel.url {
            ExportSettings.folderURL = url
            exportFolder = url
        }
    }
}
