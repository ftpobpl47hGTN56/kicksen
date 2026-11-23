import 'package:flutter_chatsen_irc/Twitch.dart' as twitch;

import 'Accounts/AccountModel.dart';
import 'kick_app_config.dart';
import 'kick_oauth.dart';

twitch.Credentials kickCredentials(AccountModel account) => twitch.Credentials(
      clientId: account.clientId ?? kKicksenClientId,
      id: account.id,
      login: account.login ?? 'anonymous',
      token: account.token,
    );

Future<AccountModel> refreshKickAccount(AccountModel account) async {
  if (account.token == null) return account;
  final expiresAt = account.tokenExpiresAt;
  if (expiresAt == null || DateTime.now().isBefore(expiresAt.subtract(const Duration(minutes: 2)))) {
    return account;
  }

  final savedRefreshToken = account.refreshToken;
  if (savedRefreshToken == null || savedRefreshToken.isEmpty) {
    throw const KickOAuthException('Вход Kick истёк. Войдите в аккаунт заново.');
  }
  final oauth = createKickOAuth();
  if (oauth == null) throw const KickOAuthException('Сервер входа Kick не настроен.');

  final refreshed = await oauth.refresh(KickToken(
    accessToken: account.token!,
    refreshToken: savedRefreshToken,
    expiresAt: expiresAt,
    scope: '',
  ));
  account.token = refreshed.accessToken;
  account.refreshToken = refreshed.refreshToken.isNotEmpty ? refreshed.refreshToken : savedRefreshToken;
  account.tokenExpiresAt = refreshed.expiresAt;
  await account.save();
  return account;
}
