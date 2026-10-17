# Contributing to clubTivi

Thanks for your interest in contributing to clubTivi! This guide will help you get started.

---

## 🛠️ Development Setup

### Prerequisites
- [Flutter SDK 3.24+](https://docs.flutter.dev/get-started/install)
- [Dart SDK 3.5+](https://dart.dev/get-dart) (included with Flutter)
- An IDE: [VS Code](https://code.visualstudio.com/) (recommended) or [Android Studio](https://developer.android.com/studio)
- Git

### Platform-Specific Requirements

**Android:**
- Android Studio with Android SDK
- Android 7.0+ device or emulator

**macOS:**
- Xcode 15+
- macOS 12+

**Linux:**
```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev
```

**Windows:**
- Visual Studio 2022 with "Desktop development with C++" workload

### Getting Started

```bash
# Fork and clone
git clone https://github.com/<your-username>/clubTivi.git
cd clubTivi

# Install dependencies
flutter pub get

# Verify setup
flutter doctor

# Run the app
flutter run
```

---

## 📐 Architecture

clubTivi follows a **feature-first** architecture with clean separation of concerns:

```
lib/
├── app/              # App entry, routing, theme
├── core/             # Shared utilities, constants, extensions
├── data/
│   ├── models/       # Data classes (immutable, with copyWith)
│   ├── repositories/ # Repository interfaces + implementations
│   ├── datasources/  # Database, API clients, file parsers
│   └── services/     # Business logic services (failover, EPG mapper)
├── features/         # Feature modules (each self-contained)
│   ├── player/
│   ├── guide/
│   ├── channels/
│   └── ...
└── platform/         # Platform-specific adaptations
```

### Key Conventions
- **State management**: Riverpod (prefer `AsyncNotifier` for async state)
- **Models**: Immutable data classes with `freezed` or manual `copyWith`
- **Database**: Drift (SQLite) — all queries in `datasources/`
- **Networking**: Dio with interceptors for auth/retry
- **Testing**: Unit tests for services/repositories, widget tests for UI

---

## 🌿 Branching & Commits

### Branch Naming
```
feat/short-description    # New feature
fix/short-description     # Bug fix
docs/short-description    # Documentation
refactor/short-description # Code refactoring
```

### Commit Messages
Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add M3U Plus parser with extended attributes
fix: handle malformed XMLTV dates in EPG parser
docs: add failover engine architecture doc
refactor: extract stream health monitor from player
test: add unit tests for fuzzy channel matcher
```

### DCO Sign-Off
All commits **must** include a DCO sign-off:

```bash
git commit -s -m "feat: add M3U Plus parser"
# Produces: Signed-off-by: Your Name <your@email.com>
```

---

## 🔀 Pull Request Process

1. Create a feature branch from `main`
2. Make your changes with clear, signed-off commits
3. Ensure all tests pass: `flutter test`
4. Ensure code is formatted: `dart format .`
5. Ensure analysis passes: `flutter analyze`
6. Open a PR with a clear description of what and why
7. Link any related issues

### PR Template
```markdown
### Summary
Brief description of what this PR does.

### Changes
- Bullet list of changes

### Testing
- How was this tested?
- [ ] Unit tests added/updated
- [ ] Widget tests added/updated
- [ ] Manual testing on [platforms]

### Related Issues
Fixes #123
```

---

## 🧪 Testing

```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/data/services/epg_mapper_test.dart

# Run with coverage
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html

# Integration tests
flutter test integration_test/
```

### Test Conventions
- Test files mirror source structure: `lib/data/services/foo.dart` → `test/data/services/foo_test.dart`
- Use descriptive `group()` and `test()` names
- Mock external dependencies (network, filesystem, platform)
- Aim for >80% coverage on services and repositories

---

## 🚀 Publishing a Release

Versions are published with one command — there is no need to edit the version by hand or to create the tag manually:

```bat
Publicar release.bat          # double-click friendly: asks patch / minor / major
```

```powershell
pwsh -File tools/release.ps1                 # patch bump, asks for confirmation
pwsh -File tools/release.ps1 -Bump minor -Yes
pwsh -File tools/release.ps1 -Version 1.0.0-rc1 -DryRun
pwsh -File tools/release.ps1 -NoPush         # commit and tag locally, push later
```

The assistant bumps the version, runs `flutter test`, commits, creates the annotated tag `vX.Y.Z` and pushes both the branch and the tag. It refuses to run on a dirty working tree, on a detached HEAD, or when the tag already exists. `-DryRun` prints the plan without touching anything.

Version bumps are always **two** edits, and the assistant does both in one commit:

| Where | Why |
| --- | --- |
| `pubspec.yaml` → `version: X.Y.Z+N` | The build number, and the version the CI packages into the ZIP/DMG/APK |
| `lib/data/services/app_update_service.dart` → `_currentVersion` | What the app shows and compares against the published tag when checking for updates |

Never bump one without the other: the update banner reads `_currentVersion`, so a stale value means the app claims to be up to date forever. `test/version_consistency_test.dart` fails if the two ever drift apart.

Pushing the tag is what builds the release: `.github/workflows/release.yml` calls the reusable build workflow, which compiles every platform and attaches the assets plus a `SHA256SUMS.txt` manifest to the GitHub release. To package only the Windows portable ZIP locally, use `Compilar y empaquetar.bat` (or `tools/package_windows.ps1`); it is the same script the CI runs.

---

## 📄 License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
