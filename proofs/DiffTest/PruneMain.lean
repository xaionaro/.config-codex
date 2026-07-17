import Proofs.PruneTurnState
import Std

open CodexHooks

def parseBit : String → Option Bool
  | "0" => some false
  | "1" => some true
  | _ => none

def evaluate (argument : String) : Bool :=
  match argument.splitOn "|" with
  | ["revalidate", lock, observed, current] =>
      match parseBit lock, parseBit observed, parseBit current with
      | some lockAcquired, some observedSelected, some currentSelected =>
          deleteAfterRevalidation lockAcquired observedSelected currentSelected
      | _, _, _ => false
  | _ => isPrunableName argument

def main (args : List String) : IO UInt32 := do
  for name in args do
    IO.println (if evaluate name then "1" else "0")
  return 0
