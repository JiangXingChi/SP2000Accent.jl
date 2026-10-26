# ============================================================
# Precompile warm-up
# ============================================================
# One job: bake the JIT results for recall, coarse ranking, fine scoring and
# cache reading into the precompile cache (.ji). Runs once when the .ji is
# generated, never when the module is loaded normally — zero runtime cost.

"Duck table for warm-up: satisfies build_index!'s df[!, \"column\"] contract without loading the catalogue package."
struct _WarmTable
    cols::Dict{String,Vector{String}}
end
Base.getindex(t::_WarmTable, ::typeof(!), name::String) = t.cols[name]

function _precompile_warmup()
    warm = [("狗牙根", "Cynodon dactylon", "禾本科", "狗牙根属"),
            ("牛鞭草", "Hemarthria sibirica", "禾本科", "牛鞭草属"),
            ("春兰", "Cymbidium goeringii", "兰科", "兰属"),
            ("香附子", "Cyperus rotundus", "莎草科", "莎草属")]
    table = _WarmTable(Dict(
        "物种中文名" => [s[1] for s in warm],
        "物种拉丁名" => [s[2] for s in warm],
        "科中文名"   => [s[3] for s in warm],
        "属中文名"   => [s[4] for s in warm]))

    idx = Index.SpeciesIndex()
    Index.build_index!(idx, table)

    # 1. Recall, coarse ranking and fine scoring, one pass each. The bracketed
    #    name warms the qualifier branch (bracket scan + regex + second score),
    #    which the bare names never reach.
    for q in ("苟牙根", "牛鞭炒", "承兰", "由讼", "月季(原变种)")
        cands = Index.search_candidates(idx, q)
        pool = Matcher.coarse_pool(q, cands)
        Matcher.rank_candidates(q, pool; top_n=5)
        Matcher.calc_score(q, "狗牙根")
        Matcher.calc_score(q, "狗牙根(原变种)")
    end

    # 2. Full exit path, including the DataFrame construction (single and batch).
    _activate!(idx, DATASETS[1])
    for q in ("苟牙根", "承兰")
        correct(q; top_n=3)
    end
    correct(["苟牙根", "承兰"]; top_n=3)

    # 3. Cache write/read round trip and payload validation. The file-stream
    #    path differs from IOBuffer, and the atomic mv is part of the write.
    #    The payload carries the same six fields as the one `_rebuild!` writes,
    #    so this warms the accept path rather than the reject path.
    dir = mktempdir()
    try
        path = joinpath(dir, "species_index_warm.bin")
        payload = (index = idx, fingerprint = "warm", data_version = "warm",
                   dataset = DATASETS[1].slug,
                   fields = string(fieldnames(Index.SpeciesIndex)),
                   cache_version = INDEX_CACHE_VERSION)
        _cache_write(path, payload)
        _cache_valid(_cache_read(path), "warm")
    finally
        rm(dir; force = true, recursive = true)
    end

    # 4. Fingerprint chain: streaming hash, version parse, hex digest.
    _index_fingerprint()

    # 5. Reset so the warm-up index is not baked into the .ji.
    GLOBAL_INDEX[] = Index.SpeciesIndex()
    INDEX_DATASET[] = ""
    INDEX_LOADED[] = false
    return nothing
end

# `Base.generating_output()` only exists from Julia 1.12 on; the C entry point
# works on every supported version (1.10+).
if ccall(:jl_generating_output, Cint, ()) == 1
    _precompile_warmup()
end
