# SP2000Accent — unit tests (no full catalogue needed, runs in seconds)
# Run from the project root: julia --project=juliapkg juliapkg/test/runtests.jl
using Test
import DataFrames
using SP2000Accent
using SP2000Accent: Matcher, Pinyin, Index, Confusion

# Duck table that can hold missing cells, used to test index hygiene.
struct _MixedTable
    cols::Dict{String,Vector{Union{String,Missing}}}
end
Base.getindex(t::_MixedTable, ::typeof(!), name::String) = t.cols[name]

# SP2000ChinaData is a hard dependency, but a stripped checkout can lack its
# xlsx files. Tests that need the catalogue skip instead of failing, so the unit
# suite still runs without the data (and without any cache file).
const HAS_CATALOGUE = SP2000Accent._sp2000data_dir() !== nothing &&
                      all(d -> SP2000Accent._dataset_xlsx(d) !== nothing, SP2000Accent.DATASETS)

@testset "SP2000Accent" begin

@testset "Edit distance" begin
    @test Matcher.lev_distance("kitten", "sitting") == 3
    @test Matcher.lev_distance("", "abc") == 3
    @test Matcher.lev_distance("abc", "abc") == 0
    @test Matcher.lev_similarity("abc", "abc") == 1.0
    @test Matcher.lev_similarity("苟牙根", "狗牙根") ≈ 2 / 3
end

@testset "Pinyin" begin
    @test Pinyin.get_pinyin("黄花蒿") == "huang hua hao"
    @test Pinyin.get_initials("黄花蒿") == "hhh"
    @test Pinyin.is_han_char('黄')
    @test !Pinyin.is_han_char('A')
    @test isempty(Pinyin.char_all_readings('A'))
    @test length(Pinyin.char_all_readings('行')) >= 2
end

@testset "Confusion variants and ablation API" begin
    @test "nan" in Confusion.syl_variants("lan")
    @test "cao" in Confusion.syl_variants("chao")
    @test Confusion.is_confuse_pair("ri", "li")
    @test Confusion.is_confuse_pair("li", "ri")
    @test !Confusion.is_confuse_pair("pi", "mi")
    @test !Confusion.is_confuse_pair("lan", "lan")
    @test !Confusion.is_confuse_pair("ma", "ta")
    @test Confusion.is_confuse_pair("zhu", "zu")
    @test Confusion.is_confuse_pair("lan", "lang")

    g0 = Confusion.generation()
    @test Confusion.drop_edge!("l", "n")
    @test !Confusion.is_confuse_pair("lan", "nan")
    @test !("nan" in Confusion.syl_variants("lan"))
    @test Confusion.generation() > g0
    Confusion.restore!()
    @test Confusion.is_confuse_pair("lan", "nan")
    @test Confusion.generation() > g0 + 1
    # Snapshot stays isolated from the live table: in-place edits are undone by restore!
    push!(Confusion.INITIAL_CONFUSE["l"], "xx_probe")
    Confusion.restore!()
    @test Confusion.INITIAL_CONFUSE["l"] == ["n", "zh", "r"]
end

@testset "Reading-pair similarity" begin
    @test Matcher._pair_pinyin_sim("la", "la") == 1.0
    @test Matcher._pair_pinyin_sim("lan", "nan") >= Matcher.CONFUSE_SIM[]
    @test Matcher._pair_pinyin_sim("lan", "man") < Matcher.CONFUSE_SIM[]
    # Non-ASCII falls back to the general edit distance
    @test Matcher._pair_pinyin_sim("aü", "aé") ≈ 0.5
    # Range check: out-of-range values raise and leave the current value unchanged
    v0 = Matcher.CONFUSE_SIM[]
    @test_throws ErrorException Matcher.set_confuse_sim!(1.5)
    @test_throws ErrorException Matcher.set_confuse_sim!(-0.1)
    @test Matcher.CONFUSE_SIM[] == v0
end

