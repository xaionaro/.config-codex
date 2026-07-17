import Spec.PruneTurnState
import Lean.Elab.Tactic.Omega

namespace CodexHooks

theorem shouldPrune_sound (name : String) (isRegular : Bool) (now modified : Int)
    (selected : shouldPrune name isRegular now modified = true) :
    isRegular = true ∧ isPrunableName name = true ∧ now - modified > 3600 := by
  simp [shouldPrune, isExpired] at selected
  simpa [and_assoc] using selected

theorem exactAgeBoundaryIsRetained (name : String) (isRegular : Bool) (modified : Int) :
    shouldPrune name isRegular (modified + 3600) modified = false := by
  simp [shouldPrune, isExpired]
  omega

theorem ageBeyondBoundaryIsSelected (name : String)
    (namespaceAccepted : isPrunableName name = true) (modified : Int) :
    shouldPrune name true (modified + 3601) modified = true := by
  simp [shouldPrune, isExpired, namespaceAccepted]
  omega

theorem nonRegularIsRetained (name : String) (now modified : Int) :
    shouldPrune name false now modified = false := by
  simp [shouldPrune]

theorem unscopedIsRetained (name : String) (isRegular : Bool) (now modified : Int)
    (unscoped : isPrunableName name = false) :
    shouldPrune name isRegular now modified = false := by
  simp [shouldPrune, unscoped]

theorem deleteAfterRevalidation_sound
    (lockAcquired observedSelected currentSelected : Bool)
    (selected :
      deleteAfterRevalidation lockAcquired observedSelected currentSelected = true) :
    lockAcquired = true ∧ currentSelected = true := by
  simpa [deleteAfterRevalidation] using selected

theorem staleObservationDoesNotControlDeletion
    (lockAcquired firstObservation secondObservation currentSelected : Bool) :
    deleteAfterRevalidation lockAcquired firstObservation currentSelected =
      deleteAfterRevalidation lockAcquired secondObservation currentSelected := by
  rfl

theorem freshReplacementIsRetained
    (lockAcquired observedSelected : Bool) :
    deleteAfterRevalidation lockAcquired observedSelected false = false := by
  simp [deleteAfterRevalidation]

theorem busyPublicationLockRetainsEntry
    (observedSelected currentSelected : Bool) :
    deleteAfterRevalidation false observedSelected currentSelected = false := by
  simp [deleteAfterRevalidation]

end CodexHooks
