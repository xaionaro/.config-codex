namespace CodexHooks

def utf8Width (char : Char) : Nat :=
  char.toString.utf8ByteSize

def utf8Bytes : List Char → Nat
  | [] => 0
  | char :: chars => utf8Width char + utf8Bytes chars

def takeUtf8Chars : Nat → List Char → List Char
  | _, [] => []
  | budget, char :: chars =>
      if utf8Width char ≤ budget then
        char :: takeUtf8Chars (budget - utf8Width char) chars
      else
        []

def takeUtf8Prefix (budget : Nat) (input : String) : String :=
  String.mk (takeUtf8Chars budget input.toList)

end CodexHooks
