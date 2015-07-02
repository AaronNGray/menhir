open UnparameterizedSyntax
open Syntax
open Positions

(* ------------------------------------------------------------------------ *)
(* Precedence levels for tokens or pseudo-tokens alike. *)

module TokPrecedence = struct

  (* This set records, on a token by token basis, whether the token's
     precedence level is ever useful. This allows emitting warnings
     about useless precedence declarations. *)

  let ever_useful : StringSet.t ref =
    ref StringSet.empty

  let use id =
    ever_useful := StringSet.add id !ever_useful

  (* This function is invoked when someone wants to consult a token's
     precedence level. This does not yet mean that this level is
     useful, though. Indeed, if it is subsequently compared against
     [UndefinedPrecedence], it will not allow solving a conflict. So,
     in addition to the desired precedence level, we return a delayed
     computation which, when evaluated, records that this precedence
     level was useful. *)

  let levelip id properties =
    lazy (use id), properties.tk_priority

  let leveli id = 
    let properties =
      try
	StringMap.find id Front.grammar.tokens
      with Not_found ->
	assert false (* well-formedness check has been performed earlier *)
    in
    levelip id properties    

  (* This function is invoked after the automaton has been constructed.
     It warns about unused precedence levels. *)

  let diagnostics () =
    StringMap.iter (fun id properties ->
      if not (StringSet.mem id !ever_useful) then
	match properties.tk_priority with
	| UndefinedPrecedence ->
	    ()
	| PrecedenceLevel (_, _, pos1, pos2) ->
	    Error.grammar_warning (Positions.two pos1 pos2)
	      (Printf.sprintf "the precedence level assigned to %s is never useful." id)
    ) Front.grammar.tokens

end

(* ------------------------------------------------------------------------ *)
(* Nonterminals. *)

module Nonterminal = struct

  type t = int

  let n2i i = i

  let compare = (-)

  (* Determine how many nonterminals we have and build mappings
     both ways between names and indices. A new nonterminal is
     created for every start symbol. *)

  let new_start_nonterminals =
    StringSet.fold (fun symbol ss -> (symbol ^ "'") :: ss) Front.grammar.start_symbols []

  let original_nonterminals =
    nonterminals Front.grammar
  
  let start =
    List.length new_start_nonterminals

  let (n : int), (name : string array), (map : int StringMap.t) =
    Misc.index (new_start_nonterminals @ original_nonterminals)

  let () =
    Error.logG 1 (fun f ->
      Printf.fprintf f
	"Grammar has %d nonterminal symbols, among which %d start symbols.\n"
	(n - start) start
    )

  let is_start nt =
    nt < start

  let print normalize nt =
    if normalize then
      Misc.normalize name.(nt)
    else
      name.(nt)

  let lookup name =
    StringMap.find name map

  let positions nt =
    (StringMap.find (print false nt) Front.grammar.rules).positions

  let iter f =
    Misc.iteri n f

  let fold f accu =
    Misc.foldi n f accu

  let map f =
    Misc.mapi n f

  let iterx f =
    for nt = start to n - 1 do
      f nt
    done

  let foldx f accu =
    Misc.foldij start n f accu

  let ocamltype nt =
    assert (not (is_start nt));
    try
      Some (StringMap.find (print false nt) Front.grammar.types)
    with Not_found ->
      None

  let ocamltype_of_start_symbol nt =
    match ocamltype nt with
    | Some typ ->
        typ
    | None ->
        (* Every start symbol has a type. *)
        assert false

  let tabulate f =
    Array.get (Array.init n f)

end

(* Sets and maps over nonterminals, used only below. *)

module NonterminalMap = Patricia.Big

module NonterminalSet = Patricia.Big.Domain

(* ------------------------------------------------------------------------ *)
(* Terminals. *)

