# Developing ceelo

## Layout

| File | Contents |
|---|---|
| `Sources/ceelo/main.swift` | Entry point. |
| `Sources/CeeloCore/CLI.swift` | Options, `--check-rules`, `--test`, wiring, and `CeeloEnvironment`, the swappable system dependencies. |
| `Sources/CeeloCore/Rules.swift` | Rules file parsing and validation, file-name rules, `RuleEngine`. |
| `Sources/CeeloCore/Text.swift` | Normalisation (including number words), edit distance, phrase matching. |
| `Sources/CeeloCore/Soundboard.swift` | Timing, `SoundboardPipeline` (window → voice detector → ASR → rules), live microphone loop. |
| `Sources/CeeloCore/Speech.swift` | FluidAudio transcriber, voice detector and model loading. |
| `Sources/CeeloCore/Audio.swift` | Microphone capture and resampling, rolling buffer, live word tracker. |
| `Sources/CeeloCore/SoundPlayer.swift` | Preloaded sound playback. |
| `Sources/ceelo-bench` | Benchmarks. |

The only dependency is FluidAudio, pinned to 0.10.x.

## Tests

```sh
swift test
scripts/coverage.sh --min 90    # tests plus line coverage for Sources/CeeloCore
```

Tests swap the microphone, sound output and models for fakes through `CeeloEnvironment`, so they never record.
Integration tests run the real Parakeet and Silero models when they are downloaded and skip otherwise, or when
`CEELO_SKIP_MODEL_TESTS=1` is set. CI (`.github/workflows/ci.yml`) runs on macOS without the models and requires
90% line coverage.

Not covered by design: starting the real microphone, and the run loop in `CeeloRunner.run`.

## Benchmarks

```sh
swift run -c release ceelo-bench [--iterations N] [--load-only]
swift run -c release ceelo-bench --long-run MINUTES
```

**Default run.** Measures:

- model load time;
- ASR latency by window length;
- voice detector cost and accuracy;
- a simulated soundboard run: trigger latency, double-fires and Neural Engine time for several settings;
- sound playback start time.

**`--long-run`.** Streams continuous speech through the pipeline and reports, per minute: tick time, memory,
triggers, and how many words the live transcript printed. Speech comes from `say`, written to a temporary
directory and deleted afterwards.

**Results on an M4.**

| Measure | Result |
|---|---|
| Model load (cached) | ~0.3 s |
| ASR per 2 s window | ~42 ms |
| Voice detector per window | ~1.5 ms |
| Trigger time at the default 0.15 s update | mean ~130 ms before the keyword ends, worst ~70 ms before |
| Neural Engine time at 0.15 s | ~13% |
| Tick time and memory over long runs | flat |
| Triggers | match spoken keywords exactly |
| Live transcript | ~1 printed word per spoken word |

## Design notes

**Sliding windows.** Every tick re-transcribes the whole window, so each word is heard about ten times.

- **Triggers.** A rule can't fire again for `SoundboardTiming.refireGuardSec` (window + 1 s). The model can
  recognise a word from a fragment at either edge of the window, so a guard of just the window length
  double-fired 3 times in 39.
- **Live transcript.** `LiveWordTracker` counts a word as printed when a printed word with the same text started
  within 0.5 s. Timestamps alone aren't enough, because the same word's timestamp drifts by up to ~0.3 s between
  windows.

**Playback.** The microphone buffer is cleared and ignored for the clip's length + 0.4 s, so a sound can't
trigger itself.

**Short audio.** FluidAudio rejects input under 1 s; `paddedForAsr` zero-pads it. The model pads every input to
15 s anyway, so this costs nothing.

**No model warm-up.** The first transcription after loading takes ~10 ms longer than later ones.

**Streaming ASR (evaluated, not adopted).** FluidAudio 0.10 has two streaming managers:

- `StreamingAsrManager` emits text only after 10–15 s chunks.
- `StreamingEouAsrManager` streams in 160 ms chunks, but uses a separate 120M English-only model with several
  times Parakeet's word error rate (5.7–9% vs ~1.7% on LibriSpeech test-clean).

Triggers already fire before the keyword ends, so neither is worth the trade.
