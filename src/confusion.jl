"""
    Confusion — dialect confusion table (single source for recall and scoring)

One-step directed substitutions for initials and finals, plus syllable
variant expansion. Sources: all 34 rows of `model/A混淆音资料/A_混淆口音表_按语系.md`
and all 11 pairs of `model/A混淆音资料/B_输入法模糊音_对照.md` (bidirectional),
converted and deduplicated to 18 initial + 14 final = 32 directed edges —
exactly the set shipped in the package. Eleven older analogical edges (j→q, q→j,
y→r, uan→uai, uai→uan, un→ong, ong→un, u→v, v→u, ai→an, ui→ei) were removed on
2026-10-21 for lack of in-corpus evidence ("no edge without evidence").

Used at both stages:
- recall (Index): expand a query syllable with `syl_variants`, then look it up
  in the syllable inverted index;
- scoring (Matcher): `is_confuse_pair(q, t)` tests whether query reading q and
  candidate reading t differ by one step; such pairs get a similarity floor.

Edge direction: `from => to` means the record was written with `from` while the
catalogue name reads `to` (same convention as the S1 evaluation set).

Ablation scripts must mutate the table through `drop_edge!`/`restore!`, which
bump `GENERATION` so the scoring layer's memo can invalidate. Editing the Dicts
directly leaves stale scores behind.
"""
module Confusion

export INITIAL_CONFUSE, FINAL_CONFUSE, split_syllable, syl_variants,
       is_confuse_pair, drop_edge!, restore!, generation

# One-step initial substitutions (directed).
const INITIAL_CONFUSE = Dict(
    "zh" => ["z"], "z" => ["zh", "r"],   # z→r: Southwestern Mandarin r surfaced as z ([37] Chengdu–Chongqing; table row r→z)
    "ch" => ["c"], "c" => ["ch"],
    "sh" => ["s"], "s" => ["sh"],
    "n" => ["l"], "l" => ["n", "zh", "r"],  # l→zh: noise study [42], isolated syllables, direction only; l→r: IME fuzzy r↔l (Sogou/QQ, added 2026-10-21)
    "f" => ["h", "p"], "h" => ["f"],     # f→p: the f side of the noise study's p→m/f row [42]
    "r" => ["l"],
    "x" => ["q"],                         # noise study [42], strongest measured pair (q→x)
    "k" => ["t"],                         # noise study [42], t→k
    "m" => ["p"],                         # noise study [42], the m side of p→m/f
)

# One-step final substitutions (directed).
const FINAL_CONFUSE = Dict(
    "an" => ["ang", "uan"], "ang" => ["an"],   # an→uan: SW Mandarin uan→an ([35] Zhushan, after dental initials; the engine ignores that condition)
    "en" => ["eng", "un"], "eng" => ["en"],    # en→un: SW Mandarin un→en ([35] Zhushan)
    "in" => ["ing", "ian"], "ing" => ["in"],   # in→ian: SW Mandarin ian→in ([39] Jianshi interviews, unverified; [35] medial loss)
    "ian" => ["iang"], "iang" => ["ian"],
    "uan" => ["uang"], "uang" => ["uan"],
    "ei" => ["ui"],
)

const ALL_INITIALS = ["zh","ch","sh","b","p","m","f","d","t","n","l","g","k","h",
                      "j","q","x","r","z","c","s","y","w"]

"Split a syllable into (initial, final); initial is empty for zero-initial syllables."
function split_syllable(s::String)::Tuple{String,String}
    for ini in ALL_INITIALS
        startswith(s, ini) && return (ini, s[length(ini)+1:end])
    end
    return ("", s)
end

"Self plus one-step variants of a syllable (initial or final replaced; finals may have several)."
function syl_variants(s::String)::Vector{String}
    out = String[s]
    ini, fin = split_syllable(s)
    if haskey(INITIAL_CONFUSE, ini)
        for ci in INITIAL_CONFUSE[ini]
            push!(out, ci * fin)
        end
    end
    if haskey(FINAL_CONFUSE, fin)
        for cf in FINAL_CONFUSE[fin]
            push!(out, ini * cf)
        end
    end
    return out
end

"""
    is_confuse_pair(q_syl, t_syl) -> Bool

True when query syllable `q_syl` becomes target syllable `t_syl` by one step
(initial or final replaced). The direction matches `syl_variants`: with an
r→l edge, `is_confuse_pair("ri", "li")` is true. The reverse holds only when
the table also carries the reverse edge — it does for li→ri here, because the
default table has both `r => ["l"]` and `l => ["r"]`.
"""
function is_confuse_pair(q_syl::String, t_syl::String)::Bool
    q_syl == t_syl && return false
    ini, fin = split_syllable(q_syl)
    for ci in get(INITIAL_CONFUSE, ini, ())
        ci * fin == t_syl && return true
    end
    for cf in get(FINAL_CONFUSE, fin, ())
        ini * cf == t_syl && return true
    end
    return false
end

# ============================================================
# Ablation API (used by audit_variant_usage / build_eval_s1)
# GENERATION increases monotonically; the scoring layer invalidates its
# reading-pair memo when it changes.
# ============================================================
const GENERATION = Ref(0)
generation() = GENERATION[]

# Snapshot with deepcopy so that in-place edits of the live table (push!/delete!)
# cannot leak into the snapshot and break `restore!`.
const _SNAP_INITIAL = deepcopy(INITIAL_CONFUSE)
const _SNAP_FINAL = deepcopy(FINAL_CONFUSE)

"Remove one directed edge from either table; true when it existed."
function drop_edge!(from::String, to::String)::Bool
    for tbl in (INITIAL_CONFUSE, FINAL_CONFUSE)
        if haskey(tbl, from) && to in tbl[from]
            vals = filter(x -> x != to, tbl[from])
            isempty(vals) ? delete!(tbl, from) : (tbl[from] = vals)
            GENERATION[] += 1
            return true
        end
    end
    return false
end

"Restore both tables from the initial snapshot (deepcopy again on merge, so the
snapshot vectors never become shared with the live table)."
function restore!()
    empty!(INITIAL_CONFUSE); merge!(INITIAL_CONFUSE, deepcopy(_SNAP_INITIAL))
    empty!(FINAL_CONFUSE); merge!(FINAL_CONFUSE, deepcopy(_SNAP_FINAL))
    GENERATION[] += 1
    return nothing
end

end # module
