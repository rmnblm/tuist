import TSCBasic
import TuistCore
import TuistGraph
import TuistSupport

// MARK: - Swift Package Manager Interactor Errors

enum SwiftPackageManagerInteractorError: FatalError, Equatable {
    /// Thrown when `Package.resolved` cannot be found in temporary directory after `Swift Package Manager` installation.
    case packageResolvedNotFound
    /// Thrown when `.build` directory cannot be found in temporary directory after `Swift Package Manager` installation.
    case buildDirectoryNotFound

    /// Error type.
    var type: ErrorType {
        switch self {
        case .packageResolvedNotFound,
             .buildDirectoryNotFound:
            return .bug
        }
    }

    /// Error description.
    var description: String {
        switch self {
        case .packageResolvedNotFound:
            return "The Package.resolved lockfile was not found after resolving the dependencies using the Swift Package Manager."
        case .buildDirectoryNotFound:
            return "The .build directory was not found after resolving the dependencies using the Swift Package Manager"
        }
    }
}

// MARK: - Swift Package Manager Interacting

public protocol SwiftPackageManagerInteracting {
    /// Fetches `Swift Package Manager` dependencies.
    /// - Parameters:
    ///   - dependenciesDirectory: The path to the directory that contains the `Tuist/Dependencies/` directory.
    ///   - dependencies: List of dependencies to intall using `Swift Package Manager`.
    ///   - platforms: List of platforms for which you want to install depedencies.
    func fetch(
        dependenciesDirectory: AbsolutePath,
        dependencies: SwiftPackageManagerDependencies,
        platforms: Set<Platform>
    ) throws

    /// Removes all cached `Swift Package Manager` dependencies.
    /// - Parameter dependenciesDirectory: The path to the directory that contains the `Tuist/Dependencies/` directory.
    func clean(dependenciesDirectory: AbsolutePath) throws
}

// MARK: - Swift Package Manager Interactor

public final class SwiftPackageManagerInteractor: SwiftPackageManagerInteracting {
    private let fileHandler: FileHandling
    private let swiftPackageManager: SwiftPackageManaging
    private let xcframeworkBuilder: XCFrameworkBuilding

    public init(
        fileHandler: FileHandling = FileHandler.shared,
        swiftPackageManager: SwiftPackageManaging = SwiftPackageManager(),
        xcframeworkBuilder: XCFrameworkBuilding = XCFrameworkBuilder()
    ) {
        self.fileHandler = fileHandler
        self.swiftPackageManager = swiftPackageManager
        self.xcframeworkBuilder = xcframeworkBuilder
    }

    public func fetch(
        dependenciesDirectory: AbsolutePath,
        dependencies: SwiftPackageManagerDependencies,
        platforms: Set<Platform>
    ) throws {
        logger.info("Resolving and fetching Swift Package Manager dependencies.", metadata: .section)

        try fileHandler.inTemporaryDirectory { temporaryDirectoryPath in
            // prepare paths
            let pathsProvider = SwiftPackageManagerPathsProvider(
                dependenciesDirectory: dependenciesDirectory,
                temporaryDirectoryPath: temporaryDirectoryPath
            )

            // prepare for installation
            try loadDependencies(pathsProvider: pathsProvider, packageManifestContent: dependencies.manifestValue())

            // run `Swift Package Manager`
            try swiftPackageManager.resolve(at: temporaryDirectoryPath)

            // build xcframeworks from fetched dependencies
            let xcFrameworksPaths = try swiftPackageManager
                .loadDependencies(at: temporaryDirectoryPath)
                .uniqueDependencies()
                .flatMap { dependencyInfo -> [AbsolutePath] in
                    let packageInfo = try swiftPackageManager.loadPackageInfo(at: dependencyInfo.absolutePath)

                    guard !packageInfo.supportedPlatforms.isDisjoint(with: platforms) else {
                        logger.info("\(dependencyInfo.name) does not support requested platforms. Building XCFramemork has been skipped.")
                        return []
                    }

                    let packageDirectory = temporaryDirectoryPath.appending(component: packageInfo.name)
                    try fileHandler.createFolder(packageDirectory)

                    try swiftPackageManager.generateXcodeProject(
                        at: dependencyInfo.absolutePath,
                        outputPath: packageDirectory
                    )

                    return try xcframeworkBuilder
                        .buildXCFrameworks(
                            at: packageDirectory,
                            packageInfo: packageInfo,
                            platforms: platforms
                        )
                }

            // post installation
            try saveDepedencies(pathsProvider: pathsProvider, xcframeworksPaths: xcFrameworksPaths)
        }

        logger.info("Packages resolved and fetched successfully.", metadata: .subsection)
    }

