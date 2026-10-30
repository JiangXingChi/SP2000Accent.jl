"""
    Matcher — distance primitives, three-term scoring, coarse ranking

Scores are only used for ordering; the API layer formats them for display.
"""
module Matcher

using ..Pinyin
using ..Confusion

export lev_distance, lev_similarity, calc_score, rank_candidates, coarse_pool,
       CONFUSE_SIM, set_confuse_sim!, IMPORTANCE, set_importance!,
       POOL_FRACTION, set_pool_fraction!

# ============================================================
# Distance primitives
# ============================================================

"Levenshtein edit distance."
function lev_distance(a::AbstractString, b::AbstractString)::Int
    return _lev_distance_chars(collect(a), collect(b))
end

# Core DP on character vectors. Both public entry points collect their strings
# once; the scoring loop already holds the vectors, so it calls this directly.
function _lev_distance_chars(ca::Vector{Char}, cb::Vector{Char})::Int
    la, lb = length(ca), length(cb)
    la == 0 && return lb
    lb == 0 && return la

    prev = collect(0:lb)
    curr = zeros(Int, lb + 1)

    @inbounds for i in 1:la
        curr[1] = i
        ai = ca[i]
        for j in 1:lb
            cost = ai == cb[j] ? 0 : 1
            curr[j+1] = min(curr[j] + 1, prev[j+1] + 1, prev[j] + cost)
        end
        prev, curr = curr, prev
    end
    return prev[end]
end

"Normalise edit distance to a 0–1 similarity."
function lev_similarity(a::AbstractString, b::AbstractString)::Float64
    return _lev_similarity_chars(collect(a), collect(b))
end

function _lev_similarity_chars(ca::Vector{Char}, cb::Vector{Char})::Float64
    max_len = max(length(ca), length(cb))
    max_len == 0 && return 1.0
    return 1.0 - _lev_distance_chars(ca, cb) / max_len
end

# Fast Levenshtein for short ASCII strings. ASCII only, indexed by codeunit:
# multi-byte strings would raise StringIndexError. The only caller
# (_pair_pinyin_sim) guards with isascii.
function _lev_distance_fast(a::String, b::String, la::Int, lb::Int)::Int
    la == 0 && return lb
    lb == 0 && return la

    prev = collect(0:lb)
    curr = zeros(Int, lb + 1)

    for i in 1:la
        curr[1] = i
        ai = a[i]
        @inbounds for j in 1:lb
            cost = ai == b[j] ? 0 : 1
            curr[j+1] = min(curr[j] + 1, prev[j+1] + 1, prev[j] + cost)
        end
        prev, curr = curr, prev
    end
    return prev[end]
end

# ============================================================
# Reading-pair similarity
# ============================================================

# Floor for one-step confusion pairs: above ordinary one-edit near-homophones
# (syllables are at most 6 letters, so one edit gives at most 0.833) and below
# identical readings (1.0). A tunable parameter, see model/待选参数.md.
const CONFUSE_SIM = Ref(0.95)

# Memo for reading pairs and character pairs. Ablation scripts edit the table
# through Confusion.drop_edge!/restore!, which bumps the generation; on a
# generation change the whole memo is cleared. Single-threaded assumption,
# same as the CLI and evaluation scripts.
const _PAIR_SIM_CACHE = Dict{Tuple{String,String},Float64}()
const _PAIR_SIM_GEN = Ref(-1)
const _CHAR_PAIR_CACHE = Dict{Tuple{Char,Char},Float64}()
const _CHAR_PAIR_GEN = Ref(-1)
# The character-pair memo grows with every candidate scored, i.e. with the
# number of queries in a session; cap it so long batch runs stay bounded.
const _CHAR_PAIR_CACHE_MAX = 200_000

