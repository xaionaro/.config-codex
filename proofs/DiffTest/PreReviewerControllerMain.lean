import Proofs.PreReviewerController

open CodexHooks

def scenario : String → Option (List ControllerEvent)
  | "preflight-failure" => some preflightFailureTrace
  | "success" => some successTrace
  | "worker-failure" => some workerFailureTrace
  | "signal" => some signalTrace
  | "accelerated-timeout" => some acceleratedTimeoutTrace
  | _ => none

def bit (value : Bool) : String := if value then "1" else "0"

def printTuple (state : ControllerState) : IO Unit :=
  IO.println s!"{bit state.published} {bit state.leaderReaped} {bit state.bufferLive} {bit state.stdinLive} {bit state.termRequested} {bit state.killRequested}"

def main (args : List String) : IO UInt32 := do
  for label in args do
    match scenario label with
    | some events => printTuple (controllerRun events)
    | none =>
        IO.eprintln s!"unknown scenario: {label}"
        return 2
  return 0
