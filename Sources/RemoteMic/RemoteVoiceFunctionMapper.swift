import Foundation
import IOKit.hid
import IOKit.hidsystem

struct HIDUsageMapping: Equatable {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    let source: UInt64
    let destination: UInt64

    init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    init?(property: [String: NSNumber]) {
        guard let source = property[Self.sourceKey],
              let destination = property[Self.destinationKey]
        else { return nil }
        self.source = source.uint64Value
        self.destination = destination.uint64Value
    }

    var property: [String: NSNumber] {
        [
            Self.sourceKey: NSNumber(value: source),
            Self.destinationKey: NSNumber(value: destination),
        ]
    }
}

enum RemoteVoiceFunctionMappingPolicy {
    // RC003 exposes its microphone button as keyboard F5 (usage page 7,
    // usage 0x3e). macOS represents the laptop Fn/Globe key as the Apple
    // vendor top-case usage (usage page 0xff, usage 3).
    static let remoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0000_00FF_0000_0003
    )

    // Typeless 等点按式语音工具会被 Fn 长按干扰；此模式下彻底丢弃语音键的
    // 按键事件（目标 usage 0），Fn 点按改由软件注入，避免物理按键按住时干扰注入。
    static let neutralRemoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0
    )

    // RC003 exposes its power button as keyboard Power (usage 0x66).
    // Remap it to harmless F20 before macOS can turn it into a sleep event.
    static let suppressedRemotePowerKey = HIDUsageMapping(
        source: 0x0000_0007_0000_0066,
        destination: 0x0000_0007_0000_006F
    )

    // With custom mapping on, every other remote button maps to usage 0, so macOS
    // creates no native key event while HIDRemoteMonitor still reads the raw reports.
    // This replaces a global keyboard event tap, because RC003 cannot be seized.
    static let mutedRemoteButtonSources: [UInt64] = RemoteButton.allCases
        .filter { $0 != .power }
        .map { 0x0000_0007_0000_0000 | UInt64($0.hidUsage) }

    static var mutedRemoteButtonMappings: [HIDUsageMapping] {
        mutedRemoteButtonSources.map { HIDUsageMapping(source: $0, destination: 0) }
    }

    private static var managedSources: Set<UInt64> {
        Set([remoteVoiceKey.source, suppressedRemotePowerKey.source] + mutedRemoteButtonSources)
    }

    static func applying(
        to existing: [HIDUsageMapping],
        voiceMapping: HIDUsageMapping = remoteVoiceKey,
        powerMapping: HIDUsageMapping? = nil,
        buttonMappings: [HIDUsageMapping] = []
    ) -> [HIDUsageMapping] {
        let managed = managedSources
        var desired = existing.filter { !managed.contains($0.source) } + [voiceMapping]
        if let powerMapping {
            desired.append(powerMapping)
        }
        return desired + buttonMappings
    }

    static func restoring(
        originalVoiceMapping: HIDUsageMapping?,
        originalPowerMapping: HIDUsageMapping?,
        originalButtonMappings: [HIDUsageMapping] = [],
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        let managed = managedSources
        var restored = current.filter { !managed.contains($0.source) }
        if let originalVoiceMapping {
            restored.append(originalVoiceMapping)
        }
        if let originalPowerMapping {
            restored.append(originalPowerMapping)
        }
        return restored + originalButtonMappings
    }
}

struct RemoteVoiceMappingService {
    let registryID: UInt64?
    private let retainedOwner: AnyObject?
    let readMappings: () -> [HIDUsageMapping]
    let setMappings: ([HIDUsageMapping]) -> Bool

    init(
        registryID: UInt64?,
        retainedOwner: AnyObject? = nil,
        readMappings: @escaping () -> [HIDUsageMapping],
        setMappings: @escaping ([HIDUsageMapping]) -> Bool
    ) {
        self.registryID = registryID
        self.retainedOwner = retainedOwner
        self.readMappings = readMappings
        self.setMappings = setMappings
    }
}

final class RemoteVoiceFunctionMapper {
    typealias ServiceProvider = () -> [RemoteVoiceMappingService]

    private static let vendorID = 0x2717
    private static let productID = 0x32B8
    private static let mappingProperty = "UserKeyMapping" as CFString

    private struct OriginalMappings {
        let voice: HIDUsageMapping?
        let power: HIDUsageMapping?
        let buttons: [HIDUsageMapping]
    }

    private let serviceProvider: ServiceProvider
    private var originalMappings: [UInt64: OriginalMappings] = [:]
    private(set) var isApplied = false
    private(set) var isPowerKeySuppressed = false
    /// Every button except power and voice is muted on all matched services.
    private(set) var areRemoteButtonsMuted = false
    private(set) var isVoiceKeyNeutralized = false
    private var lastRequest: (suppressPowerKey: Bool, muteRemoteButtons: Bool, neutralizeVoiceKey: Bool)?

    init(serviceProvider: @escaping ServiceProvider = RemoteVoiceFunctionMapper.systemServices) {
        self.serviceProvider = serviceProvider
    }

    /// A reconnected remote gets a new HID service without these mappings.
    @discardableResult
    func reapply() -> Bool {
        guard let lastRequest else { return false }
        return apply(
            suppressPowerKey: lastRequest.suppressPowerKey,
            muteRemoteButtons: lastRequest.muteRemoteButtons,
            neutralizeVoiceKey: lastRequest.neutralizeVoiceKey
        )
    }

