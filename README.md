# Worm Arena — Flutter + WebSocket starter

A small original worm-survival multiplayer prototype (not the original Worms Zone app).
Includes:
- Create/join private rooms using a room code
- Lobby target of 4–8 players
- Match duration choices: 5, 7, or 10 minutes
- WebSocket server for room membership, timer, and player positions
- GitHub Actions workflow to build a debug APK

## Important
This is a starter prototype, not a finished commercial game. It does not copy Worms Zone assets or code. Multiplayer requires a publicly reachable WebSocket server. The included server is suitable for development/testing; add authentication, rate limiting, persistence, and production hosting before public release.

## Build the APK in GitHub Actions (no local Android SDK needed)
1. Create a GitHub repository and upload this project.
2. Push to the `main` branch.
3. Open **Actions** → **Build Android APK**.
4. When the workflow finishes, download the `worm-arena-debug-apk` artifact.
5. Extract it; install `app-debug.apk` on your Android phone. Android may ask you to allow installation from that source.

## Run locally
Install Flutter and Android SDK, then:
```bash
cd app
flutter pub get
flutter run
```

Run the server:
```bash
cd server
npm install
PORT=8080 npm start
```
For local testing, enter `ws://YOUR_COMPUTER_LAN_IP:8080` in the app. For internet play, deploy `server/` to a host that supports Node.js and WebSockets, enable TLS, and use `wss://YOUR_PUBLIC_HOST`.

## Gameplay notes
The current prototype synchronizes player dots and a countdown. It is a foundation to expand into full worm movement, food, collisions, growth, scoring, reconnects, and server-authoritative anti-cheat logic.
