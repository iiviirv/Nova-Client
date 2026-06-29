import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/proxy_profile.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import '../profiles/profiles_controller.dart';
import 'cloudflare_controller.dart';
import 'deploy_screen.dart';
import 'nova_cloudflare.dart';

/// "Connect Cloudflare" hub: sign in to a Cloudflare account, see the Workers /
/// KV / D1 on it, deploy a new Nova panel, and pull a worker's configs into the
/// app. Mirrors the native Android hub.
class CloudflareScreen extends StatelessWidget {
  const CloudflareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final CloudflareController cf = NovaScope.of(context).cloudflare;
    final ProfilesController profiles = NovaScope.of(context).profiles;
    final nova = context.nova;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Cloudflare')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListenableBuilder(
            listenable: cf,
            builder: (context, _) {
              return ListView(
                padding: const EdgeInsets.all(NovaSpace.xl),
                children: <Widget>[
                  if (cf.error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: NovaSpace.md),
                      child: Text(cf.error, style: TextStyle(color: nova.danger)),
                    ),
                  switch (cf.phase) {
                    CfPhase.connected => _connected(context, cf, profiles, nova),
                    CfPhase.connecting => _busy(context, 'Opening your browser to sign in...'),
                    CfPhase.loading => _busy(context, 'Loading...'),
                    _ => _disconnected(context, cf, nova),
                  },
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _busy(BuildContext context, String label) => NovaCard(
        child: Column(children: <Widget>[
          const SizedBox(height: NovaSpace.md),
          const CircularProgressIndicator(),
          const SizedBox(height: NovaSpace.lg),
          Text(label),
          const SizedBox(height: NovaSpace.md),
        ]),
      );

  Widget _disconnected(BuildContext context, CloudflareController cf, nova) {
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.cloud_outlined, color: nova.cyan, size: 40),
          const SizedBox(height: NovaSpace.md),
          Text('Connect your Cloudflare account', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: NovaSpace.sm),
          Text('Sign in once to deploy and manage your own free Nova panel. You stay signed in.',
              style: TextStyle(color: nova.muted)),
          const SizedBox(height: NovaSpace.lg),
          NovaButton(
            label: 'Connect Cloudflare',
            icon: Icons.login,
            expand: true,
            onPressed: () => cf.connect((String url) async {
              await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            }),
          ),
        ],
      ),
    );
  }

  Widget _connected(BuildContext context, CloudflareController cf, ProfilesController profiles, nova) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        NovaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(children: <Widget>[
                Icon(Icons.cloud_done, color: nova.successStrong),
                const SizedBox(width: NovaSpace.sm),
                Expanded(
                  child: Text(cf.accountName.isEmpty ? 'Connected' : cf.accountName,
                      style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                ),
                TextButton(onPressed: cf.disconnect, child: const Text('Sign out')),
              ]),
              const SizedBox(height: NovaSpace.md),
              Row(children: <Widget>[
                _stat(context, 'Workers', '${cf.workers.length}', nova),
                _stat(context, 'KV', '${cf.kvCount}', nova),
                _stat(context, 'D1', '${cf.d1Count}', nova),
              ]),
            ],
          ),
        ),
        const SizedBox(height: NovaSpace.md),
        NovaButton(
          label: 'Deploy a new panel',
          icon: Icons.add,
          expand: true,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DeployScreen()),
          ),
        ),
        const SizedBox(height: NovaSpace.lg),
        Text('Your workers', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: NovaSpace.sm),
        if (cf.workers.isEmpty)
          Text('No workers yet. Deploy one above.', style: TextStyle(color: nova.muted))
        else
          ...cf.workers.map((CfWorker w) => _workerRow(context, cf, profiles, w, nova)),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, String value, nova) => Expanded(
        child: Column(children: <Widget>[
          Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: nova.cyan)),
          Text(label, style: TextStyle(color: nova.muted, fontSize: 12)),
        ]),
      );

  Widget _workerRow(BuildContext context, CloudflareController cf, ProfilesController profiles, CfWorker w, nova) {
    final bool busy = cf.busyWorker == w.name || cf.busyWorker == w.url;
    return Padding(
      padding: const EdgeInsets.only(bottom: NovaSpace.sm),
      child: NovaCard(
        padding: const EdgeInsets.symmetric(horizontal: NovaSpace.lg, vertical: NovaSpace.md),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(w.name, style: Theme.of(context).textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                  if (w.url.isNotEmpty) Text(w.url, style: TextStyle(color: nova.muted, fontSize: 12), overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (busy)
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            else
              PopupMenuButton<String>(
                onSelected: (String v) async {
                  if (v == 'import') {
                    await _importFromWorker(context, cf, profiles, w);
                  } else if (v == 'delete') {
                    await cf.deleteWorker(w);
                  }
                },
                itemBuilder: (_) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(value: 'import', child: Text('Import configs')),
                  const PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _importFromWorker(
      BuildContext context, CloudflareController cf, ProfilesController profiles, CfWorker w) async {
    final String? password = await _askPassword(context, w.name);
    if (password == null || password.isEmpty || w.url.isEmpty) return;
    final String? sub = await cf.fetchPanelSubscription(w.url, password);
    if (sub == null) return;
    profiles.add(ProxyProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: w.name,
      kind: ProxyKind.subscription,
      uri: sub,
      subscriptionUrl: sub,
    ));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported configs from ${w.name}')),
      );
    }
  }

  Future<String?> _askPassword(BuildContext context, String name) {
    final TextEditingController c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('Panel password for $name'),
        content: TextField(
          controller: c,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(c.text), child: const Text('Import')),
        ],
      ),
    );
  }
}
