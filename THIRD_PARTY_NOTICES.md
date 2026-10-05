# Third-party notices

Pennant is licensed under the Apache License 2.0 (see [LICENSE](LICENSE)). It builds on the following open-source packages, fetched by Swift Package Manager. Each keeps its own license, found in its repository.

| Package | License |
| --- | --- |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | MIT |
| [gonzalezreal/swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | MIT |
| [gonzalezreal/NetworkImage](https://github.com/gonzalezreal/NetworkImage) | MIT |
| [mattt/eventsource](https://github.com/mattt/eventsource) | MIT |
| [swiftlang/swift-cmark](https://github.com/swiftlang/swift-cmark) | BSD 2-Clause (with MIT-licensed parts) |
| [apple/swift-nio](https://github.com/apple/swift-nio) | Apache 2.0 |
| [apple/swift-log](https://github.com/apple/swift-log) | Apache 2.0 |
| [apple/swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 |
| [apple/swift-atomics](https://github.com/apple/swift-atomics) | Apache 2.0 |
| [apple/swift-system](https://github.com/apple/swift-system) | Apache 2.0 |
| [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) (the Mac app's updater) | MIT, with the bundled parts listed in its LICENSE |

Pennant Voice, the helper that runs Talk mode's natural voice on a Mac, adds these:

| Package | License |
| --- | --- |
| [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) | MIT |
| [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) and [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT |
| [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers), [swift-huggingface](https://github.com/huggingface/swift-huggingface) and [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache 2.0 |
| [mattt/swift-xet](https://github.com/mattt/swift-xet) | Apache 2.0 |
| [ibireme/yyjson](https://github.com/ibireme/yyjson) | MIT |
| [swift-server/async-http-client](https://github.com/swift-server/async-http-client) and [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | Apache 2.0 |
| apple/swift-crypto, swift-certificates, swift-asn1, swift-numerics, swift-algorithms, swift-async-algorithms, swift-configuration, swift-distributed-tracing, swift-service-context, swift-http-types, swift-http-structured-headers, swift-nio-ssl, swift-nio-http2, swift-nio-extras and swift-nio-transport-services; swiftlang/swift-syntax | Apache 2.0 |

## Voice models

The natural voices aren't shipped with the app. The Mac downloads them from Hugging Face, at a fixed revision, when they're first used:

| Model | License |
| --- | --- |
| [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), as [mlx-community/Kokoro-82M-bf16](https://huggingface.co/mlx-community/Kokoro-82M-bf16) | Apache 2.0 |
| [beshkenadze/kitten-tts-g2p](https://huggingface.co/beshkenadze/kitten-tts-g2p) (English pronunciation data for Kokoro) | MIT |
| [Qwen/Qwen3-TTS](https://huggingface.co/Qwen), as [mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit) (Penny, cloned from `Apps/PennantVoice/penny.wav`, which Kokoro made), [mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16) and, for `Pennant Voice speak --ref-audio`, [mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16) | Apache 2.0 |
| [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo), as [mlx-community/whisper-large-v3-turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo), for `Pennant Voice transcribe` | MIT |

## The website

pennant.dev serves its own copies of [IBM Plex Sans and IBM Plex Mono](https://github.com/IBM/plex) (`www/assets/fonts`), under the SIL Open Font License 1.1, whose text is in `www/assets/fonts/OFL.txt`. No font service sees the site's visitors.

## Brand marks

The service logos in `Sources/PennantUI/Resources/BrandIcons.xcassets` come from [Simple Icons](https://simpleicons.org) (CC0 1.0), fetched by `Scripts/fetch-brand-icons.swift`. The marks themselves remain the trademarks of their owners. Pennant uses them only to show which service a connection talks to; it does not imply any endorsement or affiliation.

Product and company names in the app and docs belong to their owners and are used only to identify them.
