(* -------------------------------------------------------------------------- *)

(* The type functor. *)

module Symbols (T : sig

  type 'a terminal
  type 'a nonterminal

end) = struct

  open T

  (* This should be the only place in the whole library (and generator!)
     where these types are defined. *)

  type 'a symbol =
    | T : 'a terminal -> 'a symbol
    | N : 'a nonterminal -> 'a symbol

  type xsymbol = 
    | X : 'a symbol -> xsymbol

end

(* -------------------------------------------------------------------------- *)

(* The code functor. *)

module Make
  (B : TableFormat.TABLES)
  (T : InspectionTableFormat.TABLES
       with type 'a lr1state = int)
= struct

  (* Including [T] is an easy way of inheriting the definitions of the types
     [symbol] and [xsymbol]. *)

  include T

  (* This auxiliary function decodes a packed linearized array, as created by
     [TableBackend.linearize_and_marshal1]. Here, we read a row all at once. *)

  let read_packed_linearized ((data, entry) : PackedIntArray.t * PackedIntArray.t) (i : int) : int list =
    LinearizedArray.read_row_via
      (PackedIntArray.get data)
      (PackedIntArray.get entry)
      i

  (* This auxiliary function decodes a symbol. The encoding was done by
     [encode_symbol] or [encode_symbol_option] in the table back-end. *)

  let decode_symbol (symbol : int) : T.xsymbol =
    (* If [symbol] is 0, then we have no symbol. This could mean e.g.
       that the function [incoming_symbol] has been applied to an
       initial state. In principle, this cannot happen. *)
    assert (symbol > 0);
    (* The low-order bit distinguishes terminal and nonterminal symbols. *)
    let kind = symbol land 1 in
    let symbol = symbol lsr 1 in
    if kind = 0 then
      T.terminal (symbol - 1)
    else
      T.nonterminal symbol

  (* This auxiliary function converts a nonterminal symbol to its integer
     code. For speed and for convenience, we use an unsafe type cast. This
     relies on the fact that the data constructors of the [nonterminal] GADT
     are declared in an order that reflects their internal code. We add
     [start] to account for the presence of the start symbols. *)

  let n2i (nt : 'a T.nonterminal) : int =
    let answer = B.start + Obj.magic nt in
    assert (T.nonterminal answer = X (N nt)); (* TEMPORARY roundtrip *)
    answer

  (* The function [incoming_symbol] goes through the tables [T.lr0_core] and
     [T.lr0_incoming]. This yields a representation of type [xsymbol], out of
     which we strip the [X] quantifier, so as to get a naked symbol. This last
     step is ill-typed and potentially dangerous. It is safe only because this
     function is used at type ['a lr1state -> 'a symbol], which forces an
     appropriate choice of ['a]. *)

  let incoming_symbol (s : 'a T.lr1state) : 'a T.symbol =
    let core = PackedIntArray.get T.lr0_core s in
    let symbol = decode_symbol (PackedIntArray.get T.lr0_incoming core) in
    match symbol with
    | T.X symbol ->
        Obj.magic symbol

  (* The function [lhs] reads the table [B.lhs] and uses [T.nonterminal]
     to decode the symbol. *)

  let lhs prod =
    T.nonterminal (PackedIntArray.get B.lhs prod)

  (* The function [rhs] reads the table [T.rhs] and uses [decode_symbol]
     to decode the symbol. *)

  let rhs prod =
    List.map decode_symbol (read_packed_linearized T.rhs prod)

  (* The function [items] maps the LR(1) state [s] to its LR(0) core,
     then uses [core] as an index into the table [T.lr0_items]. The
     items are then decoded by the function [export] below, which is
     essentially a copy of [Item.export]. *)

  type item =
      int * int

  let export t : item =
    (t lsr 7, t mod 128)

  let items s =
    (* Map [s] to its LR(0) core. *)
    let core = PackedIntArray.get T.lr0_core s in
    (* Now use [core] to look up the table [T.lr0_items]. *)
    List.map export (read_packed_linearized T.lr0_items core)

  (* The function [nullable] maps the nonterminal symbol [nt] to its
     integer code, which it uses to look up the array [T.nullable].
     This yields 0 or 1, which we map back to a Boolean result. *)

  let nullable nt =
    PackedIntArray.get1 T.nullable (n2i nt) = 1

  (* The function [foreach_terminal] exploits the fact that the
     first component of [B.error] is [Terminal.n - 1], i.e., the
     number of terminal symbols, including [error] but not [#]. *)

  let rec foldij i j f accu =
    if i = j then
      accu
    else
      foldij (i + 1) j f (f i accu)

  let foreach_terminal f accu =
    let n, _ = B.error in
    foldij 0 n (fun i accu ->
      f (T.terminal i) accu
    ) accu

  let foreach_terminal_but_error f accu =
    let n, _ = B.error in
    foldij 0 n (fun i accu ->
      if i = B.error_terminal then
        accu
      else
        f (T.terminal i) accu
    ) accu

end
