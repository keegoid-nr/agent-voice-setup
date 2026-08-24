"""Public voice-design presets."""

from __future__ import annotations

_CONSISTENT_SPEAKER = (
    " Maintain one consistent speaker identity for the entire output: same timbre, "
    "pitch center, age, accent, microphone distance, and vocal texture from "
    "sentence to sentence. Emotional swings should change only cadence, pause "
    "length, intensity, and emphasis. Do not morph into a different voice, "
    "character, register, accent, or age between sentences."
)

_CHESAPEAKE_BALANCED = (
    "A warm adult male British baritone, friendly and steady, not too formal, "
    "like someone "
    "who's right there with you. Clear, reassuring, but never stiff."
)

_CHESAPEAKE_BALANCED_FEMALE = (
    "A warm adult female British contralto, friendly and steady, not too formal, "
    "like someone "
    "who's right there with you. Clear, reassuring, but never stiff."
)

_COOL_STREET_DEADPAN = (
    "A young woman voice actor with a mid-range tone and dry deadpan confidence. "
    "Street-smart, neon-lit back-alley cool under pressure. "
    "Not bubbly and no high-pitched or fast-paced genki."
    + _CONSISTENT_SPEAKER
)

VOICE_DESIGNS: dict[str, str] = {
    "chesapeake_balanced": _CHESAPEAKE_BALANCED,
    "chesapeake_balanced_female": _CHESAPEAKE_BALANCED_FEMALE,
    "cool_street_deadpan": _COOL_STREET_DEADPAN,
}