@testset "Three-term scoring" begin
    @test Matcher.W_READING[] + Matcher.W_CHAR[] + Matcher.W_INITIAL[] ≈ 1.0
    # Defaults: importance 5/4/1 gives 0.5, 0.4, 0.1
    @test Matcher.IMPORTANCE[] == (5, 4, 1)
    @test all((Matcher.W_READING[], Matcher.W_CHAR[], Matcher.W_INITIAL[]) .≈ (0.5, 0.4, 0.1))
    @test all(Matcher.set_importance!(3, 3, 1) .≈ (3/7, 3/7, 1/7))
    @test Matcher.IMPORTANCE[] == (3, 3, 1)
    @test_throws ErrorException Matcher.set_importance!(0, 3, 2)
    @test_throws ErrorException Matcher.set_importance!(3, 6, 1)
    @test Matcher.IMPORTANCE[] == (3, 3, 1)          # rejected values do not stick
    Matcher.set_importance!(5, 4, 1)                 # reset
    @test Matcher.calc_score("苟牙根", "狗牙根") > 0.8
    @test Matcher.calc_score("苟牙根", "狗牙根") > Matcher.calc_score("苟牙根", "画眉草")
    @test Matcher.calc_score("牛鞭炒", "牛鞭草") > 0.7
    # Every character differs, yet readings and initials match
    @test Matcher.calc_score("由讼", "油松") > 0.5
end

@testset "Coarse ranking" begin
    cands = [("狗牙根", "Cynodon dactylon", "禾本科", "狗牙根属"),
             ("狗牙藓", "Cynodontium gracilescens", "粗石藓科", "狗牙藓属"),
             ("春兰", "Cymbidium goeringii", "兰科", "兰属")]
    # Cap takes effect: neither query nor candidates share the initials key
    pool = Matcher.coarse_pool("苟牙草", cands; fraction=0.1)
    @test length(pool) == 1
    # Initials-route hits skip the ordering and are always kept
    pool2 = Matcher.coarse_pool("苟牙根", cands; fraction=0.1)
    @test any(c -> c[1] == "狗牙根", pool2)
end

@testset "Index and three-way recall" begin
    species = [("狗牙根", "Cynodon dactylon", "禾本科", "狗牙根属"),
               ("牛鞭草", "Hemarthria sibirica", "禾本科", "牛鞭草属"),
               ("春兰", "Cymbidium goeringii", "兰科", "兰属"),
               ("香附子", "Cyperus rotundus", "莎草科", "莎草属")]
    table = SP2000Accent._WarmTable(Dict(
        "物种中文名" => [s[1] for s in species],
        "物种拉丁名" => [s[2] for s in species],
        "科中文名" => [s[3] for s in species],
        "属中文名" => [s[4] for s in species]))
    idx = Index.SpeciesIndex()
    Index.build_index!(idx, table)
    @test length(idx.names) == 4
    @test any(x -> x[1] == "狗牙根", Index.search_candidates(idx, "苟牙根"))
    @test any(x -> x[1] == "牛鞭草", Index.search_candidates(idx, "牛鞭炒"))
    @test any(x -> x[1] == "春兰", Index.search_candidates(idx, "承兰"))
    # Chinese names only: Latin input recalls nothing
    @test isempty(Index.search_candidates(idx, "Cynodon"))
    # Rebuilding leaves no residue
    Index.build_index!(idx, table)
    @test length(idx.names) == 4
    @test length(idx.syllable_index["gou"]) == 1
end

