<div align="center">
  <img src="./macos/Resources/AppIcon.png" width="112" alt="Lithe app icon">

  <h1>Lithe</h1>

  <p><strong>A lightweight macOS IDE for multi-language development and AI collaboration</strong></p>

  <p>
    <a href="./README.zh-CN.md"><strong>简体中文</strong></a> ·
    <a href="#current-focus">Current focus</a> ·
    <a href="#future-todo">TODO</a> ·
    <a href="#core-features">Core features</a> ·
    <a href="#product-tour">Product tour</a> ·
    <a href="#download-and-install">Download</a> ·
    <a href="#architecture-overview">Architecture</a> ·
    <a href="#develop-lithe">Develop Lithe</a>
  </p>

  <p>
    <a href="https://hellogithub.com/repository/1lck/Lithe-IDEA" target="_blank"><img src="https://abroad.hellogithub.com/v1/widgets/recommend.svg?rid=633af067f07d4d16af010b9dc16c0b8d&amp;claim_uid=7NYd4yvRlGtqfgr" alt="Featured | HelloGitHub" style="width: 250px; height: 54px;" width="250" height="54"></a>
  </p>

  <p>
    <a href="https://qm.qq.com/cgi-bin/qm/qr?k=&amp;group_code=163027877"><img src="https://img.shields.io/badge/QQ_Group-163027877-EB1923?style=for-the-badge&logo=qq&logoColor=white" alt="Join the Lithe QQ group 163027877"></a>
    <a href="https://gcnctzuuwe9u.feishu.cn/wiki/HJFbwZ0hZirAPnkWF3xcPWkCnid?from=from_copylink"><img src="https://img.shields.io/badge/WeChat_Group-Join_Now-07C160?style=for-the-badge&logo=wechat&logoColor=white" alt="Join the Lithe WeChat group"></a>
  </p>

  <p>
    <a href="https://github.com/1lck/Lithe-IDEA/releases/latest"><img src="https://img.shields.io/github/v/release/1lck/Lithe-IDEA?style=flat&label=release&logo=github&logoColor=white" alt="Latest release"></a>
    <a href="https://github.com/1lck/Lithe-IDEA/releases"><img src="https://img.shields.io/github/downloads/1lck/Lithe-IDEA/total?style=flat&label=downloads&logo=github&logoColor=white" alt="Total downloads"></a>
    <img src="https://img.shields.io/badge/macOS-13%2B-111827?style=flat&logo=apple&logoColor=white" alt="macOS 13+">
    <img src="https://img.shields.io/badge/memory-300--400%20MB-159957?style=flat" alt="300 to 400 MB baseline memory">
    <a href="#download-and-install"><img src="https://img.shields.io/badge/Homebrew-Install-FBB040?style=flat&logo=homebrew&logoColor=black" alt="Install with Homebrew"></a>
    <a href="./LICENSE"><img src="https://img.shields.io/github/license/1lck/Lithe-IDEA?style=flat&label=license" alt="Apache License 2.0"></a>
  </p>
  <p>
    <img src="https://img.shields.io/badge/Debugger-Breakpoints-D32F2F?style=flat" alt="Breakpoint debugging">
    <img src="https://img.shields.io/badge/Git-Diff%20Review-F05032?style=flat&logo=git&logoColor=white" alt="Git diff review">
    <img src="https://img.shields.io/badge/Database-SQL%20Workspace-336791?style=flat" alt="Database SQL workspace">
  </p>
</div>

> **Fork status — 2026-10-28:** This fork focuses on a lightweight macOS IDE for Rust, Go, and Python. Maintenance selectively picks useful upstream fixes without importing entire compatibility stacks or adding settings. Larger feature work remains deferred; the TODO list has no committed schedule. Source is preserved on `dev/aiide`.

## Why Lithe

Codex, Claude Code, and other AI coding tools can now handle much of the implementation work. Developers still need an IDE to understand the generated code, follow symbols, run and debug the project, and review every diff. Keeping a heavyweight development environment open for those tasks can mean several gigabytes of resident memory.

## Meet Lithe

