# Kicksen

Cross-platform **Kick** chat client — a Chatsen-style app for [Kick.com](https://kick.com), built with Flutter/Dart. Work in progress.

## Status

- Live Kick chat over the public Pusher WebSocket, without authentication.
- First Flutter screen: channel selection, connection status, live messages, replies, badges and Kick emotes.
- OAuth 2.1 (PKCE) login and sending through the official Kick API are available in the core and CLI example.
- OAuth and sending controls still need to be wired into the Flutter screen.

## Run the Windows app

Install Flutter 3.50.1 or newer and Visual Studio with the **Desktop development with C++** workload. Then, from the repository root:

```powershell
flutter create --project-name kick_chat --platforms=windows .
flutter pub get
flutter run -d windows
```

Enter a channel slug such as `xqc`, or paste a full `https://kick.com/xqc` link, and press **Подключиться**. No login is required to read chat.

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

1. **IDs**: resolves `channel_id` + `chatroom_id` for a slug via `kick.com/api/v2/channels/{slug}` (internal API). If Dart HTTP is blocked by Cloudflare, the client falls back to a `curl` subprocess.
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
| Flutter live-chat screen | Flutter Windows | First version |
| Flutter OAuth and sending controls | Official Kick API | Next |
| 7TV / BTTV emotes | Provider APIs | Planned |
| Multi-channel tabs | — | Planned |

## Disclaimer

Unofficial project, not affiliated with Kick.com. The chatroom-lookup, realtime-config and Pusher endpoints are internal/undocumented and may break without notice; the official API is used wherever it exists.

## License

[GNU AGPL-3.0](LICENSE) — chosen for compatibility with Chatsen (AGPLv3), whose UI code will be ported here.

Credits: [Chatsen](https://github.com/chatsen/chatsen) for the original client architecture; the Kounex/obs_blade project for documenting the 2026 realtime-config flow.