"Set the confusion-pair floor and clear the memo; out-of-range values are rejected."
function set_confuse_sim!(v::Float64)
    0.0 <= v <= 1.0 || error("CONFUSE_SIM 须在 [0,1]（得到 $v）：>1 会使 DP 替换成本为负")
    CONFUSE_SIM[] = v
    empty!(_PAIR_SIM_CACHE)
    empty!(_CHAR_PAIR_CACHE)
    return v
end

"Similarity of two readings: 1.0 if equal, at least CONFUSE_SIM for a one-step confusion pair, otherwise edit distance."
function _pair_pinyin_sim(ra::String, rb::String)::Float64
    ra == rb && return 1.0
    g = Confusion.generation()
    if g != _PAIR_SIM_GEN[]
        empty!(_PAIR_SIM_CACHE)
        _PAIR_SIM_GEN[] = g
    end
    key = (ra, rb)
    hit = get(_PAIR_SIM_CACHE, key, nothing)
    hit !== nothing && return hit
    sim = if isascii(ra) && isascii(rb)
        la, lb = length(ra), length(rb)
        ml = max(la, lb)
        ml == 0 ? 1.0 : 1.0 - Float64(_lev_distance_fast(ra, rb, la, lb)) / ml
    else
        # pinyin_data contains 68 self-mapped non-ASCII readings (rare and
        # variant characters); use the general implementation for those.
        lev_similarity(ra, rb)
    end
    Confusion.is_confuse_pair(ra, rb) && (sim = max(sim, CONFUSE_SIM[]))
    _PAIR_SIM_CACHE[key] = sim
    return sim
end

"Best reading similarity for two characters: max over all reading pairs; falls back to character equality."
function _best_pinyin_sim_pair(readings_a::Vector{String}, readings_b::Vector{String},
                                char_a::Char, char_b::Char)::Float64
    (isempty(readings_a) || isempty(readings_b)) && return Float64(char_a == char_b)
    g = Confusion.generation()
    if g != _CHAR_PAIR_GEN[]
        empty!(_CHAR_PAIR_CACHE)
        _CHAR_PAIR_GEN[] = g
    end
    key = (char_a, char_b)
    hit = get(_CHAR_PAIR_CACHE, key, nothing)
    hit !== nothing && return hit

    best = 0.0
    for ra in readings_a
        for rb in readings_b
            ra == rb && (best = 1.0; break)
            s = _pair_pinyin_sim(ra, rb)
            s > best && (best = s)
        end
        best == 1.0 && break
    end
    if length(_CHAR_PAIR_CACHE) >= _CHAR_PAIR_CACHE_MAX
        empty!(_CHAR_PAIR_CACHE)
    end
    _CHAR_PAIR_CACHE[key] = best
    return best
end

# ============================================================
# Three-term scoring
# ============================================================

# Weights are derived from relative importance: weight = importance / sum.
# Importance is 1–5 per term; see model/待选参数.md for the grid and the
# deduplication. Defaults are the best combination from the 2026-10-21 sweep
# (2875 configurations) and the frozen S1 set: 5/4/1, floor 0.95, pool 30%.
const IMPORTANCE = Ref((5, 4, 1))   # reading, literal, initials
const W_READING = Ref(5 / 10)
const W_CHAR = Ref(4 / 10)
const W_INITIAL = Ref(1 / 10)

"Set the three importances and recompute weights; out-of-range values are rejected."
function set_importance!(r::Int, c::Int, i::Int)
    (1 <= r <= 5 && 1 <= c <= 5 && 1 <= i <= 5) ||
        error("重要度须在 1 到 5 之间（得到 $r/$c/$i）")
    s = r + c + i
    IMPORTANCE[] = (r, c, i)
    W_READING[] = r / s
    W_CHAR[] = c / s
    W_INITIAL[] = i / s
    return (W_READING[], W_CHAR[], W_INITIAL[])
end


