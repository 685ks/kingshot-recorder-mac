// ksrec - the macOS capture helper of Kingshot Recorder: screens, windows and sound through ScreenCaptureKit.
//
// The capture side is adapted from QuickRecorder by lihaoyun6 (https://github.com/lihaoyun6/QuickRecorder),
// licensed under the GNU Affero General Public License v3.0: the content filters, the stream configuration and the
// sample handling follow its RecordEngine.swift and SCContext.swift. This file is under the same license (see
// mac/ksrec/LICENSE-QuickRecorder.txt).
//
// Kingshot Recorder (Python) starts it and reads what it writes:
//   ksrec list [--exclude-pid P]          JSON of the screens and windows that can be recorded
//   ksrec devices                         JSON of the sound sources ({"desktop": name|null, "mic": name|null})
//   ksrec capture (--display ID | --window ID) [--fps 60] [--cursor 1] [--format nv12|rgb] [--box WxH]
//       stderr: "SIZE <w> <h>", then "STARTED <wall time of frame 0>", finally "DONE" (or "ERROR: ...")
//       stdout: raw frames (nv12 or rgb24) of that size at a steady frame rate (the newest picture is repeated
//               while nothing changes on screen), until a "q" line or the end of stdin
//   ksrec audio --source system|mic       stdout: 48 kHz 16-bit stereo PCM until a "q" line or the end of stdin
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

signal(SIGPIPE, SIG_IGN)                                   // a reader that went away is an error we report, not a crash

func say(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func fail(_ s: String) -> Never {
    say("ERROR: " + s)
    exit(1)
}

func writeAll(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
    var off = 0
    while off < n {
        let r = write(1, p + off, n - off)
        if r < 0 {
            if errno == EINTR { continue }
            return false
        }
        off += r
    }
    return true
}

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

var signalSources: [DispatchSourceSignal] = []

/// Ends the process cleanly on a "q" line, the end of stdin, SIGINT or SIGTERM.
func onStopRequest(_ stop: @escaping () -> Void) {
    Thread.detachNewThread {
        while let line = readLine() {
            if line.trimmingCharacters(in: .whitespaces) == "q" { break }
        }
        stop()
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { stop() }
        src.resume()
        signalSources.append(src)
    }
}

func shareable() -> SCShareableContent {
    let sem = DispatchSemaphore(value: 0)
    var out: SCShareableContent?
    var err: Error?
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { c, e in
        out = c
        err = e
        sem.signal()
    }
    sem.wait()
    guard let c = out else {
        fail("no access to the screen (\(err?.localizedDescription ?? "unknown reason")). Allow Kingshot Recorder in "
             + "System Settings > Privacy & Security > Screen & System Audio Recording, then open it again.")
    }
    return c
}

/// A display's size in real pixels (SCDisplay gives points).
func pixelSize(_ d: SCDisplay) -> (Int, Int) {
    if let m = CGDisplayCopyDisplayMode(d.displayID) { return (m.pixelWidth, m.pixelHeight) }
    return (d.width, d.height)
}

/// Points -> pixels of the display a window is on (2 on a Retina screen).
func scale(of w: SCWindow, in c: SCShareableContent) -> CGFloat {
    let mid = CGPoint(x: w.frame.midX, y: w.frame.midY)
    let d = c.displays.first(where: { $0.frame.contains(mid) }) ?? c.displays.first
    guard let disp = d, disp.width > 0 else { return 1 }
    return CGFloat(pixelSize(disp).0) / CGFloat(disp.width)
}

// the system's own windows, as QuickRecorder leaves them out of its window list (SCContext.excludedApps)
let systemApps: Set<String> = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter",
                               "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager"]

