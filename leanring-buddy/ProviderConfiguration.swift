//
//  ProviderConfiguration.swift
//  leanring-buddy
//
//  Manages a user-editable JSON config file that stores API keys for
//  voice providers (TTS and STT). Lives alongside models.json in
//  ~/Library/Application Support/Clicky/config.json.
//

import Combine
import Foundation

/// User-editable configuration for voice providers (TTS + STT).
struct ProviderConfig: Codable, Equatable {
    /// Smallest AI API key for TTS (Lightning) and STT (Pulse).
    /// Get one at https://app.smallest.ai/dashboard
    var smallestAIApiKey: String

    /// Voice ID for Smallest AI TTS. Defaults to "emily" if empty.
    /// See available voices at https://docs.smallest.ai
    var ttsVoiceId: String
}

// MARK: - Manager

/// Loads and caches the provider config from ~/Library/Application Support/Clicky/config.json.
/// If the file doesn't exist, creates one with placeholder values.
@MainActor
final class ProviderConfigurationManager: ObservableObject {
    @Published private(set) var providerConfig: ProviderConfig = ProviderConfigurationManager.defaultProviderConfig

    private static let defaultProviderConfig = ProviderConfig(
        smallestAIApiKey: "",
        ttsVoiceId: "emily"
    )

    private var configFileURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let clickyDirectory = applicationSupportDirectory.appendingPathComponent("Clicky")
        return clickyDirectory.appendingPathComponent("config.json")
    }

    init() {
        loadProviderConfig()
    }

    /// Reads config.json from disk. If the file doesn't exist, writes
    /// the default configuration. Falls back to defaults on any error.
    func loadProviderConfig() {
        let fileManager = FileManager.default
        let configDirectory = configFileURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: configDirectory.path) {
            try? fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: configFileURL.path) {
            writeDefaultConfigFile()
            providerConfig = Self.defaultProviderConfig
            return
        }

        do {
            let configData = try Data(contentsOf: configFileURL)
            let decoder = JSONDecoder()
            let loadedConfig = try decoder.decode(ProviderConfig.self, from: configData)
            providerConfig = loadedConfig
        } catch {
            print("Warning: Failed to load config.json: \(error). Using default provider configuration.")
            providerConfig = Self.defaultProviderConfig
        }
    }

    /// Whether a Smallest AI API key has been configured.
    var hasSmallestAIApiKey: Bool {
        !providerConfig.smallestAIApiKey.isEmpty
    }

    /// The configured TTS voice ID, falling back to "emily" if empty.
    var effectiveTTSVoiceId: String {
        providerConfig.ttsVoiceId.isEmpty ? "emily" : providerConfig.ttsVoiceId
    }

    // MARK: - Private

    private func writeDefaultConfigFile() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let defaultData = try? encoder.encode(Self.defaultProviderConfig) else { return }
        try? defaultData.write(to: configFileURL)
        print("Created default config.json at \(configFileURL.path)")
    }
}
