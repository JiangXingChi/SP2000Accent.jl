"""
    Index — inverted indices

Builds three inverted indices over the catalogue rows and serves the three-way
recall (by character, by syllable, by initials). Recall only merges and
deduplicates; truncation happens later in the scoring layer's coarse ranking.
"""
module Index

using ..Pinyin
using ..Confusion

export SpeciesIndex, build_index!, search_candidates

"""
    SpeciesIndex

Inverted indices over the catalogue. `names`, `scientific_names`, `families`
and `genera` are row-aligned; all three indices store row numbers.
"""
mutable struct SpeciesIndex
    names::Vector{String}
    scientific_names::Vector{String}
    families::Vector{String}
    genera::Vector{String}
    char_index::Dict{Char,Vector{Int}}
    syllable_index::Dict{String,Vector{Int}}
    init_index::Dict{String,Vector{Int}}
end

SpeciesIndex() = SpeciesIndex(String[], String[], String[], String[],
                              Dict{Char,Vector{Int}}(),
                              Dict{String,Vector{Int}}(),
                              Dict{String,Vector{Int}}())

# String form of one catalogue cell. `string(missing)` is the literal
# "missing", which would reach the result table as if it were a name
# component; a cell that is absent must stay an empty string.
_cell(v) = (v === missing || v === nothing) ? "" : strip(string(v))


"""
    build_index!(idx, df)

Build the index from a catalogue table. `df` is duck-typed: any table that
supports `df[!, "column"]` and has the four columns 物种中文名 / 物种拉丁名 /
科中文名 / 属中文名. The module does not depend on DataFrames, so the
cache-hit startup path never loads it.
"""
function build_index!(idx::SpeciesIndex, df)
    empty!(idx.names)
    empty!(idx.scientific_names)
    empty!(idx.families)
    empty!(idx.genera)
    empty!(idx.char_index)
    empty!(idx.syllable_index)
    empty!(idx.init_index)

    cn_col = df[!, "物种中文名"]
    sci_col = df[!, "物种拉丁名"]
    fam_col = df[!, "科中文名"]
    gen_col = df[!, "属中文名"]

    seen_names = Set{String}()
    # One set reused for the per-row reading dedupe: allocating a set per row
    # meant 47 279 sets for one build. `empty!` keeps the buckets.
    seen_syl = Set{String}()
    for k in eachindex(cn_col)
        raw = cn_col[k]
        (raw === missing || raw === nothing) && continue
        cn_name = strip(string(raw))
        isempty(cn_name) && continue
        cn_name in seen_names && continue      # duplicate Chinese names: keep the first row
        push!(seen_names, cn_name)

        push!(idx.names, cn_name)
        push!(idx.scientific_names, _cell(sci_col[k]))
        push!(idx.families, _cell(fam_col[k]))
        push!(idx.genera, _cell(gen_col[k]))
        row = length(idx.names)

        # A query only forms an initials key from two or more Han characters
        # (see search_candidates), so a one-Han name would only add a posting
        # list that can never be looked up.
        n_han = count(Pinyin.is_han_char, cn_name)
        n_han >= 2 && push!(get!(idx.init_index, "$(n_han):$(Pinyin.get_initials(cn_name))") do
            Int[]
        end, row)

        empty!(seen_syl)
        for c in cn_name
            # Non-Han characters (brackets, punctuation) are not indexed: a query
            # on them would recall thousands of rows that can never score well.
            Pinyin.is_han_char(c) || continue
            push!(get!(idx.char_index, c) do
                Int[]
            end, row)
            for r in Pinyin.readings_of(c)
                r in seen_syl && continue
                push!(seen_syl, r)
                push!(get!(idx.syllable_index, r) do
                    Int[]
                end, row)
            end
        end
    end
    return nothing
end

"""
    search_candidates(idx, query) -> Vector{NTuple{4,String}}

Union of the three recall routes, deduplicated: by character (character index),
by syllable (syllable index, expanded through the confusion table), and by
initials (same Han-character count and identical initials). No truncation —
everything is passed to coarse ranking.
"""
function search_candidates(idx::SpeciesIndex, query::AbstractString)::Vector{NTuple{4,String}}
    rows = Set{Int}()
    # `unique` on a string collects the characters once; collecting first and
    # uniquing after copied the query twice.
    q_chars = unique(query)

    for c in q_chars
        haskey(idx.char_index, c) && union!(rows, idx.char_index[c])
    end

    q_syls = Set{String}()
    for c in q_chars
        for r in Pinyin.readings_of(c)
            union!(q_syls, Confusion.syl_variants(r))
        end
    end
    for s in q_syls
        haskey(idx.syllable_index, s) && union!(rows, idx.syllable_index[s])
    end

    q_han = count(Pinyin.is_han_char, query)
    if q_han >= 2
        key = "$(q_han):$(Pinyin.get_initials(query))"
        haskey(idx.init_index, key) && union!(rows, idx.init_index[key])
    end

    return [(idx.names[i], idx.scientific_names[i], idx.families[i], idx.genera[i])
            for i in rows]
end

end # module
