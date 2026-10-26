# ============================================================
# Index cache and loading entry point
# ============================================================
# One job: the dataset table, cache file location and IO, the input fingerprint
# (including the catalogue package version), and the global index lifetime.
# The query entry point is in api.jl.

const INDEX_CACHE_VERSION = "5"   # 5: no unnamed/duplicate rows, non-Han chars not indexed

# ------------------------------------------------------------
# Dataset table
# ------------------------------------------------------------
# SP2000ChinaData ships five catalogues with identical columns
# (species Chinese name / scientific name / family / genus).
# To add a dataset, add one row here: Chinese name, English slug (also the
# cache suffix), loader function, file name.

struct _Dataset
    name::String      # Chinese name, used in messages
    slug::String      # English name, the public parameter value and cache suffix
    loader::Symbol    # loader function in SP2000ChinaData
    file::String      # catalogue xlsx file name
end

const DATASETS = [
    _Dataset("植物界",         "plantae",       :Plantae,                   "植物界-2024-47474.xlsx"),
    _Dataset("脊索动物门",     "chordata",      :AnimaliaChordata,          "动物界-脊索动物门-2024-10486.xlsx"),
    _Dataset("昆虫纲",         "insecta",       :AnimaliaInsecta,           "动物界-昆虫纲-2024-45664.xlsx"),
    _Dataset("其他无脊椎动物", "invertebrates", :AnimaliaOtherInvertebrates, "动物界-其他无脊椎动物-2024-17712.xlsx"),
    _Dataset("真菌界",         "fungi",         :Fungi,                     "真菌界-2024-27807.xlsx"),
]

"""
    dataset_names() -> Vector{String}

Available dataset names in table order:
`["plantae", "chordata", "insecta", "invertebrates", "fungi"]`.
What each one contains is documented in [`correct`](@ref).
"""
dataset_names() = [d.slug for d in DATASETS]

"Look up a dataset by English name (case- and whitespace-insensitive); unknown names list the options."
function _dataset(key::AbstractString)::_Dataset
    k = lowercase(strip(key))
    for d in DATASETS
        k == d.slug && return d
    end
    error("未知数据集「$(strip(key))」；可选：$(join(["$(d.slug)（$(d.name)）" for d in DATASETS], "、"))")
end

_cache_file(d::_Dataset) = joinpath(@__DIR__, "..", "cache", "species_index_$(d.slug).bin")

# These three refs are one piece of state and are only written together, under
# _LOAD_LOCK (see _current_index), index first and the INDEX_LOADED latch last.
# The query path reads them under the same lock, so it never observes a slug
# paired with another dataset's index. Direct readers outside the lock (scripts/
# do `load_index!(ds); GLOBAL_INDEX[]`) are single-threaded and read after
# load_index! has returned, i.e. after activation finished.
const GLOBAL_INDEX = Ref{Index.SpeciesIndex}(Index.SpeciesIndex())
const INDEX_LOADED = Ref(false)
const INDEX_DATASET = Ref("")   # slug of the dataset currently loaded

# Guards check-then-act in _current_index: two concurrent first queries on the
# same dataset must build the index once, not twice.
const _LOAD_LOCK = ReentrantLock()

# Lazy-load latch: SP2000ChinaData (and the XLSX parsing chain) is imported only
# on a cache miss, so the cache-hit startup path does not pay for it.
const _DATA_DEPS_LOADED = Ref(false)

# Cache IO. `_cache_read` deserialises straight from the stream: the payload is
# untyped at the call site, so this path is not specialised for SpeciesIndex.

_cache_read(path::AbstractString) = open(deserialize, path)

"""
The temp file is removed when the write fails, so no half-written cache is left
behind. Its name carries the pid: two processes cold-starting the same dataset
would otherwise share one `.tmp`, truncate each other's bytes and make the
`mv` fail (or rename a half-written file into place).
"""
function _cache_write(path::AbstractString, payload)
    tmp = string(path, '.', getpid(), ".tmp")
    try
        open(io -> serialize(io, payload), tmp, "w")
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    return nothing
end

"True when the cache is disabled for this process (CAOMU_NO_CACHE is the pre-rename alias)."
_no_cache() = get(ENV, "SP2000ACCENT_NO_CACHE", get(ENV, "CAOMU_NO_CACHE", "")) == "1"

# ------------------------------------------------------------
# Catalogue package location, version and fingerprint
# ------------------------------------------------------------

"Directory of the SP2000ChinaData package, located without loading it."
function _sp2000data_dir()::Union{String, Nothing}
    pk = Base.identify_package(@__MODULE__, "SP2000ChinaData")
    pk === nothing && return nothing
    src = Base.locate_package(pk)
    src === nothing && return nothing
    return normpath(joinpath(dirname(src), ".."))
