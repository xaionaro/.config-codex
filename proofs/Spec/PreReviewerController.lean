namespace CodexHooks

inductive ControllerStatus where
  | success
  | failure
  | timeout
  | signal
deriving DecidableEq, Repr

inductive ControllerEvent where
  | preflight
  | allocate
  | openStdin
  | startLeader
  | reapLeader (status : ControllerStatus)
  | requestTERM
  | requestKILL
  | publish
  | closeStdin
  | removeBuffer
deriving DecidableEq, Repr

structure ControllerState where
  preflightPassed : Bool := false
  bufferLive : Bool := false
  stdinLive : Bool := false
  leaderOwned : Bool := false
  leaderReaped : Bool := false
  status : Option ControllerStatus := none
  termRequested : Bool := false
  killRequested : Bool := false
  published : Bool := false
deriving DecidableEq, Repr

def controllerStep (state : ControllerState) : ControllerEvent → ControllerState
  | .preflight => { state with preflightPassed := true }
  | .allocate => if state.preflightPassed then { state with bufferLive := true } else state
  | .openStdin => if state.bufferLive then { state with stdinLive := true } else state
  | .startLeader =>
      if state.stdinLive && !state.published then
        { state with leaderOwned := true, leaderReaped := false }
      else state
  | .reapLeader result =>
      if state.leaderOwned && !state.published then
        { state with leaderOwned := false, leaderReaped := true, status := some result }
      else state
  | .requestTERM =>
      if state.leaderOwned then { state with termRequested := true } else state
  | .requestKILL =>
      if state.leaderOwned then { state with killRequested := true } else state
  | .publish =>
      if state.leaderReaped && state.status == some .success then
        { state with published := true }
      else state
  | .closeStdin => { state with stdinLive := false }
  | .removeBuffer => { state with bufferLive := false }

def controllerRun (events : List ControllerEvent) : ControllerState :=
  events.foldl controllerStep {}

def controllerTuple (state : ControllerState) : Bool × Bool × Bool × Bool × Bool × Bool :=
  (state.published, state.leaderReaped, state.bufferLive, state.stdinLive,
    state.termRequested, state.killRequested)

def preflightFailureTrace : List ControllerEvent :=
  []

def successTrace : List ControllerEvent :=
  [.preflight, .allocate, .openStdin, .startLeader, .closeStdin,
    .reapLeader .success, .publish, .removeBuffer]

def workerFailureTrace : List ControllerEvent :=
  [.preflight, .allocate, .openStdin, .startLeader, .closeStdin,
    .reapLeader .failure, .publish, .removeBuffer]

def signalTrace : List ControllerEvent :=
  [.preflight, .allocate, .openStdin, .startLeader, .closeStdin,
    .requestTERM, .requestKILL, .reapLeader .signal, .removeBuffer]

def acceleratedTimeoutTrace : List ControllerEvent :=
  [.preflight, .allocate, .openStdin, .startLeader, .closeStdin,
    .requestTERM, .requestKILL, .reapLeader .timeout, .publish, .removeBuffer]

end CodexHooks