func recordableWindows(_ c: SCShareableContent, excludePid: pid_t?) -> [SCWindow] {
    c.windows.filter {
        guard let app = $0.owningApplication, let title = $0.title, !title.isEmpty else { return false }
        return !systemApps.contains(app.bundleIdentifier) && $0.windowLayer == 0 && $0.frame.width > 40
            && $0.frame.height > 40 && app.processID != excludePid && !title.contains("Item-0")
    }
}

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func cmdList() {
    let c = shareable()
    let exclude = arg("--exclude-pid").flatMap { pid_t($0) }
    let screens: [[String: Any]] = c.displays.map { d in
        let (w, h) = pixelSize(d)
        return ["id": Int(d.displayID), "w": w, "h": h, "x": Int(d.frame.minX), "y": Int(d.frame.minY),
                "main": CGDisplayIsMain(d.displayID) != 0]
    }
    let windows: [[String: Any]] = recordableWindows(c, excludePid: exclude).map { w in
        let s = scale(of: w, in: c)
        return ["id": Int(w.windowID), "title": w.title ?? "", "app": w.owningApplication?.applicationName ?? "",
                "bundle": w.owningApplication?.bundleIdentifier ?? "", "pid": Int(w.owningApplication?.processID ?? 0),
                "w": Int(w.frame.width * s), "h": Int(w.frame.height * s)]
    }
    printJSON(["screens": screens, "windows": windows])
}

func cmdDevices() {
    var mic: Any = NSNull()
    if let d = AVCaptureDevice.default(for: .audio) { mic = d.localizedName }
    printJSON(["desktop": "System sound", "mic": mic])
}

// ------------------------------------------------------------------------------------------------ video

final class VideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let fps: Int
    let rgb: Bool
    let width: Int
    let height: Int
    var stream: SCStream!
    let lock = NSLock()
    var latest: CVPixelBuffer?
    var stopped = false
    var closed = false

    init(fps: Int, rgb: Bool, width: Int, height: Int) {
        self.fps = fps
        self.rgb = rgb
        self.width = width
        self.height = height
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let img = sb.imageBuffer else { return }
        // only complete frames carry a new picture (QuickRecorder: SCStreamFrameInfo.status == .complete)
        guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        lock.lock()
        latest = img
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        say("capture ended: \(error.localizedDescription)")   // the window was closed, or the screen went away
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// The picture packed tightly (no row padding) in the output format.
    func pack(_ pb: CVPixelBuffer, into out: inout [UInt8]) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = min(width, CVPixelBufferGetWidth(pb)), h = min(height, CVPixelBufferGetHeight(pb))
        out.withUnsafeMutableBytes { dst in
            let d = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
            if rgb {
                guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
                let src = base.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
                for y in 0..<h {
                    let row = src + y * bpr, o = d + y * width * 3
                    for x in 0..<w {
                        o[x * 3] = row[x * 4 + 2]
                        o[x * 3 + 1] = row[x * 4 + 1]
                        o[x * 3 + 2] = row[x * 4]
                    }
                }
            } else {
                for plane in 0..<2 {
                    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { return }
                    let src = base.assumingMemoryBound(to: UInt8.self)
                    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                    let rows = plane == 0 ? h : h / 2, start = plane == 0 ? 0 : width * height
                    for y in 0..<rows { memcpy(d + start + y * width, src + y * bpr, w - w % 2) }
                }
            }
        }
    }

    func run() -> Int32 {
        let frameBytes = rgb ? width * height * 3 : width * height * 3 / 2
        var buf = [UInt8](repeating: 0, count: frameBytes)
        if !rgb { for i in (width * height)..<frameBytes { buf[i] = 128 } }   // black, not green, until a picture comes
        let t_end = Date().addingTimeInterval(5)
        var first: CVPixelBuffer?
        while first == nil && Date() < t_end && !stopped && !closed {
            lock.lock()
            first = latest
            lock.unlock()
            if first == nil { usleep(5000) }
        }
        guard let pb0 = first else {
            say("ERROR: no picture from this source (is the window minimised, or is screen recording not allowed?)")
            return 1
        }
        pack(pb0, into: &buf)
        var shown: CVPixelBuffer? = pb0
        let t0 = CFAbsoluteTimeGetCurrent()
        say(String(format: "STARTED %.6f", Date().timeIntervalSince1970))
        var written = 0
        while true {
            lock.lock()
            let (pb, end) = (latest, stopped || closed)
            lock.unlock()
            if end { break }
            let due = Int((CFAbsoluteTimeGetCurrent() - t0) * Double(fps)) + 1    // frames that belong in the file by now
            if written >= due {
                let wait = t0 + Double(written) / Double(fps) - CFAbsoluteTimeGetCurrent()
                if wait > 0 { usleep(useconds_t(wait * 1e6)) }
                continue
            }
            if let pb = pb, pb !== shown {
                pack(pb, into: &buf)
                shown = pb
            }
            while written < due {                                  // running late: the same picture again, time stays exact
                let ok = buf.withUnsafeBytes { writeAll($0.baseAddress!, frameBytes) }
                if !ok {
                    say("ERROR: the encoder stopped taking video")
                    return 1
                }
                written += 1
            }
        }
        if closed { say("window closed") }
        return 0
    }
}

