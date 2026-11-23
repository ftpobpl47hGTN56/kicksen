import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_chatsen_irc/Kick.dart';
import 'package:flutter_chatsen_irc/Twitch.dart' as twitch;
import 'package:http/http.dart' as http;

import '/Accounts/AccountModel.dart';
import '/Accounts/AccountsCubit.dart';
import '/Commands/Command.dart';
import '/Components/UI/BlurModal.dart';
import '/Components/UserPrefs.dart';
import '/kick_account.dart';
import '/kick_app_config.dart';

class TokenModal extends StatefulWidget {
  final twitch.Client client;
  final Command? command;

  const TokenModal({Key? key, this.command, required this.client}) : super(key: key);

  @override
  State<TokenModal> createState() => _TokenModalState();

  static Future<void> show(BuildContext context, {Command? command, required twitch.Client client}) async {
    await BlurModal.show(context: context, child: TokenModal(command: command, client: client));
  }
}

class _TokenModalState extends State<TokenModal> {
  late TextEditingController tokenController;
  bool busy = false;

  @override
  void initState() {
    tokenController = TextEditingController(text: widget.command?.trigger);
    super.initState();
  }

  @override
  void dispose() {
    tokenController.dispose();
    super.dispose();
  }

  Future<void> _addAccount() async {
    final token = tokenController.text.trim();
    if (token.isEmpty || busy) return;
    setState(() => busy = true);
    try {
      final api = KickApiClient(accessToken: token);
      final Map<String, dynamic> user;
      try {
        user = await api.getCurrentUser();
      } finally {
        api.dispose();
      }
      final avatarUrl = user['profile_picture'] as String?;
      final avatarBytes = avatarUrl == null || avatarUrl.isEmpty
          ? null
          : (await http.get(Uri.parse(avatarUrl))).bodyBytes;
      if (!mounted) return;

      final cubit = BlocProvider.of<AccountsCubit>(context);
      final userId = user['user_id'] as int;
      var account = cubit.state.firstWhereOrNull((model) => model.id == userId);
      if (account == null) {
        account = AccountModel(id: userId);
        await cubit.add(account);
      }
      account
        ..clientId = kKicksenClientId
        ..token = token
        ..refreshToken = null
        ..tokenExpiresAt = null
        ..login = user['name'] as String
        ..avatarBytes = avatarBytes;
      await account.save();
      await cubit.setActive(account);
      await widget.client.swapCredentials(kickCredentials(account));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Invalid Kick token: $e', 'Недействительный токен Kick: $e')),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
          child: ListView(
            shrinkWrap: true,
            children: [
              TextField(
                controller: tokenController,
                obscureText: true,
                decoration: InputDecoration(
                  filled: true,
                  labelText: tr('Kick access token', 'Токен доступа Kick'),
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: busy ? null : _addAccount,
                icon: const Icon(Icons.add),
                label: Text(tr('Add account', 'Добавить аккаунт')),
                style: ButtonStyle(
                  padding: WidgetStateProperty.all(const EdgeInsets.all(16.0)),
                  shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(32.0))),
                ),
              ),
            ],
          ),
        ),
      );
}
