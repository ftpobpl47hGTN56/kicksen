# Kicksen

Cross-platform **Kick** chat client — a Chatsen-style app for [Kick.com](https://kick.com), built with Flutter/Dart. Work in progress.

## Status: chat core working

`kick_chat` is a pure-Dart package that already does the two hardest parts:

- **Reading** live chat in real time over Kick's Pusher WebSocket — no auth.
- **Writing** to chat via the **official** Kick API with OAuth 2.1 (PKCE) login.

The Flutter UI (ported from [Chatsen](https://github.com/chatsen/chatsen)) comes next.

## Quickstart: read a channel

```bash
dart pub get
dart run example/read_chat.dart xqc   # any channel slug
```

No authentication needed.

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
2. Export credentials and run:

```bash
export KICK_CLIENT_ID=... KICK_CLIENT_SECRET=...
dart run example/send_chat.dart <channel>
```

The first run prints an authorization URL — open it, approve, and paste the redirect URL back. The token is cached in `.kick_token.json` (gitignored) and refreshed automatically. Then every line you type is posted to the channel's chat through `POST /public/v1/chat`.

```dart
import 'package:kick_chat/kick_oauth.dart';
import 'package:kick_chat/kick_api.dart';

final oauth = KickOAuth(clientId: id, clientSecret: secret, redirectUri: uri);
final pkce = KickOAuth.generatePkce();
print(oauth.buildAuthorizationUrl(
  scopes: ['user:read', 'channel:read', 'chat:write'],
  pkce: pkce,
));
// ... user authorizes, you get ?code=...&state=... back ...
final token = await oauth.exchangeCode(code: code, pkce: pkce);

final api = KickApiClient(accessToken: token.accessToken);
final me = await api.getCurrentUser();
final channel = await api.getChannelBySlug('xqc');
await api.sendMessage(
  broadcasterUserId: channel!.broadcasterUserId,
  content: 'Hello from Kicksen!',
);
```

## How reading works

1. **IDs**: resolves `channel_id` + `chatroom_id` for a slug via `kick.com/api/v2/channels/{slug}` (internal API). The endpoint sits behind Cloudflare: if Dart's TLS fingerprint gets blocked (HTTP 403), the client automatically falls back to a `curl` subprocess; you can also pass browser-resolved IDs via `connectByIds()`.
2. **Realtime config**: since October 2026 the Pusher app is dynamic and per-channel — the client asks `POST web.kick.com/api/v1/realtime/channels/{id}/chat/connection` for the current `app_key` + `cluster` (the old hardcoded key now returns Pusher error 4001). A compiled-in fallback config is used if the endpoint is unreachable, and a fatal Pusher error (4000–4099) triggers a re-resolution.
3. **Socket**: subscribes to `chatrooms.{chatroom_id}.v2`, parses `App\Events\ChatMessageEvent` frames (sender color, badges, replies). Keepalive ping every 30 s, auto-reconnect on drops.
4. Emotes arrive as `[emote:{id}:{name}]` tokens; full-size images at `https://files.kick.com/emotes/{id}/fullsize` (helper: `kickEmoteUrl`).

## API coverage

| Feature | Mechanism | Status |
|---|---|---|
| Read live chat | Pusher WebSocket (no auth, dynamic config) | ✅ tested live |
| OAuth 2.1 login (PKCE, refresh, revoke) | `id.kick.com` | ✅ |
| Send message (as user / bot, replies) | `POST /public/v1/chat` | ✅ |
| Delete message | `DELETE /public/v1/chat/{id}` | ✅ |
| Current user / channel info | `GET /public/v1/users`, `/channels` | ✅ |
| Flutter UI (from Chatsen) | — | ⬜ |
| 7TV / BTTV emotes | — | ⬜ |
| Multi-channel tabs | — | ⬜ |

## Disclaimer

Unofficial project, not affiliated with Kick.com. The chatroom-lookup, realtime-config and Pusher endpoints are internal/undocumented and may break without notice; the official API is used wherever it exists.

## License

[GNU AGPL-3.0](LICENSE) — chosen for compatibility with Chatsen (AGPLv3), whose UI code will be ported here.

Credits: [Chatsen](https://github.com/chatsen/chatsen) for the original client architecture; the Kounex/obs_blade project for documenting the 2026 realtime-config flow.
