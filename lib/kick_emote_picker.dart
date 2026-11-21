import 'package:kick_chat/kick_emote_image.dart';
import 'package:kick_chat/kick_emotes.dart';
import 'package:material_ui/material_ui.dart';

Future<KickEmote?> showKickEmotePicker({
  required BuildContext context,
  required Map<String, KickEmote> emotes,
}) {
  final items = emotes.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return showDialog<KickEmote>(
    context: context,
    builder: (_) => _KickEmotePickerDialog(emotes: items),
  );
}

class _KickEmotePickerDialog extends StatefulWidget {
  const _KickEmotePickerDialog({required this.emotes});

  final List<KickEmote> emotes;

  @override
  State<_KickEmotePickerDialog> createState() => _KickEmotePickerDialogState();
}

class _KickEmotePickerDialogState extends State<_KickEmotePickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.emotes
        .where((emote) => emote.name.toLowerCase().contains(_query))
        .toList();

    return AlertDialog(
      title: const Text('Эмоуты'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
              decoration: const InputDecoration(
                hintText: 'Найти эмоут…',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('Ничего не найдено'))
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 0.9,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final emote = filtered[index];
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => Navigator.of(context).pop(emote),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              children: [
                                Expanded(
                                  child: Center(
                                    child: KickEmoteImage(url: emote.imageUrl),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  emote.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                Text(
                                  emote.provider,
                                  style: const TextStyle(
                                    color: Color(0xFF9AA69B),
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
