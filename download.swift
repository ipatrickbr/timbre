import Foundation

/// Fetches the Whisper language models on first use, so a downloaded copy of
/// Timbre needs no terminal and no compiler. The engine itself ships inside the
/// app; only these data files are missing.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    struct Model {
        let name: String
        let expectedBytes: Int64
        var overrideURL: URL? = nil

        var fileName: String { "ggml-\(name).bin" }
        var url: URL {
            overrideURL
                ?? URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")!
        }
    }

    /// Transcription runs on the turbo model; translation needs a second one,
    /// because turbo returns the source language when asked to translate.
    static let required = [
        Model(name: "large-v3-turbo", expectedBytes: 1_624_555_275),
        Model(name: "small", expectedBytes: 487_601_967),
    ]

    static var totalBytes: Int64 { required.reduce(0) { $0 + $1.expectedBytes } }

    static var missing: [Model] {
        required.filter { model in
            let path = Transcriber.modelsDirectory.appendingPathComponent(model.fileName)
            let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int64) ?? nil
            // A half-finished file from an interrupted run counts as missing.
            return (size ?? 0) < model.expectedBytes / 2
        }
    }

    private var session: URLSession!
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((Bool) -> Void)?
    private var queue: [Model] = []
    private var completedBytes: Int64 = 0
    private var current: Model?
    private var cancelled = false
    private var expectedTotal: Int64 = 0

    /// `models` is injectable so the flow can be exercised against a local
    /// server instead of a two-gigabyte download.
    func start(models: [Model]? = nil,
               progress: @escaping (Double) -> Void,
               completion: @escaping (Bool) -> Void) {
        onProgress = progress
        onFinish = completion
        queue = models ?? Self.missing
        expectedTotal = queue.reduce(0) { $0 + $1.expectedBytes }
        completedBytes = 0
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        next()
    }

    func cancel() {
        cancelled = true
        session?.invalidateAndCancel()
    }

    private func next() {
        guard !cancelled else { return }
        guard let model = queue.first else {
            finish(true)
            return
        }
        queue.removeFirst()
        current = model
        session.downloadTask(with: model.url).resume()
    }

    private func finish(_ ok: Bool) {
        let handler = onFinish
        onFinish = nil
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async { handler?(ok) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = expectedTotal > 0 ? expectedTotal : Self.totalBytes
        let overall = Double(completedBytes + totalBytesWritten) / Double(total)
        DispatchQueue.main.async { self.onProgress?(min(overall, 0.99)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let model = current else { return }
        let destination = Transcriber.modelsDirectory.appendingPathComponent(model.fileName)
        do {
            try FileManager.default.createDirectory(at: Transcriber.modelsDirectory,
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(false)
            return
        }
        completedBytes += model.expectedBytes
        next()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil, !cancelled else { return }
        finish(false)
    }
}
