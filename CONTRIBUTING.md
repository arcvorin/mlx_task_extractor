# Contributing

TaskBench requires macOS 14 or newer on Apple silicon, Xcode 27 or newer, and
the Metal Toolchain.

Before opening a pull request, run:

```bash
swift test
xcodebuild \
  -project TaskBench.xcodeproj \
  -scheme TaskBench \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/TaskBenchDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Changes to the extraction prompt, JSON schema, provenance enrichment, or due
date validation should include focused tests. Do not commit model weights,
build products, user-specific Xcode data, screenshots containing private
information, or exported benchmark reports containing private text.