end

"Path of the catalogue xlsx for one dataset; nothing when it cannot be located."
function _dataset_xlsx(d::_Dataset)::Union{String, Nothing}
    dir = _sp2000data_dir()
    dir === nothing && return nothing
    p = joinpath(dir, "data", d.file)
    return isfile(p) ? p : nothing
end

"""
    _sp2000data_version() -> Union{String, Nothing}

Version line of the package's Project.toml, read without loading the package.
Returns nothing when unavailable.
"""
function _sp2000data_version()::Union{String, Nothing}
    dir = _sp2000data_dir()
    dir === nothing && return nothing
    proj = joinpath(dir, "Project.toml")
    isfile(proj) || return nothing
    for line in eachline(proj)
        # Exact key: a bare startswith("version") would also accept
        # `version_something = ...` and return the wrong value.
        m = match(r"^version\s*=\s*\"([^\"]*)\"", strip(line))
        m === nothing && continue
        return m.captures[1]
    end
    return nothing
end

# SHA-256 input is fed in 1 MiB chunks: no whole-file copy, no second buffer
# holding every input at once (the plantae xlsx alone is 3.4 MB).
const _HASH_CHUNK = 1 << 20

"Feed one file's bytes into the SHA context."
function _sha_file!(ctx, path::AbstractString)
    open(path, "r") do io
        buf = Vector{UInt8}(undef, _HASH_CHUNK)
        while !eof(io)
            n = readbytes!(io, buf)
            n == 0 && break
            SHA.update!(ctx, view(buf, 1:n), n)
        end
    end
    return ctx
end

"Feed a marker string to the SHA context without copying it (`update!` takes bytes)."
_sha_text!(ctx, s::AbstractString) = (SHA.update!(ctx, codeunits(s)); ctx)

"""
    _index_fingerprint(d=DATASETS[1]; version=nothing) -> Union{String, Nothing}

SHA-256 over everything the index is built from: dataset name, pinyin logic
(pinyin.jl), pinyin table (pinyin_data.jl), index builder (index.jl), the
dataset's xlsx content, the SP2000ChinaData version and the Julia version.
Each input is hashed together with its path and byte length, so a moved
checkout or a truncated file also forces a rebuild.
Any change forces a rebuild; nothing is read or written when an input is
missing. Query-time code (matcher.jl, confusion.jl) is not part of the
fingerprint — the cache holds the index only, never scores.
"""
function _index_fingerprint(d::_Dataset=DATASETS[1]; version::Union{String, Nothing}=nothing)::Union{String, Nothing}
    xlsx = _dataset_xlsx(d)
    xlsx === nothing && return nothing
    files = [joinpath(@__DIR__, "pinyin.jl"),
             joinpath(@__DIR__, "pinyin_data.jl"),
             joinpath(@__DIR__, "index.jl"),
             xlsx]
    any(!isfile, files) && return nothing

    ctx = SHA.SHA256_CTX()
    for f in files
        # Path and length are part of the digest, so two files cannot be swapped
        # or truncated and still hash the same.
        _sha_text!(ctx, string("<<", f, ':', filesize(f), ">>"))
        _sha_file!(ctx, f)
    end
    ver = something(version === nothing ? _sp2000data_version() : version, "unknown")
    _sha_text!(ctx, string("<<dataset:", d.name, ">>"))
    _sha_text!(ctx, string("<<version:", ver, ">>"))
    _sha_text!(ctx, string("<<julia:", Base.VERSION, ">>"))
    return bytes2hex(SHA.digest!(ctx))
end

# ------------------------------------------------------------
# Loading entry point
# ------------------------------------------------------------

"""
    load_index!(dataset="plantae")

Build (or read from cache) the index for one dataset and make it current.
`correct` loads the index through this same path on first use, so manual calls
are only needed to warm up or to fix when the index is built relative to a
batch loop.

# Argument
- `dataset::AbstractString="plantae"`: same values as `correct`'s `dataset` —
  `"plantae"` Plantae (default), `"chordata"` Chordata, `"insecta"` Insecta,
  `"invertebrates"` other invertebrates, `"fungi"` Fungi. English names only;
  case- and whitespace-insensitive.

# Behaviour
- Same dataset already loaded: returns immediately (idempotent).
- Different dataset: reads its cache file; builds it on first use (about 14 s)
  and writes `cache/species_index_<slug>.bin` in the package directory.
- Touches the in-process global index only; no catalogue or parameter is changed.
- Concurrent calls are serialised: two tasks asking for the same unloaded
  dataset build it once, and a query runs against the dataset it asked for even
  if another task switches datasets meanwhile.

# Errors
Unknown `dataset` raises `ErrorException` listing all five values with their
Chinese names.

# Example
```julia
SP2000Accent.load_index!("fungi")             # warm up the fungi catalogue
correct("冬虫夏草"; dataset="fungi")           # later queries only read the cache
```
"""
function load_index!(dataset::AbstractString="plantae")
    _current_index(_dataset(dataset))
    return nothing
