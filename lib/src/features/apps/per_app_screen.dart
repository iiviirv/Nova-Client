import 'package:flutter/material.dart';

import '../../core/proxy/app_routing.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';

/// Per-app proxy: pick which apps Nova carries.
///
/// Android only. The mode decides what the list means, so the same list of
/// ticks reads as "only these" or "everything but these" without the user
/// re-picking anything when they change their mind.
///
/// A change takes effect on the next connect, not immediately: Android fixes the
/// allow/deny list when the VPN interface is established, so an already-running
/// tunnel keeps the list it was started with. The screen says so rather than
/// letting someone wonder why nothing changed.
class PerAppScreen extends StatefulWidget {
  const PerAppScreen({super.key});

  @override
  State<PerAppScreen> createState() => _PerAppScreenState();
}

class _PerAppScreenState extends State<PerAppScreen> {
  final TextEditingController _search = TextEditingController();
  List<InstalledApp>? _apps;
  String _query = '';

  /// Which apps were already picked when this screen opened.
  ///
  /// The list shows picked apps first, which is only useful if it holds still.
  /// Re-sorting on every tick meant a row jumped to the top the instant it was
  /// ticked and everything below it slid up, so the next tap landed on the wrong
  /// app. The order is decided once, from this snapshot, and stays put until the
  /// screen is opened again.
  Set<String> _pickedOnOpen = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final AppRouting routing = NovaScope.of(context).appRouting;
    final List<InstalledApp> apps = await routing.installedApps();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _pickedOnOpen = routing.packages;
    });
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final AppRouting routing = NovaScope.of(context).appRouting;
    final nova = context.nova;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.perAppTitle),
        actions: <Widget>[
          ListenableBuilder(
            listenable: routing,
            builder: (BuildContext context, _) => TextButton(
              onPressed: routing.packages.isEmpty ? null : routing.clear,
              child: Text(s.perAppClear),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: routing,
        builder: (BuildContext context, _) {
          final List<InstalledApp>? apps = _apps;
          final bool picking = routing.mode != AppRoutingMode.all;
          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    NovaSpace.lg, NovaSpace.lg, NovaSpace.lg, NovaSpace.sm),
                child: NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(s.perAppSubtitle,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: nova.muted)),
                      const SizedBox(height: NovaSpace.md),
                      _ModePill(
                        label: s.perAppModeAll,
                        selected: routing.mode == AppRoutingMode.all,
                        onTap: () => routing.setMode(AppRoutingMode.all),
                      ),
                      const SizedBox(height: NovaSpace.xs),
                      _ModePill(
                        label: s.perAppModeOnly,
                        selected: routing.mode == AppRoutingMode.only,
                        onTap: () => routing.setMode(AppRoutingMode.only),
                      ),
                      const SizedBox(height: NovaSpace.xs),
                      _ModePill(
                        label: s.perAppModeExcept,
                        selected: routing.mode == AppRoutingMode.except,
                        onTap: () => routing.setMode(AppRoutingMode.except),
                      ),
                      const SizedBox(height: NovaSpace.md),
                      Row(
                        children: <Widget>[
                          Icon(Icons.info_outline_rounded,
                              size: 14, color: nova.muted),
                          const SizedBox(width: NovaSpace.xs),
                          Expanded(
                            child: Text(s.perAppReconnectNote,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(color: nova.muted)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (picking)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: NovaSpace.lg, vertical: NovaSpace.xs),
                  child: TextField(
                    controller: _search,
                    onChanged: (String v) => setState(() => _query = v),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: s.perAppSearch,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      isDense: true,
                    ),
                  ),
                ),
              Expanded(
                child: !picking
                    ? _Note(text: s.perAppModeAllNote)
                    : apps == null
                        ? const Center(child: CircularProgressIndicator())
                        : apps.isEmpty
                            ? _Note(text: s.perAppNone)
                            : _list(apps, routing),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _list(List<InstalledApp> apps, AppRouting routing) {
    final String q = _query.trim().toLowerCase();
    final List<InstalledApp> shown = q.isEmpty
        ? apps
        : apps
            .where((InstalledApp a) =>
                a.label.toLowerCase().contains(q) ||
                a.package.toLowerCase().contains(q))
            .toList();
    // Picked apps first, from the snapshot taken when the screen opened, so
    // ticking one does not move it out from under the next tap.
    shown.sort((InstalledApp a, InstalledApp b) {
      final bool pa = _pickedOnOpen.contains(a.package);
      final bool pb = _pickedOnOpen.contains(b.package);
      if (pa != pb) return pa ? -1 : 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return ListView.builder(
      itemCount: shown.length,
      itemBuilder: (BuildContext context, int i) {
        final InstalledApp a = shown[i];
        final bool on = routing.packages.contains(a.package);
        return CheckboxListTile(
          value: on,
          onChanged: (bool? v) => routing.toggle(a.package, v ?? false),
          title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(a.package,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.nova.muted, fontSize: 11)),
          secondary: a.icon == null
              ? const Icon(Icons.android_rounded)
              : ClipRRect(
                  borderRadius: NovaRadii.iconChipR,
                  child: Image.memory(a.icon!, width: 32, height: 32),
                ),
          controlAffinity: ListTileControlAffinity.trailing,
        );
      },
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Material(
      color: selected ? nova.cyan.withValues(alpha: 0.12) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: NovaRadii.toolR,
        side: BorderSide(color: selected ? nova.cyan : nova.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: NovaSpace.md, vertical: NovaSpace.sm),
          child: Row(
            children: <Widget>[
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: selected ? nova.cyan : nova.muted,
              ),
              const SizedBox(width: NovaSpace.sm),
              Expanded(
                child: Text(label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(NovaSpace.xl),
          child: Text(text,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.nova.muted)),
        ),
      );
}
