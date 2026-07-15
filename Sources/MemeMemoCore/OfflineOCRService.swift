import Foundation

public protocol OfflineOCRProviding: Sendable {
    func recognize(imageURL: URL) async throws -> String
}

public enum OfflineOCRError: LocalizedError {
    case engineUnavailable
    case recognitionFailed

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable: "离线 OCR 引擎未安装。"
        case .recognitionFailed: "无法识别图片中的文字。"
        }
    }
}

/// The production bundle will provide a vendored Tesseract binary and chi_sim/eng data files.
public struct BundledTesseractOCRService: OfflineOCRProviding {
    public let executableURL: URL?
    public let languages: String

    public init(executableURL: URL?, languages: String = "chi_sim+eng") {
        self.executableURL = executableURL
        self.languages = languages
    }

    public func recognize(imageURL: URL) async throws -> String {
        guard let executableURL else { throw OfflineOCRError.engineUnavailable }
        return try await Task.detached(priority: .utility) {
            let output = Pipe()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [imageURL.path, "stdout", "-l", languages]
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw OfflineOCRError.recognitionFailed }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
