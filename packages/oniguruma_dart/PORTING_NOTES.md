# Oniguruma 6.9.10 → Dart port: engineering notes

Reference source: `oniguruma-master/src/` (all line numbers below are into those C files).
This doc is the durable spec for the port; the approved plan is at
`~/.claude/plans/twinkling-growing-wall.md`.

## Pipeline

```
pattern bytes ─► regparse.c (prs_*) ─► Node AST ─► regcomp.c (tune_tree, compile_tree)
   ─► Operation[] bytecode + optimize info ─► regexec.c (match_at VM) ─► OnigRegion
```

## Key translation rules (Dart)

- Subject/pattern = `Uint8List` + integer cursor; every C `UChar*` becomes an `int` offset.
  `PFETCH/PUNFETCH/PPEEK` (regparse.c:497-522) → `(codePoint, newIndex)` returns; keep prev index.
- No unions → sealed class per `ND_*` (node) and per `OP_*` (op), + status bitfields (`ND_ST_*` regparse.h:324).
- No computed goto → `switch` VM (port the non-`USE_DIRECT_THREADED_CODE` path).
- No unsigned → `Uint*List` / explicit masking. `MemStatusType` bitsets cap ~31 groups (`MEM_STATUS_*`).
- Op addresses are **op-index offsets**, all `OPSIZE_*`=`SIZE_INC`=1. Two-pass model:
  `compile_length_*` MUST equal `compile_*` emission count. Forward jumps precomputed; back jumps = negative sums.
  `OP_REPEAT`/`OP_CALL` targets patched after array finalized (`set_addr_in_repeat_range` regcomp.c:1242,
  `fix_unset_addr_list` :3009). In Dart can store target op refs directly, but keep `repeat_range[id]{lower,upper}`.
- Parse recursion guard: `INC/DEC_PARSE_DEPTH` limit 4096 (regparse.c:295, regint.h:108).
- Feature macros ON in default build: USE_CALL, USE_CALLOUT, USE_BACKREF_WITH_LEVEL, USE_WHOLE_OPTIONS,
  USE_CAPTURE_HISTORY, USE_OP_PUSH_OR_JUMP_EXACT. Skip USE_DIRECT_THREADED_CODE.

## Parser (regparse.c): call chain

`onig_parse_tree`(9428) → `prs_regexp`(9391) → `prs_alts`(9326, handles `|`, saves/restores env.options)
→ `prs_branch`(9273, concat → ND_LIST) → `prs_exp`(8852, one elem + trailing quantifier at label `repeat:` 9198)
→ `fetch_token`(5566) / `prs_bag`(7883, groups) / `prs_cc`(6970, classes) / `prs_char_property`(6819).

- Tokens `TokenSyms` (4553); `PToken` tagged union (4587). Metachar recognition fully gated by
  `IS_SYNTAX_OP/OP2/BV`. Greedy/lazy/possessive suffix at labels greedy_check/possessive_check (5638-5661).
- `fetch_token_cc`(5282) in-class tokenizer: TK_CC_CLOSE/RANGE/AND(`&&`)/OPEN_CC/POSIX_BRACKET_OPEN.
- Node types (regparse.h:39): ND_STRING, CCLASS, CTYPE, BACKREF, QUANT, BAG, ANCHOR, LIST, ALT, CALL, GIMMICK.
  BAG subtypes: MEMORY, OPTION, STOP_BACKTRACK(atomic), IF_ELSE. LIST/ALT are cons cells (car/cdr).
- Strings: consecutive TK_STRING concatenated; short bytes inline in buf[24]. `\Q..\E`, `\x{}`, octal, `\uHHHH`.
- Classes `prs_cc`: BitSet(256) + BBuf* mbuf; state machine CS_*; ranges, POSIX `[[:name:]]`(prs_posix_bracket 6718),
  nested `[..[..]]`, set-intersection `&&`(and_cclass), `\w\d\s\h`/`\p{}` via add_ctype_to_cc.
