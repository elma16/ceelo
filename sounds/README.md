# Soundboard rules (rules.json)

This document explains the `rules.json` format used by `parakeet_ptt` to map
transcript text to sound effects. When a rules file exists, only sounds listed
in `rules.json` can trigger; otherwise, each sound filename acts as a keyword.

## Where the rules file is loaded from
The app looks for a rules file in this order:
- `--rules /path/to/file.json` (explicit path, if provided)
- In the sounds directory: `rules.json`, `soundboard.json`, or `soundboard_rules.json`
- In the current working directory: same filenames as above

The sounds directory is resolved from `--sounds-dir`, or from `./sounds` /
`../sounds` relative to the working directory or the executable.

## File structure
Top-level:
- `global` (optional): default settings applied to every rule.
- `rules` (required): array of per-sound rules.

```json
{
  "global": {
    "default_cooldown_sec": 1.5,
    "setup_within_sec": 8,
    "start_word_max": 6,
    "serious_min_count": 1,
    "fuzzy_max_distance": 1
  },
  "rules": [
    {
      "sound": "airhorn.mp3",
      "trigger_substring_any": ["epic"]
    }
  ]
}
```

## Matching model (important)
All transcript text is normalized before matching:
- Lowercased
- Non-alphanumeric characters become spaces
- Repeated spaces are collapsed

Two matching styles are used:
- `*_any` fields match contiguous word sequences (token-based)
- `*_substring_any` fields match substring text in the normalized transcript

Fuzzy matching is only used for `serious_fuzzy_any` and compares words with a
max edit distance (`fuzzy_max_distance`).

## Global settings
All fields are optional. Defaults are shown in parentheses.
- `default_cooldown_sec` (1.5): minimum seconds between triggers for a rule.
- `setup_within_sec` (8): time window for setup -> trigger sequences.
- `start_word_max` (no limit): maximum word index where a trigger can start.
- `serious_min_count` (1): minimum number of serious matches required.
- `fuzzy_max_distance` (1): max edit distance per word for fuzzy matches.

## Per-rule settings
Each rule must include `sound` and at least one trigger or serious matcher.

- `sound` (required): filename in the sounds directory, or a relative path. The
  match is case-insensitive; you can also omit the extension (stem matching).
- `trigger_any`: list of phrases that must match as full word sequences.
- `trigger_substring_any`: list of phrases that match as substrings in the
  normalized transcript.
- `setup_any`: phrases that must appear before the trigger (either earlier in
  the same transcript or in a previous transcript within `within_sec`).
- `within_sec`: override for the setup -> trigger window (defaults to
  `setup_within_sec`).
- `cooldown_sec`: override for the rule cooldown (defaults to
  `default_cooldown_sec`).
- `start_word_max`: override for maximum allowed trigger start index.
- `serious_any`: phrases that count toward a "serious" match (exact, token-based).
- `serious_fuzzy_any`: phrases that count toward a "serious" match (fuzzy).
- `serious_min_count`: override for required number of serious hits.
- `fuzzy_max_distance`: override for per-word fuzzy matching distance.

### Trigger vs serious logic
- If a rule has only triggers, any trigger match fires the sound.
- If a rule has only serious matchers, a serious match fires the sound.
- If a rule has both, the trigger and serious conditions must both match.

## Examples
### Simple substring trigger
```json
{
  "sound": "wow.mp3",
  "trigger_substring_any": ["wow"],
  "cooldown_sec": 2
}
```

### Setup -> trigger chain
```json
{
  "sound": "john.mp3",
  "setup_any": ["my favorite son"],
  "trigger_any": ["and his name is john cena"],
  "within_sec": 10
}
```

### Serious-topic gate with fuzzy matching
```json
{
  "sound": "fart.mp3",
  "serious_fuzzy_any": ["diagnosis", "funeral", "laid off"],
  "serious_min_count": 1,
  "fuzzy_max_distance": 1,
  "cooldown_sec": 2
}
```

## Common pitfalls
- If a rules file exists, new sounds will not trigger until you add a rule.
- A rule with neither triggers nor serious matchers is skipped.
- `start_word_max` counts the word index of the trigger start (0-based).
- `setup_any` must appear before the trigger or within the time window.
