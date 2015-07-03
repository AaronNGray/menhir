(* This is an enriched version of [CompletedNat], where we compute not just
   numbers, but also sequences of matching length. *)

(* A property is either [Finite (n, xs)], where [n] is a natural number and
   [xs] is a sequence of length [n]; or [Infinity]. *)

type 'a t =
| Finite of int * 'a Seq.seq
| Infinity

let equal p1 p2 =
  match p1, p2 with
  | Finite (i1, _), Finite (i2, _) ->
      i1 = i2
  | Infinity, Infinity ->
      true
  | _, _ ->
      false

let bottom =
  Infinity

let epsilon =
  Finite (0, Seq.empty)

let singleton x =
  Finite (1, Seq.singleton x)

let is_maximal p =
  match p with
  | Finite (0, _) ->
      true
  | _ ->
      false

let min p1 p2 =
  match p1, p2 with
  | Finite (i1, _), Finite (i2, _) ->
      if i1 <= i2 then p1 else p2
  | p, Infinity
  | Infinity, p ->
      p

let min_lazy p1 p2 =
  match p1 with
  | Finite (0, _) ->
      p1
  | _ ->
      min p1 (p2())

let min_cutoff p1 p2 =
  match p1 with
  | Finite (0, _) ->
      p1
  | Finite (i1, _) ->
      (* Pass [i1] as a cutoff value to [p2]. *)
      min p1 (p2 i1)
  | Infinity ->
      (* Pass [max_int] to indicate no cutoff. *)
      p2 max_int

(* [until_finite] can be viewed as a variant of [min_lazy] where
   we are happy as soon as we find a finite value. It can be viewed
   as a minimum operation for the partial ordering where [Infinity]
   is above everyone and everyone else is incomparable. *)
let until_finite p1 p2 =
  match p1 with
  | Finite _ ->
      p1
  | Infinity ->
      p2()

let add p1 p2 =
  match p1, p2 with
  | Finite (i1, xs1), Finite (i2, xs2) ->
      Finite (i1 + i2, Seq.append xs1 xs2)
  | _, _ ->
      Infinity

let add_lazy p1 p2 =
  match p1 with
  | Infinity ->
      Infinity
  | _ ->
      add p1 (p2())

let print conv p =
  match p with
  | Finite (i, xs) ->
      string_of_int i ^ " " ^
      String.concat " " (List.map conv (Seq.elements xs))
  | Infinity ->
      "infinity"