- Groups `prs_bag`: `(?:)`,`(name)`,`(?<name>)`,`(?=)(?!)`→ANCR_PREC_READ[_NOT], `(?<=)(?<!)`→ANCR_LOOK_BEHIND[_NOT],
  `(?>)`→BAG_STOP_BACKTRACK, `(?imsx...)` options→BAG_OPTION (returns 2 if option-only), `(?(cond)t|e)`→BAG_IF_ELSE,
  `(?~)` absent, `(?{})`/`(*name)` callouts→GIMMICK, `(?@)` capture-history.
- Option letters (8345): i=IGNORECASE x=EXTEND m=MULTILINE(Perl s=MULTILINE, Perl m→SINGLELINE) W/D/S/P/a=ASCII.
- Anchors (regint.h:468): ANCR_BEGIN_BUF `\A`, END_BUF `\z`, SEMI_END_BUF `\Z`, BEGIN/END_LINE `^`/`$`,
  BEGIN_POSITION `\G`, WORD_BOUNDARY/NO `\b`/`\B`, WORD_BEGIN/END `\<`/`\>`, TEXT_SEGMENT `\y`, LOOK_BEHIND, PREC_READ.
- Special escapes: `\R`→general_newline `(?>\x0D\x0A|[\x0A-\x0D..])`, `\N`/`\O`, `\X`→text_segment(EGC), `\K`→keep gimmick,
  `\p{}`, `\k<>`→BACKREF, `\g<>`→CALL.

## Case folding: TWO phases (do NOT unify)

- **Classes: parse time** (regparse.c i_apply_case_fold 8740, via ONIGENC_APPLY_ALL_CASE_FOLD). Single-char folds
  → bitset/mbuf; multi-char folds (ß→ss) → ND_ALT OR-ed onto the class. Applied even in negative classes.
- **Strings: tune/compile time** (regcomp.c unravel_case_fold_string 4963 in tune_tree 5769) when ND_ST_IGNORECASE.
  Multi-alternatives materialize as ND_ALT subtrees; simple 1:1 keeps flag → IC opcodes.

## Compiler (regcomp.c)

`onig_compile`(7493): ops_init(8) → `parse_and_tune`(7381) → set push_mem_start/end + stack_pop_level →
clear/`set_optimize_info_from_tree` → `compile_tree` → OP_UPDATE_VAR(if `\K`) + OP_END → ops_resize →
`set_addr_in_repeat_range` → `ops_make_string_pool`.
`parse_and_tune`: onig_parse_tree → reduce_string_list → named renumber → check_backrefs →
[tune_call/tune_call2/recursive checks if calls] → `tune_tree` → [set_parent/empty_repeat/empty_status if backrefs].

### tune_tree(5745) state bits: IN_ALT/IN_NOT/IN_REAL_REPEAT/IN_VAR_REPEAT/IN_MULTI_ENTRY/IN_PREC_READ/IN_LOOK_BEHIND
- Sets qn.emptiness (empty-loop), expands IC strings, sets backtrack_mem/backrefed_mem, sets head_exact/next_head_exact.
- tune_quant(5668): emptiness via quantifiers_memory_node_info (BODY_MAY_BE_EMPTY[_MEM|_REC]); fixed-string expand
  `x{n}` n≤100 & len*n≤100; head_exact=get_tree_head_literal(body) when greedy&nonempty.
- tune_next(4693): next_head_exact for peek; **auto-possessify** `a*b` (exclusive heads) → `(?>a*)b`.
- BAG_MEMORY under alt/not/var-repeat/multi-entry/rec → set backtrack_mem[regnum]. BAG_STOP_BACKTRACK over greedy
  `*`/`{0,∞}`/`{1,∞}` on strict-real → ND_ST_STRICT_REAL_REPEAT. tune_look_behind(4600) computes char_min/max_len/lead_node.

### Codegen: two mirrored fns compile_length_tree(2480) / compile_tree(2558). add_op(874). All OPSIZE=1.
Addresses relative to own slot, include SIZE_INC(1); `pc += addr`.

