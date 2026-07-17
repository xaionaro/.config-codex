import Lake
open Lake DSL

package «codex-stop-proofs» where

lean_lib StopEci where

lean_lib CodexHooksProofs where
  roots := #[`Spec.OwnedProcessGroup, `Proofs.OwnedProcessGroup,
    `Spec.PruneTurnState, `Spec.TurnCapture, `Spec.Utf8Prefix,
    `Spec.PreReviewerController, `Proofs.PruneTurnState, `Proofs.TurnCapture,
    `Proofs.Utf8Prefix, `Proofs.PreReviewerController]

@[default_target]
lean_exe utf8PrefixDiff where
  root := `DiffTest.Main

@[default_target]
lean_exe pruneTurnStateDiff where
  root := `DiffTest.PruneMain

@[default_target]
lean_exe turnCaptureDiff where
  root := `DiffTest.TurnCaptureMain

@[default_target]
lean_exe preReviewerControllerDiff where
  root := `DiffTest.PreReviewerControllerMain

@[default_target]
lean_exe ownedProcessGroupDiff where
  root := `DiffTest.OwnedProcessGroupMain