@testset "Exit" begin
    species = [("狗牙根", "Cynodon dactylon", "禾本科", "狗牙根属"),
               ("牛鞭草", "Hemarthria sibirica", "禾本科", "牛鞭草属"),
               ("春兰", "Cymbidium goeringii", "兰科", "兰属")]
    table = SP2000Accent._WarmTable(Dict(
        "物种中文名" => [s[1] for s in species],
        "物种拉丁名" => [s[2] for s in species],
        "科中文名" => [s[3] for s in species],
        "属中文名" => [s[4] for s in species]))
    idx = Index.SpeciesIndex()
    Index.build_index!(idx, table)
    SP2000Accent._activate!(idx, SP2000Accent._dataset("plantae"))
    try
        df = correct("苟牙根")
        @test df isa DataFrames.DataFrame
        @test names(df) == ["中文名", "拉丁学名", "科", "属", "分数"]
        @test df[1, "中文名"] == "狗牙根"
        @test df[1, "拉丁学名"] == "Cynodon dactylon"
        @test df[1, "科"] == "禾本科"
        @test 0.0 <= df[1, "分数"] <= 1.0
        # Row count follows top_n, capped by the number of candidates
        @test DataFrames.nrow(correct("苟牙根"; top_n=1)) == 1
        @test DataFrames.nrow(correct("苟牙根"; top_n=5)) == 1
        # top_n=0 keeps the schema but drops every row
        zero_df = correct("苟牙根"; top_n=0)
        @test DataFrames.nrow(zero_df) == 0
        @test eltype.(eachcol(zero_df)) == [String, String, String, String, Float64]
        # Empty input returns an empty table with all columns present
        empty_df = correct("")
        @test DataFrames.nrow(empty_df) == 0
        @test names(empty_df) == ["中文名", "拉丁学名", "科", "属", "分数"]
        # Zero recall (Latin input) still returns the five-column schema, untyped columns included
        none_df = correct("Cynodon")
        @test DataFrames.nrow(none_df) == 0
        @test eltype.(eachcol(none_df)) == [String, String, String, String, Float64]

        # Initials route as last resort
        @test correct("承兰")[1, "中文名"] == "春兰"
        # dataset keyword: same dataset is not rebuilt; Chinese names are rejected
        @test correct("苟牙根"; dataset="plantae")[1, "中文名"] == "狗牙根"
        @test_throws ErrorException correct("苟牙根"; dataset="植物界")
        @test_throws ArgumentError correct("苟牙根"; top_n=-1)
        @test_throws ArgumentError correct(["苟牙根"]; top_n=-1)

        # The loaded dataset is not reloaded: the same index object stays current
        SP2000Accent.load_index!("plantae")
        @test SP2000Accent.GLOBAL_INDEX[] === idx
        @test SP2000Accent.INDEX_DATASET[] == "plantae"
        # Switching datasets replaces the index wholesale, no residue of the old one
        idx_f = Index.SpeciesIndex()
        SP2000Accent._activate!(idx_f, SP2000Accent._dataset("fungi"))
        @test SP2000Accent.GLOBAL_INDEX[] === idx_f
        @test SP2000Accent.INDEX_DATASET[] == "fungi"
        @test SP2000Accent.INDEX_LOADED[]
        SP2000Accent._activate!(idx, SP2000Accent._dataset("plantae"))

        # Batch form: one table, 输入 first, input order preserved
        b = correct(["苟牙根", "承兰"])
        @test names(b) == ["输入", "中文名", "拉丁学名", "科", "属", "分数"]
        @test DataFrames.nrow(b) == 2
        @test b[1, "输入"] == "苟牙根" && b[1, "中文名"] == "狗牙根"
        @test b[2, "输入"] == "承兰" && b[2, "中文名"] == "春兰"
        # Empty elements skipped; empty vector and all-empty input give the six-column empty table
        @test DataFrames.nrow(correct(["", "  "])) == 0
        eb = correct(String[])
        @test DataFrames.nrow(eb) == 0
        @test names(eb) == ["输入", "中文名", "拉丁学名", "科", "属", "分数"]
        # A batch where nothing is recalled is also the six-column empty table
        nb = correct(["Cynodon", "Abies"])
        @test DataFrames.nrow(nb) == 0
        @test eltype.(eachcol(nb)) == [String, String, String, String, String, Float64]
        # Batch honours the dataset keyword
        @test correct(["苟牙根"]; dataset="plantae")[1, "中文名"] == "狗牙根"
        # Batch rows are exactly the single-name rows with 输入 prepended
        single = correct("苟牙根")
        one = correct(["苟牙根"])
        @test DataFrames.nrow(one) == DataFrames.nrow(single)
        @test one[!, "分数"] == single[!, "分数"]
        @test one[!, "中文名"] == single[!, "中文名"]
    finally
        # Always leave the module unloaded, even when an assertion above failed
        SP2000Accent.GLOBAL_INDEX[] = Index.SpeciesIndex()
        SP2000Accent.INDEX_DATASET[] = ""
        SP2000Accent.INDEX_LOADED[] = false
    end
