import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder_app/services/last_save_path_store.dart';

void main() {
  test('file store remembers a directory across instances', () async {
    final config = await Directory.systemTemp.createTemp('save_prefs_');
    addTearDown(() => config.delete(recursive: true));
    final folder = Directory(p.join(config.path, 'Videos'));
    await folder.create();

    final first = FileLastSavePathStore(configDir: config);
    await first.remember(p.join(folder.path, 'clip.mp4'));

    final second = FileLastSavePathStore(configDir: config);
    expect(await second.lastDirectory(), folder.path);
  });

  test('file store ignores a remembered folder that no longer exists', () async {
    final config = await Directory.systemTemp.createTemp('save_prefs_');
    addTearDown(() => config.delete(recursive: true));
    final folder = Directory(p.join(config.path, 'gone'));
    await folder.create();

    final store = FileLastSavePathStore(configDir: config);
    await store.remember(p.join(folder.path, 'clip.mp4'));
    await folder.delete(recursive: true);

    expect(await store.lastDirectory(), isNull);
  });
}
