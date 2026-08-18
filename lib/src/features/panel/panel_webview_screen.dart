import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_theme.dart';

/// Opens a Nova Server panel (or its mini-app) inside the client, so an owner
/// can manage their panel without leaving Nova. Just a hosted web view with a
/// progress bar and reload; the panel handles its own auth in-page.
class PanelWebviewScreen extends StatefulWidget {
  const PanelWebviewScreen({super.key, required this.url, this.title});

  final String url;
  final String? title;

  @override
  State<PanelWebviewScreen> createState() => _PanelWebviewScreenState();
}

class _PanelWebviewScreenState extends State<PanelWebviewScreen> {
  late final WebViewController _controller;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (int p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _progress = 100);
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final bool loading = _progress < 100;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? s.panelTitle,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            tooltip: s.nodeRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
        bottom: loading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress / 100,
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  color: nova.cyan,
                ),
              )
            : null,
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