function _pinyin_sim_aligned_impl(q_readings::Vector{Vector{String}}, q_chars::Vector{Char},
                                  t_readings::Vector{Vector{String}}, t_chars::Vector{Char})::Float64
    isempty(q_chars) && isempty(t_chars) && return 1.0
    (isempty(q_chars) || isempty(t_chars)) && return 0.0

    la, lb = length(q_chars), length(t_chars)
    norm = max(la, lb)
    step = 1.0 / norm

    prev = zeros(Float64, lb + 1)
    curr = zeros(Float64, lb + 1)
    @inbounds for j in 1:lb
        prev[j+1] = Float64(j) * step
    end

    @inbounds for i in 1:la
        curr[1] = Float64(i) * step
        qi = q_chars[i]
        pi = q_readings[i]
        for j in 1:lb
            tj = t_chars[j]
            pj = t_readings[j]
            cost = (1.0 - _best_pinyin_sim_pair(pi, pj, qi, tj)) * step
            curr[j+1] = min(curr[j] + step, prev[j+1] + step, prev[j] + cost)
        end
        prev, curr = curr, prev
    end
    return clamp(1.0 - prev[end], 0.0, 1.0)
end

"Initial similarity, four levels: equal 1.0, target prefixed by query 0.8, same first letter 0.5, otherwise 0."
function _init_sim(q_init::String, t_init::String)::Float64
    (isempty(q_init) || isempty(t_init)) && return 0.0
    q_init == t_init && return 1.0
    startswith(t_init, q_init) && return 0.8
    q_init[1] == t_init[1] && return 0.5
    return 0.0
end

"""
    calc_score(query, target) -> Float64

Weighted similarity of query and target name. Uses the same implementation as
ranking, so the two cannot drift apart. A trailing qualifier on the target,
such as `"(新亚种)"`, is ignored: both the full name and the bare name are
scored and the better one is returned.
"""
calc_score(query::AbstractString, target::AbstractString)::Float64 =
    _calc_score_prepped(_prep_query(query), target)

"Query-side precomputation, shared across all candidates of one query."
struct _QueryPrep
    chars::Vector{Char}
    readings::Vector{Vector{String}}
    init::String
end

function _prep_query(query::AbstractString)
    chars = collect(query)
    # No `str` field: the only reader used to be `_score_one`, which now passes
    # the target straight to `get_initials`. An extra String copy per query was
    # built and never read.
    return _QueryPrep(chars, [Pinyin.char_all_readings(c) for c in chars],
                      Pinyin.get_initials(query))
end

# Trailing qualifier in parentheses, e.g. "中华喀蚱(新亚种)".
const _QUALIFIER_RE = r"\s*[\(（][^\)）]*[\)）]\s*$"

"Scoring core; `calc_score` is a thin wrapper around it."
_calc_score_prepped(qp::_QueryPrep, target::AbstractString)::Float64 =
    _score_and_bare(qp, target)[1]

"""
Score one name and report whether it is bare. `rank_candidates` needs both, and
the qualifier test must run once per candidate rather than once for the score
and again for the sort key.
"""
function _score_and_bare(qp::_QueryPrep, target::AbstractString)::Tuple{Float64,Bool}
    full = _score_one(qp, target)
    _is_bare_name(target) && return (full, true)
    # `_is_bare_name` has already accepted every bracket-free name; only the few
    # names that still carry brackets reach this replace.
    base = replace(target, _QUALIFIER_RE => "")
    base == target && return (full, true)
    return (max(full, _score_one(qp, base)), false)
end

"Score one exact string with the three weighted terms."
function _score_one(qp::_QueryPrep, target::AbstractString)::Float64
    t_chars = collect(target)
    t_readings = [Pinyin.char_all_readings(c) for c in t_chars]
    py = _pinyin_sim_aligned_impl(qp.readings, qp.chars, t_readings, t_chars)
    ch = _lev_similarity_chars(qp.chars, t_chars)
    # `get_initials` takes any AbstractString; the copy some callers would need
    # is paid inside it (one small Char buffer), not here.
    ini = _init_sim(qp.init, Pinyin.get_initials(target))
    return py * W_READING[] + ch * W_CHAR[] + ini * W_INITIAL[]
