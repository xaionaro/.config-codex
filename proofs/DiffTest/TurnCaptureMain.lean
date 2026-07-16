import Proofs.TurnCapture
import Std

open CodexHooks

def repeated (count : Nat) (char : Char) : String :=
  String.mk (List.replicate count char)

def captureCase : String → Option (String × TurnCapture)
  | "exact" => some ("turn", { turnId := "turn", prompt := "prompt" })
  | "mismatch" => some ("turn", { turnId := "other", prompt := "prompt" })
  | "prompt-3999" => some ("turn", { turnId := "turn", prompt := repeated 3999 'x' })
  | "prompt-4000" => some ("turn", { turnId := "turn", prompt := repeated 4000 'x' })
  | "prompt-4001" => some ("turn", { turnId := "turn", prompt := repeated 4001 'x' })
  | "prompt-multibyte-4000" => some ("turn", { turnId := "turn", prompt := repeated 2000 'é' })
  | "prompt-multibyte-4002" => some ("turn", { turnId := "turn", prompt := repeated 2001 'é' })
  | "id-4096" =>
      let turnId := repeated 4096 'x'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "id-4097" =>
      let turnId := repeated 4097 'x'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "id-multibyte-4096" =>
      let turnId := repeated 2048 'é'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "id-multibyte-4098" =>
      let turnId := repeated 2049 'é'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "turn-empty" => some ("", { turnId := "", prompt := "prompt" })
  | "turn-ascii-4095" =>
      let turnId := repeated 4095 'x'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "turn-ascii-4096" =>
      let turnId := repeated 4096 'x'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "turn-ascii-4097" =>
      let turnId := repeated 4097 'x'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "turn-two-byte-4096" =>
      let turnId := repeated 2048 'é'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "turn-two-byte-4098" =>
      let turnId := repeated 2049 'é'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "turn-four-byte-4096" =>
      let turnId := repeated 1024 '😀'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "turn-four-byte-4100" =>
      let turnId := repeated 1025 '😀'
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "turn-mixed-4096" =>
      let turnId := repeated 4090 'x' ++ "é😀"
      some (turnId, { turnId := turnId, prompt := "prompt" })
  | "empty" => some ("turn", { turnId := "turn", prompt := "" })
  | "nul" => some ("turn", { turnId := "turn", prompt := String.mk ['a', '\x00', 'b'] })
  | "replacement" => some ("turn", { turnId := "turn", prompt := "before-�-after" })
  | _ => none

def main (args : List String) : IO UInt32 := do
  for label in args do
    match captureCase label with
    | some (expected, capture) =>
        IO.println (if (validateTurnCapture expected capture).isSome then "1" else "0")
    | none =>
        IO.eprintln s!"unknown case: {label}"
        return 2
  return 0
