namespace CodexHooks

structure TurnCapture where
  turnId : String
  prompt : String
deriving DecidableEq

def turnIdByteLimit : Nat := 4096

def promptByteLimit : Nat := 4000

def validateTurnCapture (expectedTurnId : String) (capture : TurnCapture) : Option String :=
  if capture.turnId = expectedTurnId &&
      capture.turnId.utf8ByteSize ≤ turnIdByteLimit &&
      capture.prompt.utf8ByteSize ≤ promptByteLimit &&
      '\x00' ∉ capture.prompt.toList then
    some capture.prompt
  else
    none

end CodexHooks
