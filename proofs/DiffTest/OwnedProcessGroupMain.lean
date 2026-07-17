import Proofs.OwnedProcessGroup

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

def stateString (state : OwnedGroupState) : String :=
  s!"{bit state.registered} {bit state.identityReserved} {bit state.termSent} {bit state.killSent} {bit state.leaderExitObserved} {bit state.leaderReaped} {bit state.groupAbsenceObserved} {bit state.rejected} {state.reapCount} {bit state.unrelatedTouched}"

def checkAdmission : List String → Option Bool
  | [linux, parent, parentDeath, subreaper, pidfd, closeOnExec] => do
      return linuxContainmentAdmissionAccepted
        (← parseBit linux) (← parseBit parent) (← parseBit parentDeath)
        (← parseBit subreaper) (← parseBit pidfd) (← parseBit closeOnExec)
  | _ => none

def main (args : List String) : IO UInt32 := do
  if args.head? == some "check-admission" then
    match checkAdmission args.tail with
    | some accepted =>
        IO.println (bit accepted)
        return 0
    | none =>
        IO.eprintln "invalid containment bits"
        return 2
  let mut events : List OwnedGroupEvent := []
  for value in args do
    match parseEvent value with
    | some event => events := events ++ [event]
    | none =>
        IO.eprintln s!"unknown owned-group event: {value}"
        return 2
  IO.println (stateString (ownedGroupRun events))
  return 0