    @discardableResult
    func apply(
        suppressPowerKey: Bool = false,
        muteRemoteButtons: Bool = false,
        neutralizeVoiceKey: Bool = false
    ) -> Bool {
        lastRequest = (suppressPowerKey, muteRemoteButtons, neutralizeVoiceKey)
        let services = serviceProvider()
        let matchedCount = services.count
        guard matchedCount > 0 else {
            resetAppliedState()
            AppLogger.shared.write(
                "VOICE FN MAPPING applied=false neutralized=false power_suppressed=false buttons_muted=false matched=0"
            )
            return false
        }

        var snapshots: [Int: [HIDUsageMapping]] = [:]
        var appliedIndices: [Int] = []
        var newlyStoredRegistryIDs = Set<UInt64>()

        for (index, service) in services.enumerated() {
            guard let registryID = service.registryID else {
                if neutralizeVoiceKey {
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        matchedCount: matchedCount
                    )
                    return false
                }
                continue
            }
            let current = service.readMappings()
            snapshots[index] = current
            if originalMappings[registryID] == nil {
                let currentPower = current.first {
                    $0.source == RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey.source
                }
                originalMappings[registryID] = OriginalMappings(
                    voice: current.first {
                        $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
                    },
                    power: currentPower == RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                        ? nil
                        : currentPower,
                    // A mute left behind by a run that did not exit cleanly is ours, not an original mapping.
                    buttons: current.filter {
                        RemoteVoiceFunctionMappingPolicy.mutedRemoteButtonSources.contains($0.source) &&
                            $0.destination != 0
                    }
                )
                newlyStoredRegistryIDs.insert(registryID)
            }
            let desired = RemoteVoiceFunctionMappingPolicy.applying(
                to: current,
                voiceMapping: neutralizeVoiceKey
                    ? RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey
                    : RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                powerMapping: suppressPowerKey
                    ? RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                    : originalMappings[registryID]?.power,
                buttonMappings: muteRemoteButtons
                    ? RemoteVoiceFunctionMappingPolicy.mutedRemoteButtonMappings
                    : originalMappings[registryID]?.buttons ?? []
            )
            guard service.setMappings(desired) else {
                if neutralizeVoiceKey {
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        matchedCount: matchedCount
                    )
                    return false
                }
                continue
            }
            appliedIndices.append(index)
        }

        let appliedCount = appliedIndices.count
        let allTargetsApplied = appliedCount == matchedCount
        isApplied = neutralizeVoiceKey ? allTargetsApplied : appliedCount > 0
        isVoiceKeyNeutralized = neutralizeVoiceKey && allTargetsApplied
        isPowerKeySuppressed = suppressPowerKey && allTargetsApplied
        areRemoteButtonsMuted = muteRemoteButtons && allTargetsApplied
        AppLogger.shared.write(
            "VOICE FN MAPPING applied=\(isApplied) neutralized=\(isVoiceKeyNeutralized) " +
                "power_suppressed=\(isPowerKeySuppressed) buttons_muted=\(areRemoteButtonsMuted) " +
                "matched=\(matchedCount) applied=\(appliedCount)"
        )
        return isApplied
    }

    func restore() {
        lastRequest = nil
        guard !originalMappings.isEmpty else {
            resetAppliedState()
            return
        }

        let services = serviceProvider()
        var restoredCount = 0
        for service in services {
            guard let registryID = service.registryID,
                  let original = originalMappings[registryID]
            else { continue }
            let restored = RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: original.voice,
                originalPowerMapping: original.power,
                originalButtonMappings: original.buttons,
                in: service.readMappings()
            )
            if service.setMappings(restored) {
                restoredCount += 1
            }
        }

        originalMappings.removeAll()
        resetAppliedState()
        AppLogger.shared.write("VOICE FN MAPPING restored=\(restoredCount)")
    }

    private func rollback(
        services: [RemoteVoiceMappingService],
        snapshots: [Int: [HIDUsageMapping]],
        appliedIndices: [Int],
        newlyStoredRegistryIDs: Set<UInt64>,
        matchedCount: Int
    ) {
        var rollbackCount = 0
        var registryIDsNeedingRestore = Set<UInt64>()
        for index in appliedIndices {
            guard let snapshot = snapshots[index] else { continue }
            if services[index].setMappings(snapshot) {
                rollbackCount += 1
            } else if let registryID = services[index].registryID {
                registryIDsNeedingRestore.insert(registryID)
            }
        }
        newlyStoredRegistryIDs
            .subtracting(registryIDsNeedingRestore)
            .forEach { originalMappings.removeValue(forKey: $0) }
        resetAppliedState()
        AppLogger.shared.write(
            "VOICE FN MAPPING rollback matched=\(matchedCount) applied=\(appliedIndices.count) " +
                "restored=\(rollbackCount)"
        )
    }

    private func resetAppliedState() {
        isApplied = false
        isPowerKeySuppressed = false
        areRemoteButtonsMuted = false
        isVoiceKeyNeutralized = false
    }

    private static func systemServices() -> [RemoteVoiceMappingService] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.filter(isTarget).map { service in
            RemoteVoiceMappingService(
                registryID: registryID(service),
                retainedOwner: client,
                readMappings: { readMappings(service) },
                setMappings: { mappings in
                    IOHIDServiceClientSetProperty(
                        service,
                        mappingProperty,
                        mappings.map(\.property) as CFArray
                    )
                }
            )
        }
    }

    private static func isTarget(_ service: IOHIDServiceClient) -> Bool {
        let vendor = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDVendorIDKey as CFString
        ) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDProductIDKey as CFString
        ) as? NSNumber
        return vendor?.intValue == vendorID && product?.intValue == productID
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private static func readMappings(_ service: IOHIDServiceClient) -> [HIDUsageMapping] {
        let properties = IOHIDServiceClientCopyProperty(
            service,
            mappingProperty
        ) as? [[String: NSNumber]] ?? []
        return properties.compactMap(HIDUsageMapping.init(property:))
    }
}
