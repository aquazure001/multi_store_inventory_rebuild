part of '../main.dart';

class StripeSettingsPage extends StatefulWidget {
  const StripeSettingsPage({super.key});

  @override
  State<StripeSettingsPage> createState() => _StripeSettingsPageState();
}

class _StripeSettingsPageState extends State<StripeSettingsPage> {
  final TextEditingController _commonAccountController =
      TextEditingController();
  final Map<String, TextEditingController> _storeAccountControllers = {};
  final Map<String, bool> _storeEnabled = {};
  final Map<String, String> _storeModes = {};
  List<LegacyStore> _stores = [];
  bool _commonEnabled = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commonAccountController.dispose();
    for (final controller in _storeAccountControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        AppSession.doc('stores').get(),
        AppSession.posStripeSettingsDoc.get(),
      ]);
      final storesDoc = results[0];
      final settingsDoc = results[1];
      final stores = _parseStores(storesDoc.data() ?? <String, dynamic>{});
      final data = settingsDoc.data() ?? <String, dynamic>{};
      final common = data['common'] is Map
          ? Map<String, dynamic>.from(
              (data['common'] as Map).map((k, v) => MapEntry(k.toString(), v)),
            )
          : <String, dynamic>{};
      final storeSettings = data['stores'] is Map
          ? data['stores'] as Map
          : <dynamic, dynamic>{};

      _commonAccountController.text = (common['stripeAccountId'] ?? '')
          .toString();
      _commonEnabled = common['enabled'] == true;

      for (final store in stores) {
        final raw = storeSettings[store.id];
        final map = raw is Map
            ? Map<String, dynamic>.from(
                raw.map((k, v) => MapEntry(k.toString(), v)),
              )
            : <String, dynamic>{};
        _storeEnabled[store.id] = map['enabled'] == true;
        final mode = (map['mode'] ?? 'common').toString();
        _storeModes[store.id] = mode == 'store' ? 'store' : 'common';
        _storeAccountControllers
            .putIfAbsent(store.id, () => TextEditingController())
            .text = (map['stripeAccountId'] ?? '')
            .toString();
      }

      setState(() {
        _stores = stores;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final storesMap = <String, dynamic>{};
      for (final store in _stores) {
        storesMap[store.id] = {
          'storeId': store.id,
          'storeName': store.name,
          'enabled': _storeEnabled[store.id] == true,
          'mode': _storeModes[store.id] ?? 'common',
          'stripeAccountId':
              _storeAccountControllers[store.id]?.text.trim() ?? '',
        };
      }
      await AppSession.posStripeSettingsDoc.set({
        'common': {
          'enabled': _commonEnabled,
          'stripeAccountId': _commonAccountController.text.trim(),
        },
        'stores': storesMap,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtLocal': DateTime.now().toIso8601String(),
        'updatedBy': AppSession.nickname,
        'updatedByEmail': AppSession.email,
        'note':
            'Stripe secret key is not stored in Flutter/Firestore. Payment server setup is required separately.',
      }, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('店舗Stripe設定を保存しました'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失敗: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _canEdit => AppSession.isAdmin || AppSession.isSuperAdmin;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('店舗Stripe設定')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText('読み取りエラー\n\n$_error'),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('店舗Stripe設定'),
        actions: [
          IconButton(
            onPressed: _saving ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.blue.shade700),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'ここではStripeの入金先設定だけを保存します',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '店舗独自Stripeも、全店舗共通Stripeも選べます。秘密キーはアプリやFirestoreには保存しません。カード決済の実行には別途、共通の決済用サーバーを1つ用意します。',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '全店舗共通Stripe',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _commonEnabled,
                      onChanged: !_canEdit || _saving
                          ? null
                          : (value) => setState(() => _commonEnabled = value),
                      title: const Text('共通Stripeを利用可能にする'),
                    ),
                    TextField(
                      controller: _commonAccountController,
                      enabled: _canEdit && !_saving,
                      decoration: const InputDecoration(
                        labelText: '共通Stripe Account ID',
                        hintText: 'acct_...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final store in _stores) _buildStoreCard(store),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: !_canEdit || _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('Stripe設定を保存'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeTile({
    required LegacyStore store,
    required String modeValue,
    required String currentMode,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final selected = currentMode == modeValue;
    final enabled = _canEdit && !_saving;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: enabled
            ? () => setState(() => _storeModes[store.id] = modeValue)
            : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? Colors.deepPurple.shade50 : Colors.white,
            border: Border.all(
              color: selected ? Colors.deepPurple : Colors.grey.shade300,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? Colors.deepPurple : Colors.grey,
              ),
              const SizedBox(width: 8),
              Icon(icon, color: selected ? Colors.deepPurple : Colors.grey),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStoreCard(LegacyStore store) {
    final enabled = _storeEnabled[store.id] == true;
    final mode = _storeModes[store.id] ?? 'common';
    final controller = _storeAccountControllers.putIfAbsent(
      store.id,
      () => TextEditingController(),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              store.name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              '店舗ID: ${store.id}',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: enabled,
              onChanged: !_canEdit || _saving
                  ? null
                  : (value) => setState(() => _storeEnabled[store.id] = value),
              title: const Text('この店舗でカード決済を使う'),
            ),
            _buildModeTile(
              store: store,
              modeValue: 'common',
              currentMode: mode,
              title: '全店舗共通Stripeを使う',
              subtitle: '会社共通のStripeに入金',
              icon: Icons.groups,
            ),
            _buildModeTile(
              store: store,
              modeValue: 'store',
              currentMode: mode,
              title: '店舗独自Stripeを使う',
              subtitle: 'この店舗専用のStripeに入金',
              icon: Icons.store,
            ),
            TextField(
              controller: controller,
              enabled: _canEdit && !_saving && mode == 'store',
              decoration: const InputDecoration(
                labelText: '店舗独自 Stripe Account ID',
                hintText: 'acct_...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
