import Combine
import Foundation

enum AppConfigurationError: Error {
    case unsupportedVersion
    case invalidValues
}

private struct PersonalizedConfiguration: Codable {
    let formatVersion: Int
    let gainDB: Double
    let selectedAudioDeviceUID: String
    let customMappingEnabled: Bool
    let buttonBindings: [String: ButtonAction]
    let buttonShortcuts: [String: CustomKeyboardShortcut]
    let buttonApplicationProfileIDs: [String: UUID]?
    let secondaryButtonBindings: [String: [String: ConfiguredButtonAction]]
    let customApplicationProfiles: [CustomApplicationProfile]?
    let applicationLanguage: AppLanguage
    let showDockIcon: Bool
    let openMainWindowAtLaunch: Bool?
    let checksForPreReleaseUpdates: Bool?
    let experimentalContinuousRecordingEnabled: Bool?
    let voiceFnTapModeEnabled: Bool?
    let continuousRecordingPowerBindingBackup: ConfiguredButtonAction?
}

enum UsageEventSource: String, Codable, CaseIterable, Hashable {
    case bluetoothRemote = "bluetooth_remote"
    case nearbyPhone = "nearby_phone"
    case webRemote = "web_remote"
    case unknown
}

final class AppSettings: ObservableObject {
    static let continuousRecordingExperimentAvailable = false
    static let currentOnboardingVersion = 1

    private enum Keys {
        static let gainDB = "gainDB"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let customMappingEnabled = "customMappingEnabled"
        static let legacyExclusiveHID = "exclusiveHID"
        static let buttonBindings = "buttonBindings"
        static let buttonShortcuts = "buttonShortcuts"
        static let buttonApplicationProfileIDs = "buttonApplicationProfileIDs"
        static let secondaryButtonBindings = "secondaryButtonBindings"
        static let customApplicationProfiles = "customApplicationProfiles"
        static let peripheralIdentifier = "peripheralIdentifier"
        static let remoteDeviceProfiles = "remoteDeviceProfiles"
        static let selectedRemoteProfileID = "selectedRemoteProfileID"
        static let applicationLanguage = "applicationLanguage"
        static let showDockIcon = "showDockIcon"
        static let openMainWindowAtLaunch = "openMainWindowAtLaunch"
        static let checksForPreReleaseUpdates = "checksForPreReleaseUpdates"
        static let experimentalContinuousRecordingEnabled = "experimentalContinuousRecordingEnabled"
        static let voiceFnTapModeEnabled = "voiceFnTapModeEnabled"
        static let continuousRecordingPowerBindingBackup = "continuousRecordingPowerBindingBackup"
        static let lastLaunchedBuild = "launch.lastLaunchedBuild"
        /// Usage statistics were removed; these keys are only deleted on launch.
        static let retiredUsageStatistics = [
            "usage.totalButtonPressCount",
            "usage.totalVoiceDuration",
            "usage.dailyStatistics",
            "usage.voiceSessionRanking",
        ]
        static let trustedPhoneIdentityFingerprints = "security.trustedPhoneIdentityFingerprints"
        static let onboardingCompletedVersion = "onboarding.completedVersion"
        static let onboardingStep = "onboarding.step"
        static let onboardingVoiceTool = "onboarding.voiceTool"
    }

    private let defaults: UserDefaults

    @Published var gainDB: Double {
        didSet { defaults.set(gainDB, forKey: Keys.gainDB) }
    }

    @Published var selectedAudioDeviceUID: String {
        didSet { defaults.set(selectedAudioDeviceUID, forKey: Keys.selectedAudioDeviceUID) }
    }

    @Published var customMappingEnabled: Bool {
        didSet { defaults.set(customMappingEnabled, forKey: Keys.customMappingEnabled) }
    }

