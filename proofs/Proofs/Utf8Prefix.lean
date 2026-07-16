import Spec.Utf8Prefix
import Lean.Elab.Tactic.Omega

namespace CodexHooks

theorem takeUtf8Chars_bytes_le (budget : Nat) (chars : List Char) :
    utf8Bytes (takeUtf8Chars budget chars) ≤ budget := by
  induction chars generalizing budget with
  | nil => simp [takeUtf8Chars, utf8Bytes]
  | cons char chars ih =>
      simp only [takeUtf8Chars]
      split
      next fits =>
        simp only [utf8Bytes]
        have tailBound := ih (budget - utf8Width char)
        omega
      next doesNotFit =>
        simp [utf8Bytes]

theorem takeUtf8Chars_isPrefix (budget : Nat) (chars : List Char) :
    (takeUtf8Chars budget chars).IsPrefix chars := by
  induction chars generalizing budget with
  | nil => simp [takeUtf8Chars]
  | cons char chars ih =>
      simp only [takeUtf8Chars]
      split
      next fits =>
        rcases ih (budget - utf8Width char) with ⟨suffix, suffixEq⟩
        refine ⟨suffix, ?_⟩
        simp [suffixEq]
      next doesNotFit =>
        exact List.nil_prefix

theorem stringMk_append (left right : List Char) :
    String.mk (left ++ right) = String.mk left ++ String.mk right := by
  rw [← String.toByteArray_inj]
  simp [String.mk, List.utf8Encode_append]

theorem stringMk_singleton (char : Char) :
    String.mk [char] = char.toString := by
  rw [← String.toByteArray_inj]
  simp [String.mk, Char.toString, String.singleton]

theorem stringMk_nil : String.mk [] = "" := by
  rw [← String.toByteArray_inj]
  simp [String.mk]

theorem stringMk_toList (chars : List Char) :
    (String.mk chars).toList = chars := by
  induction chars with
  | nil => simp [stringMk_nil]
  | cons char chars ih =>
      rw [show char :: chars = [char] ++ chars by rfl]
      rw [stringMk_append, String.toList_append, stringMk_singleton]
      simp [ih]

theorem stringMk_utf8ByteSize (chars : List Char) :
    (String.mk chars).utf8ByteSize = utf8Bytes chars := by
  induction chars with
  | nil => simp [utf8Bytes, stringMk_nil]
  | cons char chars ih =>
      rw [show char :: chars = [char] ++ chars by rfl]
      rw [stringMk_append, String.utf8ByteSize_append, stringMk_singleton]
      simp [utf8Bytes, utf8Width, ih]

theorem takeUtf8Prefix_utf8ByteSize_le (budget : Nat) (input : String) :
    (takeUtf8Prefix budget input).utf8ByteSize ≤ budget := by
  rw [takeUtf8Prefix, stringMk_utf8ByteSize]
  exact takeUtf8Chars_bytes_le budget input.toList

theorem takeUtf8Prefix_isPrefix (budget : Nat) (input : String) :
    ∃ suffix : String, takeUtf8Prefix budget input ++ suffix = input := by
  rcases takeUtf8Chars_isPrefix budget input.toList with ⟨suffix, h⟩
  refine ⟨String.mk suffix, ?_⟩
  simp only [takeUtf8Prefix]
  have joined : String.mk (takeUtf8Chars budget input.toList ++ suffix) = input := by
    rw [← String.toByteArray_inj]
    simp [String.mk, h]
  simpa only [stringMk_append] using joined

theorem takeUtf8Chars_next_not_fit (budget : Nat) (chars : List Char)
    (next : Char) (rest : List Char)
    (h : chars = takeUtf8Chars budget chars ++ next :: rest) :
    budget - utf8Bytes (takeUtf8Chars budget chars) < utf8Width next := by
  induction chars generalizing budget next rest with
  | nil => simp [takeUtf8Chars] at h
  | cons char chars ih =>
      by_cases fits : utf8Width char ≤ budget
      · rw [takeUtf8Chars, if_pos fits] at h ⊢
        simp only [List.cons_append, List.cons.injEq] at h
        have tailBound := takeUtf8Chars_bytes_le (budget - utf8Width char) chars
        have nextDoesNotFit := ih (budget - utf8Width char) next rest h.2
        simp only [utf8Bytes]
        omega
      · rw [takeUtf8Chars, if_neg fits] at h ⊢
        simp only [List.nil_append, List.cons.injEq] at h
        rcases h with ⟨rfl, _⟩
        simp only [utf8Bytes]
        omega

theorem takeUtf8Prefix_next_not_fit (budget : Nat) (input : String)
    (next : Char) (rest : List Char)
    (h : input.toList = (takeUtf8Prefix budget input).toList ++ next :: rest) :
    budget - (takeUtf8Prefix budget input).utf8ByteSize < utf8Width next := by
  rw [takeUtf8Prefix, stringMk_utf8ByteSize]
  apply takeUtf8Chars_next_not_fit budget input.toList next rest
  simpa only [takeUtf8Prefix, stringMk_toList] using h

end CodexHooks
