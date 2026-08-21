import Foundation

@main
struct SettingsModelMigrationQA {
    static func main() throws {
        try upgradesOnlyTheExactVisionModel()
        try appendsTheMissingVisionModelWithoutDiscardingOthers()
        try replacesAStandaloneTextOnlyModalitiesList()
        try leavesUnrelatedSettingsUntouched()
        try verifiesTheAtomicFileMigrationAndBackup()
        print("SETTINGS_MODEL_MIGRATION_QA_OK exact_model=1 idempotent=1 backup=1")
    }

    private static func upgradesOnlyTheExactVisionModel() throws {
        let original = """
        permission:
          defaultPreset: danger-full-access
        llm-deepseek:
          models:
            - id: deepseek-v4-flash
              name: DeepSeek-V4-Flash
              inputModalities: [text]
            - id: deepseek-v4-pro
              name: DeepSeek-V4-Pro
              inputModalities: [text]
            - id: deepseek-v4-flash-vision-exp
              name: deepseek-v4-flash-vision
        agent-default-model:
          provider: deepseek-official
          model: deepseek-v4-flash-vision-exp
        """
        let migrated = try require(DeepSeekModelCatalogMigration.reconciledSettings(original))
        try require(migrated.contains("- id: deepseek-v4-flash-vision-exp\n      inputModalities: [text, image]"))
        try require(migrated.contains("- id: deepseek-v4-flash\n      name: DeepSeek-V4-Flash\n      inputModalities: [text]"))
        try require(migrated.contains("- id: deepseek-v4-pro\n      name: DeepSeek-V4-Pro\n      inputModalities: [text]"))
        try require(DeepSeekModelCatalogMigration.reconciledSettings(migrated) == migrated)
    }

    private static func appendsTheMissingVisionModelWithoutDiscardingOthers() throws {
        let original = """
        llm-deepseek:
          baseURL: https://example.invalid
          models:
            - id: deepseek-v4-flash
              name: DeepSeek-V4-Flash
              inputModalities: [text]
        ui-theme:
          preference: system
        """
        let migrated = try require(DeepSeekModelCatalogMigration.reconciledSettings(original))
        try require(migrated.contains("baseURL: https://example.invalid"))
        try require(migrated.contains("- id: deepseek-v4-flash\n      name: DeepSeek-V4-Flash\n      inputModalities: [text]"))
        try require(migrated.contains("- id: deepseek-v4-flash-vision-exp\n      name: DeepSeek-V4-Flash Vision\n      contextWindow: 1000000\n      inputModalities: [text, image]"))
        try require(migrated.contains("ui-theme:\n  preference: system"))
    }

    private static func replacesAStandaloneTextOnlyModalitiesList() throws {
        let original = """
        llm-deepseek:
          models:
            - id: deepseek-v4-flash-vision-exp
              inputModalities:
                - text
              contextWindow: 1000000
        """
        let migrated = try require(DeepSeekModelCatalogMigration.reconciledSettings(original))
        try require(migrated.contains("inputModalities: [text, image]\n      contextWindow"))
        try require(!migrated.contains("- text"))
    }

    private static func leavesUnrelatedSettingsUntouched() throws {
        let original = """
        agent-default-model:
          provider: deepseek-official
          model: deepseek-v4-flash-vision-exp
        """
        try require(DeepSeekModelCatalogMigration.reconciledSettings(original) == nil)
    }

    private static func verifiesTheAtomicFileMigrationAndBackup() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deepseek-settings-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.yaml")
        let original = """
        llm-deepseek:
          models:
            - id: deepseek-v4-flash-vision-exp
              name: deepseek-v4-flash-vision
        """
        try Data(original.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        try require(DeepSeekModelCatalogMigration.reconcile(settingsAt: settings))
        let migrated = try String(contentsOf: settings, encoding: .utf8)
        try require(migrated.contains("inputModalities: [text, image]"))
        let backup = root.appendingPathComponent("settings.before-deepseek-flash-vision.yaml")
        try require(FileManager.default.fileExists(atPath: backup.path))
        try require(try String(contentsOf: backup, encoding: .utf8) == original)
        try require(!DeepSeekModelCatalogMigration.reconcile(settingsAt: settings))
    }

    private static func require(_ value: Bool, _ message: String = "assertion failed") throws {
        guard value else { throw NSError(domain: "SettingsModelMigrationQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "SettingsModelMigrationQA", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected nil"]) }
        return value
    }
}
