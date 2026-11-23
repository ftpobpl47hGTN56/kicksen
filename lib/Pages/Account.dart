import 'dart:io';

import '/Accounts/AccountModel.dart';
import '/Accounts/AccountsCubit.dart';
import '/Components/Modal/TokenModal.dart';
import '/Components/UI/CustomSliverAppBarDelegate.dart';
import '/Components/UI/NoAppBarBlur.dart';
import '/Components/UI/Tile.dart';
import '/Pages/OAuth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_chatsen_irc/Twitch.dart' as twitch;
import '/Components/UserPrefs.dart';
import '/kick_account.dart';

class AccountPage extends StatefulWidget {
  final twitch.Client client;

  const AccountPage({
    Key? key,
    required this.client,
  }) : super(key: key);

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final TextEditingController searchController = TextEditingController();

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: InkWell(
          onLongPress: () async => TokenModal.show(
            context,
            client: widget.client,
          ),
          child: FloatingActionButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => OAuthPage(
                  client: widget.client,
                ),
              ),
            ),
            // : () {},
            child: Icon(Icons.add),
          ),
        ),
        appBar: NoAppBarBlur(),
        body: BlocBuilder<AccountsCubit, List<AccountModel>>(
          builder: (context, state) {
            var listChildren = [
              for (var account in [AccountsCubit.defaultAccount, ...state].where((account) => account.login!.toLowerCase().contains(searchController.text.toLowerCase())))
                Tile(
                  leading: Padding(
                    padding: EdgeInsets.all(account.token != null ? 0.0 : 8.0),
                    child: account.token != null && account.avatarBytes != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(128.0),
                            child: Image.memory(
                              account.avatarBytes!,
                              height: 32.0 + 8.0,
                            ),
                          )
                        : Icon((Platform.isMacOS || Platform.isIOS) ? CupertinoIcons.question_circle : Icons.hide_source),
                  ),
                  trailing: account != AccountsCubit.defaultAccount
                      ? Padding(
                          padding: EdgeInsets.all(0.0),
                          child: IconButton(
                            icon: Icon((Platform.isMacOS || Platform.isIOS) ? CupertinoIcons.trash_fill : Icons.delete),
                            onPressed: () async {
                              if (account.isActive == true) {
                                await widget.client.swapCredentials(
                                  twitch.Credentials(
                                    clientId: AccountsCubit.defaultAccount.clientId,
                                    id: AccountsCubit.defaultAccount.id,
                                    login: AccountsCubit.defaultAccount.login!,
                                    token: AccountsCubit.defaultAccount.token,
                                  ),
                                );
                              }
                              await BlocProvider.of<AccountsCubit>(context).remove(account);
                            },
                          ),
                        )
                      : null,
                  title: account.token != null ? '${account.login}' : tr('Anonymous User', 'Анонимный пользователь'),
                  subtitle: !kDebugMode ? null : (account.token != null ? '${account.clientId}' : tr('Login as ${account.login}', 'Войти как ${account.login}')),
                  onTap: () async {
                    var accountsCubit = BlocProvider.of<AccountsCubit>(context);
                    var navigator = Navigator.of(context);

                    try {
                      final selected = await refreshKickAccount(account);
                      await widget.client.swapCredentials(kickCredentials(selected));
                      if (selected.token != null) await accountsCubit.setActive(selected);
                      if (navigator.canPop()) navigator.pop();
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(tr('Could not activate Kick account: $e', 'Не удалось выбрать аккаунт Kick: $e')),
                        behavior: SnackBarBehavior.floating,
                      ));
                    }
                  },
                ),
            ];

            return CustomScrollView(
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 128.0 * 1.5,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16.0) + EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: 24.0),
                          Row(
                            children: [
                              // Container(
                              //   width: 24.0,
                              //   height: 24.0,
                              //   child: IconButton(
                              //     icon: Icon((Platform.isIOS || Platform.isMacOS) ? Icons.arrow_back_ios : Icons.arrow_back),
                              //     onPressed: () => Navigator.of(context).pop(),
                              //     padding: EdgeInsets.zero,
                              //     iconSize: 24.0,
                              //   ),
                              // ),
                              IconButton(
                                icon: Icon((Platform.isIOS || Platform.isMacOS) ? Icons.arrow_back_ios : Icons.arrow_back),
                                onPressed: () => Navigator.of(context).pop(),
                                padding: EdgeInsets.zero,
                                iconSize: 24.0,
                              ),
                            ],
                          ),
                          Spacer(),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0),
                            child: Text(
                              tr('Accounts', 'Аккаунты'),
                              style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                                    color: Theme.of(context).colorScheme.onSurface,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverPersistentHeader(
                  // pinned: true,
                  floating: true,
                  delegate: CustomSliverAppBarDelegate(
                    minHeight: 64.0 + MediaQuery.paddingOf(context).top,
                    maxHeight: 64.0 + MediaQuery.paddingOf(context).top,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0) + EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
                      child: Material(
                        borderRadius: BorderRadius.circular(64.0),
                        color: Theme.of(context).colorScheme.surface,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24.0),
                          child: Center(
                            child: Row(
                              children: [
                                Icon(Icons.search),
                                SizedBox(
                                  width: 12.0,
                                ),
                                Expanded(
                                  child: TextField(
                                    controller: searchController,
                                    decoration: InputDecoration(
                                      hintText: tr('Search accounts', 'Поиск аккаунтов'),
                                      isDense: true,
                                      filled: false,
                                      border: InputBorder.none,
                                    ),
                                    onChanged: (value) => setState(() {}),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) => listChildren[index],
                    childCount: listChildren.length,
                  ),
                ),
              ],
            );
          },
        ),
      );
}
