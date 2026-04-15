# Lob Music — Remaining Tasks

## Known Issues

### 1. App Icon — Lobster image not showing
- **Status:** In progress
- **Problem:** Android shows generic robot instead of lobster icon
- **Note:** v3 updated assets/icon/app_icon.png (compressed from 1MB to 30KB) and mipmaps. v2 has old icon assets. Try replacing mipmaps + `flutter pub get` + rebuild.
- **Next:** Replace mipmaps from v3's android/app/src/main/res/mipmap-*/ directories and rebuild

### 2. Background Audio + Media Notification
- **Status:** In progress
- **Status note:** `audio_service` already integrated — notification working. But audio stops when app is backgrounded because foreground service may not be properly wired.
- **Next:** Verify foreground service is active when playing; check AndroidManifest.xml foreground service type

---

## Features Completed ✅

- [x] **Queue system** — full port from v3 (long-press menu, queue sheet, drain on completion, queue icon)
- [x] **Gengar empty state** — ghost image when no album selected
- [x] **Audio interruption handling** — pauses on phone calls/Siri
- [x] **Snackbar/bottom sheet polish** — deepPurple.shade800, green.shade800

---

## Features to Revisit Later

- [ ] **Fix launcher icon** — replace mipmaps from v3
- [ ] **Background audio** — verify foreground service wiring
- [ ] **Auto-select album on boot** — was removed due to infinite loading bug

---

## Current Working State
- **Commit:** `653dd8b` ("Add full queue system from v3")
- **APK:** Rebuild after mipmap update recommended
- **Key Files:**
  - `lib/main.dart` — main UI + queue
  - `lib/audio_handler.dart` — audio_service + AudioSession handling
  - `assets/gengar.jpg` — empty state ghost
  - `assets/icon/app_icon.png` — outdated, replace from v3

---

## Recent Commits
- `653dd8b` Add full queue system from v3
- `dea64f7` Add gengar empty state, audio interruption handling, queue UI polish
- `d967fb9` fix startup speed: await AudioService.init in main()
- `4aab1ba` audio_service: live notification + playback controls