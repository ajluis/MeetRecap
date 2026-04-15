import Foundation
import AVFoundation
import CoreAudio
import Combine

struct AudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let uid: String
    let isDefault: Bool
    let channelCount: Int
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedDevice: AudioDevice?
    @Published var systemAudioAvailable: Bool = false
    
    private var deviceListObserver: NSObjectProtocol?
    
    init() {
        refreshDevices()
        setupDeviceChangeObserver()
    }
    
    deinit {
        if let observer = deviceListObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func refreshDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        
        var devices: [AudioDevice] = []
        
        // Get default input device
        var defaultDeviceID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0, nil,
            &defaultSize,
            &defaultDeviceID
        )
        
        // Enumerate all devices
        for device in discoverySession.devices {
            let formatDesc = device.activeFormat.formatDescription
            let channels: Int
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                channels = Int(asbd.pointee.mChannelsPerFrame)
            } else {
                channels = 1
            }
            
            let audioDevice = AudioDevice(
                id: device.uniqueID,
                name: device.localizedName,
                uid: device.uniqueID,
                isDefault: device.uniqueID == String(defaultDeviceID),
                channelCount: channels
            )
            devices.append(audioDevice)
        }
        
        // Also check for system audio (BlackHole or aggregate devices)
        var systemAudioFound = false
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &propertySize
        ) == noErr else {
            inputDevices = devices
            return
        }
        
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            inputDevices = devices
            return
        }
        
        for deviceID in deviceIDs {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var deviceName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            
            guard AudioObjectGetPropertyData(
                deviceID,
                &nameAddress, 0, nil,
                &nameSize,
                &deviceName
            ) == noErr else { continue }
            
            let name = deviceName as String
            
            // Check if this is a virtual/system audio device
            if name.lowercased().contains("blackhole") || 
               name.lowercased().contains("aggregate") ||
               name.lowercased().contains("multi-output") {
                systemAudioFound = true
                
                var uidAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                
                var deviceUID: CFString = "" as CFString
                var uidSize = UInt32(MemoryLayout<CFString>.size)
                
                if AudioObjectGetPropertyData(
                    deviceID,
                    &uidAddress, 0, nil,
                    &uidSize,
                    &deviceUID
                ) == noErr {
                    let uid = deviceUID as String
                    if !devices.contains(where: { $0.uid == uid }) {
                        devices.append(AudioDevice(
                            id: uid,
                            name: name,
                            uid: uid,
                            isDefault: false,
                            channelCount: 2
                        ))
                    }
                }
            }
        }
        
        inputDevices = devices
        systemAudioAvailable = systemAudioFound
        
        // Set default selection - prefer system audio if available, otherwise default mic
        if selectedDevice == nil {
            if systemAudioAvailable, let systemDevice = devices.first(where: { $0.name.lowercased().contains("blackhole") || $0.name.lowercased().contains("aggregate") }) {
                selectedDevice = systemDevice
            } else if let defaultDevice = devices.first(where: { $0.isDefault }) {
                selectedDevice = defaultDevice
            }
        }
    }
    
    private func setupDeviceChangeObserver() {
        deviceListObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
    }
}
