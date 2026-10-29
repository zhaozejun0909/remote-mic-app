import Testing
@testable import RemoteMic

struct SystemAudioLifecycleTests {
    @Test func overlappingSuspensionRequiresEveryReasonToClear() {
        var state = SystemAudioSuspensionState()
        state.apply(.screenDidSleep)
        state.apply(.screenDidSleep)
        state.apply(.sessionDidResignActive)
        state.apply(.systemWillSleep)
        state.apply(.systemDidWake)
        state.apply(.screenDidWake)
        #expect(!state.shouldKeepAudioActive(hasReadyRemote: true, hasActiveVoiceOrTone: false))
        state.apply(.sessionDidBecomeActive)
        #expect(state.shouldKeepAudioActive(hasReadyRemote: true, hasActiveVoiceOrTone: false))
        #expect(!state.shouldKeepAudioActive(hasReadyRemote: false, hasActiveVoiceOrTone: false))
    }

    @Test func logicalVoiceIncludingContinuationWaitProtectsAudioUntilFinalStop() {
        var state = SystemAudioSuspensionState()
        state.apply(.screenDidSleep)
        // The bridge keeps logical voice active during the two-second silence gap.
        #expect(state.shouldKeepAudioActive(hasReadyRemote: true, hasActiveVoiceOrTone: true))
        #expect(!state.shouldKeepAudioActive(hasReadyRemote: true, hasActiveVoiceOrTone: false))
        // A real new voice request is allowed to wake output before all screen events arrive.
        #expect(state.shouldKeepAudioActive(hasReadyRemote: false, hasActiveVoiceOrTone: true))
    }
    @Test func idlePauseWaitsForEveryAudioUseToFinish() {
        func canPause(
            keep: Bool = true,
            active: Bool = false,
            streaming: Bool = false,
            pending: Int = 0,
            release: Bool = false
        ) -> Bool {
            IdleAudioPausePolicy.canPause(
                shouldKeepAudioActive: keep,
                hasActiveSource: active,
                isStreaming: streaming,
                pendingVoiceBufferCount: pending,
                releasePending: release
            )
        }
        #expect(canPause())
        // Continuation waits keep the Bluetooth source active.
        #expect(!canPause(active: true))
        #expect(!canPause(streaming: true))
        // Tail audio still queued must play before IO stops.
        #expect(!canPause(pending: 1))
        // Without a ready remote or while suspended, the full release path owns the engine.
        #expect(!canPause(keep: false))
        #expect(!canPause(release: true))
        #expect(IdleAudioPausePolicy.delay == 30)
    }

    @Test func idlePauseRetriesOnlyWhileAudioIsInUse() {
        #expect(IdleAudioPausePolicy.shouldRetryLater(hasActiveSource: true, isStreaming: false, pendingVoiceBufferCount: 0))
        #expect(IdleAudioPausePolicy.shouldRetryLater(hasActiveSource: false, isStreaming: true, pendingVoiceBufferCount: 0))
        #expect(IdleAudioPausePolicy.shouldRetryLater(hasActiveSource: false, isStreaming: false, pendingVoiceBufferCount: 2))
        #expect(!IdleAudioPausePolicy.shouldRetryLater(hasActiveSource: false, isStreaming: false, pendingVoiceBufferCount: 0))
    }

    @Test func unconfiguredOutputNeitherPausesNorResumes() {
        let output = VirtualAudioOutput()
        #expect(!output.pauseWhileIdle())
        #expect(!output.isIdlePaused)
        #expect(!output.resumeFromIdlePause())
    }
}
