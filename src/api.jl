# ============================================================
# Public API
# ============================================================
# One job: one query in, one candidate table out — recall, coarse ranking,
# fine scoring.

"""
    correct(query; top_n=5, dataset="plantae") -> DataFrame

Check one Chinese plant name written in a field record and return candidates
from the catalogue. Retrieval only: the input is never rewritten and no record
is modified.

# Positional argument
- `query::AbstractString`: one Chinese name, e.g. `"苟牙根"`. Chinese names only;
  scientific (Latin) names are not accepted. Surrounding whitespace is stripped;
  an empty string returns an empty five-column table without loading any index.

# Keyword arguments
- `top_n::Int=5`: maximum rows in the candidate table. Fewer are returned when
  fewer candidates exist; `top_n=1` asks for the first choice only, `top_n=0`
  returns an empty table with the same five columns.
- `dataset::AbstractString="plantae"`: which catalogue to search. English names
  only (case- and whitespace-insensitive); see the list below.

# Datasets
- `"plantae"`: Plantae, 47,279 searchable names (default)
- `"chordata"`: Animalia, Chordata, 8,681
- `"insecta"`: Animalia, Insecta, 38,463
- `"invertebrates"`: Animalia, other invertebrates, 15,925
- `"fungi"`: Fungi, 11,601

All five are the 2024 Catalogue of Life China, shipped as xlsx files inside
SP2000ChinaData.jl; everything runs offline. They share the same columns
(Chinese name, scientific name, family, genus) and each gets its own index.
The counts above are the names that can actually be returned: a row without a
Chinese name is not searchable (the fungi catalogue has 27,807 rows but only
11,601 distinct Chinese names), and a repeated Chinese name is kept once, first
row wins.
Passing a Chinese name (e.g. `"真菌界"`) or any other spelling raises
`未知数据集` and lists the five valid values.

# Returns
A `DataFrame` sorted by descending score, with five columns:

- `中文名` (`String`): accepted Chinese name in the catalogue
- `拉丁学名` (`String`): corresponding scientific name
- `科` (`String`): family, in Chinese
- `属` (`String`): genus, in Chinese
- `分数` (`Float64`): weighted similarity, three decimals

The score orders the table; it is not a probability and not a confidence value.
Whether to change the record is up to the person reading the table.

# Index and cache
The first query on a dataset builds its index (about 14 s) or reads it from
cache (about 0.5 s); later queries on the same dataset reuse it. Switching
`dataset` switches the catalogue, and returning to a previously built one only
reads its cache. Cache files live in the package's own `cache/` directory
(`species_index_<slug>.bin`, writable by the current user)
and are rebuilt automatically when the catalogue package version, the xlsx
file, the pinyin table, the index code or the Julia version change. Force a
rebuild with `SP2000ACCENT_NO_CACHE=1` (that also skips writing the cache).
To warm up outside a loop, call `SP2000Accent.load_index!`; it is idempotent
and safe to call from several tasks at once — the index is built once and a
query always runs against the dataset it asked for.

# Batch input
Pass a vector of names to check many records at once:

```julia
correct(["镜子苔草", "盲箕", "承兰"]; top_n=3)
```

Returns one `DataFrame` with `输入` added as the first column; the other five
are unchanged. Rows follow the input order and, within one name, descending
score. Empty strings are skipped; an empty vector returns an empty six-column
table. The index is loaded once for the whole batch.

# Edge cases
- Negative `top_n`: throws `ArgumentError`.
- Unknown `dataset`: throws `ErrorException` listing every valid value.
- Input without Han characters (e.g. a Latin name): no error; recall finds
  almost nothing, so the result is usually an empty table.
- Invented Chinese names: still return low-scoring candidates, typically below
  0.4, because the character and initials routes match something.

# Examples
```julia-repl
julia> using SP2000Accent

julia> correct("苟牙根"; top_n=3)
3×5 DataFrame
 Row │ 中文名  拉丁学名                    科        属        分数
     │ String  String                      String    String    Float64
─────┼─────────────────────────────────────────────────────────────────
   1 │ 狗牙根  Cynodon dactylon            禾本科    狗牙根属    0.867
   2 │ 狗牙藓  Cynodontium gracilescens    粗石藓科  狗牙藓属    0.558
   3 │ 狗牙花  Tabernaemontana divaricata  夹竹桃科  狗牙花属    0.517

julia> correct("冬虫夏草"; dataset="fungi", top_n=1)
1×5 DataFrame
 Row │ 中文名    拉丁学名                科      属      分数
     │ String    String                  String  String  Float64
─────┼───────────────────────────────────────────────────────────
   1 │ 冬虫夏草  Cordyceps sichuanensis  虫草科  虫草属      1.0
```

# See also
`SP2000Accent.load_index!`, `SP2000Accent.dataset_names`
"""
function correct(query::AbstractString; top_n::Int=5, dataset::AbstractString="plantae")
    top_n >= 0 || throw(ArgumentError("top_n must be ≥ 0 (got $top_n)"))
    d = _dataset(dataset)      # validate even when the query is empty
    q = strip(query)
    isempty(q) && return _empty_result()
    idx = _current_index(d)
    return _query_table(idx, q; top_n=top_n)