func cmdCapture() {
    let fps = Int(arg("--fps") ?? "60") ?? 60
    let rgb = arg("--format") == "rgb"
    let c = shareable()
    let filter: SCContentFilter
    var pw: Int, ph: Int
    if let s = arg("--display"), let id = UInt32(s) {
        guard let d = c.displays.first(where: { $0.displayID == id }) else { fail("screen \(id) not found") }
        let size = pixelSize(d)
        pw = size.0
        ph = size.1
        filter = SCContentFilter(display: d, excludingApplications: [], exceptingWindows: [])
    } else if let s = arg("--window"), let id = UInt32(s) {
        guard let w = c.windows.first(where: { $0.windowID == id }) else { fail("window \(id) not found (closed?)") }
        let sc = scale(of: w, in: c)
        pw = Int(w.frame.width * sc)
        ph = Int(w.frame.height * sc)
        filter = SCContentFilter(desktopIndependentWindow: w)
    } else {
        fail("capture needs --display ID or --window ID")
    }
    pw = max(pw, 2)
    ph = max(ph, 2)
    // the picture's size: inside --box (the preview), else portrait into 1080x1920 (the video's size) and landscape
    // at its own size, at most 4K - the GPU scales, so less goes through the pipe
    var s: Double
    if let box = arg("--box")?.split(separator: "x").compactMap({ Double($0) }), box.count == 2 {
        s = min(box[0] / Double(pw), box[1] / Double(ph), 1)
    } else if ph >= pw {
        s = min(1080 / Double(pw), 1920 / Double(ph))
    } else {
        s = min(1, 3840 / Double(pw), 2160 / Double(ph))
    }
    let w = max(2, Int(Double(pw) * s) / 2 * 2), h = max(2, Int(Double(ph) * s) / 2 * 2)

    let conf = SCStreamConfiguration()
    conf.width = w
    conf.height = h
    conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    conf.showsCursor = arg("--cursor") != "0"
    conf.queueDepth = 6
    conf.capturesAudio = false
    if rgb {
        conf.pixelFormat = kCVPixelFormatType_32BGRA
    } else {
        conf.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        conf.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
    }
    conf.colorSpaceName = CGColorSpace.sRGB
    if #available(macOS 14.0, *) {
        conf.ignoreShadowsSingleWindow = true
        conf.preservesAspectRatio = true
    }
    let cap = VideoCapture(fps: fps, rgb: rgb, width: w, height: h)
    cap.stream = SCStream(filter: filter, configuration: conf, delegate: cap)
    do {
        try cap.stream.addStreamOutput(cap, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ksrec.video"))
    } catch {
        fail("cannot capture: \(error.localizedDescription)")
    }
    say("SIZE \(w) \(h)")
    let started = DispatchSemaphore(value: 0)
    var startErr: Error?
    cap.stream.startCapture { e in
        startErr = e
        started.signal()
    }
    started.wait()
    if let e = startErr { fail("cannot start capturing: \(e.localizedDescription)") }
    onStopRequest {
        cap.lock.lock()
        cap.stopped = true
        cap.lock.unlock()
    }
    let rc = cap.run()
    let done = DispatchSemaphore(value: 0)
    cap.stream.stopCapture { _ in done.signal() }
    _ = done.wait(timeout: .now() + 3)
    close(1)                                                       // the encoder sees the end of the video
    if rc == 0 { say("DONE") }
    exit(rc)
}

