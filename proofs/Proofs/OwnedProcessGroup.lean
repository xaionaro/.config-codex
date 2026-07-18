import Spec.OwnedProcessGroup

namespace CodexHooks

theorem owned_group_order_reaches_observation_only_absence :
    ownedGroupRun [
      .registerIdentity, .sendTerm, .sendKill, .observeLeaderExit,
      .reapLeader, .observeGroupAbsence
    ] = {
      phase := .groupAbsenceObserved
      rejected := false
      unrelatedTouched := false
    } := by
  rfl

theorem owned_group_signal_after_reap_is_rejected
    (alreadyRejected unrelatedTouched : Bool) :
    let state : OwnedGroupState := {
      phase := .leaderReaped
      rejected := alreadyRejected
      unrelatedTouched := unrelatedTouched
    }
    (ownedGroupStep state .sendTerm).rejected = true ∧
      (ownedGroupStep state .sendKill).rejected = true := by
  cases alreadyRejected <;> cases unrelatedTouched <;> constructor <;> rfl

theorem owned_group_second_reap_is_rejected
    (alreadyRejected unrelatedTouched : Bool) :
    let state : OwnedGroupState := {
      phase := .leaderReaped
      rejected := alreadyRejected
      unrelatedTouched := unrelatedTouched
    }
    (ownedGroupStep state .reapLeader).rejected = true ∧
      (ownedGroupStep state .reapLeader).reapCount = state.reapCount := by
  cases alreadyRejected <;> cases unrelatedTouched <;> constructor <;> rfl

theorem unrelated_identity_is_never_marked_touched
    (state : OwnedGroupState) :
    (ownedGroupStep state .signalUnrelated).unrelatedTouched =
      state.unrelatedTouched := by
  cases state with
  | mk phase rejected unrelatedTouched =>
      cases phase <;> cases rejected <;> cases unrelatedTouched <;> rfl

theorem unsupported_linux_containment_fails_closed
    (parentMatched parentDeathVerified subreaperVerified pidfdVerified
      controlCloseOnExec : Bool) :
    linuxContainmentAdmissionAccepted false parentMatched parentDeathVerified
      subreaperVerified pidfdVerified controlCloseOnExec = false := by
  cases parentMatched <;> cases parentDeathVerified <;> cases subreaperVerified <;>
    cases pidfdVerified <;> cases controlCloseOnExec <;> rfl

theorem wrong_parent_containment_fails_closed
    (linux parentDeathVerified subreaperVerified pidfdVerified
      controlCloseOnExec : Bool) :
    linuxContainmentAdmissionAccepted linux false parentDeathVerified
      subreaperVerified pidfdVerified controlCloseOnExec = false := by
  cases linux <;> cases parentDeathVerified <;> cases subreaperVerified <;>
    cases pidfdVerified <;> cases controlCloseOnExec <;> rfl

end CodexHooks
