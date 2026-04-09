# Lob Music — Remaining Tasks

## Known Issues

### 1. App Icon — Lobster image not showing
- **Status:** In progress
- **Problem:** APK contains correct icon assets (`micon.png` hashed correctly), Android shows generic robot instead
- **Last attempt:** Used `flutter_launcher_icons` to generate mipmaps from `assets/icon/app_icon.png`
- **Next:** Try `adb shell pm clear com.justinh.lob.lob_music` to clear icon cache, or investigate Android adaptive icon XML config

### 2. Background Audio + Media Notification
- **Status:** Blocked
- **Problem:** Music stops when app is backgrounded
- **Root cause:** `just_audio` alone doesn't keep app alive; needs `audio_service` + foreground service
- **Next:** Requires `audio_service` package + BackgroundPlayer handler refactor (significant architectural change)

---

## Features to Revisit Later

- [ ] **Fix launcher icon** — Android icon cache cleared, try `adb install -r` with `--clear-icon-cache`
- [ ] **Background audio** — Requires `audio_service` + foreground service (deferred)
- [ ] **Auto-select album on boot** — Was removed due to infinite loading bug; revisit once background audio is stable

---

## Current Working State
- **Commit:** `a36118a` ("Add flutter_launcher_icons with proper adaptive icon for Android 8+")
- **Last stable commit:** `ef42da4` (before icon change attempt)
- **APK:** `~/Documents/lob_music-debug.apk`

## Key Files
- `lib/main.dart` — main UI
- `assets/icon/app_icon.png` — source icon (micon.png)
- `android/app/src/main/res/` — Android resources (mipmaps, drawables, adaptive icons)
