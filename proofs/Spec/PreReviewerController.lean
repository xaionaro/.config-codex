namespace CodexHooks

inductive ChildStatus where
  | success
  | failure
  | timeout
  | signal
deriving DecidableEq, Repr

inductive ExternalEvidence where
  | preflightPassed
  | inputOpened
  | reviewerOwned
  | reviewerStarted
  | inputClosed
  | reviewerReadClosed
  | reviewerWriteClosed
  | captureComplete
  | captureRejected
  | bytesValid
  | cancellationObserved
  | reviewerReaped (status : ChildStatus)
  | publisherOwned
  | publisherStarted
  | outputEscaped
  | publisherReaped (status : ChildStatus)
  | publicationConfirmed
deriving DecidableEq, Repr

structure ControllerState where
  preflightPassed : Bool := false
  inputLive : Bool := false
  reviewerReadLive : Bool := false
  reviewerWriteLive : Bool := false
  captureComplete : Bool := false
  captureRejected : Bool := false
  bytesValid : Bool := false
  cancellationObserved : Bool := false
  reviewerOwned : Bool := false
  reviewerStarted : Bool := false
  reviewerReaped : Bool := false
  reviewerStatus : Option ChildStatus := none
  publisherOwned : Bool := false
  publisherReaped : Bool := false
  publisherStatus : Option ChildStatus := none
  publicationStarted : Bool := false
  outputMayHaveEscaped : Bool := false
  publicationConfirmed : Bool := false
deriving DecidableEq, Repr

def descriptorsClosed (state : ControllerState) : Bool :=
  !state.inputLive && !state.reviewerReadLive && !state.reviewerWriteLive

def publicationEligible (state : ControllerState) : Bool :=
  state.preflightPassed && descriptorsClosed state &&
    state.captureComplete && state.reviewerStarted &&
    !state.captureRejected && state.bytesValid &&
    !state.cancellationObserved && state.reviewerReaped &&
    state.reviewerStatus == some .success

def publisherOwnable (state : ControllerState) : Bool :=
  publicationEligible state && !state.publisherOwned &&
    !state.publisherReaped && !state.publicationStarted

def publisherStartable (state : ControllerState) : Bool :=
  publicationEligible state && state.publisherOwned &&
    !state.publisherReaped && !state.publicationStarted

def publicationConfirmable (state : ControllerState) : Bool :=
  publicationEligible state && state.publicationStarted &&
    state.outputMayHaveEscaped &&
    !state.publisherOwned && state.publisherReaped &&
    state.publisherStatus == some .success

def controllerStepUnconfirmed
    (state : ControllerState) : ExternalEvidence → ControllerState
  | .preflightPassed => { state with preflightPassed := true }
  | .inputOpened =>
      if state.preflightPassed then { state with inputLive := true } else state
  | .reviewerOwned =>
      if state.inputLive && !state.reviewerOwned && !state.reviewerReaped then
        { state with
            reviewerOwned := true
            reviewerReadLive := true
            reviewerWriteLive := true }
      else state
  | .reviewerStarted =>
      if state.reviewerOwned && !state.cancellationObserved then
        { state with reviewerStarted := true }
      else state
  | .inputClosed => { state with inputLive := false }
  | .reviewerReadClosed => { state with reviewerReadLive := false }
  | .reviewerWriteClosed => { state with reviewerWriteLive := false }
  | .captureComplete =>
      if state.reviewerStarted && state.reviewerReadLive then
        { state with captureComplete := true, captureRejected := false }
      else state
  | .captureRejected =>
      { state with captureComplete := false, captureRejected := true }
  | .bytesValid =>
      if state.captureComplete && !state.captureRejected then
        { state with bytesValid := true }
      else state
  | .cancellationObserved =>
      { state with cancellationObserved := true }
  | .reviewerReaped status =>
      if state.reviewerOwned then
        { state with
            reviewerOwned := false
            reviewerReaped := true
            reviewerStatus := some status }
      else state
  | .publisherOwned =>
      if publisherOwnable state then
        { state with publisherOwned := true }
      else state
  | .publisherStarted =>
      if publisherStartable state then
        { state with publicationStarted := true }
      else state
  | .outputEscaped =>
      if state.publicationStarted then
        { state with outputMayHaveEscaped := true }
      else state
  | .publisherReaped status =>
      if state.publisherOwned then
        { state with
            publisherOwned := false
            publisherReaped := true
            publisherStatus := some status }
      else state
  | .publicationConfirmed =>
      if publicationConfirmable state then
        { state with publicationConfirmed := true }
      else state