end

"""
    correct(queries::AbstractVector{<:AbstractString}; top_n=5, dataset="plantae") -> DataFrame

Batch form of [`correct`](@ref): check many names at once and return one table.

Columns are the single-name five columns with `输入` added first, so every row
shows which query produced it. Rows follow the order of `queries`; within one
query they stay sorted by descending score. Empty strings are skipped, and an
empty vector returns an empty table with the six columns. A query that recalls
nothing (e.g. a Latin name) contributes no row, so the table cannot be mapped
back one-to-one onto the input. The index is loaded once per call.
"""
function correct(queries::AbstractVector{<:AbstractString}; top_n::Int=5, dataset::AbstractString="plantae")
    top_n >= 0 || throw(ArgumentError("top_n must be ≥ 0 (got $top_n)"))
    d = _dataset(dataset)      # validate even when the batch is empty
    qs = String[strip(q) for q in queries]
    filter!(!isempty, qs)
    isempty(qs) && return _empty_batch_result()
    idx = _current_index(d)

    # Columns are accumulated across queries and the table is built once: a
    # DataFrame per query plus reduce(vcat, ...) would copy every row twice.
    # Rows per query are at most min(top_n, recalls); the hint is capped so a
    # huge top_n cannot reserve megabytes for rows that will never exist.
    hint = length(qs) * min(top_n, 8)
    inputs = String[]
    names = String[]
    scis = String[]
    fams = String[]
    gens = String[]
    scores = Float64[]
    for col in (inputs, names, scis, fams, gens)
        sizehint!(col, hint)
    end
    sizehint!(scores, hint)
    for q in qs
        for r in _query_rows(idx, q; top_n=top_n)
            push!(inputs, q)
            push!(names, r[2])
            push!(scis, r[3])
            push!(fams, r[4])
            push!(gens, r[5])
            push!(scores, round(r[1]; digits=3))
        end
    end
    isempty(inputs) && return _empty_batch_result()
    return DataFrames.DataFrame("输入" => inputs, "中文名" => names, "拉丁学名" => scis,
                                "科" => fams, "属" => gens, "分数" => scores)
end

"Rank one query against `idx`; the scored rows before any table is built."
function _query_rows(idx::Index.SpeciesIndex, q::AbstractString; top_n::Int=5)
    cands = Index.search_candidates(idx, q)
    pool = Matcher.coarse_pool(q, cands)
    return Matcher.rank_candidates(q, pool; top_n=top_n)
end

"Rank one query against the loaded index: five columns, descending score."
function _query_table(idx::Index.SpeciesIndex, q::AbstractString; top_n::Int=5)
    rows = _query_rows(idx, q; top_n=top_n)

    return DataFrames.DataFrame(
        "中文名" => [r[2] for r in rows],
        "拉丁学名" => [r[3] for r in rows],
        "科" => [r[4] for r in rows],
        "属" => [r[5] for r in rows],
        "分数" => [round(r[1]; digits=3) for r in rows])
end

"Empty result with the same five columns, used for an empty query."
function _empty_result()
    return DataFrames.DataFrame("中文名" => String[], "拉丁学名" => String[],
                                "科" => String[], "属" => String[],
                                "分数" => Float64[])
end

"Empty batch result: six columns, `输入` first."
function _empty_batch_result()
    return DataFrames.DataFrame("输入" => String[],
                                "中文名" => String[], "拉丁学名" => String[],
                                "科" => String[], "属" => String[],
                                "分数" => Float64[])
end
