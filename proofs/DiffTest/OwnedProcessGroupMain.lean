import Spec.OwnedProcessGroup

open CodexHooks

def bit (value : Bool) : String := if value then "1" else "0"

def parseBit : String → Option Bool
  | "0" => some false
  | "1" => some true
  | _ => none

def parseEvent : String → Option OwnedGroupEvent
  | "register" => some .registerIdentity
  | "term" => some .sendTerm
  | "kill" => some .sendKill
  | "exit" => some .observeLeaderExit
  | "reap" => some .reapLeader
  | "absence" => some .observeGroupAbsence
  | "unrelated" => some .signalUnrelated
  | _ => none

def parsePhase : String → Option OwnedGroupPhase
  | "idle" => some .idle
  | "reserved" => some .identityReserved
  | "term-sent" => some .termSent
  | "kill-sent" => some .killSent
  | "exit-observed" => some .leaderExitObserved
  | "reaped" => some .leaderReaped
  | "absence-observed" => some .groupAbsenceObserved
  | _ => none

def stateString (state : OwnedGroupState) : String :=
  s!"{bit state.registered} {bit state.identityReserved} {bit state.termWasSent} {bit state.killWasSent} {bit state.exitWasObserved} {bit state.leaderWasReaped} {bit state.absenceWasObserved} {bit state.rejected} {state.reapCount} {bit state.unrelatedTouched}"

def checkAdmission : List String → Option Bool
  | [linux, parent, parentDeath, subreaper, pidfd, closeOnExec] => do
      return linuxContainmentAdmissionAccepted
        (← parseBit linux) (← parseBit parent) (← parseBit parentDeath)
        (← parseBit subreaper) (← parseBit pidfd) (← parseBit closeOnExec)
  | _ => none

def checkStep : List String → Option OwnedGroupState
  | [phase, rejected, unrelatedTouched, event] => do
      return ownedGroupStep {
        phase := (← parsePhase phase)
        rejected := (← parseBit rejected)
        unrelatedTouched := (← parseBit unrelatedTouched)
      } (← parseEvent event)
  | _ => none

def runEventCases : List String → List OwnedGroupEvent → IO UInt32
  | [], events => do
      IO.println (stateString (ownedGroupRun events))
      return 0
  | "--next" :: remaining, events => do
      IO.println (stateString (ownedGroupRun events))
      runEventCases remaining []
  | value :: remaining, events => do
      match parseEvent value with
      | some event => runEventCases remaining (events ++ [event])
      | none =>
          IO.eprintln s!"unknown owned-group event: {value}"
          return 2

def runAdmissionCases : List String → IO UInt32
  | [] => return 0
  | linux :: parent :: parentDeath :: subreaper :: pidfd :: closeOnExec :: rest =>
    do
      match checkAdmission [
        linux, parent, parentDeath, subreaper, pidfd, closeOnExec
      ] with
      | some accepted => IO.println (bit accepted)
      | none =>
          IO.eprintln "invalid containment bits"
          return 2
      match rest with
      | [] => return 0
      | "--next" :: remaining => runAdmissionCases remaining
      | _ =>
          IO.eprintln "invalid containment case separator"
          return 2
  | _ => do
      IO.eprintln "invalid containment bits"
      return 2

def runStepCases : List String → IO UInt32
  | [] => return 0
  | phase :: rejected :: unrelatedTouched :: event :: rest =>
    do
      match checkStep [phase, rejected, unrelatedTouched, event] with
      | some state => IO.println (stateString state)
      | none =>
          IO.eprintln "invalid owned-group step case"
          return 2
      match rest with
      | [] => return 0
      | "--next" :: remaining => runStepCases remaining
      | _ =>
          IO.eprintln "invalid owned-group step case separator"
          return 2
  | _ => do
      IO.eprintln "invalid owned-group step case"
      return 2

def main (args : List String) : IO UInt32 := do
  match args with
  | "check-admission" :: remaining =>
    match checkAdmission remaining with
    | some accepted =>
        IO.println (bit accepted)
        return 0
    | none =>
        IO.eprintln "invalid containment bits"
        return 2
  | "check-admissions" :: remaining => runAdmissionCases remaining
  | "check-step-cases" :: remaining => runStepCases remaining
  | "check-event-cases" :: remaining => runEventCases remaining []
  | _ => runEventCases args []
