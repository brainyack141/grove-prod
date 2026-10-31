# Grove

Grove is an iOS plant-care app. Point the camera at a plant to identify it and
check its health, keep a journal of photos over time, get watering and care
reminders tuned to local weather, and ask a botanist assistant follow-up
questions. It works offline-first and syncs when an account is signed in. A
companion Apple Watch app and Live Activities cover watering and plant-sitting.

## Tech stack

- **iOS app**: Swift 6, SwiftUI, iOS 18+, with a watchOS app, widget and Live
  Activity extension. The Xcode project is generated from `project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- **Packages**: GoogleSignIn, RevenueCat (subscriptions), Vortex and Pow
  (effects).
- **Backend**: Supabase (Postgres, Auth, Edge Functions in TypeScript under
  `supabase/functions/`), with Google Gemini for plant analysis. `Backend/` is
  a Node server used for local development.

## Building

1. Install Xcode 26 and XcodeGen (`brew install xcodegen`).
2. Copy the secrets template and fill in the values:

   ```bash
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```

   Set `GROVE_APP_KEY`, `GROVE_ANALYSIS_URL` and `GROVE_SYNC_URL` for your own
   gateway. `Config/Secrets.xcconfig` is gitignored and must never be
   committed. With any value left empty the app still builds and runs, but the
   services that need it are disabled and a config error is logged. Release
   builds refuse to build without them.
3. Generate the project and build:

   ```bash
   xcodegen generate
   open Grove.xcodeproj
   ```

### Signing

The Apple developer team comes from `DEVELOPMENT_TEAM` in
`Config/Grove.xcconfig`, which every target uses. To sign with your own team,
set `DEVELOPMENT_TEAM = <your team id>` in `Config/Secrets.xcconfig`, and change
the `nz.co.thinkingai.*` bundle identifiers, App Group and URL scheme in
`project.yml` to ones registered to your team.

### Running on a physical iPhone

`scripts/dev-phone.sh` (local backend), `scripts/prod-phone.sh` (Release
against production) and `scripts/visual-tour.sh` (UI screenshot tour) build and
install on a connected iPhone. No device identifier is committed; set it first:

```bash
export GROVE_DEVICE_ID=<device UDID>        # xcrun xctrace list devices
export GROVE_DEVICECTL_ID=<CoreDevice id>   # optional; xcrun devicectl list devices
./scripts/dev-phone.sh
```

`GROVE_DEVICECTL_ID` defaults to `GROVE_DEVICE_ID`. Either can also go in
`.env.production` (see `.env.example`). The scripts stop with an error if
`GROVE_DEVICE_ID` is unset.

Backend tests run with `cd Backend && npm install && npm test`. Release and
deployment steps are in `Backend/DEPLOY.md`.
