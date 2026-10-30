import Foundation
import Darwin

struct MergeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thrown when a None merge needs matching videos but they differ; the caller can retry with re-encoding.
struct CopyMismatch: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MergeCancelled: LocalizedError {
    var errorDescription: String? { "Cancelled. No file was saved." }
}

struct AudioTrack: Equatable {
    let codec: String
    let sampleRate: String
    let channels: Int
}

struct VideoInfo {
    let duration: Double
    let width: Int
    let height: Int
    let rotation: Int
    let frameRate: String
    let realFrameRate: String
    let videoCount: Int
    let videoCodec: String
    /// The video stream's time base, such as "1/600" for many MOV files.
    let videoTimeBase: String
    let pixelFormat: String
    let sampleAspectRatio: String
    let audioTracks: [AudioTrack]
    var hasAudio: Bool { !audioTracks.isEmpty }
    private var isQuarterTurn: Bool { rotation == 90 || rotation == 270 }
    /// Frame size after FFmpeg applies the rotation metadata.
    var displayWidth: Int { isQuarterTurn ? height : width }
    var displayHeight: Int { isQuarterTurn ? width : height }
}

struct CommandResult {
    let status: Int32
    let output: String
}

enum Quality: String, CaseIterable {
    case veryHigh = "Very High"
    case high = "High"
    case normal = "Normal"
    case low = "Low"

    var crf: Int {
        switch self {
        case .veryHigh: 10
        case .high: 14
        case .normal: 18
        case .low: 23
        }
    }
}

final class MergeEngine {
    private let fm = FileManager.default
    let ffmpeg: URL?
    let ffprobe: URL?

    private let lock = NSLock()
    private var currentProcess: Process?
    private var cancelled = false
    private var cachedTransitions: [String]?

    init() {
        ffmpeg = Self.findExecutable("ffmpeg")
        ffprobe = Self.findExecutable("ffprobe")
    }