    public func clean(dependenciesDirectory: AbsolutePath) throws {
        let swiftPackageManagerDirectory = dependenciesDirectory
            .appending(component: Constants.DependenciesDirectory.swiftPackageManagerDirectoryName)
        let packageResolvedPath = dependenciesDirectory
            .appending(component: Constants.DependenciesDirectory.lockfilesDirectoryName)
            .appending(component: Constants.DependenciesDirectory.packageResolvedName)

        try fileHandler.delete(swiftPackageManagerDirectory)
        try fileHandler.delete(packageResolvedPath)
    }

    // MARK: - Installation

    /// Loads lockfile and dependencies into working directory if they had been saved before.
    private func loadDependencies(pathsProvider: SwiftPackageManagerPathsProvider, packageManifestContent: String) throws {
        // copy `.build` directory from previous run if exist
        if fileHandler.exists(pathsProvider.destinationBuildDirectory) {
            try copy(
                from: pathsProvider.destinationBuildDirectory,
                to: pathsProvider.temporaryBuildDirectory
            )
        }

        // copy `Package.resolved` directory from previous run if exist
        if fileHandler.exists(pathsProvider.destinationPackageResolvedPath) {
            try copy(
                from: pathsProvider.destinationPackageResolvedPath,
                to: pathsProvider.temporaryPackageResolvedPath
            )
        }

        // create `Package.swift`
        let packageManifestPath = pathsProvider.temporaryDirectoryPath.appending(component: "Package.swift")
        try fileHandler.write(packageManifestContent, path: packageManifestPath, atomically: true)

        // log
        logger.debug("Package.swift:", metadata: .subsection)
        logger.debug("\(packageManifestContent)")
    }

    /// Saves lockfile, resolved dependencies and built XCFrameworks in `Tuist/Dependencies` directory.
    private func saveDepedencies(pathsProvider: SwiftPackageManagerPathsProvider, xcframeworksPaths: [AbsolutePath]) throws {
        // validation
        guard fileHandler.exists(pathsProvider.temporaryPackageResolvedPath) else {
            throw SwiftPackageManagerInteractorError.packageResolvedNotFound
        }
        guard fileHandler.exists(pathsProvider.temporaryBuildDirectory) else {
            throw SwiftPackageManagerInteractorError.buildDirectoryNotFound
        }

        // remove old state
        try fileHandler.delete(pathsProvider.destinationDirectory)

        // save `Package.resolved`
        try copy(
            from: pathsProvider.temporaryPackageResolvedPath,
            to: pathsProvider.destinationPackageResolvedPath
        )

        // save `.build` directory
        try copy(
            from: pathsProvider.temporaryBuildDirectory,
            to: pathsProvider.destinationBuildDirectory
        )

        // save XCFrameworks
        try xcframeworksPaths.forEach { xcframeworksPath in
            try copy(
                from: xcframeworksPath,
                to: pathsProvider.destinationDirectory.appending(component: xcframeworksPath.basename)
            )
        }
    }

    // MARK: - Helpers

    private func copy(from fromPath: AbsolutePath, to toPath: AbsolutePath) throws {
        if fileHandler.exists(toPath) {
            try fileHandler.replace(toPath, with: fromPath)
        } else {
            try fileHandler.createFolder(toPath.removingLastComponent())
            try fileHandler.copy(from: fromPath, to: toPath)
        }
    }
}

// MARK: - Models

private struct SwiftPackageManagerPathsProvider {
    let dependenciesDirectory: AbsolutePath
    let temporaryDirectoryPath: AbsolutePath

    let destinationPackageResolvedPath: AbsolutePath
    let destinationDirectory: AbsolutePath
    let destinationBuildDirectory: AbsolutePath

    let temporaryPackageResolvedPath: AbsolutePath
    let temporaryBuildDirectory: AbsolutePath

    init(dependenciesDirectory: AbsolutePath, temporaryDirectoryPath: AbsolutePath) {
        self.dependenciesDirectory = dependenciesDirectory
        self.temporaryDirectoryPath = temporaryDirectoryPath

        destinationPackageResolvedPath = dependenciesDirectory
            .appending(component: Constants.DependenciesDirectory.lockfilesDirectoryName)
            .appending(component: Constants.DependenciesDirectory.packageResolvedName)
        destinationDirectory = dependenciesDirectory
            .appending(component: Constants.DependenciesDirectory.swiftPackageManagerDirectoryName)
        destinationBuildDirectory = dependenciesDirectory
            .appending(component: Constants.DependenciesDirectory.swiftPackageManagerDirectoryName)
            .appending(component: ".build")

        temporaryPackageResolvedPath = temporaryDirectoryPath
            .appending(component: Constants.DependenciesDirectory.packageResolvedName)
        temporaryBuildDirectory = temporaryDirectoryPath
            .appending(component: ".build")
    }
}