end

@testset "Cache payload" begin
    table = SP2000Accent._WarmTable(Dict(
        "物种中文名" => ["狗牙根", "春兰"],
        "物种拉丁名" => ["Cynodon dactylon", "Cymbidium goeringii"],
        "科中文名" => ["禾本科", "兰科"],
        "属中文名" => ["狗牙根属", "兰属"]))
    idx = Index.SpeciesIndex()
    Index.build_index!(idx, table)
    d = SP2000Accent._dataset("plantae")
    payload = (index = idx, fingerprint = "fp-probe", data_version = "0.1.0", dataset = d.slug,
               fields = string(fieldnames(Index.SpeciesIndex)),
               cache_version = SP2000Accent.INDEX_CACHE_VERSION)
    dir = mktempdir()
    path = joinpath(dir, "species_index_probe.bin")
    SP2000Accent._cache_write(path, payload)

    # Hit: fingerprint and layout match, the index comes back intact
    got = SP2000Accent._cached(d, "fp-probe", path)
    @test got isa Index.SpeciesIndex
    @test got.names == idx.names && got.char_index == idx.char_index
    # Stale: another fingerprint (input or catalogue version changed) is rejected
    @test SP2000Accent._cached(d, "fp-other", path) === nothing
    # Another cache layout is rejected before it is used
    @test !SP2000Accent._cache_valid(merge(payload, (cache_version = "0",)), "fp-probe")
    @test !SP2000Accent._cache_valid("not a payload", "fp-probe")
    # Every field the payload is read through is checked: a missing one is stale, not a crash
    @test !SP2000Accent._cache_valid(Base.structdiff(payload, NamedTuple{(:data_version,)}), "fp-probe")
    @test !SP2000Accent._cache_valid(Base.structdiff(payload, NamedTuple{(:dataset,)}), "fp-probe")
    @test !SP2000Accent._cache_valid(merge(payload, (index = "not an index",)), "fp-probe")
    # No fingerprint (cache disabled) is a miss, not a MethodError
    @test !SP2000Accent._cache_valid(payload, nothing)
    # ... and through the file path such a payload rebuilds instead of throwing
    short = joinpath(dir, "species_index_short.bin")
    SP2000Accent._cache_write(short, Base.structdiff(payload, NamedTuple{(:data_version,)}))
    @test SP2000Accent._cached(d, "fp-probe", short) === nothing
    # Truncated file: unreadable, so the caller falls back to a rebuild
    write(path, read(path)[1:64])
    @test SP2000Accent._cached(d, "fp-probe", path) === nothing
    # A write that cannot open its target rethrows and leaves no temp file behind
    blocker = joinpath(dir, "blocker")
    write(blocker, "x")
    @test_throws Exception SP2000Accent._cache_write(joinpath(blocker, "x.bin"), payload)
    # A write that fails after the temp file exists (a Task cannot be serialised)
    # rethrows too, and the partial temp file is removed instead of left behind
    @test_throws Exception SP2000Accent._cache_write(joinpath(dir, "unserialisable.bin"), current_task())
    @test !isfile(joinpath(dir, "unserialisable.bin"))
    @test isempty(filter(f -> endswith(f, ".tmp"), readdir(dir)))
    rm(dir; force = true, recursive = true)
