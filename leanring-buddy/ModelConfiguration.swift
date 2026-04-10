//
//  ModelConfiguration.swift
//  leanring-buddy
//
//  Manages a user-editable JSON config file that defines which AI models
//  are available in the model picker. Each entry specifies a display name,
//  upstream model ID, API endpoint, and optional API key. This replaces
//  the hardcoded Sonnet/Opus picker and supports any Anthropic-compatible API.
//

import Combine
import Foundation

/// A single model entry in the user's models.json config file.
/// Each entry can point to a different Anthropic-compatible API endpoint
/// (e.g. the Cloudflare Worker proxy, direct Anthropic API, or a third-party host).
struct ModelProviderConfiguration: Codable, Identifiable, Equatable {
    /// Unique identifier for this config entry (e.g. "claude-sonnet").
    /// Used as the persisted selection key in UserDefaults.
    var id: String

    /// Human-readable name shown in the model picker dropdown (e.g. "Sonnet").
    var displayName: String

    /// The upstream model ID sent in the API request body (e.g. "claude-sonnet-4-6").
    var modelID: String

    /// Full URL of the chat endpoint. For the Cloudflare Worker proxy this is
    /// "https://<worker>/chat". For direct Anthropic access use
    /// "https://api.anthropic.com/v1/messages".
    var apiEndpoint: String

    /// API key for this endpoint. Leave empty when routing through the
    /// Cloudflare Worker (it injects its own key). When calling an endpoint
    /// directly, provide the Anthropic (or compatible) API key here.
    var apiKey: String
}

// MARK: - Manager

/// Loads and caches the model list from ~/Library/Application Support/Clicky/models.json.
/// If the file doesn't exist, it creates one with sensible defaults.
@MainActor
final class ModelConfigurationManager: ObservableObject {
    @Published private(set) var availableModelConfigurations: [ModelProviderConfiguration] = []

    /// The default Worker base URL placeholder. Matches the value previously
    /// hardcoded in CompanionManager.workerBaseURL.
    private static let defaultWorkerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    private static let defaultModelConfigurations: [ModelProviderConfiguration] = [
        ModelProviderConfiguration(
            id: "claude-sonnet",
            displayName: "Sonnet",
            modelID: "claude-sonnet-4-6",
            apiEndpoint: "\(defaultWorkerBaseURL)/chat",
            apiKey: ""
        ),
        ModelProviderConfiguration(
            id: "claude-opus",
            displayName: "Opus",
            modelID: "claude-opus-4-6",
            apiEndpoint: "\(defaultWorkerBaseURL)/chat",
            apiKey: ""
        )
    ]

    private var configFileURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let clickyDirectory = applicationSupportDirectory.appendingPathComponent("Clicky")
        return clickyDirectory.appendingPathComponent("models.json")
    }

    init() {
        loadModelConfigurations()
    }

    /// Reads models.json from disk. If the file doesn't exist, writes the
    /// default configuration and uses that. Falls back to defaults on any
    /// read or decode error.
    func loadModelConfigurations() {
        let fileManager = FileManager.default
        let configDirectory = configFileURL.deletingLastPathComponent()

        // Ensure the Clicky Application Support directory exists
        if !fileManager.fileExists(atPath: configDirectory.path) {
            try? fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        }

        // If the config file doesn't exist yet, create it with defaults
        if !fileManager.fileExists(atPath: configFileURL.path) {
            writeDefaultConfigurationFile()
            availableModelConfigurations = Self.defaultModelConfigurations
            return
        }

        // Read and decode the existing config file
        do {
            let configData = try Data(contentsOf: configFileURL)
            let decoder = JSONDecoder()
            let loadedConfigurations = try decoder.decode([ModelProviderConfiguration].self, from: configData)

            // Filter out entries with invalid endpoint URLs so they can't crash ClaudeAPI
            let validConfigurations = loadedConfigurations.filter { config in
                guard URL(string: config.apiEndpoint) != nil else {
                    print("⚠️ models.json: skipping '\(config.displayName)' — invalid apiEndpoint '\(config.apiEndpoint)'")
                    return false
                }
                return true
            }

            if validConfigurations.isEmpty {
                print("⚠️ models.json has no valid configurations — using defaults")
                availableModelConfigurations = Self.defaultModelConfigurations
            } else {
                availableModelConfigurations = validConfigurations
            }
        } catch {
            print("⚠️ Failed to load models.json: \(error). Using default model configurations.")
            availableModelConfigurations = Self.defaultModelConfigurations
        }
    }

    /// Returns the configuration matching the given ID, or nil if not found.
    func configuration(forID configurationID: String) -> ModelProviderConfiguration? {
        availableModelConfigurations.first { $0.id == configurationID }
    }

    // MARK: - Private

    private func writeDefaultConfigurationFile() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let defaultData = try? encoder.encode(Self.defaultModelConfigurations) else { return }
        try? defaultData.write(to: configFileURL)
        print("📝 Created default models.json at \(configFileURL.path)")
    }
}
