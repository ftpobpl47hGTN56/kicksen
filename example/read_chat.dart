// Prints live chat of a Kick channel. Usage: dart run example/read_chat.dart <channel>
import 'dart:io';

import 'package:kick_chat/kick_chat.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/read_chat.dart <channel>');
    exit(64);
  }

  final client = KickChatClient();
  client.status.listen((s) => stderr.writeln('[status] $s'));

  await client.connect(args.first);

  await for (final msg in client.messages) {
    stdout.writeln('${msg.sender.username}: ${msg.content}');
  }
}