// ------------------------------------------------------------------------------------------------ sound

let pcmLock = NSLock()

func writePCM(_ samples: [Int16]) {
    pcmLock.lock()
    defer { pcmLock.unlock() }
    let ok = samples.withUnsafeBytes { writeAll($0.baseAddress!, $0.count) }
    if !ok { exit(0) }                                            // the recorder went away
}

func clip(_ f: Float) -> Int16 { Int16(max(-1, min(1, f)) * 32767) }

/// Desktop sound: an audio-only ScreenCaptureKit stream of the whole system (QuickRecorder's "audio" stream type).
final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream!

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let fmt = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let n = CMSampleBufferGetNumSamples(sb)
        var size = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let abl = AudioBufferList.allocate(maximumBuffers: max(1, size / MemoryLayout<AudioBuffer>.stride))
        defer { free(abl.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil,
            bufferListOut: abl.unsafeMutablePointer, bufferListSize: size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block) == noErr else { return }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let ch = Int(asbd.mChannelsPerFrame)
        guard isFloat, asbd.mBitsPerChannel == 32, ch >= 1 else { return }
        var out = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            for c in 0..<2 {
                let sc = min(c, ch - 1)                               // mono: the same sound on both sides
                let f: Float
                if interleaved {
                    f = abl[0].mData!.assumingMemoryBound(to: Float.self)[i * ch + sc]
                } else {
                    f = abl[min(sc, abl.count - 1)].mData!.assumingMemoryBound(to: Float.self)[i]
                }
                out[i * 2 + c] = clip(f)
            }
        }
        writePCM(out)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        say("ERROR: desktop sound stopped: \(error.localizedDescription)")
        exit(1)
    }
}

func cmdAudio() {
    let source = arg("--source") ?? "system"
    if source == "mic" {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000,
              channels: 2, interleaved: true), let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            fail("no microphone")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 48000 / inFmt.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            var given = false
            var err: NSError?
            _ = conv.convert(to: out, error: &err) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, out.frameLength > 0, let p = out.int16ChannelData else { return }
            writePCM(Array(UnsafeBufferPointer(start: p[0], count: Int(out.frameLength) * 2)))
        }
        do { try engine.start() } catch { fail("cannot start the microphone: \(error.localizedDescription)") }
        say("STARTED")
        onStopRequest {
            engine.stop()
            exit(0)
        }
        dispatchMain()
    }
    let c = shareable()
    guard let display = c.displays.first else { fail("no screen") }
    let conf = SCStreamConfiguration()
    conf.width = 2                                                // (QuickRecorder: the picture of an audio-only stream)
    conf.height = 2
    conf.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    conf.capturesAudio = true
    conf.sampleRate = 48000
    conf.channelCount = 2
    conf.excludesCurrentProcessAudio = true
    let sys = SystemAudio()
    sys.stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                          configuration: conf, delegate: sys)
    do {
        try sys.stream.addStreamOutput(sys, type: .audio, sampleHandlerQueue: DispatchQueue(label: "ksrec.audio"))
    } catch {
        fail("cannot capture the desktop sound: \(error.localizedDescription)")
    }
    let started = DispatchSemaphore(value: 0)
    var startErr: Error?
    sys.stream.startCapture { e in
        startErr = e
        started.signal()
    }
    started.wait()
    if let e = startErr { fail("cannot start the desktop sound: \(e.localizedDescription)") }
    say("STARTED")
    onStopRequest {
        sys.stream.stopCapture { _ in exit(0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
    }
    dispatchMain()
}

// ------------------------------------------------------------------------------------------------ main

switch CommandLine.arguments.dropFirst().first {
case "list": cmdList()
case "devices": cmdDevices()
case "capture": cmdCapture()
case "audio": cmdAudio()
default:
    say("usage: ksrec list | devices | capture (--display ID | --window ID) [--fps N] [--format nv12|rgb] [--box WxH] "
        + "| audio --source system|mic")
    exit(2)
}
