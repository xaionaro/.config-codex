namespace StopEci

inductive Marker where
  | session
  | sideParent
  | legacy
  deriving DecidableEq, Repr

structure Input where
  validSession : Bool
  subagent : Bool
  sessionMarker : Bool
  sideParentMarker : Bool
  legacyMarker : Bool
  deriving Repr, DecidableEq

def activeMarker (i : Input) : Option Marker :=
  match i.validSession, i.sessionMarker, i.subagent, i.sideParentMarker, i.legacyMarker with
  | false, _, _, _, _ => none
  | true, true, _, _, _ => some Marker.session
  | true, false, true, _, _ => none
  | true, false, false, true, _ => some Marker.sideParent
  | true, false, false, false, true => some Marker.legacy
  | true, false, false, false, false => none

theorem invalidSession_noMarker {i : Input}
    (hValid : i.validSession = false) :
    activeMarker i = none := by
  cases i
  simp_all [activeMarker]

theorem ownSessionMarker_wins {i : Input}
    (hValid : i.validSession = true)
    (hSession : i.sessionMarker = true) :
    activeMarker i = some Marker.session := by
  cases i
  simp_all [activeMarker]

theorem subagentWithoutOwnMarker_inheritsNoMarker {i : Input}
    (hValid : i.validSession = true)
    (hSubagent : i.subagent = true)
    (hSession : i.sessionMarker = false) :
    activeMarker i = none := by
  cases i
  simp_all [activeMarker]

theorem sideParentMarker_appliesOnlyOutsideSubagent {i : Input}
    (hValid : i.validSession = true)
    (hSubagent : i.subagent = false)
    (hSession : i.sessionMarker = false)
    (hSideParent : i.sideParentMarker = true) :
    activeMarker i = some Marker.sideParent := by
  cases i
  simp_all [activeMarker]

theorem legacyMarker_appliesOnlyWithoutSessionOrParent {i : Input}
    (hValid : i.validSession = true)
    (hSubagent : i.subagent = false)
    (hSession : i.sessionMarker = false)
    (hSideParent : i.sideParentMarker = false)
    (hLegacy : i.legacyMarker = true) :
    activeMarker i = some Marker.legacy := by
  cases i
  simp_all [activeMarker]

theorem noMarker_whenNoApplicableMarker {i : Input}
    (hValid : i.validSession = true)
    (hSubagent : i.subagent = false)
    (hSession : i.sessionMarker = false)
    (hSideParent : i.sideParentMarker = false)
    (hLegacy : i.legacyMarker = false) :
    activeMarker i = none := by
  cases i
  simp_all [activeMarker]

end StopEci
