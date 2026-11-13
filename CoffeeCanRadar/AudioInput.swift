import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let sampleRate: Double

    var looksLikeUCA222: Bool {
        name.range(of: "USB Audio CODEC|UCA|Behringer|Burr-Brown",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum AudioDevices {
    static func inputs() -> [AudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ch = inputChannelCount(id)
            guard ch > 0 else { return nil }
            return AudioDeviceInfo(id: id, name: name(id) ?? "Device \(id)", inputChannels: ch,
                                   sampleRate: nominalSampleRate(id))
        }
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func name(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : 0
    }
}

struct AudioError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (OSStatus \(status))" }
}

private func check(_ status: OSStatus, _ step: String) throws {
    if status != noErr { throw AudioError(step: step, status: status) }
}

/// Captures stereo float samples from one input device with an AUHAL unit.
final class AudioInput {
    /// Called on the Core Audio I/O thread with (left, right) blocks.
    var onSamples: (([Float], [Float]) -> Void)?
    private(set) var sampleRate: Double = 0
    private(set) var deviceChannels = 0

    private var unit: AudioUnit?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var channelData: [UnsafeMutablePointer<Float>] = []
    private var clientChannels = 2
    private let maxFrames = 8192

    deinit { stop() }

    func prepare(deviceID: AudioDeviceID) throws {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioError(step: "Finding the HAL audio unit", status: -1)
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &newUnit), "Creating the audio unit")
        guard let au = newUnit else { throw AudioError(step: "Creating the audio unit", status: -1) }
        unit = au

        var one: UInt32 = 1, zero: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32),
                  "Enabling input")
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32),
                  "Disabling output")
        var dev = deviceID
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "Selecting the input device")

        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size),
                  "Reading the device format")
        sampleRate = hw.mSampleRate
        deviceChannels = Int(hw.mChannelsPerFrame)
        clientChannels = deviceChannels >= 2 ? 2 : 1

        var fmt = AudioStreamBasicDescription(
            mSampleRate: hw.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(clientChannels), mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, size),
                  "Setting the capture format")
        var maxF = UInt32(maxFrames)
        _ = AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF, u32)

        let abl = AudioBufferList.allocate(maximumBuffers: clientChannels)
        channelData = (0..<clientChannels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: maxFrames) }
        for c in 0..<clientChannels {
            abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4),
                                 mData: UnsafeMutableRawPointer(channelData[c]))
        }
        bufferList = abl

        var cb = AURenderCallbackStruct(inputProc: audioInputCallback,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "Installing the input callback")
        try check(AudioUnitInitialize(au), "Initializing the audio unit")
    }

    func start() throws {
        guard let unit else { throw AudioError(step: "Starting capture", status: -1) }
        try check(AudioOutputUnitStart(unit), "Starting capture")
    }

    func stop() {
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        unit = nil
        if let abl = bufferList { free(abl.unsafeMutablePointer) }
        bufferList = nil
        channelData.forEach { $0.deallocate() }
        channelData = []
    }

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, let abl = bufferList, Int(frames) <= maxFrames else { return noErr }
        for c in 0..<clientChannels {
            abl[c].mDataByteSize = frames * 4
            abl[c].mData = UnsafeMutableRawPointer(channelData[c])
        }
        let status = AudioUnitRender(unit, flags, ts, bus, frames, abl.unsafeMutablePointer)
        guard status == noErr else { return status }
        let n = Int(frames)
        let left = Array(UnsafeBufferPointer(start: channelData[0], count: n))
        let right = clientChannels > 1 ? Array(UnsafeBufferPointer(start: channelData[1], count: n)) : left
        onSamples?(left, right)
        return noErr
    }
}

private func audioInputCallback(refCon: UnsafeMutableRawPointer,
                                flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                ts: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32,
                                data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<AudioInput>.fromOpaque(refCon).takeUnretainedValue().render(flags, ts, bus, frames)
}

// MARK: - Simulator

/// Synthetic sync + IF signal for testing without the radar: a smooth, AC-coupled,
/// inverted square wave whose period is not a whole number of samples, and beat tones
/// for targets at 8 m (fixed), 13-37 m (moving) and 60 m.
struct SyncIFSimulator {
    let fs: Double = 48000
    private var hp = 0.0, hpPrev = 0.0

    mutating func generate(start: Int, count: Int, params: RadarParams) -> ([Float], [Float]) {
        let tp = params.tpMs * 1e-3
        let bw = max(1, (params.fStopMHz - params.fStartMHz) * 1e6)
        let period = 2 * tp * fs * 1.000371
        let aHP = exp(-2 * Double.pi * 5 / fs)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for k in 0..<count {
            let s = Double(start + k)
            // smooth square wave (edges ~3 samples wide, negligible energy above Nyquist,
            // like the output of the ADC anti-alias filter), then AC coupled
            let sq = tanh(100 * sin(2 * Double.pi * s / period))
            hp = aHP * (hp + sq - hpPrev)
            hpPrev = sq
            left[k] = Float(-0.45 * hp)

            let ph = s.truncatingRemainder(dividingBy: period) / period
            let up = ph < 0.5
            let tr = (up ? ph : ph - 0.5) * period / fs
            let fb = { (r: Double) in 2 * r * bw / (speedOfLight * tp) * (up ? 1 : 0.92) }
            // walking pace (up to 1.1 m/s), inside the ±1.5 m/s the 50 Hz pulse rate can measure
            let r2 = 25 + 12 * sin(2 * Double.pi * 0.015 * s / fs)
            let carrier = 4 * Double.pi * params.fStartMHz * 1e6 * r2 / speedOfLight   // two-way phase: Doppler
            let v = 0.08 * sin(2 * Double.pi * fb(8) * tr + 0.3)
                + 0.03 * sin(2 * Double.pi * fb(r2) * tr + 1.1 + carrier)
                + 0.01 * sin(2 * Double.pi * fb(60) * tr)
                + 0.15 * (up ? tr / tp : 1 - tr / tp)
                + 0.002 * Double.random(in: -0.5...0.5)
            right[k] = Float(-v)
        }
        return (left, right)
    }
}

/// Feeds the simulator at real-time pace.
final class SimulatedSource {
    var onSamples: (([Float], [Float]) -> Void)?
    private var timer: DispatchSourceTimer?
    private var sim = SyncIFSimulator()
    private var sent = 0
    private var startTime = DispatchTime.now()
    private let params: RadarParams

    init(params: RadarParams) { self.params = params }

    func start(queue: DispatchQueue) {
        startTime = .now()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1e9
        let due = Int(elapsed * sim.fs)
        while sent < due {
            let n = min(2048, due - sent)
            let (l, r) = sim.generate(start: sent, count: n, params: params)
            if params.syncOnRight { onSamples?(r, l) } else { onSamples?(l, r) }   // follow the sync-input setting
            sent += n
        }
    }
}
