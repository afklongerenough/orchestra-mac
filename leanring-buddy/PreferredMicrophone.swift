//
//  PreferredMicrophone.swift
//  leanring-buddy
//
//  With Bluetooth headphones (AirPods etc.), Orchestra listens through the
//  Mac's built-in microphone instead of the headphones' own mic.
//
//  Why: the moment any app opens a Bluetooth headset's mic, macOS switches
//  the headphones to "headset mode" (low-quality call audio). Music apps
//  usually pause on that switch, music sounds worse, and macOS's echo
//  cancellation can deliver plain silence from that mic, so Orchestra hears
//  nothing. With the built-in mic the headphones stay in normal high-quality
//  mode, the music keeps playing, and there's no echo to cancel (the sound
//  is in the user's ears, not the room).
//
//  Every Orchestra mic (push-to-talk, Live, wake word, notes) asks this
//  helper before it starts. A menu setting turns it off for people who want
//  to talk through the headphones' mic (e.g. away from the laptop).
//

import AVFoundation
import CoreAudio
import Foundation

enum PreferredMicrophone {
    static let useBuiltInMicWithBluetoothDefaultsKey = "useBuiltInMicWithBluetoothHeadphones"

    /// On by default: keeps music playing and Orchestra hearing the user.
    static var usesBuiltInMicWithBluetoothHeadphones: Bool {
        get { UserDefaults.standard.object(forKey: useBuiltInMicWithBluetoothDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: useBuiltInMicWithBluetoothDefaultsKey) }
    }

    /// True when the system's default microphone is a Bluetooth headset's mic.
    static var defaultInputIsBluetooth: Bool {
        guard let defaultInputDeviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice) else { return false }
        return isBluetooth(deviceID: defaultInputDeviceID)
    }

    /// True when sound is going to Bluetooth headphones (or a Bluetooth headset).
    static var defaultOutputIsBluetooth: Bool {
        guard let defaultOutputDeviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice) else { return false }
        return isBluetooth(deviceID: defaultOutputDeviceID)
    }

    /// Both the mic and the sound are Bluetooth, i.e. the user is wearing
    /// headphones: no echo for the mic to pick up. (A Bluetooth mic with the
    /// Mac's speakers is NOT this case: the speakers echo, so the normal
    /// echo-cancelled setup is kept.)
    static var isWearingBluetoothHeadset: Bool {
        defaultInputIsBluetooth && defaultOutputIsBluetooth
    }

    /// The built-in mic to use instead of a Bluetooth headset's mic, or nil to
    /// keep the system default (setting off, not wearing Bluetooth headphones,
    /// or no built-in mic, e.g. a Mac mini).
    static func builtInMicrophoneReplacingBluetooth() -> AudioDeviceID? {
        guard usesBuiltInMicWithBluetoothHeadphones, isWearingBluetoothHeadset else { return nil }
        return builtInMicrophoneDeviceID()
    }

    /// Points an engine's input at the built-in mic when that's the better
    /// choice. Call before reading the input node's format or installing a tap.
    /// Returns true when the built-in mic is now in use.
    @discardableResult
    static func applyPreferredMicrophone(to audioEngine: AVAudioEngine, logLabel: String) -> Bool {
        guard let builtInMicrophoneDeviceID = builtInMicrophoneReplacingBluetooth() else {
            // A reused engine (push-to-talk keeps one) may still point at the
            // built-in mic from earlier: follow the system default again.
            if let defaultInputDeviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice),
               audioEngine.inputNode.auAudioUnit.deviceID != defaultInputDeviceID {
                do {
                    try audioEngine.inputNode.auAudioUnit.setDeviceID(defaultInputDeviceID)
                } catch {
                    OrchestraLog.write("🎧 \(logLabel): couldn't switch back to the default mic (\(error.localizedDescription))")
                }
            }
            return false
        }
        if audioEngine.inputNode.auAudioUnit.deviceID == builtInMicrophoneDeviceID { return true }
        do {
            try audioEngine.inputNode.auAudioUnit.setDeviceID(builtInMicrophoneDeviceID)
            OrchestraLog.write("🎧 \(logLabel): Bluetooth headphones on, listening with the Mac's built-in mic")
            return true
        } catch {
            OrchestraLog.write("🎧 \(logLabel): couldn't switch to the built-in mic (\(error.localizedDescription)); using the headphones' mic")
            return false
        }
    }

    // MARK: - Core Audio lookups

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let lookupStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceID)
        return lookupStatus == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transportTypeValue = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let lookupStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &transportTypeValue)
        return lookupStatus == noErr ? transportTypeValue : nil
    }

    private static func isBluetooth(deviceID: AudioDeviceID) -> Bool {
        let deviceTransportType = transportType(of: deviceID)
        return deviceTransportType == kAudioDeviceTransportTypeBluetooth
            || deviceTransportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }
        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer) == noErr else { return 0 }
        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        return audioBufferList.reduce(0) { channelTotal, audioBuffer in channelTotal + Int(audioBuffer.mNumberChannels) }
    }

    /// The Mac's own microphone (built-in transport with input channels).
    private static func builtInMicrophoneDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return nil }
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return nil }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return nil }
        return deviceIDs.first { deviceID in
            transportType(of: deviceID) == kAudioDeviceTransportTypeBuiltIn && inputChannelCount(of: deviceID) > 0
        }
    }
}
