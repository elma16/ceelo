# ceelo

Realtime speech-to-soundboard and push-to-talk dictation for macOS.
`parakeet_ptt` is the Swift STT backend used by ceelo.

## Requirements
- macOS with microphone access
- Accessibility permission for the app or Terminal (event tap)
- Xcode Command Line Tools / Swift toolchain
- Internet on first run to download ASR models

## Model & performance
ceelo uses the FluidInference Parakeet TDT 0.6B v2 CoreML model.
Model files are not committed; the backend downloads them on first run or you can fetch them manually.
Performance benchmarks and details:
https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml#performance

## Build
```sh
cd parakeet_ptt
swift build -c release
```

## Run (soundboard, default)
From the repo root:
```sh
./parakeet_ptt/.build/release/parakeet_ptt
```

## Sound assets
- Looks for files in `./sounds` (or `--sounds-dir PATH`)
- Audio assets are local and intentionally not tracked in git
- If no rules file is present, each filename becomes a keyword (partial matches are OK)
- If a `rules.json` (or `soundboard.json`) exists in the sounds dir, only the listed rules will trigger
- Defaults are tuned for low latency; you can tweak timing with flags

## Rules configuration (optional)
Create `sounds/rules.json` to define advanced matching like setup phrases, exact triggers, substring triggers, or fuzzy triggers.
If a rules file exists, you must add new sounds there for them to trigger.
Use `trigger_fuzzy_any` for near-miss matches; `fuzzy_max_distance` controls per-token edit distance (default 1).

Example:
```json
{
  "rules": [
    {
      "sound": "chime.wav",
      "setup_any": ["heads up", "attention"],
      "trigger_any": ["new ticket", "incoming message"],
      "within_sec": 10
    },
    {
      "sound": "soft_bell.wav",
      "trigger_fuzzy_any": ["favorite"],
      "fuzzy_max_distance": 1
    }
  ]
}
```

Run with:
```sh
./parakeet_ptt/.build/release/parakeet_ptt --rules sounds/rules.json
```

## Low-latency tuning
```sh
./parakeet_ptt/.build/release/parakeet_ptt --live-window 1.6 --live-update 0.25 --min-audio 0.3
```

## Pause mic during playback (optional)
Drop mic audio while sounds are playing to avoid feedback or re-triggering:
```sh
./parakeet_ptt/.build/release/parakeet_ptt --pause-during-playback
```

## Push-to-talk dictation
```sh
./parakeet_ptt/.build/release/parakeet_ptt --push-to-talk
```
- Hold Cmd+1 to record
- Release to transcribe and paste into the active app
- Live partial output prints while holding

## WAV transcription
```sh
./parakeet_ptt/.build/release/parakeet_ptt --wav /path/to/audio.wav
```

## Customize hotkey
Edit `holdKeyCode` and `holdRequiredModifiers` in `parakeet_ptt/Sources/main.swift`.
