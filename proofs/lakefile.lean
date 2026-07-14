import Lake
open Lake DSL

package «codex-stop-proofs» where

lean_lib StopEci where

lean_lib CodexHooksProofs where
  roots := #[`Spec.PruneTurnState, `Spec.TurnCapture, `Spec.Utf8Prefix,
    `Proofs.PruneTurnState, `Proofs.TurnCapture, `Proofs.Utf8Prefix]

@[default_target]
lean_exe utf8PrefixDiff where
  root := `DiffTest.Main

@[default_target]
lean_exe pruneTurnStateDiff where
  root := `DiffTest.PruneMain

@[default_target]
lean_exe turnCaptureDiff where
  root := `DiffTest.TurnCaptureMain
