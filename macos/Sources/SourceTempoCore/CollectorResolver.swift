import Foundation

public enum CollectorResolutionError: Error, Equatable, LocalizedError {
    case explicitNotExecutable(String)
    case notFound([String])

    public var errorDescription: String? {
        switch self {
        case let .explicitNotExecutable(path):
            "Configured SourceTempo collector is not executable: \(path)"
        case let .notFound(searched):
            "SourceTempo collector not found. Searched: \(searched.joined(separator: ", "))"
        }
    }
}

public struct CollectorResolver {
    private let homeDirectory: URL
    private let environmentPath: String
    private let fixedCandidates: [URL]
    private let isExecutable: (URL) -> Bool

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        fixedCandidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/source-tempo"),
            URL(fileURLWithPath: "/usr/local/bin/source-tempo"),
        ],
        isExecutable: @escaping (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.environmentPath = environmentPath
        self.fixedCandidates = fixedCandidates
        self.isExecutable = isExecutable
    }

    public func resolve(explicit: URL? = nil) throws -> URL {
        if let explicit {
            guard isExecutable(explicit) else {
                throw CollectorResolutionError.explicitNotExecutable(explicit.path)
            }
            return explicit
        }

        var searched = [homeDirectory.appending(path: ".local/bin/source-tempo")]
        searched.append(contentsOf: fixedCandidates)
        searched.append(contentsOf: environmentPath
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "source-tempo") })

        if let found = searched.first(where: isExecutable) {
            return found
        }
        throw CollectorResolutionError.notFound(searched.map(\.path))
    }
}