This fork keeps Lithe’s macOS workbench for browsing, editing, navigation, search, run and debug, Git diff review, local history, and databases. The default package omits JDK/JDTLS and Java Debug/Test resources. Maven, Spring, Windows, and Linux.do integration have been removed; Go, Rust, Python, and other existing language integrations remain available. Upstream releases through **v0.5.0** have been merged in order with their original history preserved. Useful Git, run, search, save-protection, and HTML/SVG preview improvements are adapted to the native macOS architecture. This maintenance batch cherry-picks selected output, Git, and terminal fixes from upstream history through **v0.6.5**; it is not a full v0.6.5 integration. Windows, Java ecosystem/framework increments, Linux.do, and the Monaco editor migration remain excluded. See the [integration and acceptance record](./docs/architecture/ai-ide-phase-one.md).

The Lithe application typically uses about **300–400 MB of baseline memory** after opening a regular project. Language servers, terminals, build tools, debuggers, and database helpers start on demand. Actual usage varies with the project and active services.

> **AI writes the code. Lithe helps you understand it, run it, and review it.**

## Current focus

- **Native macOS editing:** Keep SwiftUI/AppKit and `NSTextView`, native project windows, terminal ownership, and existing Go/Rust/Python integrations. Prioritize correct editing and predictable resource use.
- **Safe changes across files:** Preserve document freshness checks, mutation leases, selected-file/occurrence exclusions, shared Undo/Redo, and disk compensation across search replacement and language actions.
- **Language tooling and daily workflows:** Build on existing LSP navigation, rename, formatting, code actions, Go Tools/Cargo, Git review, and run/debug support. Rich completion and language hints remain unfinished.
- **Small, practical maintenance:** Improve Unicode output, Git status/discovery, terminal Control shortcuts and shell exit behavior using existing modules, with no new settings. Remaining B6a2 acceptance and larger plans stay tracked in their owning documents.

