# TaskBench and MLXTaskExtractor

A tiny native macOS app that captures the main display, extracts visible text with Apple Vision, and benchmarks multiple models with MLX directly on Apple silicon.

The repository includes `MLXTaskExtractor`, a reusable Swift library containing the complete extraction pipeline. Screen capture is intentionally not part of the library; pass it a `CGImage` from a screenshot, file, camera, or any other source.

## Requirements

- macOS 14 or newer
- Apple silicon
- Xcode 27 or newer
- The Metal Toolchain

## Use the library

After the first release tag exists, add the package in Xcode or declare it in your app's `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/arcvorin/mlx_task_extractor.git",
        from: "0.1.0"
    )
]
```

Then add the `MLXTaskExtractor` product to your app target.

For an image, the library performs Vision OCR and MLX extraction in one call:

```swift
import MLXTaskExtractor

let extractor = TaskExtractor()
let result = try await extractor.extract(from: screenshotCGImage)

print(result.ocr.text)
for task in result.extraction.tasks {
    print(task.text, task.requester ?? "unknown", task.dueDate ?? "no due date")
}
```

If your app already has text, bypass OCR:

```swift
let result = try await extractor.extract(from: visibleText)
print(result.tasks)
```

`TaskExtractor` is an actor and keeps its MLX model loaded across calls. Call `preload()` when you want to pay the model-loading cost ahead of time, `warmUp(text:)` to perform an unmeasured inference, or `unload()` to release it. Calls to `extract` reuse the resident model without performing a hidden warm-up. A different compatible MLX model can be selected through configuration:

```swift
let extractor = TaskExtractor(configuration: .init(
    modelID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
    maxOutputTokens: 600
))
```

Public results include extracted tasks, requester, validated due date, source evidence, raw model output, OCR strategy, model load time, wall time, time to first token, throughput, and thermal state.

`MLXTaskExtractor` downloads model weights from Hugging Face on first use and caches them locally. Applications should disclose the download and should review the license of every model ID they offer.

The consuming app remains responsible for obtaining the `CGImage` and requesting any permissions required by its capture method.

## Run

Open [TaskBench.xcodeproj](TaskBench.xcodeproj), select the **TaskBench** scheme and **My Mac**, then press Run. TaskBench is a native macOS application product with bundle identifier `com.arcvorin.taskbench`.

The first build compiles MLX and can take a while. Subsequent builds are incremental. The application bundle contains MLX's `default.metallib`; do not use `swift run TaskBench` as the application launch path.

If the launcher reports a missing Metal Toolchain, install it once:

```bash
xcodebuild -downloadComponent MetalToolchain
```

On first capture, macOS asks for Screen Recording permission. You can also choose an existing image, which is useful for repeating the exact same benchmark input. MLX weights download from Hugging Face on first use and are cached for later runs.

## What it measures

- Apple Vision OCR time (reported separately)
- median end-to-end wall time across configurable runs
- MLX model download/load time
- MLX-reported prompt time, time-to-first-token, and generation throughput
- JSON validity and extracted task count

Task output uses MLX guided generation with a shared JSON Schema, so model formatting differences do not invalidate benchmark runs.

Warm-up is enabled by default, then each model is measured sequentially to avoid unified-memory contention. The OCR text is editable, and the model list accepts compatible Hugging Face MLX model IDs.

## Export results

After a benchmark finishes, click **Export JSON…** above the result cards. The report includes:

- macOS, architecture, memory, and processor details
- selected models, run count, and warm-up setting
- OCR text, screenshot dimensions, and OCR duration
- timestamped progress and failure logs
- every measured sample, summary medians, extracted tasks, and raw model output

The default filename is `taskbench-YYYY-MM-DD-HHmmss.json`.

## Interactive consistency checks

After the full benchmark, expand a model result. **Re-warm** performs an unmeasured warm-up and leaves that model resident. **Run once** performs exactly one measured extraction without a hidden warm-up and appends its metrics and tasks to the run history. Repeated **Run once** clicks reuse the resident model; selecting or warming a different model replaces it in memory.

## Versioning and releases

The `MLXTaskExtractor` library follows semantic versioning. Until the public API is intentionally frozen, pre-1.0 releases should use tags such as `0.1.0`. A release is a Git tag whose name is a semantic version without a `v` prefix:

```bash
git tag 0.1.0
git push origin main 0.1.0
```

Swift Package Manager resolves that tag directly from the Git repository; no separate package-registry upload is required.

## License

TaskBench and MLXTaskExtractor are available under the [MIT License](LICENSE). Model weights are downloaded separately and remain subject to their respective model licenses.
