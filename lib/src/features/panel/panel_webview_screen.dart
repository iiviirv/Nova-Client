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

  /// The URL of the page currently loading/loaded, so an HTTP error can be
  /// attributed to the page itself rather than to one of its sub-resources.
  String? _pageUrl;

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
        onPageStarted: (String url) {
          _pageUrl = url;
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
          // Android reports this for EVERY resource: a missing favicon or a
          // blocked tracker must not flip the page into an error. Only the
          // page itself counts (the platform gives no main-frame flag, so
          // match the URL). And 401/403 are the panel asking for a login,
          // not a dead page: leave the webview up, it renders the panel's own
          // login or the Basic-auth dialog below. A tester's panel was hidden
          // behind "HTTP 401" exactly this way on the first 1.13 build.
          final int? code = e.response?.statusCode;
          final String? failed = e.request?.uri.toString();
          final bool isPage = failed != null &&
              (failed == _pageUrl || _sameDoc(failed, widget.url));
          if (!isPage || code == null || mounted == false) return;
          if (code == 401 || code == 403) return;
          if (code == 404 || code >= 500) {
            setState(() {
              _progress = 100;
              _error = 'HTTP $code';
            });
          }
        },
        // A panel behind HTTP Basic auth (many Nova Server panels are) sends
        // 401 + WWW-Authenticate; without this handler the webview cancels the
        // request and shows a blank 401. Ask for the credentials and answer.
        onHttpAuthRequest: (HttpAuthRequest req) => _askCredentials(req),
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  /// Same document ignoring a trailing slash and the fragment.
  static bool _sameDoc(String a, String b) {
    String norm(String u) {
      final int hash = u.indexOf('#');
      if (hash >= 0) u = u.substring(0, hash);
      while (u.endsWith('/')) {
        u = u.substring(0, u.length - 1);
      }
      return u;
    }

    return norm(a) == norm(b);
  }

  Future<void> _askCredentials(HttpAuthRequest req) async {
    if (!mounted) {
      req.onCancel();
      return;
    }
    final NovaStrings s = NovaStrings.of(context);
    final TextEditingController user = TextEditingController();
    final TextEditingController pass = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.panelSignIn),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(req.realm?.isNotEmpty == true ? '${req.host} (${req.realm})' : req.host,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: user,
              autofocus: true,
              autocorrect: false,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(labelText: s.panelUsername),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pass,
              obscureText: true,
              autocorrect: false,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(labelText: s.panelPassword),
              onSubmitted: (_) => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(s.cancel)),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(s.panelSignIn)),
        ],
      ),
    );
    if (ok == true) {
      req.onProceed(WebViewCredential(user: user.text, password: pass.text));
    } else {
      req.onCancel();
    }
    user.dispose();
    pass.dispose();
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
