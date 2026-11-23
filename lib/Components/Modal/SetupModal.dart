import 'package:flutter/material.dart';
import 'package:flutter_chatsen_irc/Twitch.dart' as twitch;

import '/Components/UI/BlurModal.dart';
import '/Components/UserPrefs.dart';

class SetupModal extends StatelessWidget {
  final twitch.Client client;

  const SetupModal({Key? key, required this.client}) : super(key: key);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Welcome to Chatsen Kick!', 'Добро пожаловать в Chatsen Kick!'), style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(tr(
              'Add Kick channels with the + button. Reading chat works without an account; to send messages, log in through Settings → Accounts.',
              'Добавляйте каналы Kick кнопкой ＋. Читать чат можно без аккаунта; для отправки сообщений войдите через Настройки → Аккаунты.',
            )),
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(tr('Continue', 'Продолжить')),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ],
        ),
      );

  static Future<void> show(BuildContext context, twitch.Client client) async => BlurModal.show(
        context: context,
        child: SetupModal(client: client),
      );
}