module Terminal = struct

  type t = int

  let t2i i = i

  let compare = (-)

  let equal (tok1 : t) (tok2 : t) =
    tok1 = tok2

  (* Determine how many terminals we have and build mappings
     both ways between names and indices. A new terminal "#"
     is created. A new terminal "error" is created. The fact
     that the integer code assigned to the "#" pseudo-terminal
     is the last one is exploited in the table-based back-end.
     (The right-most row of the action table is not created.)

     Pseudo-tokens (used in %prec declarations, but never
     declared using %token) are filtered out. *)

  (* In principle, the number of the [error] token is irrelevant.
     It is currently 0, but we do not rely on that. *)

  let (n : int), (name : string array), (map : int StringMap.t) =
    let tokens = tokens Front.grammar in
    match tokens with
    | [] ->
	Error.error [] "no tokens have been declared."
    | _ ->
	Misc.index ("error" :: tokens @ [ "#" ])

  let print tok =
    name.(tok)

  let lookup name =
    StringMap.find name map

  let sharp =
    lookup "#"

  let error =
    lookup "error"

  let pseudo tok =
    (tok = sharp) || (tok = error)

  let token_properties = 
    let not_so_dummy_properties = (* applicable to [error] and [#] *)
      {
	tk_filename      = "__primitives__";
	tk_priority      = UndefinedPrecedence;
	tk_associativity = UndefinedAssoc;
	tk_ocamltype     = None;
	tk_is_declared   = true;
	tk_position      = Positions.dummy;
      }
    in
    Array.init n (fun tok ->
      try 
	 StringMap.find name.(tok) Front.grammar.tokens 
       with Not_found ->
	 assert (tok = sharp || tok = error);
	 not_so_dummy_properties
    )

  let () =
    Error.logG 1 (fun f ->
      Printf.fprintf f "Grammar has %d terminal symbols.\n" (n - 2)
    )

  let precedence_level tok = 
    TokPrecedence.levelip (print tok) token_properties.(tok)

  let associativity tok =
    token_properties.(tok).tk_associativity

  let ocamltype tok =
    token_properties.(tok).tk_ocamltype

  let iter f =
    Misc.iteri n f

  let fold f accu =
    Misc.foldi n f accu

  let map f =
    Misc.mapi n f

  let mapx f =
    assert (sharp = n - 1);
    Misc.mapi (n-1) f

  (* If a token named [EOF] exists, then it is assumed to represent
     ocamllex's [eof] pattern. *)

  let eof =
    try
      Some (lookup "EOF")
    with Not_found ->
      None

end

(* Sets of terminals are used intensively in the LR(1) construction,
   so it is important that they be as efficient as possible. *)

module TerminalSet = struct

  include CompressedBitSet 

  let print toks =
    let _, accu =
      fold (fun tok (first, accu) ->
	false,
	if first then
          accu ^ (Terminal.print tok)
	else
	  accu ^ " " ^ (Terminal.print tok)
    ) toks (true, "") in
    accu

  let universe =
    remove Terminal.sharp (
      remove Terminal.error (
        Terminal.fold add empty
      )
    )

  (* The following definitions are used in the computation of FIRST sets
     below. They are not exported outside of this file. *)

  type property =
    t

  let bottom =
    empty

  let is_maximal _ =
    false

end

(* Maps over terminals. *)

module TerminalMap = Patricia.Big

(* ------------------------------------------------------------------------ *)
(* Symbols. *)

module Symbol = struct

  type t =
    | N of Nonterminal.t
    | T of Terminal.t

  let compare sym1 sym2 =
    match sym1, sym2 with
    | N nt1, N nt2 ->
	Nonterminal.compare nt1 nt2
    | T tok1, T tok2 ->
	Terminal.compare tok1 tok2
    | N _, T _ ->
	1
    | T _, N _ ->
	-1

  let equal sym1 sym2 =
    compare sym1 sym2 = 0

  let rec lequal syms1 syms2 =
    match syms1, syms2 with
    | [], [] ->
	true
    | sym1 :: syms1, sym2 :: syms2 ->
	equal sym1 sym2 && lequal syms1 syms2
    | _ :: _, []
    | [], _ :: _ ->
	false

  let print = function
    | N nt ->
	Nonterminal.print false nt
    | T tok ->
	Terminal.print tok

  let nonterminal = function
    | T _ ->
	false
    | N _ ->
	true

  (* Printing an array of symbols. [offset] is the start offset -- we
     print everything to its right. [dot] is the dot offset -- we
     print a dot at this offset, if we find it. *)

  let printaod offset dot symbols =
    let buffer = Buffer.create 512 in
    let length = Array.length symbols in
    for i = offset to length do
      if i = dot then
	Buffer.add_string buffer ". ";
      if i < length then begin
	Buffer.add_string buffer (print symbols.(i));
	Buffer.add_char buffer ' '
      end
    done;
    Buffer.contents buffer

  let printao offset symbols =
    printaod offset (-1) symbols

  let printa symbols =
    printao 0 symbols

  let printl symbols =
    printa (Array.of_list symbols)

  let lookup name =
    try
      T (Terminal.lookup name)
    with Not_found ->
      try
	N (Nonterminal.lookup name)
      with Not_found ->
	assert false (* well-formedness check has been performed earlier *)

end

(* Sets of symbols. *)

module SymbolSet = Set.Make(Symbol)

(* Maps over symbols. *)

module SymbolMap = struct

  include Map.Make(Symbol)

  let domain m =
    fold (fun symbol _ accu ->
      symbol :: accu
    ) m []

  let purelynonterminal m =
    fold (fun symbol _ accu ->
      accu && Symbol.nonterminal symbol
    ) m true

end

(* ------------------------------------------------------------------------ *)
(* Productions. *)

module Production = struct

  type index =
      int

  (* Create an array of productions. Record which productions are
     associated with every nonterminal. A new production S' -> S
     is created for every start symbol S. It is known as a
     start production. *)

  let n : int =
    let n = StringMap.fold (fun _ { branches = branches } n ->
      n + List.length branches
    ) Front.grammar.rules 0 in
    Error.logG 1 (fun f -> Printf.fprintf f "Grammar has %d productions.\n" n);
    n + StringSet.cardinal Front.grammar.start_symbols

  let p2i prod =
    prod

  let i2p prod =
    assert (prod >= 0 && prod < n);
    prod

  let table : (Nonterminal.t * Symbol.t array) array =
    Array.make n (-1, [||])

  let identifiers : identifier array array =
    Array.make n [||]

  let used : bool array array =
    Array.make n [||]

  let actions : action option array =
    Array.make n None

  let ntprods : (int * int) array =
    Array.make Nonterminal.n (-1, -1)

  let positions : Positions.t list array =
    Array.make n []

  let (start : int),
      (startprods : index NonterminalMap.t) =
    StringSet.fold (fun nonterminal (k, startprods) ->
      let nt = Nonterminal.lookup nonterminal
      and nt' = Nonterminal.lookup (nonterminal ^ "'") in
      table.(k) <- (nt', [| Symbol.N nt |]);
      identifiers.(k) <- [| "_1" |];
      used.(k) <- [| true |];
      ntprods.(nt') <- (k, k+1);
      positions.(k) <- Nonterminal.positions nt;
      k+1,
      NonterminalMap.add nt k startprods
    ) Front.grammar.start_symbols (0, NonterminalMap.empty)

  let prec_decl : symbol located option array = 
    Array.make n None

  let reduce_precedence : precedence_level array = 
    Array.make n UndefinedPrecedence

  let (_ : int) = StringMap.fold (fun nonterminal { branches = branches } k ->
    let nt = Nonterminal.lookup nonterminal in
    let k' = List.fold_left (fun k branch ->
      let action = branch.action
      and sprec = branch.branch_shift_precedence 
      and rprec = branch.branch_reduce_precedence in	
      let symbols = Array.of_list branch.producers in
      table.(k) <- (nt, Array.map (fun (v, _) -> Symbol.lookup v) symbols);
      identifiers.(k) <- Array.mapi (fun i (_, ido) ->
	match ido with
	| None ->
	    (* Symbols for which no name was chosen will be represented
	       by variables named _1, _2, etc. *)
	    Printf.sprintf "_%d" (i + 1)
        | Some id ->
	    (* Symbols for which a name was explicitly chosen will be
	       known by that name in semantic actions. *)
	    id
      ) symbols;
      used.(k) <- Array.mapi (fun i (_, ido) ->
	match ido with
	| None ->
	    (* A symbol referred to as [$i] is used if and only if the
	       [$i] keyword appears in the semantic action. *)
            Action.has_dollar (i + 1) action
	| Some _ ->
	    (* A symbol referred to via a name is considered used.
	       This is a conservative approximation. *)
            true
      ) symbols;
      actions.(k) <- Some action;
      reduce_precedence.(k) <- rprec;
      prec_decl.(k) <- sprec;
      positions.(k) <- [ branch.branch_position ];
      k+1
    ) k branches in
    ntprods.(nt) <- (k, k');
    k'
  ) Front.grammar.rules start

  (* Iteration over the productions associated with a specific
     nonterminal. *)

  let iternt nt f =
    let k, k' = ntprods.(nt) in
    for prod = k to k' - 1 do
      f prod
    done

  let foldnt (nt : Nonterminal.t) (accu : 'a) (f : index -> 'a -> 'a) : 'a =
    let k, k' = ntprods.(nt) in
    let rec loop accu prod =
      if prod < k' then
	loop (f prod accu) (prod + 1)
      else
	accu
    in
    loop accu k

  (* This funny variant is lazy. If at some point [f] does not demand its
     second argument, then iteration stops. *)
  let foldnt_lazy (nt : Nonterminal.t) (f : index -> 'a Lazy.t -> 'a) (seed : 'a) : 'a =
    let k, k' = ntprods.(nt) in
    let rec loop prod seed =
      if prod < k' then
        f prod (lazy (loop (prod + 1) seed))
      else
        seed
    in
    loop k seed

  (* Accessors. *)

  let def prod =
    table.(prod)

  let nt prod =
    let nt, _ = table.(prod) in
    nt

  let rhs prod =
    let _, rhs = table.(prod) in
    rhs

  let length prod =
    Array.length (rhs prod)

  let identifiers prod =
    identifiers.(prod)

  let used prod =
    used.(prod)

  let is_start prod =
    prod < start

  let classify prod =
    if is_start prod then
      match (rhs prod).(0) with
      | Symbol.N nt ->
	  Some nt
      | Symbol.T _ ->
	  assert false
    else
      None

  let action prod =
    match actions.(prod) with
    | Some action ->
	action
    | None ->
	(* Start productions have no action. *)
	assert (is_start prod);
	assert false

  let positions prod =
    positions.(prod)

  let startsymbol2startprod nt =
    try
      NonterminalMap.find nt startprods
    with Not_found ->
      assert false (* [nt] is not a start symbol *)

  (* Iteration. *)

  let iter f =
    Misc.iteri n f

  let fold f accu =
    Misc.foldi n f accu

  let map f =
    Misc.mapi n f

  let amap f =
    Array.init n f

  let iterx f =
    for prod = start to n - 1 do
      f prod
    done

  let foldx f accu =
    Misc.foldij start n f accu

  let mapx f =
    Misc.mapij start n f

  (* Printing a production. *)

  let print prod =
    assert (not (is_start prod));
    let nt, rhs = table.(prod) in
    Printf.sprintf "%s -> %s" (Nonterminal.print false nt) (Symbol.printao 0 rhs)

  (* Tabulation. *)

  let tabulate f =
    Misc.tabulate n f

  let tabulateb f =
    Misc.tabulateb n f

  (* This array allows recording, on a production by production basis,
     whether the production's shift precedence is ever useful. This
     allows emitting warnings about useless %prec declarations. *)

  let prec_decl_ever_useful =
    Array.make n false

  let consult_prec_decl prod =
    lazy (prec_decl_ever_useful.(prod) <- true),
    prec_decl.(prod)

  let diagnostics () =
    iterx (fun prod ->
      if not prec_decl_ever_useful.(prod) then
	match prec_decl.(prod) with
	| None ->
	    ()
	| Some id ->
	    Error.grammar_warning [Positions.position id] "this %prec declaration is never useful."
    )

  (* Determining the precedence level of a production. If no %prec
     declaration was explicitly supplied, it is the precedence level
     of the rightmost terminal symbol in the production's right-hand
     side. *)

  type production_level =
    | PNone
    | PRightmostToken of Terminal.t
    | PPrecDecl of symbol

  let rightmost_terminal prod =
    Array.fold_left (fun accu symbol ->
      match symbol with
      | Symbol.T tok ->
	  PRightmostToken tok
      | Symbol.N _ ->
	  accu
    ) PNone (rhs prod)

  let combine e1 e2 =
    lazy (Lazy.force e1; Lazy.force e2)

  let shift_precedence prod =
    let fact1, prec_decl = consult_prec_decl prod in
    let oterminal =
      match prec_decl with
      | None ->
	  rightmost_terminal prod
      | Some { value = terminal } ->
	  PPrecDecl terminal
    in
    match oterminal with
    | PNone ->
	fact1, UndefinedPrecedence
    | PRightmostToken tok ->
	let fact2, level = Terminal.precedence_level tok in
	combine fact1 fact2, level
    | PPrecDecl id ->
	let fact2, level = TokPrecedence.leveli id  in
	combine fact1 fact2, level

end

(* ------------------------------------------------------------------------ *)
(* Maps over productions. *)

module ProductionMap = struct

  include Patricia.Big

  (* Iteration over the start productions only. *)

  let start f =
    Misc.foldi Production.start (fun prod m ->
      add prod (f prod) m
    ) empty

end

(* ------------------------------------------------------------------------ *)
(* Build the grammar's forward and backward reference graphs.

   In the backward reference graph, edges relate each nonterminal [nt]
   to each of the nonterminals whose definition mentions [nt]. The
   reverse reference graph is used in the computation of the nullable,
   nonempty, and FIRST sets.

   The forward reference graph is unused but can be printed on demand. *)

let forward : NonterminalSet.t array =
  Array.make Nonterminal.n NonterminalSet.empty

let backward : NonterminalSet.t array =
  Array.make Nonterminal.n NonterminalSet.empty

let () =
  Array.iter (fun (nt1, rhs) ->
    Array.iter (function
      | Symbol.T _ ->
	  ()
      | Symbol.N nt2 ->
	  forward.(nt1) <- NonterminalSet.add nt2 forward.(nt1);
	  backward.(nt2) <- NonterminalSet.add nt1 backward.(nt2)
    ) rhs
  ) Production.table

(* ------------------------------------------------------------------------ *)
(* If requested, dump the forward reference graph. *)

let () =
  if Settings.graph then
    let module P = Dot.Print (struct
      type vertex = Nonterminal.t
      let name nt =
	Printf.sprintf "nt%d" nt
      let successors (f : ?style:Dot.style -> label:string -> vertex -> unit) nt =
	NonterminalSet.iter (fun successor ->
	  f ~label:"" successor
	) forward.(nt)
      let iter (f : ?style:Dot.style -> label:string -> vertex -> unit) =
	Nonterminal.iter (fun nt ->
	  f ~label:(Nonterminal.print false nt) nt
	)
    end) in
    let f = open_out (Settings.base ^ ".dot") in
    P.print f;
    close_out f

(* ------------------------------------------------------------------------ *)
(* Support for analyses of the grammar, expressed as fixed point computations.
   We exploit the generic fixed point algorithm in [Fix]. *)

(* We perform memoization only at nonterminal symbols. We assume that the
   analysis of a symbol is the analysis of its definition (as opposed to,
   say, a computation that depends on the occurrences of this symbol in
   the grammar). *)

module GenericAnalysis
  (P : Fix.PROPERTY)
  (S : sig
    open P

    (* An analysis is specified by the following functions. *)

    (* [terminal] maps a terminal symbol to a property. *)
    val terminal: Terminal.t -> property
    
    (* [disjunction] abstracts a binary alternative. That is, when we analyze
       an alternative between several productions, we compute a property for
       each of them independently, then we combine these properties using
       [disjunction]. *)
    val disjunction: property -> property Lazy.t -> property

    (* [P.bottom] should be a neutral element for [disjunction]. We use it in
       the analysis of an alternative with zero branches. *)

    (* [conjunction] abstracts a binary sequence. That is, when we analyze a
       sequence, we compute a property for each member independently, then we
       combine these properties using [conjunction]. In general, conjunction
       needs access to the first member of the sequence (a symbol), not just
       to its analysis (a property). *)
    val conjunction: Symbol.t -> property -> property Lazy.t -> property

    (* [epsilon] abstracts the empty sequence. It should be a neutral element
       for [conjunction]. *)
    val epsilon: property

  end)
: sig
  open P

  (* The results of the analysis take the following form. *)

  (* To every nonterminal symbol, we associate a property. *)
  val nonterminal: Nonterminal.t -> property

  (* To every symbol, we associate a property. *)
  val symbol: Symbol.t -> property

  (* To every suffix of every production, we associate a property.
     The offset [i], which determines the beginning of the suffix,
     must be contained between [0] and [n], inclusive, where [n]
     is the length of the production. *)
  val production: Production.index -> int -> property

end = struct
  open P

  (* The following analysis functions are parameterized over [get], which allows
     making a recursive call to the analysis at a nonterminal symbol. [get] maps
     a nonterminal symbol to a property. *)

  (* Analysis of a symbol. *)

  let symbol sym get : property =
    match sym with
    | Symbol.T tok ->
        S.terminal tok
    | Symbol.N nt ->
        (* Recursive call to the analysis, via [get]. *)
        get nt    

  (* Analysis of (a suffix of) a production [prod], starting at index [i]. *)

  let production prod i get : property =
    let rhs = Production.rhs prod in
    let n = Array.length rhs in
    (* Conjunction over all symbols in the right-hand side. This can be viewed
       as a version of [Array.fold_right], which does not necessarily begin at
       index [0]. Note that, because [conjunction] is lazy, it is possible
       to stop early. *)
    let rec loop i =
      if i = n then
        S.epsilon
      else
        let sym = rhs.(i) in
        S.conjunction sym
          (symbol sym get)
          (lazy (loop (i+1)))
    in
    loop i

  (* The analysis is the least fixed point of the following function, which
     analyzes a nonterminal symbol by looking up and analyzing its definition
     as a disjunction of conjunctions of symbols. *)

  let nonterminal nt get : property =
    (* Disjunction over all productions for this nonterminal symbol. *)
    Production.foldnt_lazy nt (fun prod rest ->
      S.disjunction
        (production prod 0 get)
        rest
    ) P.bottom

  (* The least fixed point is taken as follows. Note that it is computed
     on demand, as [lfp] is called by the user. *)

  module F =
    Fix.Make
      (Maps.ConsecutiveIntegerKeysToImperativeMaps(Nonterminal))
      (P)

  let nonterminal =
    F.lfp nonterminal

  (* The auxiliary functions can be published too. *)

  let symbol sym =
    symbol sym nonterminal

  let production prod i =
    production prod i nonterminal

end

(* ------------------------------------------------------------------------ *)
(* Generic support for fixpoint computations.

   A fixpoint computation associates a property with every nonterminal.
   A monotone function tells how properties are computed. [compute nt]
   updates the property associated with nonterminal [nt] and returns a
   flag that tells whether the property actually needed an update. The
   state of the computation is maintained entirely inside [compute] and
   is invisible here.

   Whenever a property of [nt] is updated, the properties of the
   terminals whose definitions depend on [nt] are updated. The
   dependency graph must be explicitly supplied. *)

let fixpoint (dependencies : NonterminalSet.t array) (compute : Nonterminal.t -> bool) : unit =
  let queue : Nonterminal.t Queue.t = Queue.create () in
  let onqueue : bool array = Array.make Nonterminal.n true in
  for i = 0 to Nonterminal.n - 1 do
    Queue.add i queue
  done;
  Misc.qiter (fun nt ->
    onqueue.(nt) <- false;
    let changed = compute nt in
    if changed then
      NonterminalSet.iter (fun nt ->
	if not onqueue.(nt) then begin
	  Queue.add nt queue;
	  onqueue.(nt) <- true
	end
      ) dependencies.(nt)
  ) queue

(* ------------------------------------------------------------------------ *)
(* Compute which nonterminals are nonempty, that is, recognize a
   nonempty language. Also, compute which nonterminals are
   nullable. The two computations are almost identical. The only
   difference is in the base case: a single terminal symbol is not
   nullable, but is nonempty. *)

module NONEMPTY =
  GenericAnalysis
    (Boolean)
    (struct
      (* A terminal symbol is nonempty. *)
      let terminal _ = true
      (* An alternative is nonempty if at least one branch is nonempty. *)
      let disjunction p q = p || (Lazy.force q)
      (* A sequence is nonempty if both members are nonempty. *)
      let conjunction _ p q = p && (Lazy.force q)
      (* The sequence epsilon is nonempty. It generates the singleton
         language {epsilon}. *)
      let epsilon = true
     end)

module NULLABLE =
  GenericAnalysis
    (Boolean)
    (struct
      (* A terminal symbol is not nullable. *)
      let terminal _ = false
      (* An alternative is nullable if at least one branch is nullable. *)
      let disjunction p q = p || (Lazy.force q)
      (* A sequence is nullable if both members are nullable. *)
      let conjunction _ p q = p && (Lazy.force q)
      (* The sequence epsilon is nullable. *)
      let epsilon = true
     end)

(* ------------------------------------------------------------------------ *)
(* Compute FIRST sets. *)

let first =
  Array.make Nonterminal.n TerminalSet.empty

let first_symbol = function
  | Symbol.T tok ->
      TerminalSet.singleton tok
  | Symbol.N nt ->
      first.(nt)

let nullable_first_rhs (rhs : Symbol.t array) (i : int) : bool * TerminalSet.t =
  let length = Array.length rhs in
  assert (i <= length);
  let rec loop i toks =
    if i = length then
      true, toks
    else
      let symbol = rhs.(i) in
      let toks = TerminalSet.union (first_symbol symbol) toks in
      if NULLABLE.symbol symbol then
	loop (i+1) toks
      else
	false, toks
  in
  loop i TerminalSet.empty

let () =
  fixpoint backward (fun nt ->
    let original = first.(nt) in
    (* union over all productions for this nonterminal *)
    let updated = Production.foldnt nt TerminalSet.empty (fun prod accu ->
      let rhs = Production.rhs prod in
      let _, toks = nullable_first_rhs rhs 0 in
      TerminalSet.union toks accu
    ) in
    first.(nt) <- updated;
    TerminalSet.compare original updated <> 0
  )

let first', _first_prod', _first_symbol' =
  let module FIRST =
    GenericAnalysis
      (TerminalSet)
      (struct
        (* A terminal symbol has a singleton FIRST set. *)
        let terminal = TerminalSet.singleton
        (* The FIRST set of an alternative is the union of the FIRST sets. *)
        let disjunction p q = TerminalSet.union p (Lazy.force q)
        (* The FIRST set of a sequence is the union of:
             the FIRST set of the first member, and
             the FIRST set of the second member, if the first member is nullable. *)
        let conjunction symbol p q =
          if NULLABLE.symbol symbol then
            TerminalSet.union p (Lazy.force q)
          else
            p
        (* The FIRST set of the empty sequence is empty. *)
        let epsilon = TerminalSet.empty
       end)
  in
  FIRST.nonterminal, FIRST.production, FIRST.symbol

(* TEMPORARY sanity check *)
let () =
  for nt = Nonterminal.start to Nonterminal.n - 1 do
    assert (TerminalSet.equal first.(nt) (first' nt))
  done

(* ------------------------------------------------------------------------ *)

let () =
  (* If a start symbol generates the empty language or generates
     the language {epsilon}, report an error. In principle, this
     could be just a warning. However, in [Engine], in the function
     [start], it is convenient to assume that neither of these
     situations can arise. This means that at least one token must
     be read. *)
  StringSet.iter (fun symbol ->
    let nt = Nonterminal.lookup symbol in
    if not (NONEMPTY.nonterminal nt) then
      Error.error
	(Nonterminal.positions nt)
	(Printf.sprintf "%s generates the empty language." (Nonterminal.print false nt));
    if TerminalSet.is_empty first.(nt) then
      Error.error
	(Nonterminal.positions nt)
	(Printf.sprintf "%s generates the language {epsilon}." (Nonterminal.print false nt))
  ) Front.grammar.start_symbols;
  (* If a nonterminal symbol generates the empty language, issue a warning. *)
  for nt = Nonterminal.start to Nonterminal.n - 1 do
    if not (NONEMPTY.nonterminal nt) then
      Error.grammar_warning
	(Nonterminal.positions nt)
	(Printf.sprintf "%s generates the empty language." (Nonterminal.print false nt));
  done

(* ------------------------------------------------------------------------ *)
(* Dump the analysis results. *)

let () =
  Error.logG 2 (fun f ->
    for nt = 0 to Nonterminal.n - 1 do
      Printf.fprintf f "nullable(%s) = %b\n"
	(Nonterminal.print false nt)
	(NULLABLE.nonterminal nt)
    done;
    for nt = 0 to Nonterminal.n - 1 do
      Printf.fprintf f "first(%s) = %s\n"
	(Nonterminal.print false nt)
	(TerminalSet.print first.(nt))
    done
  )

let () =
  Time.tick "Analysis of the grammar"

(* ------------------------------------------------------------------------ *)
(* Compute FOLLOW sets. Unnecessary for us, but requested by a user. Also,
   this is useful for the SLR(1) test. Thus, we perform this analysis only
   on demand. *)

let follow : TerminalSet.t array Lazy.t =
  lazy (

    let follow =
      Array.make Nonterminal.n TerminalSet.empty

    and forward : NonterminalSet.t array =
      Array.make Nonterminal.n NonterminalSet.empty

    and backward : NonterminalSet.t array =
      Array.make Nonterminal.n NonterminalSet.empty

    in

    (* Iterate over all start symbols. *)
    for nt = 0 to Nonterminal.start - 1 do
      assert (Nonterminal.is_start nt);
      (* Add # to FOLLOW(nt). *)
      follow.(nt) <- TerminalSet.singleton Terminal.sharp
    done;
    (* We need to do this explicitly because our start productions are
       of the form S' -> S, not S' -> S #, so # will not automatically
       appear into FOLLOW(S) when the start productions are examined. *)

    (* Iterate over all productions. *)
    Array.iter (fun (nt1, rhs) ->
      (* Iterate over all nonterminal symbols [nt2] in the right-hand side. *)
      Array.iteri (fun i symbol ->
	match symbol with
	| Symbol.T _ ->
	    ()
	| Symbol.N nt2 ->
	    let nullable, first = nullable_first_rhs rhs (i+1) in
	    (* The FIRST set of the remainder of the right-hand side
	       contributes to the FOLLOW set of [nt2]. *)
	    follow.(nt2) <- TerminalSet.union first follow.(nt2);
	    (* If the remainder of the right-hand side is nullable,
	       FOLLOW(nt1) contributes to FOLLOW(nt2). *)
	    if nullable then begin
	      forward.(nt1) <- NonterminalSet.add nt2 forward.(nt1);
	      backward.(nt2) <- NonterminalSet.add nt1 backward.(nt2)
	    end
      ) rhs
    ) Production.table;

    (* The fixpoint computation used here is not the most efficient
       algorithm -- one could do better by first collapsing the
       strongly connected components, then walking the graph in
       topological order. But this will do. *)

    fixpoint forward (fun nt ->
      let original = follow.(nt) in
      (* union over all contributors *)
      let updated = NonterminalSet.fold (fun nt' accu ->
	TerminalSet.union follow.(nt') accu
      ) backward.(nt) original in
      follow.(nt) <- updated;
      TerminalSet.compare original updated <> 0
    );

    follow

  )

(* Define an accessor that triggers the computation of the FOLLOW sets
   if it has not been performed already. *)

let follow nt =
  (Lazy.force follow).(nt)

(* At log level 2, display the FOLLOW sets. *)

let () =
  Error.logG 2 (fun f ->
    for nt = 0 to Nonterminal.n - 1 do
      Printf.fprintf f "follow(%s) = %s\n"
	(Nonterminal.print false nt)
	(TerminalSet.print (follow nt))
    done
  )

(* Compute FOLLOW sets for the terminal symbols as well. Again, unnecessary
   for us, but requested by a user. This is done in a single pass over the
   grammar -- no new fixpoint computation is required. *)

let tfollow : TerminalSet.t array Lazy.t =
  lazy (

    let tfollow =
      Array.make Terminal.n TerminalSet.empty
    in

    (* Iterate over all productions. *)
    Array.iter (fun (nt1, rhs) ->
      (* Iterate over all terminal symbols [t2] in the right-hand side. *)
      Array.iteri (fun i symbol ->
	match symbol with
	| Symbol.N _ ->
	    ()
	| Symbol.T t2 ->
	    let nullable, first = nullable_first_rhs rhs (i+1) in
	    (* The FIRST set of the remainder of the right-hand side
	       contributes to the FOLLOW set of [t2]. *)
	    tfollow.(t2) <- TerminalSet.union first tfollow.(t2);
	    (* If the remainder of the right-hand side is nullable,
	       FOLLOW(nt1) contributes to FOLLOW(t2). *)
	    if nullable then
	      tfollow.(t2) <- TerminalSet.union (follow nt1) tfollow.(t2)
      ) rhs
    ) Production.table;

    tfollow

  )

(* Define another accessor. *)

let tfollow t =
  (Lazy.force tfollow).(t)

(* At log level 3, display the FOLLOW sets for terminal symbols. *)

let () =
  Error.logG 3 (fun f ->
    for t = 0 to Terminal.n - 1 do
      Printf.fprintf f "follow(%s) = %s\n"
	(Terminal.print t)
	(TerminalSet.print (tfollow t))
    done
  )

(* ------------------------------------------------------------------------ *)
(* Provide explanations about FIRST sets. *)

(* The idea is to explain why a certain token appears in the FIRST set
   for a certain sequence of symbols. Such an explanation involves
   basic assertions of the form (i) symbol N is nullable and (ii) the
   token appears in the FIRST set for symbol N. We choose to take
   these basic facts for granted, instead of recursively explaining
   them, so as to keep explanations short. *)

(* We first produce an explanation in abstract syntax, then
   convert it to a human-readable string. *)

type explanation =
  | EObvious                                 (* sequence begins with desired token *)
  | EFirst of Terminal.t * Nonterminal.t     (* sequence begins with a nonterminal that produces desired token *)
  | ENullable of Symbol.t list * explanation (* sequence begins with a list of nullable symbols and ... *)

let explain (tok : Terminal.t) (rhs : Symbol.t array) (i : int) =
  let length = Array.length rhs in
  let rec loop i =
    assert (i < length);
    let symbol = rhs.(i) in
    match symbol with
    | Symbol.T tok' ->
	assert (Terminal.equal tok tok');
	EObvious
    | Symbol.N nt ->
	if TerminalSet.mem tok first.(nt) then
	  EFirst (tok, nt)
	else begin
	  assert (NULLABLE.nonterminal nt);
	  match loop (i + 1) with
	  | ENullable (symbols, e) ->
	      ENullable (symbol :: symbols, e)
	  | e ->
	      ENullable ([ symbol ], e)
	end
  in
  loop i

let rec convert = function
  | EObvious ->
      ""
  | EFirst (tok, nt) ->
      Printf.sprintf "%s can begin with %s"
	(Nonterminal.print false nt)
	(Terminal.print tok)
  | ENullable (symbols, e) ->
      let e = convert e in
      Printf.sprintf "%scan vanish%s%s"
	(Symbol.printl symbols)
	(if e = "" then "" else " and ")
	e

(* ------------------------------------------------------------------------ *)
(* Package the analysis results. *)

module Analysis = struct

  let nullable = NULLABLE.nonterminal

  let first = Array.get first

  let nullable_first_prod prod i =
    let rhs = Production.rhs prod in
    nullable_first_rhs rhs i

  let explain_first_rhs (tok : Terminal.t) (rhs : Symbol.t array) (i : int) =
    convert (explain tok rhs i)

  let follow = follow

end

(* ------------------------------------------------------------------------ *)
(* Conflict resolution via precedences. *)

module Precedence = struct

  type choice =
    | ChooseShift
    | ChooseReduce
    | ChooseNeither
    | DontKnow

  type order = Lt | Gt | Eq | Ic

  let precedence_order p1 p2 = 
    match p1, p2 with
      |	UndefinedPrecedence, _
      | _, UndefinedPrecedence -> 
	  Ic

      | PrecedenceLevel (m1, l1, _, _), PrecedenceLevel (m2, l2, _, _) ->
	  if not (Mark.same m1 m2) then
	    Ic
	  else
	    if l1 > l2 then 
	      Gt 
	    else if l1 < l2 then 
	      Lt
	    else 
	      Eq

  let shift_reduce tok prod =
    let fact1, tokp  = Terminal.precedence_level tok
    and fact2, prodp = Production.shift_precedence prod in
    match precedence_order tokp prodp with
   
      (* Our information is inconclusive. Drop [fact1] and [fact2],
	 that is, do not record that this information was useful. *)

    | Ic ->
	DontKnow

      (* Our information is useful. Record that fact by evaluating
	 [fact1] and [fact2]. *)

    | (Eq | Lt | Gt) as c ->
	Lazy.force fact1;
	Lazy.force fact2;
	match c with

	| Ic ->
	    assert false (* already dispatched *)

	| Eq -> 
	    begin
	      match Terminal.associativity tok with
	      | LeftAssoc  -> ChooseReduce
	      | RightAssoc -> ChooseShift
	      | NonAssoc   -> ChooseNeither
	      | _          -> assert false
			      (* If [tok]'s precedence level is defined, then
				 its associativity must be defined as well. *)
	    end

	| Lt ->
	    ChooseReduce

	| Gt ->
	    ChooseShift


  let reduce_reduce prod1 prod2 =
    let rp1 = Production.reduce_precedence.(prod1) 
    and rp2 = Production.reduce_precedence.(prod2) in
    match precedence_order rp1 rp2 with
    | Lt -> 
	Some prod1
    | Gt -> 
	Some prod2
    | Eq -> 
	(* the order is strict except in presence of inlining: 
	   two branches can have the same precedence level when
	   they come from an inlined one. *)
	None
    | Ic -> 
	None

end
  
let diagnostics () =
  TokPrecedence.diagnostics();
  Production.diagnostics()