end

# ============================================================
# Coarse ranking
# ============================================================

# Share of the recall union kept for fine scoring; see model/待选参数.md.
const POOL_FRACTION = Ref(0.05)   # 2026-10-29 扫参：0.05–0.50 同分，取最小最快的一档

"Set the coarse-ranking share, above 0 and at most 1; out-of-range values are rejected."
function set_pool_fraction!(f::Float64)
    0.0 < f <= 1.0 || error("粗排占比须在 0 到 1 之间（得到 $f）")
    POOL_FRACTION[] = f
    return f
end

# Query-side inputs for coarse ranking, built once per query.
struct _CoarsePrep
    chars::Set{Char}                  # distinct characters of the query
    syls::Set{String}                 # query syllable variants (confusion-expanded)
    init_key::String                  # "<Han count>:<initials>"; empty below two Han characters
    n_han::Int                        # Han characters in the query
    hits::Dict{Char,Vector{String}}   # memo: character -> its readings that occur in `syls` (read-only)
end

function _coarse_query(query::AbstractString)::_CoarsePrep
    chars = Set(query)
    syls = Set{String}()
    for c in chars
        for r in Pinyin.readings_of(c)
            union!(syls, Confusion.syl_variants(r))
        end
    end
    n_han = _han_count(query)
    return _CoarsePrep(chars, syls, _initials_key(n_han, query), n_han,
                       Dict{Char,Vector{String}}())
end

"`<Han count>:<initials>` key of a name; empty when it has fewer than two Han characters.
`n_han` must be `_han_count(name)`: the hot loop passes the count it already has
instead of making this function scan the name again."
_initials_key(n_han::Int, name::AbstractString)::String =
    n_han >= 2 ? "$n_han:$(Pinyin.get_initials(name))" : ""

# Han characters in a name. Counting without `collect`: this runs once per
# candidate, and `collect(name)` alone allocates 80 B.
_han_count(name::AbstractString)::Int = count(Pinyin.is_han_char, name)

"""
    _hit_readings(prep, c) -> Vector{String}

The readings of `c` that the query's variant set contains. The answer depends
only on the query, so it is memoised in the query prep: a large query asks for
the same few thousand characters over and over, and the memo turns a
`Set{String}` lookup per reading into one `Char` lookup per character. The
returned vector belongs to the memo and must not be modified.
"""
function _hit_readings(prep::_CoarsePrep, c::Char)::Vector{String}
    hit = get(prep.hits, c, nothing)
    hit === nothing || return hit
    out = String[]
    for r in Pinyin.readings_of(c)
        r in prep.syls && push!(out, r)
    end
    prep.hits[c] = out
    return out
end

# Per-name reading dedupe for `_coarse_key`. Names are at most a dozen
# characters, so a linear scan over a reused vector beats hashing every
# reading into a Set; `empty!` keeps the buffer after warm-up. Only readings
# that hit the query's variant set are stored: a reading that misses cannot
# change the count, so deduplicating misses was wasted work (1.4x on the
# isolated key; the keys loop of a 19k-candidate query went 28.5 -> 11.8 ms,
# same values on 7 queries x 47 279 names).
const _COARSE_SEEN = String[]

"Coarse key: number of characters shared with the query plus number of readings hit by the query's variants."
function _coarse_key(prep::_CoarsePrep, name::AbstractString)::Int
    shared = count(c -> c in prep.chars, name)
    hits = 0
    seen = empty!(_COARSE_SEEN)
    for c in name
        for r in _hit_readings(prep, c)
            r in seen && continue
            push!(seen, r)
            hits += 1
        end
    end
    return shared + hits
end

