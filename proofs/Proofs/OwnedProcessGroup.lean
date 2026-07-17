import Spec.OwnedProcessGroup

namespace CodexHooks

theorem owned_group_order_reaches_observation_only_absence :
    ownedGroupRun [
      .registerIdentity, .sendTerm, .sendKill, .observeLeaderExit,
      .reapLeader, .observeGroupAbsence
    ] = {
      registered := true
      identityReserved := false
      termSent := true
      killSent := true
      leaderExitObserved := true
      leaderReaped := true
      groupAbsenceObserved := true
      rejected := false
      reapCount := 1
      unrelatedTouched := false
    } := by
  decide

theorem owned_group_signal_after_reap_is_rejected
    (state : OwnedGroupState) (reaped : state.leaderReaped = true) :
    (ownedGroupStep state .sendTerm).rejected = true ∧
      (ownedGroupStep state .sendKill).rejected = true := by
  simp [ownedGroupStep, reaped]

theorem owned_group_second_reap_is_rejected
    (state : OwnedGroupState) (reaped : state.leaderReaped = true) :
    (ownedGroupStep state .reapLeader).rejected = true ∧
      (ownedGroupStep state .reapLeader).reapCount = state.reapCount := by
  simp [ownedGroupStep, reaped]

theorem unrelated_identity_is_never_marked_touched
    (state : OwnedGroupState) :
    (ownedGroupStep state .signalUnrelated).unrelatedTouched =
      state.unrelatedTouched := by
  simp [ownedGroupStep]

theorem unsupported_linux_containment_fails_closed
    (parentMatched parentDeathVerified subreaperVerified pidfdVerified
      controlCloseOnExec : Bool) :
    linuxContainmentAdmissionAccepted false parentMatched parentDeathVerified
      subreaperVerified pidfdVerified controlCloseOnExec = false := by
  simp [linuxContainmentAdmissionAccepted]

theorem wrong_parent_containment_fails_closed
    (linux parentDeathVerified subreaperVerified pidfdVerified
      controlCloseOnExec : Bool) :
    linuxContainmentAdmissionAccepted linux false parentDeathVerified
      subreaperVerified pidfdVerified controlCloseOnExec = false := by
  simp [linuxContainmentAdmissionAccepted]

end CodexHooks
