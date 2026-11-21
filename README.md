# Kicksen

Cross-platform **Kick** chat client — a Chatsen-style app for [Kick.com](https://kick.com), built with Flutter/Dart. Work in progress.

## Status: prototype

This repository currently contains `kick_chat` — a pure-Dart package that reads live Kick chat in real time. The Flutter UI (ported from [Chatsen](https://github.com/chatsen/chatsen)) comes next.

## Quickstart

```bash
dart pub get
dart run example/read_chat.dart xqc   # any channel slug
```

No authentication is required for reading chat.

## How it works

1. Resolves the numeric `chatroom_id` for a channel slug via `kick.com/api/v2/channels/{slug}` (internal API — the official API does not expose it).
2. Connects to Kick's public Pusher WebSocket (`ws-us2.pusher.com`).
3. Subscribes to `chatrooms.{id}.v2` and parses `App\Events\ChatMessageEvent` frames.
4. Auto-reconnects on drops, keepalive ping every 30 s.

```dart
import 'package:kick_chat/kick_chat.dart';

final client = KickChatClient();
await client.connect('xqc');
await for (final msg in client.messages) {
  print('${msg.sender.username}: ${msg.content}');
}
```

Sending messages and moderation use the **official** Kick API (`api.kick.com/public/v1`) with OAuth 2.1 (PKCE) — see the roadmap.

## Roadmap

- [x] Live chat reader (Pusher WebSocket, no auth)
- [ ] OAuth 2.1 login + sending messages (official API, `chat:write`)
- [ ] Flutter UI ported from Chatsen (`components`, `pages`, `widgets`)
- [ ] 7TV / BTTV / FFZ emote providers (7TV already supports Kick)
- [ ] Multi-channel tabs, mentions, highlights

## Disclaimer

Unofficial project, not affiliated with Kick.com. The chatroom-lookup and Pusher endpoints are internal/undocumented and may break without notice; the official API is used wherever it exists.

## License

[GNU AGPL-3.0](LICENSE) — chosen for compatibility with Chatsen (AGPLv3), whose UI code will be ported here.

Credits: [Chatsen](https://github.com/chatsen/chatsen) for the original client architecture.
