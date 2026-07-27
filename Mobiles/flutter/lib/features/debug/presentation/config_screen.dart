import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/o11y/faro/faro_data_collection_provider.dart';
import 'config_screen_view_model.dart';
import 'restart_required_banner.dart';

/// Sub-view of the Debug tab for changing the backend and Faro collector
/// URLs. Changes are persisted on "Save" and only take effect after an
/// app restart (see `RuntimeConfig`).
class ConfigScreen extends ConsumerStatefulWidget {
  const ConfigScreen({super.key});

  @override
  ConsumerState<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends ConsumerState<ConfigScreen> {
  final _backendController = TextEditingController();
  final _faroController = TextEditingController();
  final _sampleRateController = TextEditingController();
  bool _controllersSeeded = false;

  @override
  void dispose() {
    _backendController.dispose();
    _faroController.dispose();
    _sampleRateController.dispose();
    super.dispose();
  }

  /// Seed the text controllers once from the saved overrides. We can't do
  /// this in initState because it needs access to the ViewModel state.
  void _seedControllersOnce(ConfigScreenUiState uiState) {
    if (_controllersSeeded) return;
    _backendController.text = uiState.savedBackendOverride ?? '';
    _faroController.text = uiState.savedFaroCollectorOverride ?? '';
    _sampleRateController.text =
        uiState.savedFaroSampleRateOverride?.toString() ?? '';
    _controllersSeeded = true;
  }

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(configScreenUiStateProvider);
    final actions = ref.watch(configScreenActionsProvider);

    _seedControllersOnce(uiState);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Config'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const RestartRequiredBanner(),
          const _FaroDataCollectionCard(),
          const SizedBox(height: 24),
          Text(
            'Override the values used by this app. Changes here only take '
            'effect after you kill and restart the app — this keeps traces, '
            'logs and metrics correlated within a single session.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _UrlField(
            label: 'Backend URL',
            controller: _backendController,
            inUseValue: uiState.backendInUse,
            defaultValue: uiState.defaultBackend,
            hintText: 'http://192.168.1.100:3333',
          ),
          const SizedBox(height: 24),
          _UrlField(
            label: 'Faro collector URL',
            controller: _faroController,
            inUseValue: uiState.faroCollectorInUse,
            inUseDisplay: uiState.faroCollectorInUseDisplay,
            defaultValue: uiState.defaultFaroCollector,
            defaultDisplay: uiState.defaultFaroCollectorDisplay,
            hintText: 'https://faro-collector.../collect/<api-key>',
          ),
          const SizedBox(height: 24),
          _UrlField(
            label: 'Faro session sample rate',
            controller: _sampleRateController,
            inUseValue: uiState.faroSampleRateInUse.toString(),
            defaultValue: uiState.defaultFaroSampleRate.toString(),
            hintText: 'e.g. 0.25 — fraction of sessions sampled (0.0–1.0)',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: uiState.saving
                  ? null
                  : () => actions.save(
                      backendUrl: _backendController.text,
                      faroCollectorUrl: _faroController.text,
                      faroSampleRateText: _sampleRateController.text,
                    ),
              icon: uiState.saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: const Text('Save'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: uiState.saving
                  ? null
                  : () async {
                      await actions.clear();
                      _backendController.clear();
                      _faroController.clear();
                      _sampleRateController.clear();
                    },
              icon: const Icon(Icons.restart_alt),
              label: const Text('Use defaults (clear overrides)'),
            ),
          ),
          if (uiState.statusMessage != null) ...[
            const SizedBox(height: 16),
            Card(
              color: Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        uiState.statusMessage!,
                        style: TextStyle(color: Colors.green.shade900),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

/// Live switch for Faro's global data-collection flag. Unlike the override
/// fields below, this takes effect immediately (no restart) and Faro persists
/// the value across app launches on its own.
class _FaroDataCollectionCard extends ConsumerWidget {
  const _FaroDataCollectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = ref.watch(faroDataCollectionProvider);

    return Card(
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: const Text('Faro data collection'),
        subtitle: Text(
          enabled
              ? 'Faro is collecting and sending telemetry. Applies immediately.'
              : 'Faro telemetry is paused — nothing is sent. Applies '
                    'immediately.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        value: enabled,
        onChanged: (value) =>
            ref.read(faroDataCollectionProvider.notifier).setEnabled(value),
      ),
    );
  }
}

class _UrlField extends StatelessWidget {
  const _UrlField({
    required this.label,
    required this.controller,
    required this.inUseValue,
    required this.defaultValue,
    required this.hintText,
    this.inUseDisplay,
    this.defaultDisplay,
    this.keyboardType = TextInputType.url,
    this.inputFormatters,
  });

  final String label;
  final TextEditingController controller;
  final String inUseValue;
  final String? defaultValue;
  final String hintText;
  final String? inUseDisplay;
  final String? defaultDisplay;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final monoStyle = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Text('Currently in use', style: labelStyle),
            const SizedBox(height: 2),
            Text(inUseDisplay ?? inUseValue, style: monoStyle),
            if (defaultValue != null && defaultValue != inUseValue) ...[
              const SizedBox(height: 8),
              Text('Default', style: labelStyle),
              const SizedBox(height: 2),
              Text(defaultDisplay ?? defaultValue!, style: monoStyle),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: hintText,
                labelText: 'Override (empty = use default)',
                border: const OutlineInputBorder(),
              ),
              keyboardType: keyboardType,
              inputFormatters: inputFormatters,
              autocorrect: false,
              enableSuggestions: false,
            ),
          ],
        ),
      ),
    );
  }
}