end

"""
    _current_index(d) -> Index.SpeciesIndex

The index for `d`, loaded (cache or rebuild) when it is not already current.
Check and activation happen under `_LOAD_LOCK`, and the index is returned from
inside the lock, so the index handed to a query always belongs to `d` even when
another thread switches datasets at the same moment.
"""
function _current_index(d::_Dataset)::Index.SpeciesIndex
    return lock(_LOAD_LOCK) do
        (INDEX_LOADED[] && INDEX_DATASET[] == d.slug) || _activate!(_load(d), d)
        GLOBAL_INDEX[]
    end
end

"Fetch the index: from cache when valid, otherwise rebuild (which needs the catalogue package, behind an invokelatest barrier)."
function _load(d::_Dataset)
    fp = _no_cache() ? nothing : _index_fingerprint(d)
    if fp !== nothing
        idx = _cached(d, fp)
        idx === nothing || return idx
    end
    _ensure_data!()
    return Base.invokelatest(_rebuild!, fp, d)
end

"""
    _cache_valid(obj, fp) -> Bool

Is this payload the index built from fingerprint `fp` by this layout of the code?
`fp` is untyped so a caller without a fingerprint (`nothing`, e.g. a disabled
cache) gets `false` instead of a MethodError, and every field the payload is
read through later is checked here: a payload that is missing one is stale, not
a crash in `_cached`.
"""
function _cache_valid(obj, fp)::Bool
    return fp isa String && obj isa NamedTuple &&
           haskey(obj, :cache_version) && haskey(obj, :fingerprint) && haskey(obj, :fields) &&
           haskey(obj, :index) && haskey(obj, :data_version) && haskey(obj, :dataset) &&
           obj.cache_version == INDEX_CACHE_VERSION &&
           obj.fingerprint == fp &&
           obj.fields == string(fieldnames(Index.SpeciesIndex)) &&
           typeof(obj.index) === Index.SpeciesIndex
end

"""
    _cached(d, fp, file=_cache_file(d)) -> Union{Index.SpeciesIndex, Nothing}

Read and validate the cache; returns nothing when unreadable, stale or of
another layout. `file` is a parameter so the validation paths can be tested
against a temporary file instead of the real cache.
"""
function _cached(d::_Dataset, fp::String, file::AbstractString=_cache_file(d))
    isfile(file) || return nothing
    t0 = time()
    obj = try
        _cache_read(file)
    catch e
        println("索引缓存不可读（$(typeof(e))），重建中...")
        return nothing
    end
    if !_cache_valid(obj, fp)
        println("索引缓存过期（原料或名录版本已变），重建中...")
        return nothing
    end
    println("索引缓存命中：$(d.name) $(length(obj.index.names)) 种，名录 v$(obj.data_version)（用时 $(@sprintf("%.1f", time() - t0)) 秒）")
    return obj.index
end

"Install the index globally and remember which dataset it belongs to. Caller holds _LOAD_LOCK (the precompile warm-up and the tests are single-threaded and call it directly)."
function _activate!(idx::Index.SpeciesIndex, d::_Dataset)
    GLOBAL_INDEX[] = idx
    INDEX_DATASET[] = d.slug
    INDEX_LOADED[] = true
end

"Import SP2000ChinaData (and the XLSX chain) on the first rebuild only."
function _ensure_data!()
    _DATA_DEPS_LOADED[] && return nothing
    @eval SP2000Accent import SP2000ChinaData
    _DATA_DEPS_LOADED[] = true
    return nothing
end

"Load the catalogue, build the index, write the cache, return the index (called through invokelatest)."
function _rebuild!(fp, d::_Dataset)
    ver = something(_sp2000data_version(), "unknown")
    println("正在加载中国生物物种名录（$(d.name)，v$ver）...")
    df = getfield(SP2000ChinaData, d.loader)()
    println("已加载 $(size(df, 1)) 条记录，正在构建索引...")
    idx = Index.SpeciesIndex()
    Index.build_index!(idx, df)
    println("索引构建完成：$(d.name) $(length(idx.names)) 个物种")
    fp === nothing && return idx
    try
        mkpath(dirname(_cache_file(d)))
        Base.invokelatest(_cache_write, _cache_file(d),
                          (index = idx, fingerprint = fp, data_version = ver, dataset = d.slug,
                           fields = string(fieldnames(Index.SpeciesIndex)),
                           cache_version = INDEX_CACHE_VERSION))
    catch e
        println("索引缓存写入失败（$e），不影响本次运行")
    end
    return idx
end