- String: compile_string_node(1133), select_str_opcode(899): OP_STR_1..5/N, MB2N1..3/MB2N/MB3N/MBN. Bytes pooled.
- CClass: compile_cclass_node(1201) len=1: OP_CCLASS[_NOT]/OP_CCLASS_MB[_NOT]/OP_CCLASS_MIX[_NOT].
- Ctype(2612): OP_ANYCHAR[_ML], OP_WORD/NO_WORD[_ASCII].
- Backref(2638): OP_BACKREF1/2, BACKREF_N[_IC], BACKREF_MULTI[_IC], BACKREF_WITH_LEVEL[_IC], BACKREF_CHECK[_WITH_LEVEL].
- ALT(2569): per non-last branch: `OP_PUSH addr=SIZE_INC+branch_len+OPSIZE_JUMP` `<branch>` `OP_JUMP addr=goal-(off+1)`.

### Quantifier templates: compile_quantifier_node(1399). tlen=len(body); mod_tlen=tlen(+2 if empty-check wrapped).
- (A) anychar-inf greedy (1409): `lower×body` then `OP_ANYCHAR_STAR[_ML]` or `..._PEEK_NEXT{.c=next}`.
- (B) greedy inf `* + {n,∞}`(1434): [if lower==1&tlen>10: `OP_JUMP addr=OPSIZE_PUSH+SIZE_INC`; else lower× body]
  then `OP_PUSH addr=SIZE_INC+mod_tlen+OPSIZE_JUMP` `<body′>` `OP_JUMP addr=-(mod_tlen+OPSIZE_PUSH)`.
  PUSH may be OP_PUSH_OR_JUMP_EXACT1{addr,c}(head_exact) or OP_PUSH_IF_PEEK_NEXT{addr,c}(next_head_exact).
- (C) lazy inf `*? +?`(1504): `OP_JUMP addr=mod_tlen+SIZE_INC` `<body′>` `OP_PUSH addr=-mod_tlen`.
- (D) upper==0(1517): if include_referred `OP_JUMP addr=tlen+SIZE_INC` then body; else nothing.
- (E) finite greedy small `? {n,m}`(1530): lower× body; then (upper-lower)× [`OP_PUSH addr=(upper-lower-i)*(tlen+OPSIZE_PUSH)` `<body>`] (plain body, no empty-check).
- (F) lazy `??`(1551): `OP_PUSH addr=SIZE_INC+OPSIZE_JUMP` `OP_JUMP addr=tlen+SIZE_INC` `<body>`.
- (G) else counted → compile_range_repeat_node(1284): `OP_REPEAT|_NG {id=num_repeat++, addr=SIZE_INC+tlen+OPSIZE_REPEAT_INC}`
  `<body′>` `OP_REPEAT_INC|_NG {id}`. entry_repeat_range(id,lower,upper(∞→0x7fffffff),offset).
- Empty-check wrap compile_quant_body_with_empty_check(958): `OP_EMPTY_CHECK_START{mem=num_empty_check++}` body
  `OP_EMPTY_CHECK_END|_MEMST|_MEMST_PUSH{mem}` (variant by BODY_MAY_BE_EMPTY[_MEM|_REC]).

### Memory group compile_bag_memory_node(1698): `OP_MEM_START[_PUSH]{num=regnum}` body `OP_MEM_END[_PUSH]{num}`.
  _PUSH chosen by MEM_STATUS_AT0(push_mem_start/end, regnum). Called groups add OP_CALL/JUMP/RETURN + _REC ends.
  push_mem_start = backtrack_mem|cap_history (7540); push_mem_end (7546): callout→=start; else start all-on→backrefed|cap_hist; else start&(backrefed|cap_hist).

### Other bags compile_bag_node(1779):
- BAG_OPTION → compile_option_node (options already in node flags).
- BAG_STOP_BACKTRACK: strict-real-star → `lower×body` `OP_PUSH addr=SIZE_INC+len+OPSIZE_POP+OPSIZE_JUMP` `<body>` `OP_POP` `OP_JUMP addr=-(OPSIZE_PUSH+len+OPSIZE_POP)`; general → `OP_MARK{id}` `<body>` `OP_CUT_TO_MARK{id,restore_pos=0}`.
- BAG_IF_ELSE(1832): `OP_MARK{id}` `OP_PUSH addr=..` `<cond>` `OP_CUT_TO_MARK{id}` `<Then>` `OP_JUMP addr=..` `OP_CUT_TO_MARK{id}` `<Else>`.

