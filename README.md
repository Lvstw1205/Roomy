<p align="center"><img src="Assets/icon.png" width="128" alt="Roomy icon"></p>

# Roomy

**Make room for local AI on your Mac.**

One local LLM can take 4–40 GB, and every model you try adds more. Roomy finds that
space in what you don't need: developer caches, stale dependencies, duplicate files and
leftover installers. It leaves your models alone.

Press **Scan**, review what it found, press **Clean all**, and get a report. Roomy is a
native SwiftUI app under 1 MB. Scanning never changes anything, and cleaning moves items
to the Trash, so you can put anything back.

### Built not to break your AI setup
- **Model folders are never scanned.** `~/.ollama`, `~/.cache/huggingface` and LM Studio's folder are not touched.
- **Model files are left out.** `.gguf`, `.safetensors`, `.ckpt`, `.pt`, `.onnx` and Ollama blobs are excluded from the large-file cleanup. Duplicate copies of a model are merged as APFS clones, never deleted.
- **Caches that hold models are flagged.** When an app keeps model weights in its cache folder, Roomy leaves that cache unticked and says why.
- **Links are respected.** Model stores that link into another folder, for example from an external SSD, keep that folder safe.

[한국어 안내는 아래에 있어요](#한국어)

<p align="center">
  <img src="docs/results.png" width="45%" alt="Scan results">
  <img src="docs/report.png" width="45%" alt="Cleanup report">
</p>

## What it finds

| Category | Default | What happens |
|---|---|---|
| Developer caches: Xcode DerivedData and DeviceSupport, npm, pip, uv, Poetry, Homebrew, CocoaPods, Go, Gradle, Cargo | on | Moved to Trash; the tools rebuild them |
| App caches in `~/Library/Caches` (≥ 50 MB each) | on | Moved to Trash; apps recreate them |
| Stale project dependencies: `node_modules`, `.venv`, `venv`, Rust `target`, SwiftPM `.build`, `Pods` in projects untouched for 30+ days | on | Moved to Trash; reinstall with the project's install command |
| Unavailable simulators | on | Deleted with `simctl delete` |
| Duplicate files (≥ 10 MB) | on | **Nothing is deleted.** Copies become APFS clones that share the original's blocks |
| Old installers (`.dmg`, `.pkg`, `.iso`, `.xip`) | off | Moved to Trash |
| Large files (≥ 1 GB) unopened for 90+ days | off | Moved to Trash |
| H.264 videos (≥ 300 MB) | off | Re-encoded to HEVC with the hardware encoder; original goes to Trash |

## Safety

- **Scan is read-only.**
- **Trash, not delete.** The only permanent deletion is simulators that can no longer run.
- **A guard checks every path.** Cleaning refuses anything outside your home folder, and anything that is or contains a protected folder (`~/Library`, `~/Documents`, `~/Downloads`, …).
- **Duplicates are re-verified.** Both files are hashed again just before cloning, and a file that changed since the scan is skipped. The clone keeps the copy's own name, permissions and dates.
- **A video is replaced only if it gets at least 10% smaller.**
- **Linked folders are left alone.** Before scanning and again before cleaning, Roomy indexes every symlink in your home folder (and on external drives your home links to). Anything another path still points into is flagged and refused. Example: an app moved model files into `~/Library/Caches` and linked them back from its model store.
- **Big app caches start unticked.** A "cache" over 1 GB may hold real data, so you opt in after a look.
- **Recent projects are never touched.** "Stale" is judged from lockfiles, manifests and `.git/index`.

## Build and run

Requires macOS 15+ and Xcode 16+ (Swift 6).

```bash
git clone https://github.com/Lvstw1205/Roomy.git && cd Roomy
scripts/build-app.sh          # → dist/Roomy.app
open dist/Roomy.app
```

During development, use `swift run Roomy`.

The app is ad-hoc signed. If you download a build instead of compiling it, right-click → Open the first time.
macOS will ask for access to Desktop, Documents and Downloads the first time Roomy scans them.

### CLI (read-only)

```bash
swift run roomy-cli scan
swift run roomy-cli scan --only devCaches,appCaches
```

## Project layout

```
Sources/RoomyCore   scanning rules, cleaner, safety guard, report (no UI, fully tested)
Sources/Roomy       SwiftUI app
Sources/roomy-cli   read-only command-line scanner
Tests               tests run against a throwaway home folder and a fake Trash
```

To add a category: add a case to `CategoryID` (`Models.swift`), return findings from `Rules.findings` (`Scanner.swift`), and add a test.

```bash
swift test
```

### Releasing

```bash
scripts/release.sh 0.1.2 --prerelease    # tests, builds, zips, publishes
DRY_RUN=1 scripts/release.sh 0.1.2       # same, but publishes nothing
```

The script refuses to run with uncommitted changes or when `main` is not pushed, so every release matches the code on GitHub.

## Roadmap

- APFS transparent compression for rarely used apps and documents
- Move cold files to a NAS or external drive, keeping an index
- Plain-language explanations ("what is this 18 GB folder?")
- Settings for thresholds and excluded folders
- Signed and notarized releases

## Prior art

Roomy's categories and its preview-then-confirm flow follow established open-source cleaners: [Mole](https://github.com/tw93/Mole), [npkill](https://github.com/voidcosmos/npkill) and Free my Mac. Roomy contains no code from them.

## License

MIT

---

## 한국어

**맥에서 로컬 AI를 돌릴 공간을 만들어줘요.**

로컬 LLM 모델 하나가 4~40GB를 차지해요. Roomy는 그 공간을 필요 없는 곳에서 찾아줘요: 개발 캐시, 오래된 의존성, 중복 파일, 남은 설치 파일 등이에요. 모델 파일(`.gguf`, `.safetensors`, Ollama 모델 등)은 건드리지 않아요.

1. **스캔**을 누르면 개발 캐시, 앱 캐시, 오래된 `node_modules`, 중복 파일 등을 찾아요. 이 단계에서는 아무것도 바꾸지 않아요.
2. 목록을 확인하고 **한 번에 정리**를 누르면 선택한 항목을 휴지통으로 옮겨요.
3. **보고서**에서 확보한 용량을 확인하고 Markdown으로 저장할 수 있어요.

- 다른 곳에서 링크로 쓰고 있는 폴더는 정리하지 않아요. 1GB가 넘는 앱 캐시는 선택을 빼고 이유를 보여줘요.
- "안전" 항목은 미리 선택돼 있어요. "확인 필요" 항목(설치 파일, 큰 파일, 영상 압축)은 직접 선택해야 해요.
- 중복 파일은 지우지 않고 APFS 복제본으로 합쳐서, 파일은 그대로 두고 공간만 아껴요.
- 휴지통으로 옮긴 항목은 **휴지통을 비워야** 실제 공간이 생겨요.

```bash
scripts/build-app.sh && open dist/Roomy.app
```
