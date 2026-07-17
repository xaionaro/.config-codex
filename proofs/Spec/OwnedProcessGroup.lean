namespace CodexHooks

inductive OwnedGroupEvent where
  | registerIdentity
  | sendTerm
  | sendKill
  | observeLeaderExit
  | reapLeader
  | observeGroupAbsence
  | signalUnrelated
deriving DecidableEq, Repr

structure OwnedGroupState where
  registered : Bool := false
  identityReserved : Bool := false
  termSent : Bool := false
  killSent : Bool := false
  leaderExitObserved : Bool := false
  leaderReaped : Bool := false
  groupAbsenceObserved : Bool := false
  rejected : Bool := false
  reapCount : Nat := 0
  unrelatedTouched : Bool := false
deriving DecidableEq, Repr

def ownedGroupStep
    (state : OwnedGroupState) (event : OwnedGroupEvent) : OwnedGroupState :=
  if state.rejected then state else
  match event with
  | .registerIdentity =>
      if !state.registered then
        { state with registered := true, identityReserved := true }
      else
        { state with rejected := true }
  | .sendTerm =>
      if state.registered && state.identityReserved && !state.leaderReaped then
        { state with termSent := true }
      else
        { state with rejected := true }
  | .sendKill =>
      if state.registered && state.identityReserved && state.termSent &&
          !state.leaderReaped then
        { state with killSent := true }
      else
        { state with rejected := true }
  | .observeLeaderExit =>
      if state.registered && state.identityReserved && !state.leaderReaped then
        { state with leaderExitObserved := true }
      else
        { state with rejected := true }
  | .reapLeader =>
      if state.identityReserved && state.killSent && state.leaderExitObserved &&
          !state.leaderReaped then
        { state with identityReserved := false, leaderReaped := true,
            reapCount := state.reapCount + 1 }
      else
        { state with rejected := true }
  | .observeGroupAbsence =>
      if state.leaderReaped then
        { state with groupAbsenceObserved := true }
      else
        { state with rejected := true }
  | .signalUnrelated =>
      { state with rejected := true }

def ownedGroupRun (events : List OwnedGroupEvent) : OwnedGroupState :=
  events.foldl ownedGroupStep {}

def linuxContainmentAdmissionAccepted
    (linux parentMatched parentDeathVerified subreaperVerified pidfdVerified
      controlCloseOnExec : Bool) : Bool :=
  linux && parentMatched && parentDeathVerified && subreaperVerified &&
    pidfdVerified && controlCloseOnExec

end CodexHooks
