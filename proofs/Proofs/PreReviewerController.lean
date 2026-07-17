import Spec.PreReviewerController

namespace CodexHooks

def confirmationSafe (state : ControllerState) : Prop :=
  state.publicationConfirmed = true →
    state.preflightPassed = true ∧
    descriptorsClosed state = true ∧
    state.captureComplete = true ∧
    state.reviewerStarted = true ∧
    state.captureRejected = false ∧
    state.bytesValid = true ∧
    state.cancellationObserved = false ∧
    state.reviewerReaped = true ∧
    state.reviewerStatus = some .success ∧
    state.publicationStarted = true ∧
    state.outputMayHaveEscaped = true ∧
    state.publisherOwned = false ∧
    state.publisherReaped = true ∧
    state.publisherStatus = some .success

theorem controllerStep_confirmation_safe
    (state : ControllerState) (event : ExternalEvidence)
    (safe : confirmationSafe state) :
    confirmationSafe (controllerStep state event) := by
  by_cases confirmed : state.publicationConfirmed = true
  · simp [controllerStep, confirmed, safe]
  · cases event <;>
      simp_all [controllerStep, controllerStepUnconfirmed, confirmationSafe,
        publicationConfirmable, publisherStartable, publisherOwnable,
        publicationEligible, descriptorsClosed] <;>
      split <;> simp_all

theorem controllerFold_confirmation_safe
    (events : List ExternalEvidence) (state : ControllerState)
    (safe : confirmationSafe state) :
    confirmationSafe (events.foldl controllerStep state) := by
  induction events generalizing state with
  | nil => exact safe
  | cons event rest ih =>
      simp only [List.foldl_cons]
      exact ih (controllerStep state event)
        (controllerStep_confirmation_safe state event safe)

theorem controllerRun_confirmation_safe (events : List ExternalEvidence) :
    confirmationSafe (controllerRun events) := by
  unfold controllerRun
  exact controllerFold_confirmation_safe events {} (by simp [confirmationSafe])

theorem descriptor_cleanup_idempotent (state : ControllerState) :
    controllerStep (controllerStep state .inputClosed) .inputClosed =
      controllerStep state .inputClosed ∧
    controllerStep (controllerStep state .reviewerReadClosed) .reviewerReadClosed =
      controllerStep state .reviewerReadClosed ∧
    controllerStep (controllerStep state .reviewerWriteClosed) .reviewerWriteClosed =
      controllerStep state .reviewerWriteClosed := by
  by_cases confirmed : state.publicationConfirmed = true <;>
    simp [controllerStep, controllerStepUnconfirmed, confirmed]

theorem publication_facts_are_monotone
    (state : ControllerState) (event : ExternalEvidence) :
    (state.publicationStarted = true →
      (controllerStep state event).publicationStarted = true) ∧
    (state.outputMayHaveEscaped = true →
      (controllerStep state event).outputMayHaveEscaped = true) ∧
    (state.publicationConfirmed = true →
      (controllerStep state event).publicationConfirmed = true) := by
  by_cases confirmed : state.publicationConfirmed = true
  · simp [controllerStep, confirmed]
  · simp [controllerStep, confirmed]
    cases event <;> simp [controllerStepUnconfirmed] <;> split <;> simp_all

theorem cancelled_state_cannot_confirm
    (state : ControllerState)
    (cancelled : state.cancellationObserved = true)
    (unconfirmed : state.publicationConfirmed = false)
    (event : ExternalEvidence) :
    (controllerStep state event).cancellationObserved = true ∧
      (controllerStep state event).publicationConfirmed = false := by
  cases event <;>
    simp_all [controllerStep, controllerStepUnconfirmed,
      publicationConfirmable, publisherStartable, publisherOwnable,
      publicationEligible, descriptorsClosed] <;>
    split <;> simp_all

theorem cancelled_fold_cannot_confirm
    (events : List ExternalEvidence) (state : ControllerState)
    (cancelled : state.cancellationObserved = true)
    (unconfirmed : state.publicationConfirmed = false) :
    let final := events.foldl controllerStep state
    final.cancellationObserved = true ∧ final.publicationConfirmed = false := by
  induction events generalizing state with
  | nil => exact ⟨cancelled, unconfirmed⟩
  | cons event rest ih =>
      simp only [List.foldl_cons]
      have next := cancelled_state_cannot_confirm state cancelled unconfirmed event
      exact ih (controllerStep state event) next.1 next.2

