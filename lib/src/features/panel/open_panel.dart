import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'panel_webview_screen.dart';

/// Opens the user's Nova Server admin panel at [uri].
///
/// In-app on Android, iOS and macOS, where `webview_flutter` has a backend.
/// On Windows and Linux it has none: the embedded view rendered as a blank
/// grey surface with no way out (the reported "stuck until restart"), so there
/// the panel opens in the system browser instead, which is also where a
/// desktop user would rather manage a panel anyway.
Future<void> openPanel(BuildContext context, Uri uri, {String? title}) async {
  final bool webviewSupported =
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  if (webviewSupported) {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PanelWebviewScreen(url: uri.toString(), title: title),
    ));
    return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
