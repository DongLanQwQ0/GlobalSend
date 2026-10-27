# GlobalSend local releases

- Native release workflow: `npm run release:local`. After each successful native build, update the complete Windows bundle in `E:\Programs\GlobalSend` and restart GlobalSend; push the APK to the connected physical Android phone, install with `adb install -r`, and launch it. Preserve application data. Do not host installers on the server.
- Keep project-specific builds, logs, screenshots and temporary files inside this project. Reusable SDK/cache/download content belongs on F:. Do not read the user's SSH private keys.
- Preserve the single-instance protocol, tray receiver lifetime, existing state and transfer entry points when editing native startup or release tooling.
- Browser automation must reuse the same established persistent profile and preserve login state. Never create a new profile per run (including random or mkdtemp user-data-dir). Run profile-sharing browser jobs serially; if occupied, wait or reuse the existing session rather than deleting locks, force-closing the user's browser, or switching to a fresh profile. Keep per-run reports/screenshots separate from the persistent profile.
