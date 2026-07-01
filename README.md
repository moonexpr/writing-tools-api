# writing-tools-api

Surface macOS text tools **programmatically from Objective-C** after the macOS 27
"Siri AI" beta removed the Writing Tools context-menu item and Settings pane.

The underlying engines are all still present and running on the machine (the beta
only pulled the UI entry points). This repo reaches them directly.

## What works, and how

| Capability | Public API used | Obj-C? | Notes |
|---|---|---|---|
| **Proofread** (spelling) | `NSSpellChecker checkString:range:types:…` + `guessesForWordRange:` | ✅ pure Obj-C | Works headless. Verified. |
| **Grammar** | `NSSpellChecker` `NSTextCheckingTypeGrammar` | ✅ pure Obj-C | Built-in grammar is weak (misses e.g. "a apple" → "an apple"). |
| **Summarize** | `NSPerformService(@"Summarize", pboard)` → `com.apple.SummaryService` | ✅ pure Obj-C | Opens the system Summary panel; needs an app run loop. |
| **AI proofread / rewrite / summarize** | `FoundationModels.LanguageModelSession` via an `@objc` Swift shim | ✅ from Obj-C | On-device Apple Intelligence (3B model). Verified. |
| **Real Writing Tools UI** | `NSWritingToolsCoordinator` (public in the 27.0 SDK) | ✅ Obj-C | Needs a host `NSView`/text view; heavier to wire up. |

`wtsurface.m` implements proofread + summarize; `AIShim.swift` adds the `ai` subcommand.

## Build

```sh
make          # ./wtsurface — Obj-C + Apple Intelligence Swift shim
make pure     # ./wtsurface-pure — Obj-C only (no Swift/FoundationModels)
```

## Use

```sh
echo "teh quick brown fox jumpd over teh lazi dog" | ./wtsurface proofread   # NSSpellChecker
pbpaste | ./wtsurface summarize                                              # Summary service

echo "the fox jump over a apple" | ./wtsurface ai proofread   # Apple Intelligence
pbpaste | ./wtsurface ai summarize    # compress to 1-2 sentences
pbpaste | ./wtsurface ai simplify     # preserve structure + length, plainer language
pbpaste | ./wtsurface ai outline      # narrative skeleton as plain numbered lines
pbpaste | ./wtsurface ai rewrite      # clearer + more professional
```

The `ai` modes sit on a synthesis gradient: `summarize` compresses hardest, `simplify`
keeps the full structure and length but plainer, `outline` extracts the ordered beats.

## The AI-grade path (Apple Intelligence)

`NSSpellChecker` is the classic checker; the `ai` subcommand routes text through the
on-device LLM instead, matching what the old Writing Tools menu did.

- **`FoundationModels`** exposes only a Swift API (`LanguageModelSession`), so
  `AIShim.swift` wraps it in an `@objc` class (`AIWriter`) that the Obj-C tool calls.
  The system prompt is baked in per mode — no per-use typing.
- Availability is gated on `SystemLanguageModel.default.isAvailable`.
- First invocation after boot may fail once with `ModelManagerError 1013` while the
  model asset warms up; it succeeds on retry.

Example — grammar the classic checker misses:

```
$ echo "the quick brown fox jump over the lazy dogs and it was a apple day" | ./wtsurface ai proofread
The quick brown fox jumps over the lazy dogs, and it was an apple day.
```

## Model selection & context window

| Model | Context | Locality | Reachable from an unsigned CLI? |
|---|---|---|---|
| `SystemLanguageModel.default` (on-device 3B) | **4,096** tokens | on-device | ✅ default |
| `PrivateCloudComputeLanguageModel` | **32,768** tokens | Apple PCC (off-device) | ❌ needs a managed entitlement |

`--pcc` selects the larger cloud model:

```sh
echo "$long_text" | ./wtsurface ai --pcc summarize
```

…but it requires the **`com.apple.developer.private-cloud-compute`** entitlement,
which Apple grants to a developer account and embeds via a provisioning profile.
An ad-hoc/unsigned binary cannot use it — touching PCC without the entitlement is a
`fatalError`, and self-signing it gets the process **SIGKILL'd by AMFI**. So the tool
checks its own entitlement first (`SecTaskCopyValueForEntitlement`) and, if absent,
prints guidance and exits `3` instead of crashing. To actually use PCC, build this as
a signed `.app` with that entitlement.

### On-device chunking for large input (no PCC needed)

Rather than requiring PCC for long documents, the on-device path **auto-chunks**:
input over a safe per-mode budget is split on paragraph/sentence boundaries,
each chunk is processed on-device, then the results are combined —

- **proofread / simplify / rewrite** → chunks concatenated in order (structure preserved);
- **summarize / outline** → a *reduce* pass re-runs the mode over the joined outputs
  (recursively) so the result stays a single coherent summary/outline.

Chunk progress prints to stderr; the result to stdout. This keeps everything
on-device with no entitlement and no quota. `--pcc` remains available if you'd
rather use the 32K window in one shot (and have the entitlement).
