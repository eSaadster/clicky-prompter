//
//  SmallestAITranscriptionProvider.swift
//  leanring-buddy
//
//  Upload-based speech-to-text provider using Smallest AI's Pulse API.
//  Buffers microphone audio during push-to-talk, then uploads the WAV
//  on release and returns the transcript. Conforms to the same
//  BuddyTranscriptionProvider / BuddyStreamingTranscriptionSession
//  protocols used by all other providers.
//

import AVFoundation
import Foundation

struct SmallestAITranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class SmallestAITranscriptionProvider: BuddyTranscriptionProvider {
    private let apiKey: String

    let displayName = "Smallest AI"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Smallest AI transcription is not configured. Add your API key to ~/Library/Application Support/Clicky/config.json."
    }

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw SmallestAITranscriptionProviderError(
                message: unavailableExplanation ?? "Smallest AI transcription is not configured."
            )
        }

        return SmallestAITranscriptionSession(
            apiKey: apiKey,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

// MARK: - Session

private final class SmallestAITranscriptionSession: BuddyStreamingTranscriptionSession {
    /// Upload-based transcription takes longer than streaming — allow more
    /// time before BuddyDictationManager fires the fallback.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 10.0

    private static let targetSampleRate = 16_000

    private let apiKey: String
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.clicky.smallestai.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        apiKey: String,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.timeoutIntervalForRequest = 45
        urlSessionConfiguration.timeoutIntervalForResource = 90
        urlSessionConfiguration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.sync {
            isCancelled = true
            bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    // MARK: - Private

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let audioDataIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if audioDataIsEmpty {
            deliverFinalTranscript("")
            return
        }

        // Build WAV from buffered PCM16 data
        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await requestTranscription(for: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Smallest AI Transcription] Upload failed (audio size: \(wavAudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    /// Uploads WAV audio to Smallest AI Pulse and returns the transcript text.
    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        guard var urlComponents = URLComponents(string: "https://api.smallest.ai/waves/v1/pulse/get_text") else {
            throw SmallestAITranscriptionProviderError(message: "Invalid Smallest AI STT endpoint URL.")
        }
        urlComponents.queryItems = [URLQueryItem(name: "language", value: "en")]

        guard let endpointURL = urlComponents.url else {
            throw SmallestAITranscriptionProviderError(message: "Failed to build Smallest AI STT URL.")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavAudioData

        let audioSizeKB = wavAudioData.count / 1024
        print("[Smallest AI Transcription] Uploading \(audioSizeKB)KB WAV audio")

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SmallestAITranscriptionProviderError(
                message: "Smallest AI transcription returned an invalid response."
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw SmallestAITranscriptionProviderError(
                message: "Smallest AI transcription failed (\(httpResponse.statusCode)): \(responseText)"
            )
        }

        // Pulse returns { "transcription": "..." }
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let transcription = json["transcription"] as? String {
            let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTranscription.isEmpty {
                return trimmedTranscription
            }
        }

        // Fallback: try reading as plain text
        let responseText = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !responseText.isEmpty {
            return responseText
        }

        throw SmallestAITranscriptionProviderError(
            message: "Smallest AI transcription returned an empty transcript."
        )
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}
