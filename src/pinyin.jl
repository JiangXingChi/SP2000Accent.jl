"""
    Pinyin — pure-Julia pinyin conversion for Chinese characters

Table lookup only, no external dependencies. The mapping data is generated
once from pypinyin and bundled with the package.

# Main functions
- `get_pinyin(text)` — toneless pinyin, syllables separated by spaces
- `get_initials(text)` — initial letters of each syllable
- `char_to_pinyin(c)` — default reading of one character
- `char_all_readings(c)` — every reading of one character (recall and scoring
  use this, so a polyphone is not reduced to its default reading)
- `readings_of(c)` — `char_all_readings` with the default-reading fallback,
  shared by the recall and the scoring layers
- `is_han_char(c)` — whether the character is in the table (flat table over the
  BMP, so counting the Han characters of a name costs a few nanoseconds each)
"""
module Pinyin

include("pinyin_data.jl")

# Toneless pinyin, space separated.
function get_pinyin(text::AbstractString)::String
    parts = String[]
    for c in text
        py = char_to_pinyin(c)
        if py !== nothing
            push!(parts, py)
        end
    end
    return join(parts, " ")
end

# Initial letters of the reading of each character.
function get_initials(text::AbstractString)::String
    chars = Char[]
    for c in text
        py = char_to_pinyin(c)
        if py !== nothing && !isempty(py)
            push!(chars, first(py))
        end
    end
    return String(chars)
end

# Default reading of one character.
function char_to_pinyin(c::Char)::Union{String, Nothing}
    return get(PINYIN_MAP, c, nothing)
end

# All readings of one character.
# A shared empty vector is returned for unknown characters: the default value
# of `get` would allocate on every call, and the scoring DP calls this once
# per cell. Callers must treat the result as read-only (they all check
# `isempty` first).
const _EMPTY_READINGS = String[]
function char_all_readings(c::Char)::Vector{String}
    return get(PINYIN_ALL, c, _EMPTY_READINGS)
end

function char_all_readings(s::AbstractString)::Vector{String}
    if length(s) == 1
        return char_all_readings(s[1])
    end
    return _EMPTY_READINGS   # shared, like the unknown-character branch above
end

"""
    readings_of(c) -> Vector{String}

Readings of one character with the default-reading fallback: every reading when
the table has them, otherwise the one default reading, otherwise a shared empty
vector. Recall and scoring both need this fallback, so it lives here once. The
result is read-only.
"""
function readings_of(c::Char)::Vector{String}
    rs = get(PINYIN_ALL, c, _EMPTY_READINGS)
    isempty(rs) || return rs
    d = char_to_pinyin(c)
    return d === nothing ? _EMPTY_READINGS : String[d]
end

# Membership table for the BMP, built once at load from PINYIN_MAP. `haskey` on
# the 26 289-entry Dict costs ~0.1 µs per character and is paid for every
# character of every candidate name when the coarse ranking counts Han
# characters; a flat table costs a few nanoseconds. The 216 characters above
# the BMP fall back to the Dict, so membership is exactly the Dict's.
const _BMP_SIZE = 0x10000
const _HAN_BMP = let t = fill(false, _BMP_SIZE)
    for c in keys(PINYIN_MAP)
        Int(c) < _BMP_SIZE && (t[Int(c) + 1] = true)
    end
    t
end

# True when the character is in the pinyin table (i.e. is a Han character).
function is_han_char(c::Char)::Bool
    i = Int(c)
    i < _BMP_SIZE || return haskey(PINYIN_MAP, c)
    return @inbounds _HAN_BMP[i + 1]
end

export get_pinyin, get_initials, char_to_pinyin, is_han_char,
       char_all_readings, readings_of

end # module
