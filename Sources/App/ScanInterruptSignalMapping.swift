import Foundation

/// Pure mapping from the C signal/reap results to the coordinator's Swift
/// enums (Phase 1a, issue #24). Kept pure so the acceptance-critical
/// `ALREADY_DEAD` identity split is unit-tested independent of the C call.
extension EngineSessionCoordinator.SignalResult {
    static func from(_ r: unison_scan_signal_result_t) -> EngineSessionCoordinator.SignalResult {
        let id = EngineSessionCoordinator.TransportIdentity(
            pid: r.pid, startSec: r.start_sec, startUsec: r.start_usec)
        switch r.outcome {
        case UNISON_SIGNAL_SIGNALLED:
            // A signalled child with no captured identity cannot be
            // reap-classified → treat conservatively as unprovable.
            return r.identity_valid != 0 ? .signalled(id) : .unprovableIdentity
        case UNISON_SIGNAL_ALREADY_DEAD:
            // Acceptance point: map to `alreadyDeadWithIdentity` ONLY when a
            // valid start identity was captured (a still-present zombie);
            // otherwise `alreadyDeadNoIdentity` (nothing to classify → restart).
            return r.identity_valid != 0 ? .alreadyDeadWithIdentity(id) : .alreadyDeadNoIdentity
        case UNISON_SIGNAL_NO_CHILD:          return .noChild
        case UNISON_SIGNAL_MULTIPLE_CHILDREN: return .multipleChildren
        case UNISON_SIGNAL_FAILED:            return .signalFailed
        default:                              return .signalFailed
        }
    }
}

extension EngineSessionCoordinator.ReapState {
    static func from(_ r: unison_reap_state_t) -> EngineSessionCoordinator.ReapState {
        switch r {
        case UNISON_REAP_ABSENT: return .absent
        case UNISON_REAP_REUSED: return .reused
        case UNISON_REAP_ZOMBIE: return .zombie
        case UNISON_REAP_LIVE:   return .live
        default:                 return .unknown
        }
    }
}