end

@testset "Catalogue version is readable" begin
    if !HAS_CATALOGUE
        @test_skip false        # stripped checkout: no catalogue to read
    else
        v = SP2000Accent._sp2000data_version()
        @test v !== nothing
        @test !isempty(v)
        # The version is part of the fingerprint: a new version forces a rebuild
        fp1 = SP2000Accent._index_fingerprint(version="0.1.0")
        fp2 = SP2000Accent._index_fingerprint(version="9.9.9")
        @test fp1 !== nothing
        @test fp1 != fp2
        # Hashing is streamed: the same inputs give the same digest twice
        @test SP2000Accent._index_fingerprint() == SP2000Accent._index_fingerprint()
    end
end

@testset "Dataset table" begin
    # Only correct is exported; index building and the list stay inside the module
    @test :correct in names(SP2000Accent)
    @test !(:load_index! in names(SP2000Accent))
    @test isdefined(SP2000Accent, :load_index!)
    @test isdefined(SP2000Accent, :dataset_names)
    @test !isdefined(SP2000Accent, :build_default_index!)
    # VERSION mirrors Project.toml: two places to edit, so make them agree
    @test occursin("version = \"$(SP2000Accent.VERSION)\"",
                   read(joinpath(@__DIR__, "..", "Project.toml"), String))
    # Five catalogues, in table order (English names)
    @test SP2000Accent.dataset_names() ==
          ["plantae", "chordata", "insecta", "invertebrates", "fungi"]
    # English names only, case- and whitespace-insensitive
    d = SP2000Accent._dataset("fungi")
    @test d.name == "真菌界"
    @test d.loader == :Fungi
    @test SP2000Accent._dataset(" Plantae ").name == "植物界"
    # Chinese names are no longer parameter values; typos raise instead of falling back
    @test_throws ErrorException SP2000Accent._dataset("真菌界")
    @test_throws ErrorException SP2000Accent._dataset("animalia")
    # One cache file per dataset, no overwriting
    @test endswith(SP2000Accent._cache_file(d), "species_index_fungi.bin")
    @test SP2000Accent._cache_file(d) != SP2000Accent._cache_file(SP2000Accent._dataset("plantae"))
    # The dataset is part of the fingerprint: another catalogue means another fingerprint
    if HAS_CATALOGUE
        @test SP2000Accent._index_fingerprint(d) != SP2000Accent._index_fingerprint(SP2000Accent._dataset("plantae"))
    else
        @test_skip false    # stripped checkout: the xlsx files are needed to hash
    end
end

@testset "Index hygiene and qualifiers" begin
    # Table with a missing name, a duplicate, and a bracketed qualifier.
    tbl = _MixedTable(Dict(
        "物种中文名" => Union{String,Missing}["狗牙根", missing, "狗牙根", "月季(原变种)"],
        "物种拉丁名" => Union{String,Missing}["Cynodon dactylon", "X y", "Cynodon dactylon var.", "Rosa chinensis var."],
        "科中文名" => Union{String,Missing}["禾本科", "X科", "禾本科", "蔷薇科"],
        "属中文名" => Union{String,Missing}["狗牙根属", "X属", "狗牙根属", "蔷薇属"]))
    idx = Index.SpeciesIndex()
    Index.build_index!(idx, tbl)
    @test idx.names == ["狗牙根", "月季(原变种)"]          # missing skipped, duplicate dropped
    @test !haskey(idx.char_index, '(')                      # punctuation not indexed
    @test isempty(Index.search_candidates(idx, "("))

    # A trailing qualifier must not depress the score, and ties go to the bare name.
    @test Matcher.calc_score("穿龙属寓", "穿龙薯蓣") ≈ Matcher.calc_score("穿龙属寓", "穿龙薯蓣(原变种)")
    ranked = Matcher.rank_candidates("苟牙根", [("狗牙根(原变种)", "s1", "f1", "g1"),
                                                ("狗牙根", "s2", "f2", "g2")])
    @test ranked[1][2] == "狗牙根"
