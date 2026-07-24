part of '../main.dart';

// ─────────────────────────────────────────────
// 棚卸し一覧CSV出力
// ─────────────────────────────────────────────

class InventorySnapshotPage extends StatefulWidget {
  const InventorySnapshotPage({super.key});

  @override
  State<InventorySnapshotPage> createState() => _InventorySnapshotPageState();
}

class _InventorySnapshotPageState extends State<InventorySnapshotPage> {
  DateTime _targetDate = DateTime(2026, 6, 30, 23, 59, 59);
  bool _loading = false;
  bool _includeProducts = true;
  bool _includeTesters = false;
  bool _includeEquipments = false;
  String? _message;

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  DateTime? _toDateTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  String _csvCell(Object? value) {
    final s = (value ?? '').toString();
    return '"${s.replaceAll('"', '""')}"';
  }

  String _typeKeyFromItemType(String itemType) {
    if (itemType == '商品') return 'products';
    if (itemType == 'テスター') return 'testers';
    if (itemType == '備品') return 'equipments';
    return itemType;
  }

  Map<String, int> _parseNestedStocks(
    Map<String, dynamic> data,
    String typeKey,
    String storeId,
  ) {
    final typeRaw = data[typeKey];
    if (typeRaw is! Map) return <String, int>{};
    final storeRaw = typeRaw[storeId];
    final result = <String, int>{};
    if (storeRaw is Map) {
      for (final entry in storeRaw.entries) {
        result[entry.key.toString()] = _toInt(entry.value);
      }
    }
    return result;
  }

  List<String> _selectedTypeKeys() {
    final result = <String>[];
    if (_includeProducts) result.add('products');
    if (_includeTesters) result.add('testers');
    if (_includeEquipments) result.add('equipments');
    return result;
  }

