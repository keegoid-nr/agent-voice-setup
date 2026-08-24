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
    "An adult Black American man in his late thirties with a natural mid-baritone "
    "voice. Mostly General American speech with a subtle central Maryland, "
    "Baltimore-Washington corridor influence: relaxed vowels and consonants, never "
    "an exaggerated regional accent. Calm, affirming, warm, and emotionally "
    "grounded. Medium-slow conversational pace, gentle downward sentence endings, "
    "clean soft-edged diction, and an easy half-smile. Add a small touch of "
    "endearingly earnest, mildly dorky friendliness, as if he is naturally "
    "supportive and does not mind sounding a little uncool. Close, clean studio "
    "sound. Avoid caricature, slang performance, announcer polish, dramatic bass, "
    "therapy-session affect, whispering, breathiness, gravel, forced cheerfulness, "
    "or theatrical comedy."
    + _CONSISTENT_SPEAKER
)

_COOL_STREET_DEADPAN = (
    "A young woman voice actor with a mid-range tone and dry deadpan confidence. "
    "Street-smart, neon-lit back-alley cool under pressure. "
    "Not bubbly and no high-pitched or fast-paced genki."
    + _CONSISTENT_SPEAKER
)

VOICE_DESIGNS: dict[str, str] = {
    "chesapeake_balanced": _CHESAPEAKE_BALANCED,
    "cool_street_deadpan": _COOL_STREET_DEADPAN,
}
