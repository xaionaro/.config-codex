namespace CodexHooks

structure TurnCapture where
  turnId : String
  prompt : String
deriving DecidableEq

def turnIdByteLimit : Nat := 4096

def promptByteLimit : Nat := 4000

def usableTurnId (turnId : String) : Prop :=
  turnId ≠ "" ∧ turnId.utf8ByteSize ≤ turnIdByteLimit

instance usableTurnIdDecidable (turnId : String) : Decidable (usableTurnId turnId) := by
  unfold usableTurnId
  infer_instance

def validateTurnCapture (expectedTurnId : String) (capture : TurnCapture) : Option String :=
  if capture.turnId = expectedTurnId &&
      decide (usableTurnId capture.turnId) &&
      capture.prompt.utf8ByteSize ≤ promptByteLimit &&
      '\x00' ∉ capture.prompt.toList then
    some capture.prompt
  else
    none

end CodexHooks