  String _selectedTypeLabel() {
    final labels = <String>[];
    if (_includeProducts) labels.add('商品');
    if (_includeTesters) labels.add('テスター');
    if (_includeEquipments) labels.add('備品');
    return labels.join('・');
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(
        _targetDate.year,
        _targetDate.month,
        _targetDate.day,
      ),
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      _targetDate = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
    });
  }

  Future<void> _exportCsv() async {
    if (_loading) return;
    final selectedTypes = _selectedTypeKeys();
    if (selectedTypes.isEmpty) {
      setState(() => _message = '商品・テスター・備品のどれかを選択してください');
      return;
    }

    setState(() {
      _loading = true;
      _message = null;
    });

    try {
      final target = _targetDate;
      final masterData = await _loadMasterData();
      final results = await Future.wait([
        AppSession.doc('stocks').get(),
        AppSession.doc('stocks_v2').get(),
        AppSession.doc('orders').get(),
      ]);
      final stocksDoc = results[0];
      final stocksV2Doc = results[1];
      final ordersDoc = results[2];

      final stores = List<LegacyStore>.from(masterData.stores)
        ..sort((a, b) {
          final c = _naturalCompare(a.code, b.code);
          return c != 0 ? c : _naturalCompare(a.name, b.name);
        });

      final itemsByType = <String, List<LegacyItem>>{
        'products': masterData.products
            .where((item) => !item.discontinued)
            .toList(),
        'testers': masterData.testers
            .where((item) => !item.discontinued)
            .toList(),
        'equipments': masterData.equipments
            .where((item) => !item.discontinued)
            .toList(),
      };
      const typeLabels = <String, String>{
        'products': '商品',
        'testers': 'テスター',
        'equipments': '備品',
      };

      final currentStocksRaw = stocksDoc.data() ?? <String, dynamic>{};
      final currentStocksV2Raw = stocksV2Doc.data() ?? <String, dynamic>{};
      final snapshot = <String, Map<String, Map<String, int>>>{
        'products': <String, Map<String, int>>{},
        'testers': <String, Map<String, int>>{},
        'equipments': <String, Map<String, int>>{},
      };
      for (final store in stores) {
        snapshot['products']![store.id] = Map<String, int>.from(
          _parseStocksForStore(currentStocksRaw, store.id),
        );
        snapshot['testers']![store.id] = Map<String, int>.from(
          _parseNestedStocks(currentStocksV2Raw, 'testers', store.id),
        );
        snapshot['equipments']![store.id] = Map<String, int>.from(
          _parseNestedStocks(currentStocksV2Raw, 'equipments', store.id),
        );
      }

      // 現在在庫から、基準日より後の変更分を逆算して基準日時点に戻す。
      // 手入力の在庫修正は history/entries の oldCount/newCount を使う。
      final historySnap = await AppSession.doc('history')
          .collection('entries')
          .where('at', isGreaterThan: Timestamp.fromDate(target))
          .get();

      var historyCount = 0;
      for (final doc in historySnap.docs) {
        final data = doc.data();
        final typeKey = _typeKeyFromItemType(
          (data['itemType'] ?? '').toString(),
        );
        if (!selectedTypes.contains(typeKey)) continue;
        if (!snapshot.containsKey(typeKey)) continue;
        final storeId = (data['storeId'] ?? '').toString();
        final itemId = (data['itemId'] ?? '').toString();
        if (storeId.isEmpty || itemId.isEmpty) continue;
        if (data['oldCount'] is! num || data['newCount'] is! num) continue;
        final oldCount = _toInt(data['oldCount']);
        final newCount = _toInt(data['newCount']);
        final delta = newCount - oldCount;
        final storeMap = snapshot[typeKey]!.putIfAbsent(
          storeId,
          () => <String, int>{},
        );
        storeMap[itemId] = (storeMap[itemId] ?? 0) - delta;
        historyCount++;
      }

      // 納品処理画面からの納品は orders._deliveredBatches の軽量記録を優先して読む。
      // 旧データだけ必要な場合に限り、従来の発注表側 deliveredMap を確認する。
      var deliveryCount = 0;

      void applyDeliveredItem(Map<String, dynamic> item) {
        final typeKey = (item['typeKey'] ?? '').toString().isNotEmpty
            ? (item['typeKey'] ?? '').toString()
            : _typeKeyFromItemType((item['itemType'] ?? '').toString());
        if (!selectedTypes.contains(typeKey)) return;
        if (!snapshot.containsKey(typeKey)) return;
        final deliveredAt = _toDateTime(
          item['deliveredAt'] ?? item['deliveredAtLocal'],
        );
        if (deliveredAt == null || !deliveredAt.isAfter(target)) return;
        final storeId = (item['storeId'] ?? '').toString();
        final itemId = (item['itemId'] ?? '').toString();
        final qty = _toInt(item['qty']);
        if (storeId.isEmpty || itemId.isEmpty || qty == 0) return;
        final storeMap = snapshot[typeKey]!.putIfAbsent(
          storeId,
          () => <String, int>{},
        );
        storeMap[itemId] = (storeMap[itemId] ?? 0) - qty;
        deliveryCount++;
      }

      final deliveredBatches = ordersDoc.data()?['_deliveredBatches'];
      if (deliveredBatches is Map) {
        for (final batchRaw in deliveredBatches.values) {
          if (batchRaw is! Map) continue;
          for (final raw in batchRaw.values) {
            if (raw is! Map) continue;
            applyDeliveredItem(
              Map<String, dynamic>.from(
                raw.map((k, v) => MapEntry(k.toString(), v)),
              ),
            );
          }
        }
      }

      if (deliveryCount == 0) {
        final batchesSnap = await AppSession.doc('orders')
            .collection('batches')
            .orderBy('createdAt', descending: true)
            .limit(300)
            .get();
        for (final batch in batchesSnap.docs) {
          final deliveredMap = batch.data()['deliveredMap'];
          if (deliveredMap is! Map) continue;
          for (final raw in deliveredMap.values) {
            if (raw is! Map) continue;
            applyDeliveredItem(
              Map<String, dynamic>.from(
                raw.map((k, v) => MapEntry(k.toString(), v)),
              ),
            );
          }
        }
      }

      final rows = <List<Object?>>[
        ['基準日', '種別', '店舗コード', '店舗名', '品目コード', '品目名', '残高'],
      ];
      for (final typeKey in selectedTypes) {
        final items = itemsByType[typeKey] ?? <LegacyItem>[];
        for (final store in stores) {
          final storeStocks = snapshot[typeKey]![store.id] ?? <String, int>{};
          for (final item in items) {
            rows.add([
              '${target.year}-${target.month.toString().padLeft(2, '0')}-${target.day.toString().padLeft(2, '0')}',
              typeLabels[typeKey] ?? typeKey,
              store.code,
              store.name,
              item.code,
              item.name,
              storeStocks[item.id] ?? 0,
            ]);
          }
        }
      }

      final csv = rows.map((row) => row.map(_csvCell).join(',')).join('\r\n');
      final bytes = utf8.encode('\ufeff$csv');
      final blob = html.Blob([bytes], 'text/csv;charset=utf-8');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final typeFileLabel = _selectedTypeLabel().replaceAll('・', '_');
      final fileName =
          '棚卸し一覧_${target.year}${target.month.toString().padLeft(2, '0')}${target.day.toString().padLeft(2, '0')}_$typeFileLabel.csv';
      html.AnchorElement(href: url)
        ..download = fileName
        ..click();
      html.Url.revokeObjectUrl(url);

      final counts = <String>[];
      for (final typeKey in selectedTypes) {
        counts.add(
          '${typeLabels[typeKey]}${itemsByType[typeKey]?.length ?? 0}件',
        );
      }
      setState(() {
        _message =
            'CSVを出力しました（${counts.join('・')} × 店舗 ${stores.length}件、履歴$historyCount件・納品記録$deliveryCount件を逆算）';
      });
    } catch (e) {
      setState(() {
        _message = '出力失敗: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Widget _buildTypeCheckbox({
    required String title,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return CheckboxListTile(
      value: value,
      onChanged: _loading ? null : (v) => onChanged(v ?? false),
      secondary: Icon(icon),
      title: Text(
        title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
      ),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    final label =
        '${_targetDate.year}年${_targetDate.month}月${_targetDate.day}日 23:59時点';
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('棚卸し一覧出力')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '出力する種別を選択してください',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildTypeCheckbox(
                      title: '商品',
                      icon: Icons.inventory_2,
                      value: _includeProducts,
                      onChanged: (v) => setState(() => _includeProducts = v),
                    ),
                    _buildTypeCheckbox(
                      title: 'テスター',
                      icon: Icons.science_outlined,
                      value: _includeTesters,
                      onChanged: (v) => setState(() => _includeTesters = v),
                    ),
                    _buildTypeCheckbox(
                      title: '備品',
                      icon: Icons.category_outlined,
                      value: _includeEquipments,
                      onChanged: (v) => setState(() => _includeEquipments = v),
                    ),
                    const Divider(height: 24),
                    Text('基準日: $label'),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _selectDate,
                      icon: const Icon(Icons.calendar_month),
                      label: const Text('基準日を変更'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '計算方法: 現在在庫から、基準日より後の在庫修正履歴と納品記録を差し引いて逆算します。Firestoreは読み取りのみです。',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loading ? null : _exportCsv,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(_loading ? '作成中...' : '選択した種別の棚卸しCSVを出力'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(_message!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
