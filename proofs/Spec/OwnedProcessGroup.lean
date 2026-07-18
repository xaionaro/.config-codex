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

inductive OwnedGroupPhase where
  | idle
  | identityReserved
  | termSent
  | killSent
  | leaderExitObserved
  | leaderReaped
  | groupAbsenceObserved
deriving DecidableEq, Repr

structure OwnedGroupState where
  phase : OwnedGroupPhase := .idle
  rejected : Bool := false
  unrelatedTouched : Bool := false
deriving DecidableEq, Repr

def OwnedGroupState.registered (state : OwnedGroupState) : Bool :=
  match state.phase with
  | .idle => false
  | .identityReserved => true
  | .termSent => true
  | .killSent => true
  | .leaderExitObserved => true
  | .leaderReaped => true
  | .groupAbsenceObserved => true

def OwnedGroupState.identityReserved (state : OwnedGroupState) : Bool :=
  match state.phase with
  | .identityReserved => true
  | .termSent => true
  | .killSent => true
  | .leaderExitObserved => true
  | .idle => false
  | .leaderReaped => false
  | .groupAbsenceObserved => false

def OwnedGroupState.termWasSent (state : OwnedGroupState) : Bool :=
  match state.phase with
  | .termSent => true
  | .killSent => true
  | .leaderExitObserved => true
  | .leaderReaped => true
  | .groupAbsenceObserved => true
  | .idle => false
  | .identityReserved => false

def OwnedGroupState.killWasSent (state : OwnedGroupState) : Bool :=
  match state.phase with
  | .killSent => true
  | .leaderExitObserved => true
  | .leaderReaped => true
  | .groupAbsenceObserved => true
  | .idle => false
  | .identityReserved => false
  | .termSent => false

def OwnedGroupState.exitWasObserved (state : OwnedGroupState) : Bool :=
  match state.phase with
  | .leaderExitObserved => true
  | .leaderReaped => true
  | .groupAbsenceObserved => true
  | .idle => false
  | .identityReserved => false
  | .termSent => false
  | .killSent => false

def OwnedGroupState.leaderWasReaped (state : OwnedGroupState) : Bool :=
  match state.phase with
  | .leaderReaped => true
  | .groupAbsenceObserved => true
  | .idle => false
  | .identityReserved => false
  | .termSent => false
  | .killSent => false
  | .leaderExitObserved => false

def OwnedGroupState.absenceWasObserved (state : OwnedGroupState) : Bool :=
  match state.phase with
  | .groupAbsenceObserved => true
  | .idle => false
  | .identityReserved => false
  | .termSent => false
  | .killSent => false
  | .leaderExitObserved => false
  | .leaderReaped => false

def OwnedGroupState.reapCount (state : OwnedGroupState) : Nat :=
  match state.phase with
  | .leaderReaped => 1
  | .groupAbsenceObserved => 1
  | .idle => 0
  | .identityReserved => 0
  | .termSent => 0
  | .killSent => 0
  | .leaderExitObserved => 0

def OwnedGroupState.reject (state : OwnedGroupState) : OwnedGroupState :=
  OwnedGroupState.mk state.phase true state.unrelatedTouched

def ownedGroupStep
    (state : OwnedGroupState) (event : OwnedGroupEvent) : OwnedGroupState :=
  match state.rejected with
  | true => state
  | false =>
      match state.phase with
      | .idle =>
          match event with
          | .registerIdentity =>
              OwnedGroupState.mk .identityReserved false state.unrelatedTouched
          | .sendTerm => state.reject
          | .sendKill => state.reject
          | .observeLeaderExit => state.reject
          | .reapLeader => state.reject
          | .observeGroupAbsence => state.reject
          | .signalUnrelated => state.reject
      | .identityReserved =>
          match event with
          | .registerIdentity => state.reject
          | .sendTerm =>
              OwnedGroupState.mk .termSent false state.unrelatedTouched
          | .sendKill => state.reject
          | .observeLeaderExit => state.reject
          | .reapLeader => state.reject
          | .observeGroupAbsence => state.reject
          | .signalUnrelated => state.reject
      | .termSent =>
          match event with
          | .registerIdentity => state.reject
          | .sendTerm => state.reject
          | .sendKill =>
              OwnedGroupState.mk .killSent false state.unrelatedTouched
          | .observeLeaderExit => state.reject
          | .reapLeader => state.reject
          | .observeGroupAbsence => state.reject
          | .signalUnrelated => state.reject
      | .killSent =>
          match event with
          | .registerIdentity => state.reject
          | .sendTerm => state.reject
          | .sendKill => state.reject
          | .observeLeaderExit =>
              OwnedGroupState.mk .leaderExitObserved false state.unrelatedTouched
          | .reapLeader => state.reject
          | .observeGroupAbsence => state.reject
          | .signalUnrelated => state.reject
      | .leaderExitObserved =>
          match event with
          | .registerIdentity => state.reject
          | .sendTerm => state.reject
          | .sendKill => state.reject
          | .observeLeaderExit => state.reject
          | .reapLeader =>
              OwnedGroupState.mk .leaderReaped false state.unrelatedTouched
          | .observeGroupAbsence => state.reject
          | .signalUnrelated => state.reject
      | .leaderReaped =>
          match event with
          | .registerIdentity => state.reject
          | .sendTerm => state.reject
          | .sendKill => state.reject
          | .observeLeaderExit => state.reject
          | .reapLeader => state.reject
          | .observeGroupAbsence =>
              OwnedGroupState.mk .groupAbsenceObserved false state.unrelatedTouched
          | .signalUnrelated => state.reject
      | .groupAbsenceObserved =>
          match event with
          | .registerIdentity => state.reject
          | .sendTerm => state.reject
          | .sendKill => state.reject
          | .observeLeaderExit => state.reject
          | .reapLeader => state.reject
          | .observeGroupAbsence => state.reject
          | .signalUnrelated => state.reject

def ownedGroupRun (events : List OwnedGroupEvent) : OwnedGroupState :=
  events.foldl ownedGroupStep {}

def linuxContainmentAdmissionAccepted
    (linux parentMatched parentDeathVerified subreaperVerified pidfdVerified
      controlCloseOnExec : Bool) : Bool :=
  linux && parentMatched && parentDeathVerified && subreaperVerified &&
    pidfdVerified && controlCloseOnExec

end CodexHooks
