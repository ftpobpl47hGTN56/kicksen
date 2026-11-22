# Kicksen

Cross-platform **Kick** chat client — a Chatsen-style app for [Kick.com](https://kick.com), built with Flutter/Dart. Work in progress.

## Status

- Live Kick chat over the public Pusher WebSocket, without authentication.
- Flutter screen: Chatsen-style channel tabs, independent live chats, unread counters, replies, badges and Kick emotes.
- Open channels and the selected tab are restored and reconnect automatically after restarting the app.
- 7TV global/channel emotes, BetterTTV global emotes and prefix autocomplete in the message composer.
- OAuth 2.1 (PKCE) login and sending through the official Kick API are available in the core, CLI example, Android app and Windows app.
- The Flutter app restores the saved OAuth session when possible; the client secret itself is never persisted.

## Get the Android APK

Every push to `main` triggers the **Android APK** GitHub Actions workflow. Open the latest successful run and download `kicksen-android-debug` from **Artifacts**, then extract and install `app-debug.apk` on your phone. Android may ask you to allow installation from this source.

No local Flutter, Dart or Android SDK installation is needed for this workflow. OAuth tokens and open channels are stored in the app's private Android storage.

### Configure Kick sign-in

Kick requires a confidential Client Secret for OAuth token exchange and refresh, so the Android app uses the Cloudflare Worker in `oauth_proxy/` instead of embedding that secret in the APK.

1. Install Node.js, open the `oauth_proxy` directory and run `npx wrangler login`.
2. Run `npx wrangler secret put KICK_CLIENT_SECRET` and enter the Kick application's secret.
3. Run `npx wrangler deploy`. The deployed Worker URL is configured in `lib/kick_app_config.dart`.
4. Re-run the **Android APK** workflow. The login dialog will then open Kick's official username/password page without asking for developer keys.

The Worker does not log in users itself or persist tokens; it only adds the server-held Client Secret to requests forwarded to Kick.

## Run the Windows app

Install Flutter 3.50.1 or newer and Visual Studio with the **Desktop development with C++** workload. Then, from the repository root:

```powershell
flutter create --project-name kick_chat --platforms=windows .
flutter pub get
flutter run -d windows
```

On the home tab, enter a channel slug such as `xqc`, or paste a full `https://kick.com/xqc` link, and press **Добавить канал**. Each channel keeps its own connection, messages, composer and emote set while you switch tabs. Open channels and the selected tab are saved locally and reconnect automatically on the next launch; Windows uses the gitignored `.kick_channels.json` file, while Android uses private app storage. Message history is not persisted. No login is required to read chat.

To send messages, press **Войти** and sign in on Kick's official page. The app listens on localhost and completes the login automatically; no callback URL copying or developer keys are needed in the app. Once connected and signed in, type in the bottom field and press Enter. Typing at least two characters of a loaded 7TV/BTTV emote name opens autocomplete; select an item to insert its code. The client secret stays in memory; only the token cache is persisted locally.

## Quickstart: read a channel from Dart

```powershell
dart pub get
dart run example/read_chat.dart xqc
```

```dart
import 'package:kick_chat/kick_chat.dart';

final client = KickChatClient();
await client.connect('xqc');
await for (final msg in client.messages) {
  print('${msg.sender.username}: ${msg.content}');
}
```

## Quickstart: log in and send messages

1. Enable 2FA on kick.com, then create an app at **kick.com → Settings → Developer** with redirect URI `http://localhost:3000/callback`.
2. Set `KICK_CLIENT_ID` and `KICK_CLIENT_SECRET` in your shell, then run:

```powershell
dart run example/send_chat.dart <channel>
```

The first run prints an authorization URL. Open it, approve access, and paste the complete localhost redirect URL back into the terminal. The token is cached in `.kick_token.json` (gitignored) and refreshed automatically. Every following input line is posted through the official Kick API.

Never commit OAuth client secrets or `.kick_token.json`.

## How reading works

1. **IDs**: resolves `channel_id` + `chatroom_id` for a slug via `kick.com/api/v2/channels/{slug}` (internal API). On desktop, if Dart HTTP is blocked by Cloudflare, the client falls back to a `curl` subprocess; Android uses Dart HTTP directly.
2. **Realtime config**: requests the current per-channel Pusher `app_key` and `cluster` from Kick's realtime endpoint. A compiled-in fallback is used if that request fails.
3. **Socket**: subscribes to `chatrooms.{chatroom_id}.v2`, parses `App\Events\ChatMessageEvent` frames, sender colors, badges and replies. Keepalive runs every 30 seconds; dropped connections reconnect automatically.
4. Kick emotes arrive as `[emote:{id}:{name}]`; the Flutter screen resolves them through `https://files.kick.com/emotes/{id}/fullsize`.

## API coverage

| Feature | Mechanism | Status |
|---|---|---|
| Read live chat | Pusher WebSocket, dynamic config | Tested live |
| OAuth 2.1 login (PKCE, refresh, revoke) | `id.kick.com` | Core and CLI tested |
| Send message (user / bot, replies) | Official `POST /public/v1/chat` | Core and CLI tested |
| Delete message | Official `DELETE /public/v1/chat/{id}` | Implemented |
| Flutter live-chat screen | Flutter Android and Windows | First version |
| Flutter OAuth and sending controls | Official Kick API | Implemented in Android and Windows apps |
| 7TV global + Kick channel emotes | 7TV v3 API | Implemented |
| BTTV global emotes | BetterTTV public API | Implemented |
| Emote autocomplete | Flutter composer | Implemented |
| Multi-channel tabs | Independent sessions, unread counters | Implemented |

## Disclaimer

Unofficial project, not affiliated with Kick.com. The chatroom-lookup, realtime-config and Pusher endpoints are internal/undocumented and may break without notice; the official API is used wherever it exists.

## License

[GNU AGPL-3.0](LICENSE) — chosen for compatibility with Chatsen (AGPLv3), whose UI code will be ported here.

Credits: [Chatsen](https://github.com/chatsen/chatsen) for the original client architecture; the Kounex/obs_blade project for documenting the 2026 realtime-config flow.
