import Foundation

struct HarnessInstallation {
    let home: URL
    let integrationPatch: URL
    let helperBinary: URL
    let artifactHelperBinary: URL
}

enum HarnessHomeInstaller {
    static func prepare() throws -> HarnessInstallation {
        let fileManager = FileManager.default
        let appSupport = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeek Harness", isDirectory: true)
        let dshHome = appSupport.appendingPathComponent("dsh-home", isDirectory: true)

        try fileManager.createDirectory(at: dshHome, withIntermediateDirectories: true)

        guard let integrationRoot = Bundle.main.resourceURL?
            .appendingPathComponent("HarnessIntegration", isDirectory: true) else {
            throw InstallerError.missingResources
        }

        let templateRoot = integrationRoot
            .appendingPathComponent("dsh-home-template", isDirectory: true)
        try copyManagedTree(from: templateRoot, to: dshHome, fileManager: fileManager)

        try installBundledSkills(
            from: integrationRoot,
            to: dshHome.appendingPathComponent("skills", isDirectory: true),
            fileManager: fileManager
        )

        let globalHome = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true)
        try copyUserFileIfMissing(
            named: ".credentials.yaml",
            from: globalHome,
            to: dshHome,
            permissions: 0o600,
            fileManager: fileManager
        )
        try copyUserFileIfMissing(
            named: "settings.yaml",
            from: globalHome,
            to: dshHome,
            permissions: 0o600,
            fileManager: fileManager
        )

        let integrationPatch = integrationRoot
            .appendingPathComponent("cordis.macos-computer-use.patch.yml", isDirectory: false)
        let helperBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/DeepSeekAppBridge", isDirectory: false)
        let artifactHelperBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/DeepSeekArtifactBridge", isDirectory: false)
        guard fileManager.isReadableFile(atPath: integrationPatch.path),
              fileManager.isExecutableFile(atPath: helperBinary.path),
              fileManager.isExecutableFile(atPath: artifactHelperBinary.path) else {
            throw InstallerError.missingResources
        }

        return HarnessInstallation(
            home: dshHome,
            integrationPatch: integrationPatch,
            helperBinary: helperBinary,
            artifactHelperBinary: artifactHelperBinary
        )
    }

    private static func copyManagedTree(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw InstallerError.missingResources
        }

        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw InstallerError.missingResources
        }

        for case let sourceItem as URL in enumerator {
            let relativePath = String(sourceItem.path.dropFirst(source.path.count + 1))
            let destinationItem = destination.appendingPathComponent(relativePath)
            let values = try sourceItem.resourceValues(forKeys: [.isDirectoryKey])

            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: destinationItem,
                    withIntermediateDirectories: true
                )
            } else {
                try fileManager.createDirectory(
                    at: destinationItem.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try Data(contentsOf: sourceItem)
                try data.write(to: destinationItem, options: [.atomic])
            }
        }
    }

    private static func installBundledSkills(
        from integrationRoot: URL,
        to skillsRoot: URL,
        fileManager: FileManager
    ) throws {
        let candidates = try fileManager.contentsOfDirectory(
            at: integrationRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var installedCount = 0
        for candidate in candidates {
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  fileManager.fileExists(
                    atPath: candidate.appendingPathComponent("SKILL.md").path
                  ) else { continue }
            try copyManagedTree(
                from: candidate,
                to: skillsRoot.appendingPathComponent(candidate.lastPathComponent, isDirectory: true),
                fileManager: fileManager
            )
            installedCount += 1
        }
        guard installedCount > 0 else { throw InstallerError.missingResources }
    }

    private static func copyUserFileIfMissing(
        named name: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        permissions: Int,
        fileManager: FileManager
    ) throws {
        let source = sourceDirectory.appendingPathComponent(name)
        let destination = destinationDirectory.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: source.path) else {
            return
        }

        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: destination.path
        )
    }

    private enum InstallerError: LocalizedError {
        case missingResources

        var errorDescription: String? {
            "应用内缺少 Harness 集成资源，请重新安装 DeepSeek Harness.app。"
        }
    }
}