def controllerStep
    (state : ControllerState) (event : ExternalEvidence) : ControllerState :=
  if state.publicationConfirmed then state else controllerStepUnconfirmed state event

def controllerRun (events : List ExternalEvidence) : ControllerState :=
  events.foldl controllerStep {}

def controllerTuple (state : ControllerState) :
    Bool × Bool × Bool × Bool × Bool × Bool :=
  (state.publicationStarted, state.outputMayHaveEscaped,
    state.publicationConfirmed, state.reviewerReaped,
    descriptorsClosed state, state.cancellationObserved)

def maintenanceVisitBudget : Nat := 4096 / 24

def atomicPublicationBudget : Nat := 4096

def backendDeadlineSeconds : Nat := 58

def controllerDeadlineSeconds : Nat := 70

def hookDeadlineSeconds : Nat := 75

def generatedHookSupervisionAccepted
    (newProcessGroup deadlineArmed exactGroupCleanup : Bool) : Bool :=
  newProcessGroup && deadlineArmed && exactGroupCleanup

def generatedHookCleanupTargetAllowed (sameOwnedGroup : Bool) : Bool :=
  sameOwnedGroup

def declaredToolIdentityAccepted
    (uniqueRole exactCanonicalPath exactBytes : Bool) : Bool :=
  uniqueRole && exactCanonicalPath && exactBytes

def profileInterruptionSupervisionAccepted
    (trapsAllModes trackedProfilerGroup exactGroupCleanup
      preservesFailureEvidence : Bool) : Bool :=
  trapsAllModes && trackedProfilerGroup && exactGroupCleanup &&
    preservesFailureEvidence

def profileInterruptExitStatus (signalNumber : Nat) : Nat :=
  128 + signalNumber

def processWatchdogDrainAccepted
    (exactOwnedGroup independentGroupLiveness normalExitDrain
      interruptionDrain unrelatedSurvives : Bool) : Bool :=
  exactOwnedGroup && independentGroupLiveness && normalExitDrain &&
    interruptionDrain && unrelatedSurvives

def processWatchdogInterruptExitStatus (signalNumber : Nat) : Nat :=
  128 + signalNumber

def profileTracePublicationAccepted
    (deterministicPrivatePaths noAliasesOrPreexisting atomicDurablePublish
      reportDigestBinding runnerRevalidates preservesFailureEvidence : Bool) : Bool :=
  deterministicPrivatePaths && noAliasesOrPreexisting && atomicDurablePublish &&
    reportDigestBinding && runnerRevalidates && preservesFailureEvidence

def admissionInputBudget : Nat := 65536

def maintenancePrimaryCalls : Nat := 1

def maintenanceHoldsSharedTurnLock : Bool := false

def maintenanceVisitCount (population : Nat) : Nat :=
  min population maintenanceVisitBudget

def transcriptPathComponentAllowed (component : String) : Bool :=
  !component.isEmpty && component != "." && component != ".."

def transcriptRelativePartsAllowed (components : List String) : Bool :=
  !components.isEmpty && components.all transcriptPathComponentAllowed

def transcriptRawCharacterAllowed (character : Char) : Bool :=
  let codepoint := character.toNat
  decide (32 ≤ codepoint ∧ (codepoint < 127 ∨ 159 < codepoint))

def transcriptRawStringAllowed (raw : String) : Bool :=
  raw.toList.all transcriptRawCharacterAllowed

def transcriptRawAbsolutePathAllowed (raw : String) : Bool :=
  if transcriptRawStringAllowed raw && raw.startsWith "/" then
    match raw.splitOn "/" with
    | "" :: components => transcriptRelativePartsAllowed components
    | _ => false
  else
    false

structure ProfileEvidence where
  controllerBuildCount : Nat
  freshExecveSuccesses : Nat
  reuseExecveSuccesses : Nat
  freshControllerCompilation : Bool
  reuseControllerCompilation : Bool
deriving DecidableEq, Repr

def profileEvidenceAccepted (evidence : ProfileEvidence) : Bool :=
  evidence.controllerBuildCount == 1 &&
    0 < evidence.freshExecveSuccesses &&
    0 < evidence.reuseExecveSuccesses &&
    evidence.freshControllerCompilation &&
    !evidence.reuseControllerCompilation

end CodexHooks
