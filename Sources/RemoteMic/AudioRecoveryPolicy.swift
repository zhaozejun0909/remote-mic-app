// Adapted from upstream #524, including the active-audio and hardware-change guards.
enum AudioEngineConfigurationChangePolicy {
    static func needsRecovery(
        boundToSelectedDevice: Bool?,
        configurationHealthy: Bool,
        hasActiveAudioSource: Bool,
        pendingVoiceBufferCount: Int
    ) -> Bool {
        guard boundToSelectedDevice == true else { return true }
        if configurationHealthy { return false }
        return hasActiveAudioSource || pendingVoiceBufferCount > 0
    }
}

struct AudioRecoveryCoalescingState {
    private var includesHardwareChange = false

    mutating func record(reason: String) {
        includesHardwareChange = includesHardwareChange || reason == "hardware_change"
    }

    mutating func consumeReason(lastReason: String) -> String {
        defer { reset() }
        return includesHardwareChange ? "hardware_change" : lastReason
    }

    mutating func reset() {
        includesHardwareChange = false
    }
}
