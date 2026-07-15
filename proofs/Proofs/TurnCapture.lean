import Spec.TurnCapture

namespace CodexHooks

theorem validateTurnCapture_sound (expectedTurnId : String) (capture : TurnCapture)
    (prompt : String) (validated : validateTurnCapture expectedTurnId capture = some prompt) :
    capture.turnId = expectedTurnId ∧
      usableTurnId capture.turnId ∧
      capture.prompt.utf8ByteSize ≤ promptByteLimit ∧
      '\x00' ∉ capture.prompt.toList ∧
      prompt = capture.prompt := by
  simp only [validateTurnCapture] at validated
  split at validated <;> simp_all

theorem validateTurnCapture_complete (expectedTurnId : String) (capture : TurnCapture)
    (sameTurn : capture.turnId = expectedTurnId)
    (turnIdUsable : usableTurnId capture.turnId)
    (promptBounded : capture.prompt.utf8ByteSize ≤ promptByteLimit)
    (promptHasNoNul : '\x00' ∉ capture.prompt.toList) :
    validateTurnCapture expectedTurnId capture = some capture.prompt := by
  subst expectedTurnId
  simp [validateTurnCapture, turnIdUsable, promptBounded, promptHasNoNul]

end CodexHooks
