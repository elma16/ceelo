# ceelo

A realtime speech to soundboard for macOS.

## Installation

Requires macOS 14+ and Xcode or the Swift command line tools.

First clone the repo,

```sh
git clone https://github.com/elma16/ceelo.git
```

compile ceelo,

```sh
cd ceelo
swift build -c release
```

add the sounds you want (each file's name is the phrase that plays it, so `airhorn.mp3` plays when you say
"airhorn"; optionally add `sounds/rules.json` to choose other phrases, see **RULES FILE**),

```sh
mkdir -p sounds && cp ~/Downloads/airhorn.mp3 sounds/
```

check what each sound responds to,

```sh
.build/release/ceelo --check-rules
```

and now you can run ceelo!

```sh
.build/release/ceelo
```

The first run downloads the speech models (about 450 MB), and macOS asks for microphone access for your terminal
app; see **PERMISSIONS** if it was refused.

## Synopsis

```
ceelo [--sounds-dir DIR] [--rules FILE] [--live-window SEC] [--live-update SEC] [-q]
ceelo --check-rules [--sounds-dir DIR] [--rules FILE]
ceelo --test TEXT [--sounds-dir DIR] [--rules FILE]
ceelo -h
```

## Description

**ceelo** is a speech-triggered soundboard for macOS. It listens to the microphone, transcribes speech on-device
with [FluidAudio's CoreML conversion of NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)
on the Apple Neural Engine, and plays a sound
whenever its phrase is said.

How it listens:

- Every `--live-update` seconds, the last `--live-window` seconds of audio are transcribed, but only if the Silero
  voice detector hears speech in them.
- Each spoken phrase plays its sound once, even though overlapping windows hear it several times.
- The microphone is ignored while a sound plays, plus 0.4 s, so sounds cannot trigger themselves.

Each sound in the sounds directory is triggered by its file name (`soft_bell.mp3` by "soft bell") unless a rules
file says otherwise. The live transcript prints each word once, with a line break when speech pauses.

## Flags

`--sounds-dir DIR`
: Directory of sounds (`mp3`, `wav`, `m4a`, `aiff`, `aac`, `caf`). Default `./sounds`.

`--rules FILE`
: Rules file; see **RULES FILE**. Default `rules.json` in the sounds directory, if it exists.

`--live-window SEC`
: Seconds of audio per transcription. Longer phrases need a longer window. Default 2.0, minimum 0.5.

`--live-update SEC`
: Seconds between transcriptions. Shorter fires sooner but uses more Neural Engine time. Default 0.15,
  minimum 0.1.

`-q`, `--quiet`
: Don't print the live transcript.

`--check-rules`
: Check the sounds and rules, list what each sound responds to, and exit.

`--test TEXT`
: Show which sounds TEXT would play, as if it had been said, and exit. Needs no microphone or models.

`-h`, `--help`
: Print usage and exit.

## The rules file

A JSON file that sets what each sound responds to. Sounds it doesn't mention keep their file name as the phrase.

```json
{
  "defaults": { "match": "words", "within": 8 },
  "rules": [
    { "sound": "chime", "say": ["new ticket"], "after": ["heads up"], "within": 10 },
    { "sound": "airhorn.mp3", "say": ["epic"], "match": "contains" },
    { "sound": "yoda", "say": ["yoda"], "match": "fuzzy" },
    { "sound": "extra/horn.wav", "say": ["fifteen", "or is it"] },
    { "sound": "pm", "say": [] }
  ]
}
```

| Key | Meaning |
|---|---|
| `sound` | File name, with or without extension, or a path relative to the sounds directory. Required. |
| `say` | Phrases that play the sound. Required; `[]` switches the sound off. |
| `match` | How phrases are compared (below). Default `words`. |
| `after` | Phrases that must be said first: earlier in the same breath, or up to `within` seconds before. |
| `within` | Seconds an `after` phrase stays valid. Default 8. |

`defaults` sets `match` and `within` for every rule.

Before comparing, both phrases and speech are lowercased and stripped of punctuation and symbols. Number words
below 100 become digits, so "fifteen", "15" and "£15" all match.

The `match` values:

- `words`: whole words in order. Words of 8+ letters may differ by one letter, which covers British and American
  spellings ("favourite" matches the model's "favorite").
- `fuzzy`: whole words, more forgiving. Words of 4+ letters may differ by one letter, and 7+ letters by two, for
  names the model misspells ("yoda" matches "Yuda").
- `contains`: anywhere, including inside words ("epic" matches "epically").

Unknown keys and other mistakes are errors. `ceelo --check-rules` lists them all, and `ceelo --test` tries
sentences.

## Exit status messages

- **0**: success.
- **1**: the speech models failed to load, or the microphone is unavailable.
- **2**: usage error, missing sounds, or invalid rules.


## Permissions

macOS asks for **Microphone** access on behalf of the app running ceelo (Terminal, Visual Studio Code, …). If it
was refused, allow it in **System Settings → Privacy & Security → Microphone** and restart that app.

## Example usage

```sh
.build/release/ceelo --test "i remember when"   # which sounds would this sentence play?
.build/release/ceelo --sounds-dir ~/sfx --rules ~/sfx/party.json
.build/release/ceelo --live-update 0.1 -q                      # react faster, hide the transcript
```

## See also

[FluidAudio](https://github.com/FluidInference/FluidAudio),
[Parakeet TDT 0.6B v2 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)
