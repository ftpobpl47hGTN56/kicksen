# ChatsenKick

**Chatsen Mod, ported to Kick.** An Android chat client that combines the familiar Chatsen Mod interface and customization options with Kick chat, OAuth authorization, channels, and emotes.

[Releases](https://github.com/ftpobpl47hGTN56/kicksen/releases) · [Ready release draft](RELEASE_DRAFT.md) · [Draft release template](.github/RELEASE_TEMPLATE.md)

## Screenshots

<table>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/0a38f54a-37f8-4c5d-ad7b-df3c89bb45a3" alt="photo_1" /></td>
    <td><img src="https://github.com/user-attachments/assets/eb799aed-e9c6-466e-9532-b3ff31ecdc91" alt="photo_2" /></td>
    <td><img src="https://github.com/user-attachments/assets/32543904-13de-4303-8fda-c134679bfa34" alt="photo_3" /></td>
    <td><img src="https://github.com/user-attachments/assets/3dfebffe-0668-40ef-b792-b70a6e31cbb0" alt="photo_4" /></td>
  </tr>
</table>

## Features

- **Kick chat in real time:** read chat anonymously or sign in with Kick OAuth to send messages.
- **Multiple channels and accounts:** switch between channel tabs, add several comma-separated usernames at once, and keep a local channel list in Hive.
- **Online status:** LIVE state, viewer count, category, and stream title from the official `api.kick.com/public/v1` API.
- **Emotes and badges:** Kick emotes, 7TV, BTTV, FFZ, subscriber badges, an emote picker, and consistent inline emote sizing.
- **Conversations:** replies, threads, mentions, username autocomplete, user cards, and a searchable viewer list.
- **Media and links:** image, GIF, video, and link previews.
- **Chat customization:** font size, timestamps, line separators, mention styles, filters, and ignored users.
- **Chatsen Mod extras:** local preferences, channel history, notifications where supported, and backup/restore options.

## Download and install

1. Open [Releases](https://github.com/ftpobpl47hGTN56/kicksen/releases) and download the latest `ChatsenKick-...-release.apk`.
2. Allow installation from your browser or file manager if Android asks for permission.
3. Install the APK. Reading chat works without an account; sending messages requires Kick sign-in.

**Supported platform:** Android 7.0 (API 24) and newer.

## Build from source

Requirements: Flutter stable, Android SDK, and JDK 17 or newer.

```bash
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/`. The Gradle configuration automatically adds the app version, build number, date, time, and build type to its filename.

## OAuth configuration

The app uses Kick OAuth 2.1 with PKCE. The source of the optional Cloudflare Worker used for the authorization-code exchange is included in [`oauth_proxy`](oauth_proxy).

The public client ID and the deployed Worker URL are configured in [`lib/kick_app_config.dart`](lib/kick_app_config.dart). To use your own Worker, update `oauth_proxy/wrangler.toml`, set `KICK_CLIENT_SECRET` with `npx wrangler secret put`, deploy it, and replace the Worker URL in the app configuration.

## License and credits

Based on [Chatsen](https://github.com/chatsen/chatsen) and Chatsen Mod. Distributed under the GNU AGPLv3 license; see [LICENSE](LICENSE). Kick is a trademark of its respective owner. This project is unofficial and is not affiliated with or endorsed by Kick.