    static func findExecutable(_ name: String) -> URL? {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathEntries + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Stops the running FFmpeg/FFprobe process; the merge in progress then throws MergeCancelled.
    func cancel() {
        lock.lock()
        cancelled = true
        let process = currentProcess
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Runs a tool and returns its stderr (and stdout when no progress handler is given).
    /// With a progress handler, stdout carries FFmpeg's `-progress` key=value lines.
    /// Only cancellable runs belong to the merge in progress; others are quick lookups for the UI.
    private func run(_ executable: URL, _ arguments: [String], cancellable: Bool = true,
                     progress: ((Double) -> Void)? = nil) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errorPipe = Pipe()
        let outputPipe = progress == nil ? errorPipe : Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        if let progress {
            var buffer = Data()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                buffer.append(handle.availableData)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) {
                        progress(micros / 1_000_000)
                    }
                }
            }
        }

        lock.lock()
        if cancellable && cancelled {
            lock.unlock()
            throw MergeCancelled()
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            throw MergeFailure(message: "Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        if cancellable { currentProcess = process }
        lock.unlock()

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil

        guard cancellable else {
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }
        lock.lock()
        currentProcess = nil
        lock.unlock()
        if isCancelled { throw MergeCancelled() }
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    func availableTransitions() -> [String] {
        lock.lock()
        if let cachedTransitions {
            lock.unlock()
            return cachedTransitions
        }
        lock.unlock()
        guard let ffmpeg,
              let result = try? run(ffmpeg, ["-hide_banner", "-h", "filter=xfade"], cancellable: false),
              result.status == 0 else { return [] }
        var inOptions = false
        var names: [String] = []
        for line in result.output.split(separator: "\n") {
            let text = String(line)
            if text.range(of: #"^\s+transition\s+<int>"#, options: .regularExpression) != nil {
                inOptions = true
                continue
            }
            if inOptions && text.range(of: #"^\s+duration\s+<duration>"#, options: .regularExpression) != nil {
                break
            }
            if inOptions,
               let range = text.range(of: #"^\s+[a-z][a-z0-9]*\s+\d+\s+"#, options: .regularExpression) {
                let words = text[range].split(whereSeparator: { $0.isWhitespace })
                if let name = words.first { names.append(String(name)) }
            }
        }
        let sorted = names.sorted {
            let leftFade = $0.localizedCaseInsensitiveContains("fade")
            let rightFade = $1.localizedCaseInsensitiveContains("fade")
            return leftFade == rightFade ? $0 < $1 : leftFade
        }
        lock.lock()
        cachedTransitions = sorted
        lock.unlock()
        return sorted
    }

    private func probe(_ url: URL, cancellable: Bool = true) throws -> VideoInfo {
        guard let ffprobe else { throw MergeFailure(message: "FFprobe is required to inspect videos.") }
        let result = try run(ffprobe, [
            "-v", "error", "-show_entries",
            "format=duration:stream=codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,time_base,duration,pix_fmt,sample_aspect_ratio,sample_rate,channels:stream_side_data=rotation",
            "-of", "json", url.path
        ], cancellable: cancellable)
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            throw MergeFailure(message: "Could not read \(url.lastPathComponent): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let videos = streams.filter { $0["codec_type"] as? String == "video" }
        let audios = streams.filter { $0["codec_type"] as? String == "audio" }
        guard let video = videos.first,
              let width = video["width"] as? Int,
              let height = video["height"] as? Int else {
            throw MergeFailure(message: "No readable video stream found in \(url.lastPathComponent).")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let duration = Double(video["duration"] as? String ?? "")
            ?? Double(format["duration"] as? String ?? "") ?? 0
        let sideData = video["side_data_list"] as? [[String: Any]] ?? []
        let rawRotation = sideData.lazy.compactMap { ($0["rotation"] as? NSNumber)?.intValue }.first ?? 0
        let tracks = audios.map {
            AudioTrack(
                codec: $0["codec_name"] as? String ?? "",
                sampleRate: $0["sample_rate"] as? String ?? "",
                channels: $0["channels"] as? Int ?? 0
            )
        }
        return VideoInfo(
            duration: duration,
            width: width,
            height: height,
            rotation: (rawRotation % 360 + 360) % 360,
            frameRate: video["avg_frame_rate"] as? String ?? "0/0",
            realFrameRate: video["r_frame_rate"] as? String ?? "0/0",
            videoCount: videos.count,
            videoCodec: video["codec_name"] as? String ?? "",
            videoTimeBase: video["time_base"] as? String ?? "",
            pixelFormat: video["pix_fmt"] as? String ?? "",
            sampleAspectRatio: video["sample_aspect_ratio"] as? String ?? "",
            audioTracks: tracks
        )
    }

    private func validateCopy(_ paths: [URL]) throws -> [VideoInfo] {
        let infos = try paths.map { try probe($0) }
        guard let first = infos.first else { throw MergeFailure(message: "Choose at least one video.") }
        if infos.contains(where: { $0.videoCount != 1 }) {
            throw CopyMismatch(message: "A None merge without re-encoding needs exactly one video track in each file.")
        }
        for (index, info) in infos.enumerated().dropFirst() {
            let fields: [(String, Bool)] = [
                ("video codec", info.videoCodec == first.videoCodec),
                ("video size", info.width == first.width && info.height == first.height),
                ("orientation", info.rotation == first.rotation),
                ("frame rate", Self.sameRate(info.realFrameRate, first.realFrameRate)),
                ("pixel format", info.pixelFormat == first.pixelFormat),
                ("pixel aspect ratio", info.sampleAspectRatio == first.sampleAspectRatio),
                ("audio tracks and format", info.audioTracks == first.audioTracks)
            ]
            if let mismatch = fields.first(where: { !$0.1 })?.0 {
                throw CopyMismatch(message: "Video \(index + 1) has a different \(mismatch), so the videos can't be merged without re-encoding.")
            }
        }
        return infos
    }

    private static func rateValue(_ rate: String) -> Double? {
        let parts = rate.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    private static func sameRate(_ left: String, _ right: String) -> Bool {
        guard let a = rateValue(left), let b = rateValue(right) else { return left == right }
        return abs(a - b) < 0.01
    }

    private static func videoTag(_ codec: String) -> [String] {
        codec == "hevc" ? ["-tag:v", "hvc1"] : []
    }

    private static let progressArguments = ["-progress", "pipe:1", "-nostats"]

    /// Converts one video. Reversing always re-encodes, since a stream copy can't change frame order.
    private func singleCommand(_ source: URL, _ output: URL, _ info: VideoInfo,
                               quality: Quality, reverse: Bool = false, forceEncode: Bool = false) -> [String] {
        let copyVideoCodecs: Set<String> = ["h264", "hevc", "av1", "mpeg4"]
        let copyAudioCodecs: Set<String> = ["aac", "mp3", "alac"]
        let encodeVideo = forceEncode || reverse || !copyVideoCodecs.contains(info.videoCodec)
        let encodeAudio = forceEncode || reverse || info.audioTracks.contains { !copyAudioCodecs.contains($0.codec) }
        var command = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + Self.progressArguments
            + ["-i", source.path, "-map", "0:v:0", "-map", "0:a?"]
        if reverse { command += ["-vf", "reverse", "-af", "areverse"] }
        command += encodeVideo
            ? ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", String(quality.crf), "-preset", "medium"]
            : ["-c:v", "copy"] + Self.videoTag(info.videoCodec)
        command += encodeAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-c:a", "copy"]
        command += ["-movflags", "+faststart", output.path]
        return command
    }

    /// Whether converting this single file re-encodes its video, so the Quality setting applies.
    func singleFileNeedsEncoding(_ url: URL) -> Bool? {
        guard let info = try? probe(url, cancellable: false) else { return nil }
        return singleCommand(url, url, info, quality: .normal).contains("libx264")
    }

    /// Re-encodes and joins the videos, with an xfade transition between them, or a plain cut when transition is nil.
    private func renderCommand(_ paths: [URL], _ output: URL, reversed: [Bool], transition: String?,
                               _ quality: Quality) throws -> (command: [String], duration: Double) {
        let infos = try paths.map { try probe($0) }
        if infos.contains(where: { $0.duration <= 0 }) {
            throw MergeFailure(message: "Could not determine the duration of every video.")
        }
        var duration = 0.0
        if transition != nil {
            duration = (min(1.0, (infos.map(\.duration).min() ?? 0) / 2) * 1000).rounded() / 1000
            if duration < 0.1 {
                throw MergeFailure(message: "Videos must be at least 0.2 seconds long to use a transition.")
            }
        }
        let width = infos[0].displayWidth + infos[0].displayWidth % 2
        let height = infos[0].displayHeight + infos[0].displayHeight % 2
        let fps = Self.validFrameRate(infos[0].frameRate)
        let hasAudio = infos.contains(where: \.hasAudio)
        var graph: [String] = []
        for (index, info) in infos.enumerated() {
            let reverse = reversed[index] ? "reverse," : ""
            graph.append("[\(index):v:0]trim=duration=\(Self.number(info.duration)),setpts=PTS-STARTPTS,\(reverse)fps=\(fps),scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p,settb=AVTB[v\(index)]")
        }
        if hasAudio {
            for (index, info) in infos.enumerated() {
                let source = info.hasAudio
                    ? "[\(index):a:0]aresample=48000,apad"
                    : "anullsrc=channel_layout=stereo:sample_rate=48000"
                let reverse = reversed[index] ? ",areverse" : ""
                graph.append("\(source),aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,atrim=duration=\(Self.number(info.duration)),asetpts=PTS-STARTPTS\(reverse)[a\(index)]")
            }
        }

        var videoOut = "v0"
        var audioOut = "a0"
        var totalDuration = infos[0].duration
        if let transition {
            for index in 1..<infos.count {
                let label = "x\(index)"
                graph.append("[\(videoOut)][v\(index)]xfade=transition=\(transition):duration=\(Self.number(duration, digits: 3)):offset=\(Self.number(totalDuration - duration))[\(label)]")
                videoOut = label
                totalDuration += infos[index].duration - duration
            }
            if hasAudio {
                for index in 1..<infos.count {
                    let label = "ax\(index)"
                    graph.append("[\(audioOut)][a\(index)]acrossfade=d=\(Self.number(duration, digits: 3))[\(label)]")
                    audioOut = label
                }
            }
        } else {
            totalDuration = infos.map(\.duration).reduce(0, +)
            let inputs = infos.indices.map { hasAudio ? "[v\($0)][a\($0)]" : "[v\($0)]" }.joined()
            graph.append("\(inputs)concat=n=\(infos.count):v=1:a=\(hasAudio ? 1 : 0)[vout]\(hasAudio ? "[aout]" : "")")
            videoOut = "vout"
            audioOut = "aout"
        }

        var command = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + Self.progressArguments
        for path in paths { command += ["-i", path.path] }
        command += ["-filter_complex", graph.joined(separator: ";"), "-map", "[\(videoOut)]"]
        if hasAudio { command += ["-map", "[\(audioOut)]"] }
        command += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", String(quality.crf),
                    "-preset", "medium"]
        if hasAudio { command += ["-c:a", "aac", "-b:a", "192k"] }
        command += ["-movflags", "+faststart", output.path]
        return (command, totalDuration)
    }

    private static func validFrameRate(_ rate: String) -> String {
        rateValue(rate) == nil ? "30" : rate
    }

    private static func number(_ value: Double, digits: Int = 6) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }

    /// Quotes a path for the concat demuxer, where quoted text is literal except for the quote itself.
    private static func concatPath(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func ffmpegError(_ output: String, status: Int32) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let details = lines.reversed().first {
            let line = $0.lowercased()
            return ["error", "invalid", "failed", "could not", "unsupported", "not found"].contains {
                line.contains($0)
            } && !["conversion failed", "error opening output files", "error opening input files"].contains {
                line.contains($0)
            }
        } ?? lines.last ?? "FFmpeg exited without reporting an error."
        return "FFmpeg failed (code \(status)): \(details)"
    }

    private static func containerError(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("not currently supported in container") || text.contains("could not find tag for codec")
    }

    func outputURL(for paths: [URL], reversed: Bool = false) -> URL {
        let first = paths[0]
        let stem: String
        if paths.count > 1 {
            stem = first.deletingPathExtension().lastPathComponent + "_merged"
        } else if reversed {
            stem = first.deletingPathExtension().lastPathComponent + "_reversed"
        } else if first.pathExtension.lowercased() == "mp4" {
            stem = first.deletingPathExtension().lastPathComponent + "_converted"
        } else {
            stem = first.deletingPathExtension().lastPathComponent
        }
        let sourcePaths = Set(paths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        let folder = first.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent(stem + ".mp4")
        var number = 2
        while fm.fileExists(atPath: candidate.path)
            || sourcePaths.contains(candidate.standardizedFileURL.resolvingSymlinksInPath().path) {
            candidate = folder.appendingPathComponent("\(stem)_\(number).mp4")
            number += 1
        }
        return candidate
    }

    private func temporaryFile(in folder: URL, kind: String, extension fileExtension: String) throws -> URL {
        let url = folder.appendingPathComponent(".mp4-merge-\(kind)-\(UUID().uuidString).\(fileExtension)")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { throw MergeFailure(message: "Could not create a temporary file beside the first video.") }
        close(fd)
        return url
    }

    /// Converts or merges the videos. `progress` receives a 0...1 fraction on a background thread.
    /// `reversed` marks videos to play backwards; empty means none. Any reversed video forces re-encoding.
    /// With transition "None", `reencode` false and nothing reversed, mismatched videos throw CopyMismatch.
    func merge(_ paths: [URL], reversed: [Bool] = [], transition: String, quality: Quality, reencode: Bool = false,
               progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        lock.lock()
        cancelled = false
        lock.unlock()
        defer {
            lock.lock()
            cancelled = false
            lock.unlock()
        }
        guard !paths.isEmpty && paths.count <= 10 else {
            throw MergeFailure(message: "Choose one to ten videos.")
        }
        let reversed = reversed.isEmpty ? Array(repeating: false, count: paths.count) : reversed
        guard reversed.count == paths.count else {
            throw MergeFailure(message: "Each video needs one reverse setting.")
        }
        for path in paths where !fm.fileExists(atPath: path.path) {
            throw MergeFailure(message: "File not found: \(path.lastPathComponent)")
        }
        guard let ffmpeg else { throw MergeFailure(message: "FFmpeg is required to save videos as MP4.") }
        let folder = paths[0].deletingLastPathComponent()
        let tempOutput = try temporaryFile(in: folder, kind: "output", extension: "mp4")
        var listURL: URL?
        var rewrapped: [URL] = []
        defer {
            try? fm.removeItem(at: tempOutput)
            if let listURL { try? fm.removeItem(at: listURL) }
            for url in rewrapped { try? fm.removeItem(at: url) }
        }

        func report(over total: Double) -> (Double) -> Void {
            { seconds in if total > 0 { progress(min(1, max(0, seconds / total))) } }
        }

        let result: CommandResult
        if paths.count == 1 {
            let info = try probe(paths[0])
            result = try run(ffmpeg, singleCommand(paths[0], tempOutput, info, quality: quality, reverse: reversed[0]),
                             progress: report(over: info.duration))
            if result.status != 0 && Self.containerError(result.output) {
                let retry = try run(ffmpeg, singleCommand(paths[0], tempOutput, info, quality: quality,
                                                          reverse: reversed[0], forceEncode: true),
                                    progress: report(over: info.duration))
                if retry.status != 0 { throw MergeFailure(message: Self.ffmpegError(retry.output, status: retry.status)) }
            } else if result.status != 0 {
                throw MergeFailure(message: Self.ffmpegError(result.output, status: result.status))
            }
        } else if transition != "None" || reencode || reversed.contains(true) {
            let xfade: String? = transition == "None" ? nil : transition
            if let xfade, !availableTransitions().contains(xfade) {
                throw MergeFailure(message: "FFmpeg does not support the \(xfade) transition.")
            }
            let render = try renderCommand(paths, tempOutput, reversed: reversed, transition: xfade, quality)
            result = try run(ffmpeg, render.command, progress: report(over: render.duration))
            if result.status != 0 { throw MergeFailure(message: Self.ffmpegError(result.output, status: result.status)) }
        } else {
            let infos = try validateCopy(paths)
            // The concat demuxer reads every file's timestamps in the first file's time base, so a video
            // with another time base (MOV's 1/600 next to MP4's 1/19200) would play at the wrong speed and
            // stall players. Copy such videos into the first video's time base before joining.
            var sources = paths
            if let scale = infos[0].videoTimeBase.split(separator: "/").last.flatMap({ Int($0) }), scale > 0 {
                for index in paths.indices.dropFirst() where infos[index].videoTimeBase != infos[0].videoTimeBase {
                    let copy = try temporaryFile(in: folder, kind: "rewrap", extension: "mov")
                    rewrapped.append(copy)
                    let rewrap = try run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                                                  "-i", paths[index].path, "-map", "0:v:0", "-map", "0:a?",
                                                  "-c", "copy", "-video_track_timescale", String(scale), copy.path])
                    if rewrap.status != 0 { throw MergeFailure(message: Self.ffmpegError(rewrap.output, status: rewrap.status)) }
                    sources[index] = copy
                }
            }
            let list = try temporaryFile(in: folder, kind: "list", extension: "txt")
            listURL = list
            let content = sources.map { "file \(Self.concatPath($0.path))\n" }.joined()
            try content.write(to: list, atomically: false, encoding: .utf8)
            result = try run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + Self.progressArguments
                             + ["-f", "concat", "-safe", "0", "-i", list.path,
                                "-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
                             + Self.videoTag(infos[0].videoCodec)
                             + ["-movflags", "+faststart", tempOutput.path],
                             progress: report(over: infos.map(\.duration).reduce(0, +)))
            if result.status != 0 {
                if Self.containerError(result.output) {
                    throw MergeFailure(message: "MP4 cannot store one of these video or audio tracks without re-encoding. No source files were changed.")
                }
                throw MergeFailure(message: Self.ffmpegError(result.output, status: result.status))
            }
        }

        let output = outputURL(for: paths, reversed: reversed[0])
        try fm.moveItem(at: tempOutput, to: output)
        return output
    }
}