    @Published var buttonBindings: [RemoteButton: ButtonAction] {
        didSet {
            saveBindings()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonShortcuts: [RemoteButton: CustomKeyboardShortcut] {
        didSet {
            saveShortcuts()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonApplicationProfileIDs: [RemoteButton: UUID] {
        didSet {
            saveButtonApplicationProfileIDs()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] {
        didSet {
            saveSecondaryBindings()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published private(set) var customApplicationProfiles: [CustomApplicationProfile] {
        didSet { saveCustomApplicationProfiles() }
    }

    @Published private(set) var remoteDeviceProfiles: [RemoteDeviceProfile] {
        didSet { saveRemoteDeviceProfiles() }
    }

    @Published private(set) var selectedRemoteProfileID: UUID? {
        didSet { defaults.set(selectedRemoteProfileID?.uuidString, forKey: Keys.selectedRemoteProfileID) }
    }

    @Published var applicationLanguage: AppLanguage {
        didSet { defaults.set(applicationLanguage.rawValue, forKey: Keys.applicationLanguage) }
    }

    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }

    @Published var openMainWindowAtLaunch: Bool {
        didSet { defaults.set(openMainWindowAtLaunch, forKey: Keys.openMainWindowAtLaunch) }
    }

    @Published var checksForPreReleaseUpdates: Bool {
        didSet {
            defaults.set(checksForPreReleaseUpdates, forKey: Keys.checksForPreReleaseUpdates)
        }
    }

    @Published private(set) var experimentalContinuousRecordingEnabled: Bool {
        didSet {
            defaults.set(
                experimentalContinuousRecordingEnabled,
                forKey: Keys.experimentalContinuousRecordingEnabled
            )
        }
    }

    @Published var voiceFnTapModeEnabled: Bool {
        didSet {
            defaults.set(
                voiceFnTapModeEnabled,
                forKey: Keys.voiceFnTapModeEnabled
            )
        }
    }

    private var continuousRecordingPowerBindingBackup: ConfiguredButtonAction? {
        didSet { saveContinuousRecordingPowerBindingBackup() }
    }

    private var isLoadingRemoteProfile = false

    @Published private(set) var trustedPhoneIdentityFingerprints: Set<String> {
        didSet {
            defaults.set(
                trustedPhoneIdentityFingerprints.sorted(),
                forKey: Keys.trustedPhoneIdentityFingerprints
            )
        }
    }

    @Published private(set) var onboardingCompletedVersion: Int {
        didSet {
            defaults.set(onboardingCompletedVersion, forKey: Keys.onboardingCompletedVersion)
        }
    }

    @Published private(set) var onboardingStep: OnboardingStep {
        didSet { defaults.set(onboardingStep.rawValue, forKey: Keys.onboardingStep) }
    }

    @Published private(set) var onboardingVoiceTool: OnboardingVoiceTool {
        didSet { defaults.set(onboardingVoiceTool.rawValue, forKey: Keys.onboardingVoiceTool) }
    }

    var isOnboardingComplete: Bool {
        onboardingCompletedVersion >= Self.currentOnboardingVersion
    }

    var peripheralIdentifier: UUID? {
        get {
            guard let raw = defaults.string(forKey: Keys.peripheralIdentifier) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            defaults.set(newValue?.uuidString, forKey: Keys.peripheralIdentifier)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        remoteDeviceProfiles = []
        selectedRemoteProfileID = nil
        gainDB = defaults.object(forKey: Keys.gainDB) == nil
            ? 10.0
            : defaults.double(forKey: Keys.gainDB)
        selectedAudioDeviceUID = defaults.string(forKey: Keys.selectedAudioDeviceUID) ?? ""
        if defaults.object(forKey: Keys.customMappingEnabled) != nil {
            customMappingEnabled = defaults.bool(forKey: Keys.customMappingEnabled)
        } else {
            customMappingEnabled = defaults.bool(forKey: Keys.legacyExclusiveHID)
        }

        if
            let data = defaults.data(forKey: Keys.buttonBindings),
            let decoded = try? JSONDecoder().decode([String: ButtonAction].self, from: data)
        {
            buttonBindings = Self.defaultBindings.merging(
                Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                })
            ) { _, saved in saved }
        } else {
            buttonBindings = Self.defaultBindings
        }

        if
            let data = defaults.data(forKey: Keys.buttonShortcuts),
            let decoded = try? JSONDecoder().decode([String: CustomKeyboardShortcut].self, from: data)
        {
            buttonShortcuts = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            })
        } else {
            buttonShortcuts = [:]
        }

        if
            let data = defaults.data(forKey: Keys.buttonApplicationProfileIDs),
            let decoded = try? JSONDecoder().decode([String: UUID].self, from: data)
        {
            buttonApplicationProfileIDs = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                }
            )
        } else {
            buttonApplicationProfileIDs = [:]
        }

        if
            let data = defaults.data(forKey: Keys.secondaryButtonBindings),
            let decoded = try? JSONDecoder().decode(
                [String: [String: ConfiguredButtonAction]].self,
                from: data
            )
        {
            secondaryButtonBindings = Dictionary(uniqueKeysWithValues: decoded.compactMap { buttonKey, bindings in
                guard let button = RemoteButton(rawValue: buttonKey) else { return nil }
                let parsed = Dictionary(uniqueKeysWithValues: bindings.compactMap { triggerKey, binding in
                    ButtonTrigger(rawValue: triggerKey).map { ($0, binding) }
                })
                return parsed.isEmpty ? nil : (button, parsed)
            })
        } else {
            secondaryButtonBindings = [:]
        }

        customApplicationProfiles = defaults
            .data(forKey: Keys.customApplicationProfiles)
            .flatMap { try? JSONDecoder().decode([CustomApplicationProfile].self, from: $0) }
            ?? []

        applicationLanguage = AppLanguage(
            rawValue: defaults.string(forKey: Keys.applicationLanguage) ?? ""
        ) ?? .system
        showDockIcon = defaults.object(forKey: Keys.showDockIcon) == nil
            ? true
            : defaults.bool(forKey: Keys.showDockIcon)
        openMainWindowAtLaunch = defaults.object(forKey: Keys.openMainWindowAtLaunch) == nil
            ? true
            : defaults.bool(forKey: Keys.openMainWindowAtLaunch)
        checksForPreReleaseUpdates = defaults.bool(forKey: Keys.checksForPreReleaseUpdates)
        experimentalContinuousRecordingEnabled = defaults.bool(
            forKey: Keys.experimentalContinuousRecordingEnabled
        )
        voiceFnTapModeEnabled = defaults.bool(
            forKey: Keys.voiceFnTapModeEnabled
        )
        continuousRecordingPowerBindingBackup = defaults
            .data(forKey: Keys.continuousRecordingPowerBindingBackup)
            .flatMap { try? JSONDecoder().decode(ConfiguredButtonAction.self, from: $0) }
        Keys.retiredUsageStatistics.forEach(defaults.removeObject(forKey:))
        trustedPhoneIdentityFingerprints = Set(
            defaults.stringArray(forKey: Keys.trustedPhoneIdentityFingerprints) ?? []
        )
        onboardingCompletedVersion = defaults.integer(forKey: Keys.onboardingCompletedVersion)
        onboardingStep = defaults.string(forKey: Keys.onboardingStep)
            .flatMap(OnboardingStep.init(rawValue:))
            ?? .welcome
        onboardingVoiceTool = defaults.string(forKey: Keys.onboardingVoiceTool)
            .flatMap(OnboardingVoiceTool.init(rawValue:))
            ?? .unselected
        let legacyMappings = RemoteDeviceMappings(
            buttonBindings: buttonBindings,
            buttonShortcuts: buttonShortcuts,
            buttonApplicationProfileIDs: buttonApplicationProfileIDs,
            secondaryButtonBindings: secondaryButtonBindings
        )
        if
            let data = defaults.data(forKey: Keys.remoteDeviceProfiles),
            let decoded = try? JSONDecoder().decode([RemoteDeviceProfile].self, from: data),
            !decoded.isEmpty
        {
            remoteDeviceProfiles = decoded
            let savedID = defaults.string(forKey: Keys.selectedRemoteProfileID).flatMap(UUID.init(uuidString:))
            selectedRemoteProfileID = decoded.contains(where: { $0.id == savedID })
                ? savedID
                : decoded.first?.id
            if let selectedRemoteProfileID,
               let selected = decoded.first(where: { $0.id == selectedRemoteProfileID }) {
                buttonBindings = Self.defaultBindings.merging(selected.mappings.parsedButtonBindings) {
                    _, saved in saved
                }
                buttonShortcuts = selected.mappings.parsedButtonShortcuts
                buttonApplicationProfileIDs = selected.mappings.parsedButtonApplicationProfileIDs
                secondaryButtonBindings = selected.mappings.parsedSecondaryButtonBindings
            }
        } else {
            let migrated = RemoteDeviceProfile(
                bluetoothIdentifier: defaults.string(forKey: Keys.peripheralIdentifier).flatMap(UUID.init(uuidString:)),
                mappings: legacyMappings
            )
            remoteDeviceProfiles = [migrated]
            selectedRemoteProfileID = migrated.id
        }
        applyContinuousRecordingExperimentState(
            enabled: experimentalContinuousRecordingEnabled,
            backup: continuousRecordingPowerBindingBackup
        )
    }

    func setOnboardingStep(_ step: OnboardingStep) {
        guard !isOnboardingComplete, onboardingStep != step else { return }
        onboardingStep = step
    }

    func setOnboardingVoiceTool(_ voiceTool: OnboardingVoiceTool) {
        guard onboardingVoiceTool != voiceTool else { return }
        onboardingVoiceTool = voiceTool
    }

    func completeOnboarding() {
        onboardingStep = .complete
        onboardingCompletedVersion = Self.currentOnboardingVersion
    }

    func restartOnboarding() {
        onboardingVoiceTool = .unselected
        onboardingStep = .welcome
        onboardingCompletedVersion = 0
    }

    func action(for button: RemoteButton) -> ButtonAction {
        buttonBindings[button] ?? .disabled
    }

    func action(for button: RemoteButton, profileID: UUID?) -> ButtonAction {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return action(for: button) }
        return profile.mappings.parsedButtonBindings[button] ?? Self.defaultBindings[button] ?? .disabled
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton) {
        buttonBindings[button] = action
    }

