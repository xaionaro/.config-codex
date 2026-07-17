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

def parseBit : String → Option Bool
  | "0" => some false
  | "1" => some true
  | _ => none

def checkGeneratedHookSupervision : List String → Option Bool
  | [newGroup, deadline, exactCleanup] => do
      let newProcessGroup ← parseBit newGroup
      let deadlineArmed ← parseBit deadline
      let exactGroupCleanup ← parseBit exactCleanup
      return generatedHookSupervisionAccepted
        newProcessGroup deadlineArmed exactGroupCleanup
  | _ => none

def checkDeclaredToolIdentity : List String → Option Bool
  | [unique, path, bytes] => do
      let uniqueRole ← parseBit unique
      let exactCanonicalPath ← parseBit path
      let exactBytes ← parseBit bytes
      return declaredToolIdentityAccepted
        uniqueRole exactCanonicalPath exactBytes
  | _ => none

def checkProfileInterruption : List String → Option Bool
  | [traps, tracked, cleanup, preserves] => do
      let trapsAllModes ← parseBit traps
      let trackedProfilerGroup ← parseBit tracked
      let exactGroupCleanup ← parseBit cleanup
      let preservesFailureEvidence ← parseBit preserves
      return profileInterruptionSupervisionAccepted trapsAllModes
        trackedProfilerGroup exactGroupCleanup preservesFailureEvidence
  | _ => none

def checkProcessWatchdogDrain : List String → Option Bool
  | [exact, independent, normal, interruption, unrelated] => do
      let exactOwnedGroup ← parseBit exact
      let independentGroupLiveness ← parseBit independent
      let normalExitDrain ← parseBit normal
      let interruptionDrain ← parseBit interruption
      let unrelatedSurvives ← parseBit unrelated
      return processWatchdogDrainAccepted exactOwnedGroup
        independentGroupLiveness normalExitDrain interruptionDrain
        unrelatedSurvives
  | _ => none

def checkProfileTracePublication : List String → Option Bool
  | [paths, aliases, atomic, report, runner, preserves] => do
      let deterministicPrivatePaths ← parseBit paths
      let noAliasesOrPreexisting ← parseBit aliases
      let atomicDurablePublish ← parseBit atomic
      let reportDigestBinding ← parseBit report
      let runnerRevalidates ← parseBit runner
      let preservesFailureEvidence ← parseBit preserves
      return profileTracePublicationAccepted deterministicPrivatePaths
        noAliasesOrPreexisting atomicDurablePublish reportDigestBinding
        runnerRevalidates preservesFailureEvidence
  | _ => none

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

def checkProfileEvidence : List String → Bool
  | [builds, freshExecves, reuseExecves, freshCompile, reuseCompile] =>
      match builds.toNat?, freshExecves.toNat?, reuseExecves.toNat? with
      | some buildCount, some freshCount, some reuseCount =>
          profileEvidenceAccepted {
            controllerBuildCount := buildCount
            freshExecveSuccesses := freshCount
            reuseExecveSuccesses := reuseCount
            freshControllerCompilation := freshCompile == "1"
            reuseControllerCompilation := reuseCompile == "1"
          }
      | _, _, _ => false
  | _ => false

def main (args : List String) : IO UInt32 := do
  if args.head? == some "check-profile-trace-publication" then
    match checkProfileTracePublication args.tail with
    | some accepted =>
        IO.println (bit accepted)
        return 0
    | none =>
        IO.eprintln "invalid profile trace publication bits"
        return 2
  else if args.head? == some "process-watchdog-interrupt-exit" then
    match args.tail with
    | [signal] =>
        match signal.toNat? with
        | some signalNumber =>
            IO.println (processWatchdogInterruptExitStatus signalNumber)
            return 0
        | none =>
            IO.eprintln "invalid process watchdog interrupt signal"
            return 2
    | _ =>
        IO.eprintln "process watchdog interrupt signal is required"
        return 2
  else if args.head? == some "check-process-watchdog-drain" then
    match checkProcessWatchdogDrain args.tail with
    | some accepted =>
        IO.println (bit accepted)
        return 0
    | none =>
        IO.eprintln "invalid process watchdog drain bits"
        return 2
  else if args.head? == some "profile-interrupt-exit" then
    match args.tail with
    | [signal] =>
        match signal.toNat? with
        | some signalNumber =>
            IO.println (profileInterruptExitStatus signalNumber)
            return 0
        | none =>
            IO.eprintln "invalid profile interrupt signal"
            return 2
    | _ =>
        IO.eprintln "profile interrupt signal is required"
        return 2
  else if args.head? == some "check-profile-interruption" then
    match checkProfileInterruption args.tail with
    | some accepted =>
        IO.println (bit accepted)
        return 0
    | none =>
        IO.eprintln "invalid profile interruption bits"
        return 2
  else if args.head? == some "check-declared-tool-identity" then
    match checkDeclaredToolIdentity args.tail with
    | some accepted =>
        IO.println (bit accepted)
        return 0
    | none =>
        IO.eprintln "invalid declared tool identity bits"
        return 2
  else if args.head? == some "check-generated-hook-supervision" then
    match checkGeneratedHookSupervision args.tail with
    | some accepted =>
        IO.println (bit accepted)
        return 0
    | none =>
        IO.eprintln "invalid generated hook supervision bits"
        return 2
  else if args.head? == some "check-raw-transcript-path" then
    match args.tail with
    | [raw] =>
        IO.println (bit (transcriptRawAbsolutePathAllowed raw))
        return 0
    | _ =>
        IO.eprintln "one raw transcript path is required"
        return 2
  else if args.head? == some "check-transcript-codepoint" then
    match args.tail with
    | [raw] =>
        match raw.toNat? with
        | some codepoint =>
            IO.println (bit (transcriptRawCharacterAllowed (Char.ofNat codepoint)))
            return 0
        | none =>
            IO.eprintln "invalid transcript codepoint"
            return 2
    | _ =>
        IO.eprintln "one transcript codepoint is required"
        return 2
  else if args.head? == some "check-transcript-path" then
    IO.println (bit (transcriptRelativePartsAllowed args.tail))
    return 0
  else if args.head? == some "check-bounds" then
    if checkBounds args.tail then
      IO.println "bounds-ok"
      return 0
    else
      IO.eprintln "production bounds differ from proved bounds"
      return 3
  else if args.head? == some "check-profile-evidence" then
    if checkProfileEvidence args.tail then
      IO.println "profile-evidence-ok"
      return 0
    else
      IO.eprintln "profile evidence violates proved bounds"
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
