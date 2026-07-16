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

theorem admission_input_is_bounded :
    admissionInputBudget = 65536 := by
  rfl

theorem maintenance_uses_one_primary_call :
    maintenancePrimaryCalls = 1 ∧ maintenanceVisitBudget = 170 := by
  decide

end CodexHooks
