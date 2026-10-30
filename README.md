# SP2000Accent.jl

Catalogue-constrained candidate retrieval for Chinese species names that were
written down from dictation. Give it the name as heard (`苟牙根`), get back the
entries of the *Catalogue of Life China* it most likely stands for
(`狗牙根 — Cynodon dactylon — 禾本科 — 狗牙根属`), ranked.

Field vegetation surveys are often recorded by ear: an expert says a name, the
recorder writes what it sounds like, and homophones, near-homophones and dialect
sound correspondences produce names that are readable but wrong. This package
turns each suspicious name into a short candidate table so that clearing records
afterwards becomes a lookup instead of a search.

Everything runs offline. The catalogue ships with
[SP2000ChinaData.jl](https://github.com/JiangXingChi/SP2000ChinaData.jl).

## Install

```julia
using Pkg
Pkg.add("SP2000Accent")
```

Requires Julia 1.10 or newer. The first query downloads the catalogue package
(about 10 MB of xlsx) and builds an index (about 14 s); later sessions read a
cache in about 0.5 s.

## Quick start

```julia
using SP2000Accent

correct("苟牙根")                 # >=1 column DataFrame: name, scientific name, family, genus, score
correct("苟牙根"; top_n=3)        # at most 3 rows
correct("冬虫夏草"; dataset="fungi")

correct(["镜子苔草", "盲箕"])      # batch: one table, `输入` first
```

`correct` never edits the input and never picks a winner: it returns candidates
with a score, and the person reading the table decides.

## Catalogues

`dataset` selects the catalogue; the default is `"plantae"`.

| `dataset` | Catalogue | Searchable names |
|---|---|---|
| `"plantae"` | Plantae | 47,279 (47,474 rows) |
| `"chordata"` | Animalia: Chordata | 8,681 |
| `"insecta"` | Animalia: Insecta | 38,463 |
| `"invertebrates"` | Animalia: other invertebrates | 15,925 |
| `"fungi"` | Fungi | 11,601 (27,807 rows) |

Rows without a Chinese name are not searchable, and a repeated Chinese name is
kept once (first row wins), which is why the searchable count is lower than the
row count.

## How it works

Three recall routes run in parallel and are unioned:

1. **characters** — shared characters with the query;
2. **syllables** — the query's pinyin syllables plus one-step dialect
   confusions (32 directed edges: `zh↔z`, `n↔l`, `f↔h`, `an↔ang`, `in↔ing`, …)
   looked up in a syllable inverted index;
3. **initials** — the pinyin initials of the query.

The union is coarse-ranked and truncated to 5% of its own size (first-letter
hits are always kept), then every survivor is scored as

```
score = 0.5 × reading + 0.4 × literal + 0.1 × initials
```

where *reading* compares pinyin with a similarity floor of 0.95 for the
confusion pairs, *literal* compares characters, and *initials* compares first
letters. The weights come from a relative-importance triple (5/4/1), not from
numbers typed in by hand.

Parameters can be changed at run time:

```julia
SP2000Accent.set_pool_fraction!(0.5)   # 0.1 … 1.0
SP2000Accent.set_importance!(5, 4, 1)  # reading, literal, initials
SP2000Accent.set_confuse_sim!(0.90)    # floor for confusion pairs, 0 … 1
```

Change them only after re-running an evaluation. The defaults come from an
18,051-point sweep (11 pool fractions × 231 weight triples × 11 similarity
floors, plus an upper-bound check) on a 2,200-item synthetic set and a 14-item
real corpus:

- pool fraction 5% — every fraction from 5% to 90% gives the same scores, so
  the smallest one is taken; it halves the names that reach fine scoring
  (median 10.5 ms per query instead of 17.5 ms at 30%);
- weights 5/4/1 — real-corpus constraint and full Top-5 hold across a plateau,
  and this triple sits inside it;
- similarity floor 0.95 — 0.99 adds nothing, 0.90 and below lose 2–36 questions.

## Cache

The first query on a catalogue builds its index and writes
`cache/species_index_<slug>.bin` next to `src/`. The file is rebuilt
automatically when the catalogue version, the xlsx content, the pinyin table,
the index code or the Julia version change. Set `SP2000ACCENT_NO_CACHE=1` to
skip both reading and writing it. If the directory is not writable the index is
rebuilt in memory each session and everything still works.

`SP2000Accent.load_index!(dataset)` warms one catalogue up ahead of a loop; it is
idempotent and safe to call from several tasks.

## Scope

- Retrieval only: the output is a candidate table, not a determination. Whether
  a record should be corrected is a human decision.
- The engine checks whether a name *looks like* a name in the catalogue. It does
  not check whether the species could occur in the plot — a genus-level record
  and a choice between close relatives still need a person.
- Chinese names only; Latin names are not accepted as queries.

## Data and licence

- Catalogue data: *Catalogue of Life China* (2024), distributed by
  [SP2000ChinaData.jl](https://github.com/JiangXingChi/SP2000ChinaData.jl).
- `src/pinyin_data.jl` is generated from [pypinyin](https://github.com/mozillazg/python-pinyin)
  (MIT) and [PinYin.jl](https://github.com/JuliaZH/PinYin.jl) (MIT).
- The package itself is MIT licensed; see [LICENSE](LICENSE).
