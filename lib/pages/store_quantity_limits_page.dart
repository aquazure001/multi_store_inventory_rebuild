part of '../main.dart';

class StoreQuantityLimitsPage extends StatefulWidget {
  const StoreQuantityLimitsPage({super.key});

  @override
  State<StoreQuantityLimitsPage> createState() =>
      _StoreQuantityLimitsPageState();
}

class _StoreQuantityLimitsPageState extends State<StoreQuantityLimitsPage> {
  final Map<String, TextEditingController> _productControllers = {};
  final Map<String, TextEditingController> _testerControllers = {};
  final Map<String, TextEditingController> _equipmentControllers = {};
  List<LegacyStore> _stores = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool get _canEdit => AppSession.isAdmin || AppSession.isSuperAdmin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      ..._productControllers.values,
      ..._testerControllers.values,
      ..._equipmentControllers.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(
    Map<String, TextEditingController> controllers,
    String storeId,
  ) {
    return controllers.putIfAbsent(storeId, () => TextEditingController());
  }

  int _readLimit(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return 0;
    return max(0, int.tryParse(text) ?? 0);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        AppSession.doc('stores').get(),
        AppSession.storeQuantityLimitsDoc.get(),
      ]);
      final stores = _parseStores(results[0].data() ?? <String, dynamic>{});
      final data = results[1].data() ?? <String, dynamic>{};
      final rawStores = data['stores'] is Map
          ? data['stores'] as Map
          : <dynamic, dynamic>{};

      for (final store in stores) {
        final raw = rawStores[store.id];
        final map = raw is Map
            ? Map<String, dynamic>.from(
                raw.map((k, v) => MapEntry(k.toString(), v)),
              )
            : <String, dynamic>{};
        _controller(
          _productControllers,
          store.id,
        ).text = inventoryIntValue(map['products']) <= 0
            ? ''
            : '${inventoryIntValue(map['products'])}';
        _controller(
          _testerControllers,
          store.id,
        ).text = inventoryIntValue(map['testers']) <= 0
            ? ''
            : '${inventoryIntValue(map['testers'])}';
        _controller(
          _equipmentControllers,
          store.id,
        ).text = inventoryIntValue(map['equipments']) <= 0
            ? ''
            : '${inventoryIntValue(map['equipments'])}';
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
          'products': _readLimit(_controller(_productControllers, store.id)),
          'testers': _readLimit(_controller(_testerControllers, store.id)),
          'equipments': _readLimit(
            _controller(_equipmentControllers, store.id),
          ),
        };
      }
      await AppSession.storeQuantityLimitsDoc.set({
        'stores': storesMap,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtLocal': DateTime.now().toIso8601String(),
        'updatedBy': AppSession.nickname,
        'updatedByEmail': AppSession.email,
      }, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('店舗別数量上限を保存しました'),
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('店舗別数量上限')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText('読み取りエラー\n\n$_error'),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('店舗別数量上限'),
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
              color: Colors.deepPurple.shade50,
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  '店舗ごとに、1品目あたりの在庫数量上限を設定します。空欄または0は上限なしです。手入力の在庫更新と納品処理で上限を超えないように止めます。',
                  style: TextStyle(fontWeight: FontWeight.bold),
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
                label: const Text('店舗別数量上限を保存'),
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

  Widget _buildStoreCard(LegacyStore store) {
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
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 12),
            _limitField(
              controller: _controller(_productControllers, store.id),
              label: '商品 数量上限',
              icon: Icons.inventory_2_outlined,
            ),
            const SizedBox(height: 8),
            _limitField(
              controller: _controller(_testerControllers, store.id),
              label: 'テスター 数量上限',
              icon: Icons.science_outlined,
            ),
            const SizedBox(height: 8),
            _limitField(
              controller: _controller(_equipmentControllers, store.id),
              label: '備品 数量上限',
              icon: Icons.build_outlined,
            ),
          ],
        ),
      ),
    );
  }

  Widget _limitField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      enabled: _canEdit && !_saving,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        prefixIcon: Icon(icon),
        labelText: label,
        suffixText: '個まで',
        hintText: '空欄は上限なし',
        border: const OutlineInputBorder(),
      ),
    );
  }
}
