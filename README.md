<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="TellWell icon">
</p>

<h1 align="center">TellWell</h1>

<p align="center">
  Private dictation for your Mac. Hold a key, speak, and clean text appears wherever you're typing.
</p>

<p align="center">
  <a href="https://ayushpatnaikgit.github.io/tellwell/">Website</a> ·
  <a href="https://github.com/ayushpatnaikgit/tellwell/releases/download/v0.1.0/TellWell.dmg"><b>Download TellWell.dmg (0.1.0, pre-release)</b></a>
</p>

---

TellWell is a fork of [FreeFlow](https://github.com/zachlatta/freeflow) by Zach Latta, the free and open-source
Mac dictation app. It keeps everything FreeFlow does and adds a focus on running entirely on your own Mac: speech
recognition on the Apple Neural Engine and a small cleanup model fine-tuned for dictation, through the
[freeflow-local](https://github.com/ayushpatnaikgit/freeflow-local) engine.

**Status: early.** The 0.1.0 pre-release isn't signed with an Apple Developer ID yet: after the first launch,
allow it in System Settings → Privacy & Security → Open Anyway. TellWell installs alongside FreeFlow without sharing
settings or permissions.

Thanks to Zach Latta and the FreeFlow contributors, including [@marcbodea](https://github.com/marcbodea) for
maintaining FreeFlow. TellWell is not affiliated with or endorsed by the FreeFlow project.

## Build from source

```sh
git clone https://github.com/ayushpatnaikgit/tellwell.git && cd tellwell
make ARCH="$(uname -m)" CODESIGN_IDENTITY=-      # builds "TellWell Dev.app" in build/
make APP_NAME=TellWell BUNDLE_ID=io.github.ayushpatnaikgit.tellwell ARCH="$(uname -m)" CODESIGN_IDENTITY=-
```

The rest of this README describes the features TellWell inherits from FreeFlow.

## Quick Start

1. Download [TellWell.dmg](https://github.com/ayushpatnaikgit/tellwell/releases/download/v0.1.0/TellWell.dmg) (or build from source)
2. Get a free Groq API key from [groq.com](https://groq.com/)
3. Hold `Fn` to talk, or tap `Command-Fn` to start and stop dictation, and have whatever you say pasted into the current text field

## Features

- **Custom shortcuts:** Customize both hold-to-talk and toggle dictation shortcuts. If your toggle shortcut extends your hold shortcut, you can start in hold mode and press the extra modifier keys to latch into tap mode without stopping the recording. You can also turn on double-tapping the hold shortcut to lock recording, then press it again to stop. Each shortcut can inherit the global Preserve exact wording setting or override it with exact wording or cleanup. The choice is fixed when recording starts; Output Language and Edit Mode retain their existing behavior.
- **Context-aware cleanup:** TellWell can read nearby app context so names, terms, and phrases are spelled correctly when you dictate into email, terminals, docs, and other apps.
- **Original-field insertion (opt in):** Enable **Insert into the original field** in Settings → General → Text insertion to keep dictation tied to its starting field when switching windows. This is off by default and applies to new dictations; otherwise dictation pastes into the currently focused field. Changed or unavailable fields and unconfirmed writes leave the transcript available through Paste Again rather than risking a misplaced or duplicate paste. Paste fallback, or Enter when an editor loses background focus, may briefly activate the original app before restoring your previous focus.
- **Custom vocabulary:** Add names, jargon, and project-specific words that TellWell should preserve during cleanup.
- **OpenAI-compatible providers:** Use Groq by default, or configure a custom model and API URL in settings.

## Edit Mode

Edit Mode lets you highlight existing text and transform it with a spoken instruction, like "make this shorter" or "turn this into bullets." Enable it in settings, then use your normal dictation shortcut on selected text, or choose Manual mode to require an extra modifier key.

## Privacy

There is no TellWell server, so TellWell does not store or retain your data. The only information that leaves your computer are API calls to your configured transcription and LLM provider.

## Custom Cleanup

If you'd rather keep cleanup more literal and less context-aware, you can paste this simpler prompt into the custom system prompt setting:

<details>
  <summary>Simple post-processing prompt</summary>

  <pre><code>You are a dictation post-processor. You receive raw speech-to-text output and return clean text ready to be typed into an application.

Your job:
- Remove filler words (um, uh, you know, like) unless they carry meaning.
- Fix spelling, grammar, and punctuation errors.
- When the transcript already contains a word that is a close misspelling of a name or term from the context or custom vocabulary, correct the spelling. Never insert names or terms from context that the speaker did not say.
- Preserve the speaker's intent, tone, and meaning exactly.

Output rules:
- Return ONLY the cleaned transcript text, nothing else. So NEVER output words like "Here is the cleaned transcript text:"
- If the transcription is empty, return exactly: EMPTY
- Do not add words, names, or content that are not in the transcription. The context is only for correcting spelling of words already spoken.
- Do not change the meaning of what was said.

Example:
RAW_TRANSCRIPTION: "hey um so i just wanted to like follow up on the meating from yesterday i think we should definately move the dedline to next friday becuz the desine team still needs more time to finish the mock ups and um yeah let me know if that works for you ok thanks"

Then your response would be ONLY the cleaned up text, so here your response is ONLY:
"Hey, I just wanted to follow up on the meeting from yesterday. I think we should definitely move the deadline to next Friday because the design team still needs more time to finish the mockups. Let me know if that works for you. Thanks."</code></pre>
</details>

## Using a Local Model

TellWell can use OpenAI-compatible local or self-hosted providers instead of Groq. In settings, configure the API base URL and model IDs for your local LLM provider, such as Ollama, LM Studio, or another OpenAI-compatible server. If your transcription backend uses a different endpoint from your LLM backend, set the transcription API URL separately.

Local models are often slower than hosted providers, especially on cold start, long recordings, or busy hardware.

<details>
  <summary>Configure longer timeouts for local models</summary>

  TellWell keeps the default network timeout at 20 seconds, but you can extend it with macOS defaults:

```bash
defaults write io.github.ayushpatnaikgit.tellwell transcription_timeout_seconds -float 120
defaults write io.github.ayushpatnaikgit.tellwell post_processing_timeout_seconds -float 120
defaults write io.github.ayushpatnaikgit.tellwell context_request_timeout_seconds -float 120
```

The timeout keys are:

- `transcription_timeout_seconds`: audio transcription requests
- `post_processing_timeout_seconds`: transcript cleanup and edit mode requests
- `context_request_timeout_seconds`: nearby app context requests

Only positive values are used. Remove a custom timeout to return to the 20-second default:

```bash
defaults delete io.github.ayushpatnaikgit.tellwell transcription_timeout_seconds
defaults delete io.github.ayushpatnaikgit.tellwell post_processing_timeout_seconds
defaults delete io.github.ayushpatnaikgit.tellwell context_request_timeout_seconds
```

</details>

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to set up the project, build, test, and submit changes.

## License

Licensed under the MIT license.
