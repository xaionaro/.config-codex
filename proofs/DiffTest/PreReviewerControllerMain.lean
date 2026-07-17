import Proofs.PreReviewerController

open CodexHooks

def parseStatus : String → Option ChildStatus
  | "success" => some .success
  | "failure" => some .failure
  | "timeout" => some .timeout
  | "signal" => some .signal
  | _ => none

def parseEvidence (value : String) : Option ExternalEvidence :=
  match value.splitOn ":" with
  | ["preflight-passed"] => some .preflightPassed
  | ["input-opened"] => some .inputOpened
  | ["reviewer-owned"] => some .reviewerOwned
  | ["reviewer-started"] => some .reviewerStarted
  | ["input-closed"] => some .inputClosed
  | ["reviewer-read-closed"] => some .reviewerReadClosed
  | ["reviewer-write-closed"] => some .reviewerWriteClosed
  | ["capture-complete"] => some .captureComplete
  | ["capture-rejected"] => some .captureRejected
  | ["bytes-valid"] => some .bytesValid
  | ["cancellation-observed"] => some .cancellationObserved
  | ["reviewer-reaped", status] => .reviewerReaped <$> parseStatus status
  | ["publisher-owned"] => some .publisherOwned
  | ["publisher-started"] => some .publisherStarted
  | ["output-escaped"] => some .outputEscaped
  | ["publisher-reaped", status] => .publisherReaped <$> parseStatus status
  | ["publication-confirmed"] => some .publicationConfirmed
  | _ => none

def bit (value : Bool) : String := if value then "1" else "0"

def tupleString (state : ControllerState) : String :=
  let tuple := controllerTuple state
  s!"{bit tuple.1} {bit tuple.2.1} {bit tuple.2.2.1} {bit tuple.2.2.2.1} {bit tuple.2.2.2.2.1} {bit tuple.2.2.2.2.2}"

def checkBounds : List String → Bool
  | [publication, admission, maintenance, backend, controller, hook,
      maintenanceSharedLock] =>
      publication.toNat? == some atomicPublicationBudget &&
      admission.toNat? == some admissionInputBudget &&
      maintenance.toNat? == some maintenanceVisitBudget &&
      backend.toNat? == some backendDeadlineSeconds &&
      controller.toNat? == some controllerDeadlineSeconds &&
      hook.toNat? == some hookDeadlineSeconds &&
      maintenanceSharedLock.toNat? ==
        some (if maintenanceHoldsSharedTurnLock then 1 else 0)
  | _ => false

def main (args : List String) : IO UInt32 := do
  if args.head? == some "check-bounds" then
    if checkBounds args.tail then
      IO.println "bounds-ok"
      return 0
    else
      IO.eprintln "production bounds differ from proved bounds"
      return 3
  let mut events : List ExternalEvidence := []
  for value in args do
    match parseEvidence value with
    | some event => events := events ++ [event]
    | none =>
        IO.eprintln s!"unknown external evidence: {value}"
        return 2
  IO.println (tupleString (controllerRun events))
  return 0
