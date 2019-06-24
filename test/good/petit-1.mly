(* This file defines the parser. The set of tokens that it exploits
   is defined in file [tokens.mly]. *)

%{

  open MIPSOps
  open LPP
  open Primitive

%}

%start <LPP.program> program

(* Tokens (or pseudo-tokens, used in %prec declarations) with lower
   precedence come first in this list. *)

%left OR
%left AND
%nonassoc NOT
%nonassoc LT LE GT GE EQ NE
%left MINUS PLUS
%left TIMES SLASH
%nonassoc unary_minus
%nonassoc LBRACKET
%nonassoc THEN
%nonassoc ELSE

%%

(* Formal and actual parameter lists are delimited with parentheses
   and separated with semicolons and commas, respectively. Contrary to
   standard Pascal, the parentheses are not optional (it would then
   become impossible to distinguish a variable from a function call
   with no parameters). *)

(* ------------------------------------------------------------------------- *)
(* Types. *)

typ:
| INTEGER
    { TypInt }
| BOOLEAN
    { TypBool }
| ARRAY OF t = typ
    { TypArray t }

(* ------------------------------------------------------------------------- *)
(* Expressions. *)

expression:
  e = raw_expression
    { Location.make $startpos $endpos e }
| LPAREN e = expression RPAREN
    { e }

raw_expression:
  i = INTCONST
    { EConst (ConstInt i) }
| b = BOOLCONST
    { EConst (ConstBool b) }
| id = ID
    { EGetVar id }
| MINUS e = expression %prec unary_minus
    { EUnOp (UOpNeg, e) }
| e1 = expression op = binop e2 = expression
    { EBinOp (op, e1, e2) }
| c = callee LPAREN actuals = separated_list(COMMA, expression) RPAREN
    { EFunCall (Location.make $startpos(c) $endpos(c) c, actuals) }
| a = expression LBRACKET i = expression RBRACKET
    { EArrayGet (a, i) }
| NEW ARRAY OF t = typ LBRACKET e = expression RBRACKET
    { EArrayAlloc (t, e) }

(* Binary operators are defined as a separate nonterminal symbol
   for enhanced readability. However, note that this symbol is
   declared %inline, which means that its definition is in fact
   textually expanded into the definition of expressions above.
   This is necessary for operator priorities to be properly
   taken into account. *)

%inline binop:
| PLUS
    { OpAdd }
| MINUS
    { OpSub }
| TIMES
    { OpMul }
| SLASH
    { OpDiv }
| LT
    { OpLt }
| LE
    { OpLe }
| GT
    { OpGt }
| GE
    { OpGe }
| EQ
    { OpEq }
| NE
    { OpNe }

(* ------------------------------------------------------------------------- *)
(* Conditions.

   We first define ``nontrivial'' conditions, which cannot simply be an
   expression or a parenthesized expression: they must involve at least
   one of the Boolean operators NOT, AND, OR. Then, we define a condition
   to be either a (Boolean-valued) expression or a nontrivial condition.

   This two-step approach is necessary to avoid ambiguity with
   parentheses. Indeed, conditions include expressions, and both
   conditions and expressions can be parenthesized, so a na�ve
   approach would yield an ambiguous grammar. Thanks to Yannick Moy
   for suggesting this solution. *)

nontrivial_condition:
| NOT c = condition
    { CNot c }
| c1 = condition AND c2 = condition
    { CAnd (c1, c2) }
| c1 = condition OR c2 = condition
    { COr (c1, c2) }
| LPAREN c = nontrivial_condition RPAREN
    { c }

condition:
| e = expression
    { CExpression e }
| c = nontrivial_condition
    { c }

(* ------------------------------------------------------------------------- *)
(* Instructions and blocks. *)

lvalue:
| id = ID
    { fun e -> ISetVar (id, e) }
| a = expression LBRACKET i = expression RBRACKET
    { fun e -> IArraySet (a, i, e) }

(* The explicit type constraint on [lvalue] below is redundant, but
   serves to avoid an ocaml warning about the code generated by
   Menhir. The need for this constraint should disappear with future
   versions of Menhir. *)

instruction:
| c = callee LPAREN actuals = separated_list(COMMA, expression) RPAREN
    { IProcCall (Location.make $startpos(c) $endpos(c) c, actuals) }
| lvalue = lvalue COLONEQ e = expression
    { (lvalue : LPP.expression -> LPP.instruction) e }
| READLN LPAREN lvalue = lvalue RPAREN
    { let callee = Location.make $startpos($1) $endpos($1) (CPrimitiveFunction Readln) in
      let e = Location.make $startpos $endpos (EFunCall (callee, [])) in
      (lvalue : LPP.expression -> LPP.instruction) e }
| IF c = condition THEN b = instruction_or_block
    { IIf (c, b, ISeq []) }
| IF c = condition THEN b1 = instruction_or_block ELSE b2 = instruction_or_block
    { IIf (c, b1, b2) }
| WHILE c = condition DO b = instruction_or_block
    { IWhile (c, b) }

block:
| BEGIN is = separated_list(SEMICOLON, instruction) END
    { ISeq is }

instruction_or_block:
| i = instruction
    { i }
| b = block
    { b }

(* ------------------------------------------------------------------------- *)
(* Callees. *)

callee:
| WRITE
    { CPrimitiveFunction Write }
| WRITELN
    { CPrimitiveFunction Writeln }
| id = ID
    { CUserFunction (Location.content id)}

(* ------------------------------------------------------------------------- *)
(* Procedures and functions. *)

(* Procedures and functions are very similar, so we are able to
   express a single semantic action that covers both productions. In
   the case of procedures, the variable [result] is bound to the value
   [None] via a simple trick: we recognize the non-terminal
   [no_result_type], whose language is empty. *)

procedure:
| FUNCTION f = ID
  LPAREN formals = separated_bindings RPAREN
  COLON result = some_result_type SEMICOLON
  locals = variables
  body = block
  SEMICOLON

| PROCEDURE f = ID
  LPAREN formals = separated_bindings RPAREN
  result = no_result_type SEMICOLON
  locals = variables
  body = block
  SEMICOLON

    {
      f, {
        formals = formals;
        result = result;
        locals = locals;
        body = body
      }
    }

%inline no_result_type:
  (* nothing *)
    { None }

%inline some_result_type:
  t = typ
    { Some t }

separated_bindings:
| bindings = separated_list(SEMICOLON, binding) (* list can be empty *)
    { List.flatten bindings }

terminated_bindings:
| bindings = terminated(binding, SEMICOLON)+    (* list is nonempty *)
    { List.flatten bindings }

binding:
| ids = separated_nonempty_list(COMMA, ID) COLON t = typ
    { List.map (fun id -> (id, t)) ids }

variables:
| vars = loption(preceded(VAR, terminated_bindings))
    { vars }

(* ------------------------------------------------------------------------- *)
(* Programs. *)

program:
  PROGRAM
  globals = variables
  defs = procedure*
  main = block
  DOT
    {{
       globals = globals;
       defs = defs;
       main = main
    }}
