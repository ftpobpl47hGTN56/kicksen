import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<File> kickLocalFile(String name) async {
  if (!Platform.isAndroid) return File(name);

  final directory = await getApplicationDocumentsDirectory();
  return File('${directory.path}/$name');
}