The [workbench plan](./docs/architecture/goland-parity-implementation.md), [refactoring status](./docs/architecture/goland-parity-b6-refactor.md#b6-current-implementation-rulings), and [language plan](./docs/architecture/syntax-and-completion.md) retain the detailed scope and evidence. The [integration and acceptance record](./docs/architecture/ai-ide-phase-one.md) separates this batch’s scope and actual verification from historical results.

## Future TODO

All items below remain open. If development resumes, recheck the current source and dependencies before choosing a batch.

- [ ] **Close the latest acceptance gap:** The B6a2 text-edit slice is now installed, with basic editing and cross-tab Undo/Redo smoke checks passed. Rename, formatting, code actions, completion and their undo behavior still need installed-app acceptance, including real `codeAction/resolve`. [B6](./docs/architecture/goland-parity-b6-refactor.md#b6-current-implementation-rulings)
- [ ] **Finish semantic editing and refactoring:** Add the remaining prepare-rename, selection/symbol and selected-range code-action paths; finish server-initiated `workspace/applyEdit`, resource transactions, preview/conflict handling and Refactor This. Reuse the existing transaction and Undo owners. [B6](./docs/architecture/goland-parity-b6-refactor.md)
- [ ] **Connect LSP features to the editor:** Parameter help, inlay hints, semantic tokens, symbol highlights, and Structure/breadcrumbs. L4a does not depend on the syntax engine; its design and placement still need review. [L4a](./docs/architecture/syntax-and-completion.md#l4a-split)
- [ ] **Build the syntax and completion engine:** Incremental document state, offline Go/Rust/Python highlighting, automatic completion with filtering, documentation and snippets, then offline symbols/folding. Follow the B6b2 → L0/L1 dependencies and L2/L3/L4b plans. [L0–L2](./docs/architecture/syntax-l0-l2-engine.md)
- [ ] **Complete workbench gaps:** Unified Find/Replace and recent items, remaining runnable-gutter interactions, a TODO tool window, and final Git graph comparison. Project/Commit/PR work remains deferred. [Workbench plan](./docs/architecture/goland-parity-implementation.md)
- [ ] **Extend language packages and formatting:** Grammar/query resources, package install/upgrade/rollback, common file formats, formatting transactions and format-on-save. [L5–L8](./docs/architecture/syntax-and-completion.md)
- [ ] **Review additional editor features:** A cross-language Problems panel, multiple cursors/column selection, call/type hierarchies, bookmarks and coverage. E1 is a recorded gap list, not an approved implementation plan. [E1](./docs/architecture/goland-parity-implementation.md#e1-editor-navigation-gaps)

## Core features

1. Multi-language project browsing, editing, and navigation.
2. Breakpoint debugging and custom run configurations.
3. Git management and side-by-side diff review.
4. Double-Shift search and `Command + Shift + F` project-wide search.
5. Process-free lightweight completion and current-file navigation, with on-demand language servers for richer completion, hover, and semantic navigation.
6. Local snapshot history.
7. Multiple projects open within the app.
8. Multiple files open independently in the same window.
9. AI-generated commit messages with customizable formats.
10. Rich Markdown rendering consistent with Yuque syntax.
11. Local application memory usage monitoring.
12. One-command installation and updates through Homebrew.
13. One-click in-app updates and installation.
14. Entry-point detection and run support focused on Rust/Cargo, Go, and Python, retaining existing Make and shell workflows.
15. Per-language service switches so language servers can be enabled or disabled independently to match the machine's resources.
16. Multi-line editor tabs for keeping more files visible in the same workspace.
17. Database connection workspace with multiple database types, connection management, SQL history, table browsing, and database operations.
18. Select useful upstream fixes while retaining the native editor, trimmed package, and simple configuration.

## Product tour

<p align="center">
  <img src="./docs/assets/screenshots/search-everywhere.png" width="49%" alt="Double-Shift Search Everywhere">
  <img src="./docs/assets/screenshots/global-search.png" width="49%" alt="Command Shift F project-wide search and replace">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/git-diff-review.png" width="96%" alt="Side-by-side Git diff review">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/ai-provider-import.png" width="49%" alt="Import AI provider settings from local tools">
  <img src="./docs/assets/screenshots/ai-commit-format.png" width="49%" alt="Customize AI commit message formats">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/ai-commit-message.png" width="96%" alt="Generate commit messages with AI">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/markdown-mermaid-preview.png" width="49%" alt="Markdown Mermaid rendering and live preview">
  <img src="./docs/assets/screenshots/markdown-rich-preview.png" width="49%" alt="Rich Markdown rendering and live preview">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/memory-monitor-annotated.png" width="49%" alt="Low memory footprint and in-app memory monitoring">
  <img src="./docs/assets/screenshots/memory-monitor.png" width="49%" alt="Application memory usage details">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/project-auto-detection-run.png" width="96%" alt="Automatic project detection and one-click run configuration">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/language-services-settings.png" width="49%" alt="Per-language service settings">
  <img src="./docs/assets/screenshots/multi-line-editor-tabs.png" width="49%" alt="Multi-line editor tabs">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/database-workspace-overview.png" width="49%" alt="Database connection workspace">
  <img src="./docs/assets/screenshots/database-sql-operation.png" width="49%" alt="Database SQL operation and table structure">
</p>

## Download and install

The release links below point to upstream builds. Build this fork locally with `./scripts/package-app.sh` to obtain the trimmed package.

- **macOS 13+:** Download the `arm64` DMG for Apple silicon or the `x86_64` DMG for Intel Macs from [GitHub Releases](https://github.com/1lck/Lithe-IDEA/releases/latest).

Homebrew is the recommended installation and update method on macOS:

```bash
brew tap 1lck/lithe https://github.com/1lck/Lithe-IDEA.git
brew install --cask 1lck/lithe/lithe
brew upgrade --cask lithe
```

### If macOS says it cannot open `Lithe.app`

If macOS says that Apple cannot verify whether `Lithe.app` contains malware, the manually downloaded package may not yet be notarized by Apple. First confirm that the app came from the trusted [GitHub Releases](https://github.com/1lck/Lithe-IDEA/releases/latest), then use one of these methods:

<p align="center">
  <img src="./docs/assets/screenshots/macos-app-verification-warning.png" width="492" alt="macOS warning that Lithe.app cannot be opened">
</p>

1. In **Applications**, Control-click `Lithe.app`, choose **Open**, and choose **Open** again in the confirmation dialog.
2. If macOS still blocks it, open **System Settings > Privacy & Security**, click **Open Anyway** next to the security warning, and launch the app again.
3. You can also remove the quarantine attribute in Terminal:

   ```bash
   sudo xattr -dr com.apple.quarantine /Applications/Lithe.app
   ```

Only use these steps for an app whose source you trust. Homebrew installations usually do not require manual quarantine removal.

## Architecture Overview

The macOS application uses Rust Core for deterministic commands and contracts, with native UI and platform integrations kept separate.

```mermaid
flowchart LR
    subgraph macOS["macOS"]
        MacUI["SwiftUI / AppKit workbench"] --> MacApp["Application models and services"]
        MacApp --> MacAdapters["macOS adapters"]
    end

    subgraph Shared["Shared behavior"]
        Contracts["JSON contracts and fixtures"] --> Core["Rust lithe-core"]
    end

    MacApp -->|"JSON C ABI"| Core
```

<a id="develop-lithe"></a>
<details>
<summary><strong>Develop Lithe</strong></summary>


Development requires Swift 6.2 or later. Running the complete test suite requires Xcode; basic SwiftPM builds only need Command Line Tools.

Run the development build from the repository root:

```bash
./scripts/preview.sh
```

The script builds and links Rust Core before launching the macOS app. To validate only the Swift source, run:

```bash
swift run --disable-sandbox Lithe
```

Build an app bundle:

```bash
./scripts/package-app.sh
open dist/Lithe.app
```

Before submitting a change, run:

```bash
./scripts/test-macos.sh
./scripts/test-git-performance-baseline.sh
./scripts/verify-core.sh
./scripts/verify-git-graph.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-rust-core.sh
```

`test-git-performance-baseline.sh` runs deterministic Git graph work gates and
records an optimized multi-sample timing baseline under `.artifacts/`.

See [Repository layout and shared boundaries](./docs/architecture/repository-layout.md) for directory ownership, cross-platform boundaries, sharing rules, and the required Rust Core comment standard. Include your verification steps and known limitations when submitting a change.

</details>

## Project support

### ❤️ Sponsors

<p align="center">
  <a href="https://www.fastaitoken.com/">
    <img src="./docs/assets/sponsors/fastai-qrcode.png" width="480" alt="FastAI Token community chat group QR code">
  </a>
</p>
<p align="center">
  <a href="https://www.fastaitoken.com/"><strong>FastAI</strong></a><br>
  FastAI provides convenient relay access to a range of leading large language models, making it easier to connect AI capabilities to everyday development workflows. Its support helps Lithe continue improving its AI-assisted experience. Thank you to FastAI for supporting this project! Scan the QR code above to join the FastAI Token community chat group #2 (group ID: 1073874006).
</p>

<a href="mailto:2188718831@qq.com">Want to be featured below?</a>

<table>
  <tr>
    <td width="112" align="center">
      <a href="https://www.fastaitoken.com/">
        <img src="./docs/assets/sponsors/fastai.png" width="64" alt="FastAI">
      </a>
    </td>
    <td>
      <a href="https://www.fastaitoken.com/"><strong>FastAI</strong></a> provides convenient relay access to a range of leading large language models, making it easier to connect AI capabilities to everyday development workflows. Its support helps Lithe continue improving its AI-assisted experience. Thank you to FastAI for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://torchai.ai/sign-up?aff=FdkE">
        <img src="./docs/assets/sponsors/torchai.jpg" width="64" alt="TorchAI">
      </a>
    </td>
    <td>
      <a href="https://torchai.ai/sign-up?aff=FdkE"><strong>TorchAI</strong></a> provides large language model relay services for developers who need convenient API access across coding, content, and automation scenarios. Its support helps sustain Lithe's development and exploration of practical AI-powered tools. Thank you to TorchAI for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://api.axis.fan/register?aff=4EZFN7322WTH">
        <img src="./docs/assets/sponsors/yuanliu-token.png" width="64" alt="Yuanliu Token">
      </a>
    </td>
    <td>
      <a href="https://api.axis.fan/register?aff=4EZFN7322WTH"><strong>Yuanliu Token</strong></a> offers relay access to multiple large language model APIs, giving developers a flexible entry point for experimenting with different models and building AI applications. Its sponsorship supports Lithe as the project expands and polishes its AI features. Thank you to Yuanliu Token for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://codezsy.com/register?aff=fDyA">
        <img src="https://raw.githubusercontent.com/zwenooo/z/main/logo/codez-logo-bq.png" width="64" alt="CodeZ relay service">
      </a>
    </td>
    <td>
      <a href="https://codezsy.com/register?aff=fDyA"><strong>CodeZ</strong></a> focuses on stable relay access to GPT-family models, offering developers a straightforward way to integrate model APIs into their tools and projects. Its sponsorship contributes to the ongoing development and maintenance of Lithe. Thank you to CodeZ for supporting this project!
    </td>
  </tr>
</table>

### Contributors

Thank you to everyone who contributes to and improves Lithe.

<a href="https://github.com/1lck/Lithe-IDEA/graphs/contributors">
  <img src="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/contributors.svg" alt="Contributors">
</a>

### License

Lithe is licensed under the [Apache License 2.0](./LICENSE).

## Star History

<a href="https://www.star-history.com/#1lck/Lithe-IDEA&Date">
  <img alt="Star History Chart" src="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/star-history-light.svg" />
</a>