theorem maintenance_visit_count_bounded (population : Nat) :
    maintenanceVisitCount population ≤ maintenanceVisitBudget := by
  exact Nat.min_le_right population maintenanceVisitBudget

theorem atomic_publication_fits_linux_pipe_buf :
    atomicPublicationBudget ≤ 4096 := by
  decide

theorem nested_deadlines_leave_cleanup_margins :
    backendDeadlineSeconds < controllerDeadlineSeconds ∧
    controllerDeadlineSeconds < hookDeadlineSeconds := by
  decide

theorem accepted_generated_hook_has_complete_supervision
    (newProcessGroup deadlineArmed exactGroupCleanup : Bool)
    (accepted :
      generatedHookSupervisionAccepted
        newProcessGroup deadlineArmed exactGroupCleanup = true) :
    newProcessGroup = true ∧
      deadlineArmed = true ∧ exactGroupCleanup = true := by
  simp [generatedHookSupervisionAccepted] at accepted
  exact ⟨accepted.1.1, accepted.1.2, accepted.2⟩

theorem unrelated_process_is_not_a_cleanup_target :
    generatedHookCleanupTargetAllowed false = false := by
  rfl

theorem owned_group_is_a_cleanup_target :
    generatedHookCleanupTargetAllowed true = true := by
  rfl

theorem accepted_declared_tool_has_exact_independent_identity
    (uniqueRole exactCanonicalPath exactBytes : Bool)
    (accepted :
      declaredToolIdentityAccepted uniqueRole exactCanonicalPath exactBytes = true) :
    uniqueRole = true ∧ exactCanonicalPath = true ∧ exactBytes = true := by
  simp [declaredToolIdentityAccepted] at accepted
  exact ⟨accepted.1.1, accepted.1.2, accepted.2⟩

theorem same_basename_without_exact_path_is_rejected
    (uniqueRole exactBytes : Bool) :
    declaredToolIdentityAccepted uniqueRole false exactBytes = false := by
  simp [declaredToolIdentityAccepted]

theorem accepted_profile_interruption_has_complete_supervision
    (trapsAllModes trackedProfilerGroup exactGroupCleanup
      preservesFailureEvidence : Bool)
    (accepted :
      profileInterruptionSupervisionAccepted trapsAllModes trackedProfilerGroup
        exactGroupCleanup preservesFailureEvidence = true) :
    trapsAllModes = true ∧ trackedProfilerGroup = true ∧
      exactGroupCleanup = true ∧ preservesFailureEvidence = true := by
  simp [profileInterruptionSupervisionAccepted] at accepted
  exact ⟨accepted.1.1.1, accepted.1.1.2, accepted.1.2, accepted.2⟩

theorem profile_hup_exit_status : profileInterruptExitStatus 1 = 129 := by
  rfl

theorem profile_int_exit_status : profileInterruptExitStatus 2 = 130 := by
  rfl

theorem profile_term_exit_status : profileInterruptExitStatus 15 = 143 := by
  rfl

theorem accepted_process_watchdog_drain_is_exact_and_complete
    (exactOwnedGroup independentGroupLiveness normalExitDrain
      interruptionDrain unrelatedSurvives : Bool)
    (accepted :
      processWatchdogDrainAccepted exactOwnedGroup independentGroupLiveness
        normalExitDrain interruptionDrain unrelatedSurvives = true) :
    exactOwnedGroup = true ∧ independentGroupLiveness = true ∧
      normalExitDrain = true ∧ interruptionDrain = true ∧
      unrelatedSurvives = true := by
  simp [processWatchdogDrainAccepted] at accepted
  exact
    ⟨accepted.1.1.1.1, accepted.1.1.1.2, accepted.1.1.2, accepted.1.2,
      accepted.2⟩

theorem process_watchdog_term_exit_status :
    processWatchdogInterruptExitStatus 15 = 143 := by
  rfl