### Anchors compile_anchor_node(2260):
- simple begin/end/line/semi-end; `\G`→OP_CHECK_POSITION{SEARCH_START}; word→OP_WORD_BOUNDARY/... {mode=ascii}; `\y`→OP_TEXT_SEGMENT_BOUNDARY{type,not}.
- `(?=)`(2318): `OP_MARK{id,save_pos=T}` `<body>` `OP_CUT_TO_MARK{id,restore_pos=T}`.
- `(?!)`(2336): `OP_PUSH addr=..` `OP_MARK{id,save_pos=F}` `<body>` `OP_POP_TO_MARK{id}` `OP_POP` `OP_FAIL`.
- look-behind(1980): fixed → `OP_MARK{id}` `OP_STEP_BACK_START{initial=min,remaining=0,addr=1}` `<body>` `OP_CUT_TO_MARK{id}`;
  variable → uses OP_SAVE_VAL/OP_UPDATE_VAR(RIGHT_RANGE)/OP_STEP_BACK_START{addr=2}/OP_STEP_BACK_NEXT/OP_CHECK_POSITION{CURRENT_RIGHT_RANGE}/OP_MOVE.
- neg look-behind(2109): analogous + OP_PUSH/OP_POP_TO_MARK/OP_FAIL.
- Gimmicks(2382): OP_SAVE_VAL, OP_UPDATE_VAR, OP_FAIL, OP_CALLOUT_CONTENTS/NAME.

### Optimizer optimize_nodes(6623)/set_optimize_info_from_tree(7009):
OptNode{len(MinMax), anc, sb/sm/spr(OptStr, exact ≤24B), map(OptMap 256B)}.
- STRING→concat exact + first-byte map. CCLASS→map bits or MB len. LIST→concat_left advancing mm. ALT→alt_merge (intersect maps).
- QUANT upper0→len0; lower≥1 copy exact; greedy `.*`→ANCR_ANYCHAR_INF[_ML]. BAG memory memoized (opt_count cap 5). ANCHOR→anc bits, `(?=)`→spr.
- Derive reg.anchor (BEGIN_BUF|BEGIN_POSITION|ANYCHAR_INF[_ML]|LOOK_BEHIND | END_BUF|SEMI_END_BUF|PREC_READ_NOT); anc_dist_min/max.
- exact vs map: select_opt_exact + comp_opt_exact_or_map (COMP_EM_BASE=20). set_optimize_exact(6940): reg.exact + Sunday/BMH skip table
  (set_sunday_quick_search_or_bmh_skip_table 5881) into reg.map+map_offset → OPTIMIZE_STR_FAST[_STEP_FORWARD] else OPTIMIZE_STR;
  threshold_len=dist_min+exact_len. set_optimize_map(6980): 256B map, OPTIMIZE_MAP, threshold=dist_min+MBC_MINLEN.
- optimize enum (regint.h:363): NONE, STR, STR_FAST, STR_FAST_STEP_FORWARD, MAP.

## Executor (regexec.c): match_at(3068), switch VM (BYTECODE_INTERPRETER_START 2967)
- Backtrack stack: growable StackType[] (union, 1289): type(unsigned int STK_*), zid, u.{state{pcode,pstr}, repeat_inc{count,prev_index},
  mem{pstr,prev_start,prev_end}, empty_check{pstr,prev_index}, call_frame{ret_addr,pstr}, val{type,v,v2}, callout}.
  Port as struct-of-arrays typed lists + stack pointer int (zero per-push alloc).
- STK_* (1239): ALT/ALT_FLAG/SUPER_ALT, MEM_START(0x10)/MEM_END(0x8030)/MEM_END_MARK(0x8100), REPEAT_INC(0x40),
  EMPTY_CHECK_START(0x3000)/END(0x5000), CALLOUT(0x70), CALL_FRAME(0x400)/RETURN(0x500), SAVE_VAL(0x600), MARK(0x704), VOID(0).
  Masks: POP_USED=ALT_FLAG, POP_HANDLED=0x10, TO_VOID_TARGET=0x100e, MEM_END_OR_MARK=0x8000.
