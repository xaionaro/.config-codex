import Proofs.PruneTurnState
import Std

open CodexHooks

def main (args : List String) : IO UInt32 := do
  for name in args do
    IO.println (if isPrunableName name then "1" else "0")
  return 0