theorem accepted_profile_trace_publication_is_bound_and_durable
    (deterministicPrivatePaths noAliasesOrPreexisting atomicDurablePublish
      reportDigestBinding runnerRevalidates preservesFailureEvidence : Bool)
    (accepted :
      profileTracePublicationAccepted deterministicPrivatePaths
        noAliasesOrPreexisting atomicDurablePublish reportDigestBinding
        runnerRevalidates preservesFailureEvidence = true) :
    deterministicPrivatePaths = true ∧ noAliasesOrPreexisting = true ∧
      atomicDurablePublish = true ∧ reportDigestBinding = true ∧
      runnerRevalidates = true ∧ preservesFailureEvidence = true := by
  simp [profileTracePublicationAccepted] at accepted
  exact
    ⟨accepted.1.1.1.1.1, accepted.1.1.1.1.2, accepted.1.1.1.2,
      accepted.1.1.2, accepted.1.2, accepted.2⟩

theorem admission_input_is_bounded :
    admissionInputBudget = 65536 := by
  rfl

theorem maintenance_uses_one_primary_call :
    maintenancePrimaryCalls = 1 ∧ maintenanceVisitBudget = 170 := by
  decide

theorem maintenance_never_holds_shared_turn_lock :
    maintenanceHoldsSharedTurnLock = false := by
  rfl

theorem transcript_empty_relative_path_rejected :
    transcriptRelativePartsAllowed [] = false := by
  rfl

theorem transcript_empty_component_rejected :
    transcriptPathComponentAllowed "" = false := by
  decide

theorem transcript_dot_component_rejected :
    transcriptPathComponentAllowed "." = false := by
  decide

theorem transcript_dot_dot_component_rejected :
    transcriptPathComponentAllowed ".." = false := by
  decide

theorem transcript_regular_component_accepted :
    transcriptPathComponentAllowed "rollout.jsonl" = true := by
  decide

theorem transcript_raw_canonical_absolute_path_accepted :
    transcriptRawAbsolutePathAllowed "/sessions/rollout.jsonl" = true := by
  native_decide

theorem transcript_raw_double_slash_rejected :
    transcriptRawAbsolutePathAllowed "/sessions//rollout.jsonl" = false := by
  native_decide

theorem transcript_raw_dot_component_rejected :
    transcriptRawAbsolutePathAllowed "/sessions/./rollout.jsonl" = false := by
  native_decide

theorem transcript_raw_trailing_dot_rejected :
    transcriptRawAbsolutePathAllowed "/sessions/rollout.jsonl/." = false := by
  native_decide

theorem transcript_raw_nul_rejected :
    transcriptRawAbsolutePathAllowed "/sessions/rollout.jsonl\u0000" = false := by
  native_decide

theorem transcript_raw_newline_rejected :
    transcriptRawAbsolutePathAllowed "/sessions/rollout.jsonl\n" = false := by
  native_decide

theorem transcript_raw_c1_control_rejected :
    transcriptRawCharacterAllowed (Char.ofNat 159) = false := by
  native_decide

theorem accepted_profile_has_one_build
    (evidence : ProfileEvidence)
    (accepted : profileEvidenceAccepted evidence = true) :
    evidence.controllerBuildCount = 1 := by
  simp [profileEvidenceAccepted] at accepted
  exact accepted.1.1.1.1

theorem accepted_profile_has_two_nonempty_phases
    (evidence : ProfileEvidence)
    (accepted : profileEvidenceAccepted evidence = true) :
    0 < evidence.freshExecveSuccesses ∧
      0 < evidence.reuseExecveSuccesses := by
  simp [profileEvidenceAccepted] at accepted
  exact ⟨accepted.1.1.1.2, accepted.1.1.2⟩

theorem accepted_profile_separates_fresh_build_from_reuse
    (evidence : ProfileEvidence)
    (accepted : profileEvidenceAccepted evidence = true) :
    evidence.freshControllerCompilation = true ∧
      evidence.reuseControllerCompilation = false := by
  simp [profileEvidenceAccepted] at accepted
  exact ⟨accepted.1.2, accepted.2⟩

end CodexHooks
