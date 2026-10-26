"""
    SP2000Accent.jl

Check a Chinese plant name against the Catalogue of Life China and return the
scientific name it most likely stands for. The catalogue ships with
SP2000ChinaData; everything runs locally.

# Quick start
```julia
using SP2000Accent
correct("苟牙根")                        # Plantae, 5 rows; index built on first call
correct("苟牙根"; top_n=3)               # first 3 rows
correct("冬虫夏草"; dataset="fungi")      # other catalogues: chordata/insecta/invertebrates/fungi
correct(["镜子苔草", "盲箕"])             # batch: one table, 输入 column first
```

# File layout (one job per file)
| File | Responsibility |
|------|----------------|
| `pinyin.jl` / `pinyin_data.jl` | Pinyin submodule: conversion / data table (generated, do not edit) |
| `confusion.jl` | Confusion submodule: variant table, directed test, ablation API |
| `index.jl` | Index submodule: inverted indices, build, three-way recall |
| `matcher.jl` | Matcher submodule: distance primitives, three-term scoring, coarse ranking, ordering |
| `store.jl` | Main module: dataset table, index cache, input fingerprint, loading entry |
| `api.jl` | Main module: the single exit, correct() |
| `warmup.jl` | Main module: precompile warm-up |
"""
module SP2000Accent

# Declared before the includes so every included file sees the package version
# rather than Base.VERSION (this binding shadows it inside the module; store.jl
# therefore spells out Base.VERSION for the Julia version in the fingerprint).
const VERSION = v"0.3.0"   # keep in sync with Project.toml

include("pinyin.jl")
include("confusion.jl")
include("index.jl")
include("matcher.jl")

using .Pinyin
using .Confusion
using .Index
using .Matcher

import DataFrames
using Serialization
using SHA
using Printf

# ---- Main module surface (one namespace, split by responsibility; include order = dependency order) ----
include("store.jl")    # dataset table, cache, fingerprint, loading entry
include("api.jl")      # exit: correct()
include("warmup.jl")   # precompile warm-up, must come last

export correct

end # module
