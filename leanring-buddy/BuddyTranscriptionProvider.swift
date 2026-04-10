//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case smallestAI = "smallestai"
        case assemblyAI = "assemblyai"
        case openAI = "openai"
        case appleSpeech = "apple"
    }

    /// Creates the default transcription provider. When a Smallest AI API
    /// key is available in config.json, it takes highest priority. Falls
    /// back through AssemblyAI → OpenAI → Apple Speech.
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        // Read Smallest AI API key directly from config.json to avoid
        // creating a @MainActor ObservableObject in a factory context.
        let smallestAIApiKey = Self.readSmallestAIApiKeyFromConfigFile()
        let smallestAIProvider = SmallestAITranscriptionProvider(apiKey: smallestAIApiKey)
        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()

        // Smallest AI always takes top priority when its API key is configured,
        // regardless of the Info.plist VoiceTranscriptionProvider setting.
        if smallestAIProvider.isConfigured {
            return smallestAIProvider
        }

        // If explicitly configured via Info.plist, respect that choice
        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .assemblyAI {
            if assemblyAIProvider.isConfigured { return assemblyAIProvider }
            print("Warning: AssemblyAI preferred but not configured, falling back")
        }

        if preferredProvider == .openAI {
            if openAIProvider.isConfigured { return openAIProvider }
            print("Warning: OpenAI preferred but not configured, falling back")
        }

        // Fallback priority: AssemblyAI → OpenAI → Apple Speech
        if assemblyAIProvider.isConfigured {
            return assemblyAIProvider
        }

        if openAIProvider.isConfigured {
            return openAIProvider
        }

        return AppleSpeechTranscriptionProvider()
    }

    /// Reads the Smallest AI API key directly from the config file without
    /// creating a full ProviderConfigurationManager instance.
    private static func readSmallestAIApiKeyFromConfigFile() -> String {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let configFileURL = applicationSupportDirectory
            .appendingPathComponent("Clicky")
            .appendingPathComponent("config.json")

        guard let configData = try? Data(contentsOf: configFileURL),
              let config = try? JSONDecoder().decode(ProviderConfig.self, from: configData) else {
            return ""
        }

        return config.smallestAIApiKey
    }
}
