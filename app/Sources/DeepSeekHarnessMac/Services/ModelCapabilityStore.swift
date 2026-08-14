import Foundation

@MainActor
final class ModelCapabilityStore: ObservableObject {
    @Published private(set) var registry: ModelCapabilityRegistry?
    @Published private(set) var errorMessage: String?

    init() {
        reload()
    }

    var providers: [VerifiedProviderCapability] {
        registry?.providers ?? []
    }

    var isExpired: Bool {
        guard let expiresAt = registry?.expiresAt,
              let date = ISO8601DateFormatter.dayOnly.date(from: expiresAt) else { return true }
        return date < Calendar.current.startOfDay(for: Date())
    }

    func reload() {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("HarnessIntegration/model-capabilities.json") else {
            registry = nil
            errorMessage = "应用内缺少模型能力注册表。"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            registry = try JSONDecoder().decode(ModelCapabilityRegistry.self, from: data)
            errorMessage = nil
        } catch {
            registry = nil
            errorMessage = "无法读取模型能力注册表：\(error.localizedDescription)"
        }
    }

    func supportsDirectImageInput(providerID: String, modelID: String) -> Bool {
        guard !isExpired,
              let registry,
              registry.schemaVersion == 1,
              let capability = effectiveCapability(
                  providerID: providerID,
                  providers: registry.providers,
                  visited: []
              ),
              capability.image == "supported",
              let model = capability.models.first(where: { $0.id == modelID }),
              model.lifecycle == "active",
              model.input?.contains("image") == true else {
            return false
        }
        return true
    }

    private func effectiveCapability(
        providerID: String,
        providers: [VerifiedProviderCapability],
        visited: Set<String>
    ) -> (image: String?, models: [VerifiedProviderCapability.Model])? {
        guard !visited.contains(providerID),
              let provider = providers.first(where: { $0.id == providerID }) else {
            return nil
        }

        var nextVisited = visited
        nextVisited.insert(providerID)
        let inherited = provider.inherits.flatMap {
            effectiveCapability(
                providerID: $0,
                providers: providers,
                visited: nextVisited
            )
        }
        return (
            image: provider.input?.image ?? inherited?.image,
            models: provider.models ?? inherited?.models ?? []
        )
    }
}

struct ModelCapabilityRegistry: Codable {
    let schemaVersion: Int
    let verifiedAt: String
    let expiresAt: String
    let intersectionRule: String
    let providers: [VerifiedProviderCapability]
}

struct VerifiedProviderCapability: Codable, Identifiable {
    struct Protocols: Codable {
        let chatCompletions: String?
        let responses: String?
    }

    struct Inputs: Codable {
        let text: String?
        let image: String?
        let video: String?
        let audio: String?
        let fileExtract: String?
    }

    struct Model: Codable, Identifiable {
        let id: String
        let lifecycle: String
        let contextTokens: Int?
        let defaultOutputTokens: Int?
        let maxOutputTokens: Int?
        let input: [String]?
    }

    let id: String
    let displayName: String
    let region: String
    let baseURL: String
    let adapter: String
    let protocols: Protocols?
    let input: Inputs?
    let models: [Model]?
    let inherits: String?
    let notes: [String]
    let sources: [String]
}

private extension ISO8601DateFormatter {
    static let dayOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