"""
    coarse_pool(query, candidates; fraction=POOL_FRACTION[])

Keep roughly `fraction × |candidates|` rows by coarse key. Candidates whose
(Han count, initials) key equals the query's are kept outside the quota; they
are still fine-scored and may rank anywhere.
"""
function coarse_pool(query::AbstractString, candidates::Vector{NTuple{4,String}};
                     fraction::Float64=POOL_FRACTION[])::Vector{NTuple{4,String}}
    isempty(candidates) && return candidates
    prep = _coarse_query(query)

    n = length(candidates)
    keep = NTuple{4,String}[]
    rest = NTuple{4,String}[]
    sizehint!(keep, min(n, 512))   # initials-route hits are a small minority of a large recall set
    sizehint!(rest, n)
    q_n = prep.n_han
    init_key = prep.init_key
    for c in candidates
        # The Han-character count is a cheap pre-check: only names with the
        # query's count can produce its initials key, so most candidates skip
        # the key construction (get_initials is 0.24 µs and 176 B each).
        if q_n >= 2 && _han_count(c[1]) == q_n && _initials_key(q_n, c[1]) == init_key
            push!(keep, c)
        else
            push!(rest, c)
        end
    end
    m = max(1, round(Int, fraction * n))
    if length(rest) > m
        keys = Vector{Int}(undef, length(rest))
        @inbounds for i in eachindex(rest)
            keys[i] = _coarse_key(prep, rest[i][1])
        end
        # Descending coarse key; ties keep recall order (stable sort), so
        # results are reproducible.
        perm = sortperm(keys; rev=true, alg=Base.Sort.MergeSort)
        rest = rest[perm[1:m]]
    end
    # `keep` and `rest` are disjoint by construction (each candidate went to
    # exactly one of them, and the quota only drops elements from `rest`), so
    # the initials-route rows can be appended without a dedupe set.
    append!(rest, keep)
    return rest
end

# ============================================================
# Ranking
# ============================================================

"True when a name carries no trailing qualifier such as `(原变种)`."
function _is_bare_name(name::AbstractString)::Bool
    # A qualifier always contains a bracket and nearly every catalogue name has
    # none, so the bracket scan short-circuits the regex: `match` on a bare name
    # spends ~0.2 µs trying every start position, the two scans ~0.1 µs.
    (occursin('(', name) || occursin('（', name)) || return true
    return match(_QUALIFIER_RE, name) === nothing
end

"""
    rank_candidates(query, candidates; top_n=5)

Score every candidate and return the top `top_n` by descending score.
`candidates` are `(chinese_name, scientific_name, family, genus)` tuples.
Ties go to the bare name first, so a qualifier-variant never outranks the
canonical entry that shares its score.
"""
function rank_candidates(query::AbstractString, candidates::Vector{NTuple{4,String}};
                         top_n::Int=5)::Vector{Tuple{Float64,String,String,String,String}}
    n = length(candidates)
    n == 0 && return Tuple{Float64,String,String,String,String}[]

    qp = _prep_query(query)
    # The bare-name flag is part of the sort key, so it is computed once per
    # candidate, and `_score_and_bare` returns it together with the score. Only
    # the keys are stored and a permutation is sorted: a `by` closure over the
    # full rows rebuilt the key tuple for every comparison, i.e. n log n tuples
    # per query.
    keys = Vector{Tuple{Float64,Bool}}(undef, n)
    @inbounds for i in 1:n
        keys[i] = _score_and_bare(qp, candidates[i][1])
    end
    # Descending score; a tie goes to the bare name, then to recall order (the
    # sort is stable), so equal-scoring candidates keep the order they came in.
    perm = sortperm(keys; rev = true, alg = Base.Sort.MergeSort)

    k = clamp(top_n, 0, n)
    out = Vector{Tuple{Float64,String,String,String,String}}(undef, k)
    @inbounds for i in 1:k
        j = perm[i]
        c = candidates[j]
        out[i] = (keys[j][1], c[1], c[2], c[3], c[4])
    end
    return out
end

end # module