    func shortcut(for button: RemoteButton) -> CustomKeyboardShortcut? {
        buttonShortcuts[button]
    }

    func shortcut(for button: RemoteButton, profileID: UUID?) -> CustomKeyboardShortcut? {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return shortcut(for: button) }
        return profile.mappings.parsedButtonShortcuts[button]
    }

    func setShortcut(_ shortcut: CustomKeyboardShortcut?, for button: RemoteButton) {
        buttonShortcuts[button] = shortcut
    }

    func applicationProfileID(for button: RemoteButton) -> UUID? {
        buttonApplicationProfileIDs[button]
    }

    func applicationProfileID(for button: RemoteButton, profileID: UUID?) -> UUID? {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return applicationProfileID(for: button) }
        return profile.mappings.parsedButtonApplicationProfileIDs[button]
    }

    func customApplicationProfile(id: UUID?) -> CustomApplicationProfile? {
        guard let id else { return nil }
        return customApplicationProfiles.first(where: { $0.id == id })
    }

    @discardableResult
    func addCustomApplicationProfile(_ profile: CustomApplicationProfile) -> UUID {
        customApplicationProfiles.append(profile)
        return profile.id
    }

    func updateCustomApplicationProfile(_ profile: CustomApplicationProfile) {
        guard let index = customApplicationProfiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        customApplicationProfiles[index] = profile
    }

    func configuredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> ConfiguredButtonAction {
        if trigger == .singleClick {
            return ConfiguredButtonAction(
                action: action(for: button),
                shortcut: shortcut(for: button),
                applicationProfileID: applicationProfileID(for: button)
            )
        }
        return secondaryButtonBindings[button]?[trigger] ?? .disabled
    }

    func configuredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        profileID: UUID?
    ) -> ConfiguredButtonAction {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return configuredAction(for: button, trigger: trigger) }
        let bindings = profile.mappings.parsedButtonBindings
        let shortcuts = profile.mappings.parsedButtonShortcuts
        if trigger == .singleClick {
            return ConfiguredButtonAction(
                action: bindings[button] ?? Self.defaultBindings[button] ?? .disabled,
                shortcut: shortcuts[button],
                applicationProfileID: profile.mappings.parsedButtonApplicationProfileIDs[button]
            )
        }
        return profile.mappings.parsedSecondaryButtonBindings[button]?[trigger] ?? .disabled
    }

    var selectedRemoteProfile: RemoteDeviceProfile? {
        guard let selectedRemoteProfileID else { return nil }
        return remoteDeviceProfiles.first(where: { $0.id == selectedRemoteProfileID })
    }

    func selectRemoteProfile(_ profileID: UUID) {
        guard profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return }
        isLoadingRemoteProfile = true
        selectedRemoteProfileID = profileID
        buttonBindings = Self.defaultBindings.merging(profile.mappings.parsedButtonBindings) {
            _, saved in saved
        }
        buttonShortcuts = profile.mappings.parsedButtonShortcuts
        buttonApplicationProfileIDs = profile.mappings.parsedButtonApplicationProfileIDs
        secondaryButtonBindings = profile.mappings.parsedSecondaryButtonBindings
        isLoadingRemoteProfile = false
    }

    @discardableResult
    func registerBluetoothRemote(identifier: UUID) -> UUID {
        if let existing = remoteDeviceProfiles.first(where: { $0.bluetoothIdentifier == identifier }) {
            return existing.id
        }
        if let index = remoteDeviceProfiles.firstIndex(where: {
            $0.bluetoothIdentifier == nil && $0.model == .unknown
        }) {
            remoteDeviceProfiles[index].bluetoothIdentifier = identifier
            return remoteDeviceProfiles[index].id
        }
        let profile = RemoteDeviceProfile(
            bluetoothIdentifier: identifier,
            mappings: mappingsForNewRemote()
        )
        remoteDeviceProfiles.append(profile)
        return profile.id
    }

    @discardableResult
    func registerHIDRemote(fingerprint: String) -> UUID {
        if let existing = remoteDeviceProfiles.first(where: { $0.hidFingerprint == fingerprint }) {
            return existing.id
        }
        let selectedUnboundIndex = remoteDeviceProfiles.firstIndex(where: {
            $0.id == selectedRemoteProfileID && $0.hidFingerprint == nil
        })
        if let index = selectedUnboundIndex ?? remoteDeviceProfiles.firstIndex(where: { $0.hidFingerprint == nil }) {
            let defaultMappings = RemoteDeviceMappings(
                buttonBindings: Self.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
            if remoteDeviceProfiles[index].mappings == defaultMappings,
               let configured = remoteDeviceProfiles.first(where: {
                   $0.id != remoteDeviceProfiles[index].id && $0.mappings != defaultMappings
               }) {
                remoteDeviceProfiles[index].mappings = configured.mappings
            }
            remoteDeviceProfiles[index].hidFingerprint = fingerprint
            return remoteDeviceProfiles[index].id
        }
        let profile = RemoteDeviceProfile(
            hidFingerprint: fingerprint,
            mappings: mappingsForNewRemote()
        )
        remoteDeviceProfiles.append(profile)
        return profile.id
    }

    func profileID(forBluetoothIdentifier identifier: UUID) -> UUID? {
        remoteDeviceProfiles.first(where: { $0.bluetoothIdentifier == identifier })?.id
    }

    func profileID(forHIDFingerprint fingerprint: String) -> UUID? {
        remoteDeviceProfiles.first(where: { $0.hidFingerprint == fingerprint })?.id
    }

    func bindHIDFingerprint(_ fingerprint: String, to profileID: UUID) {
        guard let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        for candidate in remoteDeviceProfiles.indices where remoteDeviceProfiles[candidate].hidFingerprint == fingerprint {
            remoteDeviceProfiles[candidate].hidFingerprint = nil
        }
        remoteDeviceProfiles[index].hidFingerprint = fingerprint
    }

    private func mappingsForNewRemote() -> RemoteDeviceMappings {
        selectedRemoteProfile?.mappings ?? RemoteDeviceMappings(
            buttonBindings: buttonBindings,
            buttonShortcuts: buttonShortcuts,
            buttonApplicationProfileIDs: buttonApplicationProfileIDs,
            secondaryButtonBindings: secondaryButtonBindings
        )
    }

    func updateRemoteProfile(
        _ profileID: UUID,
        model: XiaomiRemoteModel,
        customName: String
    ) {
        guard let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        remoteDeviceProfiles[index].model = model
        remoteDeviceProfiles[index].customName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateRemoteProfileModel(_ profileID: UUID, model: XiaomiRemoteModel) {
        guard model != .unknown,
              let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }),
              remoteDeviceProfiles[index].model != model
        else { return }
        remoteDeviceProfiles[index].model = model
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton, trigger: ButtonTrigger) {
        guard trigger != .singleClick else {
            setAction(action, for: button)
            return
        }

        var bindings = secondaryButtonBindings[button] ?? [:]
        let shortcut = bindings[trigger]?.shortcut
        let applicationProfileID = bindings[trigger]?.applicationProfileID
        bindings[trigger] = ConfiguredButtonAction(
            action: action,
            shortcut: shortcut,
            applicationProfileID: applicationProfileID
        )
        secondaryButtonBindings[button] = bindings.isEmpty ? nil : bindings
    }

    func setApplicationProfileID(
        _ applicationProfileID: UUID?,
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        guard trigger != .singleClick else {
            buttonApplicationProfileIDs[button] = applicationProfileID
            return
        }
        guard var bindings = secondaryButtonBindings[button], var binding = bindings[trigger] else {
            return
        }
        binding.applicationProfileID = applicationProfileID
        bindings[trigger] = binding
        secondaryButtonBindings[button] = bindings
    }

    func setShortcut(
        _ shortcut: CustomKeyboardShortcut?,
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        guard trigger != .singleClick else {
            setShortcut(shortcut, for: button)
            return
        }
        guard var bindings = secondaryButtonBindings[button], var binding = bindings[trigger] else {
            return
        }
        binding.shortcut = shortcut
        bindings[trigger] = binding
        secondaryButtonBindings[button] = bindings
    }

    func hasSecondaryAction(for button: RemoteButton) -> Bool {
        [.doubleClick, .longPress].contains { trigger in
            configuredAction(for: button, trigger: trigger).action != .disabled
        }
    }

    func hasSecondaryAction(for button: RemoteButton, profileID: UUID?) -> Bool {
        [.doubleClick, .longPress].contains { trigger in
            configuredAction(for: button, trigger: trigger, profileID: profileID).action != .disabled
        }
    }

    func setExperimentalContinuousRecordingEnabled(_ enabled: Bool) {
        let backup = enabled
            ? continuousRecordingPowerBindingBackup ?? configuredAction(for: .power, trigger: .singleClick)
            : continuousRecordingPowerBindingBackup
        applyContinuousRecordingExperimentState(enabled: enabled, backup: backup)
    }

    func resetBindings() {
        buttonBindings = Self.defaultBindings
        buttonShortcuts = [:]
        buttonApplicationProfileIDs = [:]
        secondaryButtonBindings = [:]
        if experimentalContinuousRecordingEnabled {
            continuousRecordingPowerBindingBackup = ConfiguredButtonAction(
                action: .escape,
                shortcut: nil
            )
            setAction(.toggleLongRecording, for: .power, trigger: .singleClick)
        }
    }

    func isPhoneIdentityTrusted(_ fingerprint: String) -> Bool {
        trustedPhoneIdentityFingerprints.contains(fingerprint)
    }

    func trustPhoneIdentity(_ fingerprint: String) {
        guard !fingerprint.isEmpty else { return }
        trustedPhoneIdentityFingerprints.insert(fingerprint)
    }

    func clearTrustedPhoneIdentities() {
        trustedPhoneIdentityFingerprints.removeAll()
    }

    func recordLaunchAndDetectCompletedUpdate(
        currentBuild: String,
        sparkleHadLaunchedBefore: Bool
    ) -> Bool {
        let previousBuild = defaults.string(forKey: Keys.lastLaunchedBuild)
        defaults.set(currentBuild, forKey: Keys.lastLaunchedBuild)
        if
            let previousBuild,
            let previousBuildNumber = Int(previousBuild),
            let currentBuildNumber = Int(currentBuild)
        {
            return currentBuildNumber > previousBuildNumber
        }
        return previousBuild == nil && sparkleHadLaunchedBefore
    }

    func exportedConfigurationData() throws -> Data {
        let configuration = PersonalizedConfiguration(
            formatVersion: 1,
            gainDB: gainDB,
            selectedAudioDeviceUID: selectedAudioDeviceUID,
            customMappingEnabled: customMappingEnabled,
            buttonBindings: Dictionary(
                uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) }
            ),
            buttonShortcuts: Dictionary(
                uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) }
            ),
            buttonApplicationProfileIDs: Dictionary(
                uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
            ),
            secondaryButtonBindings: Dictionary(
                uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
                    (
                        button.rawValue,
                        Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
                    )
                }
            ),
            customApplicationProfiles: customApplicationProfiles,
            applicationLanguage: applicationLanguage,
            showDockIcon: showDockIcon,
            openMainWindowAtLaunch: openMainWindowAtLaunch,
            checksForPreReleaseUpdates: checksForPreReleaseUpdates,
            experimentalContinuousRecordingEnabled: experimentalContinuousRecordingEnabled,
            voiceFnTapModeEnabled: voiceFnTapModeEnabled,
            continuousRecordingPowerBindingBackup: continuousRecordingPowerBindingBackup
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }

    func importConfiguration(from data: Data) throws {
        let configuration = try JSONDecoder().decode(PersonalizedConfiguration.self, from: data)
        guard configuration.formatVersion == 1 else {
            throw AppConfigurationError.unsupportedVersion
        }
        guard configuration.gainDB.isFinite, (0...24).contains(configuration.gainDB) else {
            throw AppConfigurationError.invalidValues
        }

        let importedBindings = Dictionary(
            uniqueKeysWithValues: configuration.buttonBindings.compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            }
        )
        let importedShortcuts = Dictionary(
            uniqueKeysWithValues: configuration.buttonShortcuts.compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            }
        )
        let importedApplicationProfileIDs = Dictionary(
            uniqueKeysWithValues: (configuration.buttonApplicationProfileIDs ?? [:]).compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            }
        )
        let importedSecondaryBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] =
            Dictionary(
                uniqueKeysWithValues: configuration.secondaryButtonBindings.compactMap { buttonKey, bindings in
                    guard let button = RemoteButton(rawValue: buttonKey) else { return nil }
                    let parsed = Dictionary(
                        uniqueKeysWithValues: bindings.compactMap { triggerKey, binding in
                            ButtonTrigger(rawValue: triggerKey).map { ($0, binding) }
                        }
                    )
                    return parsed.isEmpty ? nil : (button, parsed)
                }
            )

        gainDB = configuration.gainDB
        selectedAudioDeviceUID = configuration.selectedAudioDeviceUID
        customMappingEnabled = configuration.customMappingEnabled
        buttonBindings = Self.defaultBindings.merging(importedBindings) { _, imported in imported }
        buttonShortcuts = importedShortcuts
        buttonApplicationProfileIDs = importedApplicationProfileIDs
        secondaryButtonBindings = importedSecondaryBindings
        customApplicationProfiles = configuration.customApplicationProfiles ?? []
        applicationLanguage = configuration.applicationLanguage
        showDockIcon = configuration.showDockIcon
        if let openMainWindowAtLaunch = configuration.openMainWindowAtLaunch {
            self.openMainWindowAtLaunch = openMainWindowAtLaunch
        }
        if let checksForPreReleaseUpdates = configuration.checksForPreReleaseUpdates {
            self.checksForPreReleaseUpdates = checksForPreReleaseUpdates
        }
        voiceFnTapModeEnabled = configuration.voiceFnTapModeEnabled ?? false
        applyContinuousRecordingExperimentState(
            enabled: configuration.experimentalContinuousRecordingEnabled ?? false,
            backup: configuration.continuousRecordingPowerBindingBackup
        )
    }

    private func saveBindings() {
        let raw = Dictionary(uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonBindings)
        }
    }

    private func saveShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonShortcuts)
        }
    }

    private func saveButtonApplicationProfileIDs() {
        let raw = Dictionary(
            uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonApplicationProfileIDs)
        }
    }

    private func saveSecondaryBindings() {
        let raw = Dictionary(uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
            (
                button.rawValue,
                Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
            )
        })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.secondaryButtonBindings)
        }
    }

    private func saveSelectedRemoteProfileMappings() {
        guard !isLoadingRemoteProfile,
              let selectedRemoteProfileID,
              let index = remoteDeviceProfiles.firstIndex(where: { $0.id == selectedRemoteProfileID })
        else { return }
        remoteDeviceProfiles[index].mappings = RemoteDeviceMappings(
            buttonBindings: buttonBindings,
            buttonShortcuts: buttonShortcuts,
            buttonApplicationProfileIDs: buttonApplicationProfileIDs,
            secondaryButtonBindings: secondaryButtonBindings
        )
    }

    private func saveCustomApplicationProfiles() {
        guard let data = try? JSONEncoder().encode(customApplicationProfiles) else { return }
        defaults.set(data, forKey: Keys.customApplicationProfiles)
    }

    private func saveRemoteDeviceProfiles() {
        guard let data = try? JSONEncoder().encode(remoteDeviceProfiles) else { return }
        defaults.set(data, forKey: Keys.remoteDeviceProfiles)
    }

    private func saveContinuousRecordingPowerBindingBackup() {
        guard let continuousRecordingPowerBindingBackup else {
            defaults.removeObject(forKey: Keys.continuousRecordingPowerBindingBackup)
            return
        }
        if let data = try? JSONEncoder().encode(continuousRecordingPowerBindingBackup) {
            defaults.set(data, forKey: Keys.continuousRecordingPowerBindingBackup)
        }
    }

    private func applyContinuousRecordingExperimentState(
        enabled: Bool,
        backup: ConfiguredButtonAction?
    ) {
        let enabled = enabled && Self.continuousRecordingExperimentAvailable
        if enabled {
            let current = configuredAction(for: .power, trigger: .singleClick)
            continuousRecordingPowerBindingBackup = Self.safeContinuousRecordingBackup(
                backup ?? current
            )
            experimentalContinuousRecordingEnabled = true
            customMappingEnabled = true
            setAction(.toggleLongRecording, for: .power, trigger: .singleClick)
            return
        }

        experimentalContinuousRecordingEnabled = false
        if backup != nil || action(for: .power) == .toggleLongRecording {
            let restored = Self.safeContinuousRecordingBackup(
                backup ?? ConfiguredButtonAction(action: .escape, shortcut: nil)
            )
            setAction(restored.action, for: .power, trigger: .singleClick)
            setShortcut(restored.shortcut, for: .power, trigger: .singleClick)
            setApplicationProfileID(
                restored.applicationProfileID,
                for: .power,
                trigger: .singleClick
            )
        }
        continuousRecordingPowerBindingBackup = nil
    }

    private static func safeContinuousRecordingBackup(
        _ binding: ConfiguredButtonAction
    ) -> ConfiguredButtonAction {
        guard binding.action == .toggleLongRecording else { return binding }
        return ConfiguredButtonAction(action: .escape, shortcut: nil)
    }

    static let defaultBindings: [RemoteButton: ButtonAction] = [
        .power: .escape,
        .up: .arrowUp,
        .left: .arrowLeft,
        .ok: .returnKey,
        .right: .arrowRight,
        .down: .arrowDown,
        .back: .deleteBackward,
        .volumeUp: .volumeUp,
        .home: .showDesktop,
        .volumeDown: .volumeDown,
        .menu: .contextMenu,
        .tv: .appSwitcher,
    ]
}
