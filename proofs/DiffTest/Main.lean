import Proofs.Utf8Prefix
import Std

open CodexHooks

def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
      IO.eprintln "usage: utf8PrefixDiff BUDGET [STRING ...]"
      return 2
  | budgetText :: inputs =>
      match budgetText.toNat? with
      | none =>
          IO.eprintln "budget must be a natural number"
          return 2
      | some budget =>
          for input in inputs do
            IO.println (takeUtf8Prefix budget input)
          return 0
