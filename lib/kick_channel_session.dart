import 'dart:async';

import 'package:kick_chat/kick_chat.dart';
import 'package:kick_chat/kick_emotes.dart';
import 'package:material_ui/material_ui.dart';

/// Mutable UI state for one independently connected channel tab.
class KickChannelSession {
  KickChannelSession(this.channel);

  final String channel;
  final client = KickChatClient();
  final composerController = TextEditingController();
  final scrollController = ScrollController();
  final messages = <KickChatMessage>[];
  var emotes = <String, KickEmote>{};

  StreamSubscription<KickChatMessage>? messageSubscription;
  StreamSubscription<KickChatStatus>? statusSubscription;

  var status = KickChatStatus.disconnected;
  String? error;
  var generation = 0;
  var unread = 0;
  var sending = false;
  var scrollScheduled = false;

  bool get isConnecting =>
      status == KickChatStatus.resolving ||
      status == KickChatStatus.connecting ||
      status == KickChatStatus.reconnecting;

  bool get isConnected => status == KickChatStatus.connected;

  Future<void> dispose() async {
    generation++;
    await messageSubscription?.cancel();
    await statusSubscription?.cancel();
    await client.dispose();
    composerController.dispose();
    scrollController.dispose();
  }
}