- repeat_stk[num_repeat] + empty_check_stk[num_empty_check] side arrays (alloc base macro 1363).
- captures: mem_start_stk[]/mem_end_stk[] arrays; filled to region beg[]/end[] at OP_END.
- Search: onig_search(5649)→search_in_range(5674)→forward_search(5429) applies optimize (exact/BMH map/anchor, dist_min/max, threshold_len).
- Guards: retry_limit_in_match/in_search (1561), subexp call limit (4440), time limit (1580).

## Syntax (DEFAULT = OnigSyntaxOniguruma, regparse.c:71; Ruby :123; OnigDefaultSyntax :165)
OnigSyntaxType{op, op2, behavior, options, meta_char_table{esc='\\', rest=INEFFECTIVE}}.
Oniguruma op = SYN_GNU_REGEX_OP + QMARK_NON_GREEDY|ESC_OCTAL3|ESC_X_HEX2|ESC_X_BRACE_HEX8|ESC_O_BRACE_OCTAL|ESC_CONTROL_CHARS|ESC_C_CONTROL − ESC_LTGT_WORD_BEGIN_END.
op2 = QMARK_GROUP_EFFECT|OPTION_ONIGURUMA|QMARK_LT_NAMED_GROUP|ESC_K_NAMED_BACKREF|QMARK_LPAREN_IF_ELSE|QMARK_TILDE_ABSENT_GROUP|
  QMARK_BRACE_CALLOUT_CONTENTS|ASTERISK_CALLOUT_NAME|ESC_X_Y_TEXT_SEGMENT|ESC_CAPITAL_R_GENERAL_NEWLINE|ESC_CAPITAL_N_O_SUPER_DOT|
  ESC_CAPITAL_K_KEEP|ESC_G_SUBEXP_CALL|ESC_P_BRACE_CHAR_PROPERTY|ESC_P_BRACE_CIRCUMFLEX_NOT|PLUS_POSSESSIVE_REPEAT|CCLASS_SET_OP|
  ESC_CAPITAL_C_BAR_CONTROL|ESC_CAPITAL_M_BAR_META|ESC_V_VTAB|ESC_H_XDIGIT|ESC_U_HEX4.
behavior = SYN_GNU_REGEX_BV + ALLOW_INTERVAL_LOW_ABBREV|DIFFERENT_LEN_ALT_LOOK_BEHIND|VARIABLE_LEN_LOOK_BEHIND|
  CAPTURE_ONLY_NAMED_GROUP|ALLOW_MULTIPLEX_DEFINITION_NAME|FIXED_INTERVAL_IS_GREEDY_ONLY|ALLOW_INVALID_CODE_END_OF_RANGE_IN_CC|
  WARN_CC_OP_NOT_ESCAPED|WHOLE_OPTIONS|ESC_P_WITH_ONE_CHAR_PROP|WARN_REDUNDANT_NESTED_REPEAT.
Ruby: OPTION_RUBY not ONIGURUMA; omits QMARK_BRACE_CALLOUT_CONTENTS, ASTERISK_CALLOUT_NAME, WHOLE_OPTIONS,
  VARIABLE_LEN_LOOK_BEHIND, ALLOW_INVALID_CODE_END_OF_RANGE_IN_CC, ESC_P_WITH_ONE_CHAR_PROP.

## Data tables (all flat OnigCodePoint[] → code-generate Dart)
- unicode_property_data.c: gperf name→ctype (replace with Map) + `CR_Name[]={count, <lo,hi>×count}` ranges (613 tables).
- unicode_fold_data.c: OnigUnicodeFolds1/2/3[] = `{from, n, to×n}` records; fold1/2/3_key + unfold_key files index them.
- unicode_wb_data.c / unicode_egcb_data.c: word-break / extended-grapheme-cluster range tables.
- Encodings: OnigEncodingType (oniguruma.h:130) struct of fn ptrs → abstract class + subclass per encoding.
  Single-byte (ISO-8859-*, CP1251, KOI8) share regenc.c onigenc_single_byte_* + a per-enc ctype table.

## Test oracle (translate mechanically)
test/test_utf8.c(1558), test_back.c(1229), testu.c(723), test_syntax.c, test_options.c, testc.c(EUC-JP).
Macros: x2(pat,str,from,to)=match at [from,to); x3(pat,str,from,to,group)=check group; n(pat,str)=no match.
