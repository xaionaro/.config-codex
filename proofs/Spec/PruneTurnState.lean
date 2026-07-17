namespace CodexHooks

def isAsciiAlphaNum (char : Char) : Bool :=
  ('a' ≤ char && char ≤ 'z') ||
    ('A' ≤ char && char ≤ 'Z') ||
    ('0' ≤ char && char ≤ '9')

def isTurnKeyChar (char : Char) : Bool :=
  isAsciiAlphaNum char || char == '_' || char == '-'

def nonemptyAll (predicate : Char → Bool) (chars : List Char) : Bool :=
  !chars.isEmpty && chars.all predicate

def stripPrefix : List Char → List Char → Option (List Char)
  | [], chars => some chars
  | _, [] => none
  | prefixChar :: prefixes, char :: chars =>
      if prefixChar = char then stripPrefix prefixes chars else none

def stripSuffix (suffix chars : List Char) : Option (List Char) :=
  (stripPrefix suffix.reverse chars.reverse).map List.reverse

def splitOnce (delimiter : Char) : List Char → Option (List Char × List Char)
  | [] => none
  | char :: chars =>
      if char = delimiter then
        some ([], chars)
      else
        (splitOnce delimiter chars).map fun (before, after) => (char :: before, after)

def temporaryStages : List (List Char) :=
  ["redacted".toList, "capped".toList, "json".toList,
    "validated".toList, "consumed".toList, "prompt".toList]

def isCaptureName (name : List Char) : Bool :=
  match stripPrefix "capture-turn-".toList name >>= stripSuffix ".json".toList with
  | some key => nonemptyAll isTurnKeyChar key
  | none => false

def isClaimName (name : List Char) : Bool :=
  match stripPrefix "claim-turn-".toList name with
  | some key => nonemptyAll isTurnKeyChar key
  | none => false

def isTemporaryName (name : List Char) : Bool :=
  match stripPrefix ".capture-turn-".toList name >>= splitOnce '.' with
  | some (key, remainder) =>
      match splitOnce '.' remainder with
      | some (stage, suffix) =>
          nonemptyAll isTurnKeyChar key &&
            temporaryStages.contains stage &&
            nonemptyAll isAsciiAlphaNum suffix
      | none => false
  | none => false

def isPrunableName (name : String) : Bool :=
  isCaptureName name.toList || isClaimName name.toList || isTemporaryName name.toList

def isExpired (now modified : Int) : Bool :=
  now - modified > 3600

def shouldPrune (name : String) (isRegular : Bool) (now modified : Int) : Bool :=
  isRegular && isPrunableName name && isExpired now modified

def deleteAfterRevalidation
    (lockAcquired _observedSelected currentSelected : Bool) : Bool :=
  lockAcquired && currentSelected

end CodexHooks