end

@testset "Flat Han table and shared readings" begin
    # The flat BMP table must agree with the Dict for every character; the 216
    # characters above the BMP fall through to the Dict. A local function keeps
    # the scan cheap: a closure over module globals at testset scope is not
    # specialised and this 26 289-character pass then takes ~0.12 s instead of
    # ~1 ms.
    same_membership(c) = Pinyin.is_han_char(c) == haskey(Pinyin.PINYIN_MAP, c)
    @test all(same_membership, keys(Pinyin.PINYIN_MAP))
    # Every character with a default reading also has a readings vector in the
    # generated table, so the recall / coarse-ranking fallback in `readings_of`
    # (a default-reading vector) is defensive rather than load-bearing.
    has_readings(c) = haskey(Pinyin.PINYIN_ALL, c)
    @test all(has_readings, keys(Pinyin.PINYIN_MAP))
    @test Pinyin.is_han_char('𪍸')      # above the BMP, in the table
    @test !Pinyin.is_han_char('\U10fffd')   # above the BMP, not in the table
    @test !Pinyin.is_han_char('(') && !Pinyin.is_han_char('A') && !Pinyin.is_han_char('（')
    @test Pinyin.is_han_char('〇')       # first entry of the generated table
    # readings_of is the one fallback both layers use, and it hands out a shared
    # empty vector so a non-Han character costs no allocation.
    @test Pinyin.readings_of('行') == Pinyin.char_all_readings('行')
    @test isempty(Pinyin.readings_of('A'))
    @test Pinyin.readings_of('A') === Pinyin.readings_of('B')
    @test Pinyin.char_all_readings("abc") === Pinyin.char_all_readings('A')
end

@testset "Coarse key memo" begin
    # The per-query reading memo must reproduce a direct computation exactly:
    # characters shared with the query plus distinct readings its variants hit.
    function naive(prep, name)
        shared = count(c -> c in prep.chars, name)
        seen = String[]
        for c in name, r in Pinyin.readings_of(c)
            (r in prep.syls && !(r in seen)) && push!(seen, r)
        end
        return shared + length(seen)
    end
    for q in ("苟牙根", "春兰")
        prep = Matcher._coarse_query(q)
        for name in ("狗牙根", "狗牙蕓", "春兰", "牛鞭草", "月季(原变种)",
                     "香附子", "金鸡角假瘤蕨")
            @test Matcher._coarse_key(prep, name) == naive(prep, name)  # builds the memo
            @test Matcher._coarse_key(prep, name) == naive(prep, name)  # memo hit
        end
        # A query prep owns its memo: a second query cannot see the first's hits
        @test Matcher._coarse_query(q).hits !== prep.hits
        @test isempty(Matcher._coarse_query(q).hits)
    end
end

@testset "Qualifier fast path and tie order" begin
    @test Matcher._is_bare_name("狗牙根")
    @test !Matcher._is_bare_name("月季(原变种)")
    @test !Matcher._is_bare_name("月季（原变种）")        # full width
    @test Matcher._is_bare_name("月季(原变种)x")          # bracket, but no trailing qualifier
    @test Matcher.calc_score("穿龙属寓", "穿龙薯蓣（原变种）") ≈
          Matcher.calc_score("穿龙属寓", "穿龙薯蓣")
    # Equal scores: bare name first, then recall order (the sort is stable)
    ranked = Matcher.rank_candidates("苟牙根", [("狗牙根", "s1", "f1", "g1"),
                                                ("狗牙根(原变种)", "s2", "f2", "g2"),
                                                ("狗牙根", "s3", "f3", "g3")])
    @test [r[3] for r in ranked] == ["s1", "s3", "s2"]   # r: score, name, sci, family, genus
end

end
