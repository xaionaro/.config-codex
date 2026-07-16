import Spec.PreReviewerController

namespace CodexHooks

def controllerSafe (state : ControllerState) : Prop :=
  state.published = true →
    state.leaderReaped = true ∧ state.status = some .success

theorem controllerStep_safe (state : ControllerState) (event : ControllerEvent)
    (safe : controllerSafe state) : controllerSafe (controllerStep state event) := by
  cases event <;> simp only [controllerStep]
  all_goals first | exact safe | (split <;> simp_all [controllerSafe])

theorem controllerFold_safe (events : List ControllerEvent) (state : ControllerState)
    (safe : controllerSafe state) : controllerSafe (events.foldl controllerStep state) := by
  induction events generalizing state with
  | nil => exact safe
  | cons event rest ih =>
      simp only [List.foldl_cons]
      exact ih (controllerStep state event) (controllerStep_safe state event safe)

theorem controllerRun_safe (events : List ControllerEvent) :
    controllerSafe (controllerRun events) := by
  unfold controllerRun
  exact controllerFold_safe events {} (by simp [controllerSafe])

theorem cleanup_idempotent (state : ControllerState) :
    controllerStep (controllerStep state .closeStdin) .closeStdin =
      controllerStep state .closeStdin ∧
    controllerStep (controllerStep state .removeBuffer) .removeBuffer =
      controllerStep state .removeBuffer := by
  simp [controllerStep]

theorem preflight_failure_never_publishes :
    (controllerRun preflightFailureTrace).published = false := by native_decide

theorem success_publishes_after_reap :
    (controllerRun successTrace).published = true ∧
      (controllerRun successTrace).leaderReaped = true := by native_decide

theorem worker_failure_never_publishes :
    (controllerRun workerFailureTrace).published = false := by native_decide

theorem signal_never_publishes_and_releases_resources :
    let state := controllerRun signalTrace
    state.published = false ∧ state.bufferLive = false ∧
      state.stdinLive = false ∧ state.leaderOwned = false := by native_decide

theorem timeout_never_publishes_and_releases_resources :
    let state := controllerRun acceleratedTimeoutTrace
    state.published = false ∧ state.bufferLive = false ∧
      state.stdinLive = false ∧ state.leaderOwned = false := by native_decide

end CodexHooks
