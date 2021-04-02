import Foundation
import ProjectDescription
import TSCBasic
import TuistCore
import TuistGraph
import TuistSupport

public final class GeneratorModelLoader {
    private let manifestLoader: ManifestLoading
    private let manifestLinter: ManifestLinting
    private let rootDirectoryLocator: RootDirectoryLocating
    private let pluginsHelper: PluginsHelping

    public convenience init() {
        self.init(
            manifestLoader: ManifestLoader(),
            manifestLinter: ManifestLinter()
        )
    }

    public convenience init(manifestLoader: ManifestLoading,
                            manifestLinter: ManifestLinting)
    {
        self.init(
            manifestLoader: manifestLoader,
            manifestLinter: manifestLinter,
            rootDirectoryLocator: RootDirectoryLocator(),
            pluginsHelper: PluginsHelper()
        )
    }

    init(
        manifestLoader: ManifestLoading,
        manifestLinter: ManifestLinting,
        rootDirectoryLocator: RootDirectoryLocating,
        pluginsHelper: PluginsHelping
    ) {
        self.manifestLoader = manifestLoader
        self.manifestLinter = manifestLinter
        self.rootDirectoryLocator = rootDirectoryLocator
        self.pluginsHelper = pluginsHelper
    }
}

extension GeneratorModelLoader: GeneratorModelLoading {
    /// Load a Project model at the specified path
    ///
    /// - Parameters:
    ///   - path: The absolute path for the project model to load.
    /// - Returns: The Project loaded from the specified path
    /// - Throws: Error encountered during the loading process (e.g. Missing project)
    public func loadProject(at path: AbsolutePath, plugins: Plugins) throws -> TuistGraph.Project {
        let manifest = try manifestLoader.loadProject(at: path)
        try manifestLinter.lint(project: manifest).printAndThrowIfNeeded()
        return try convert(
            manifest: manifest,
            path: path,
            plugins: plugins
        )
    }

    public func loadWorkspace(at path: AbsolutePath) throws -> TuistGraph.Workspace {
        let manifest = try manifestLoader.loadWorkspace(at: path)
        return try convert(manifest: manifest, path: path)
    }
}

extension GeneratorModelLoader: ManifestModelConverting {
    public func convert(
        manifest: ProjectDescription.Project,
        path: AbsolutePath,
        plugins: Plugins
    ) throws -> TuistGraph.Project {
        let generatorPaths = GeneratorPaths(manifestDirectory: path)
        return try TuistGraph.Project.from(
            manifest: manifest,
            generatorPaths: generatorPaths,
            plugins: plugins,
            pluginsHelper: pluginsHelper
        )
    }

    public func convert(manifest: ProjectDescription.Workspace, path: AbsolutePath) throws -> TuistGraph.Workspace {
        let generatorPaths = GeneratorPaths(manifestDirectory: path)
        let workspace = try TuistGraph.Workspace.from(
            manifest: manifest,
            path: path,
            generatorPaths: generatorPaths,
            manifestLoader: manifestLoader
        )
        return workspace
    }
}
