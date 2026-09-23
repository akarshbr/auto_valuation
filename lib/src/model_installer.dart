import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'exceptions.dart';

/// whisper.cpp needs a real filesystem path, but Flutter assets live inside
/// the app bundle. This copies the model out once and reuses it afterwards.
///
/// A small marker file records the installed size, so on every launch after
/// the first the asset is *not* loaded into memory just to compare lengths -
/// a 30-100 MB read that used to happen on each start.
class WhisperModelInstaller {
  const WhisperModelInstaller();

  /// Returns the on-disk path of [assetPath], copying it out on first run.
  ///
  /// Throws [ModelLoadException] if the asset is missing from the bundle or
  /// cannot be written to app storage.
  Future<String> ensureInstalled(String assetPath) async {
    final directory = await getApplicationSupportDirectory();
    final fileName = assetPath.split('/').last;
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    final marker = File('${file.path}.installed');

    if (await _isInstalled(file, marker)) return file.path;

    try {
      final data = await rootBundle.load(assetPath);
      await file.parent.create(recursive: true);
      // Write via a temp file so a crash mid-copy never leaves a truncated
      // model that passes the size check.
      final temp = File('${file.path}.part');
      await temp.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await temp.rename(file.path);
      await marker.writeAsString('${data.lengthInBytes}', flush: true);
      return file.path;
    } on FileSystemException catch (error) {
      throw ModelLoadException('Could not install speech model: ${error.message}');
    } catch (error) {
      // rootBundle.load throws a FlutterError for a missing asset.
      throw ModelLoadException('Could not load asset "$assetPath": $error');
    }
  }

  Future<bool> _isInstalled(File file, File marker) async {
    if (!await file.exists() || !await marker.exists()) return false;
    final expected = int.tryParse((await marker.readAsString()).trim());
    return expected != null && expected > 0 && await file.length() == expected;
  }
}
