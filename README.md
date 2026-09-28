# Chappe

**An offline-first messenger for places where the internet is unreliable
or shut down — with an AI assistant that lives entirely on your phone.**

Messages are end-to-end encrypted and travel over three independent
paths: an internet relay mailbox, a long-range LoRa radio node
(Meshtastic-compatible), or directly between two nearby iPhones with no
infrastructure at all. There are no accounts and no sign-up: identity is
a keypair generated on the device, contacts are exchanged by QR code.

Try the beta on TestFlight: https://testflight.apple.com/join/TTDU3r8W

## Sophie, the on-device assistant

Sophie is a built-in assistant powered by a local LLM
(Qwen3-4B-Instruct, ~2.4 GB one-time download). Everything runs on the
phone; nothing you tell her leaves it.

- **Memory**: she remembers facts you tell her — encrypted at rest with
  a key in the device Keychain. A dedicated screen shows everything she
  remembers; swipe any entry to delete it forever. "Fresh Start" wipes
  the memory key — cryptographic erasure.
- **Tools, not hallucinations**: weather comes from downloaded offline
  forecast packs, distances from the on-device gazetteer, positions,
  battery and link state from the OS. The model chooses a tool; the
  code executes it. Facts the code cannot verify are refused, not
  invented.
- **A legible agent harness**: a small explicit loop with a capped
  number of model calls per turn, a cheap heuristic gate that decides
  whether a turn needs memory at all, background consolidation of
  conversations into facts, and a local JSONL trace whose API accepts
  only enums and numbers — message text physically cannot leak into
  logs.

## Building

Requirements: Xcode 16+, an iPhone (the LLM needs a real device;
simulator works for everything else).

```
git clone <this repo>
cd chappe
scripts/fetch_llama_xcframework.sh   # fetches the pinned llama.cpp binary
open ios/Chappe/Chappe.xcodeproj
```

The Qwen model is downloaded by the app itself (Settings → Assistant)
or can be dropped into the app's Documents as a GGUF file.

Run the full test suite (serial, with a test-count floor gate):

```
tools/dev/run_suite.sh
```

## Repository layout

```
ios/        the iOS app (Swift, SwiftUI)
sim/        Python reference codec + transport simulator
tests/      test vectors shared by the Python and Swift codecs
tools/      benchmarks, linters, the model evaluation gate
docs/       specifications (wire format, LLM architecture, Sophie)
```

Engineering culture highlights, enforced by tests rather than
convention: every guarantee has a "break test" (revert the fix — the
test must go red), message length is counted by code and never by the
model, structured LLM output is validated and repaired in code, and the
release evaluation gate certifies any model swap before users see it
(`tools/sophie_eval/`).

## Status

Beta. The nearby path, relay path, Sophie with memory, offline maps and
weather are working; LoRa radio support is functional and evolving.
Expect rough edges — issues and field reports are very welcome.

## License

Apache-2.0, see LICENSE. Third-party attributions: see NOTICE.
