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

  /// Set when the page failed to load (no network, DNS, 404 from the server).
  /// Rendering an explicit error with a Retry beats a blank view that looks
  /// hung: the user always has the AppBar back arrow, and now a reason.
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (int p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageStarted: (_) {
          if (mounted) setState(() => _error = null);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _progress = 100);
        },
        onWebResourceError: (WebResourceError e) {
          // Only the main frame: a blocked tracker or a missing favicon must
          // not flip the whole page into an error.
          if (e.isForMainFrame == false) return;
          if (mounted) {
            setState(() {
              _progress = 100;
              _error = e.description;
            });
          }
        },
        onHttpError: (HttpResponseError e) {
          final int? code = e.response?.statusCode;
          if (code != null && code >= 400 && mounted) {
            setState(() {
              _progress = 100;
              _error = 'HTTP $code';
            });
          }
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
      body: _error == null
          ? WebViewWidget(controller: _controller)
          : _LoadError(
              message: _error!,
              url: widget.url,
              onRetry: () {
                setState(() {
                  _error = null;
                  _progress = 0;
                });
                _controller.loadRequest(Uri.parse(widget.url));
              },
            ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError(
      {required this.message, required this.url, required this.onRetry});
  final String message;
  final String url;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_off_rounded, size: 40, color: nova.muted),
            const SizedBox(height: 16),
            Text(s.panelLoadFailed,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: nova.muted)),
            const SizedBox(height: 4),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(url,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(s.nodeRefresh),
            ),
          ],
        ),
      ),
    );
  }
}
