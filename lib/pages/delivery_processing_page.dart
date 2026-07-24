part of '../main.dart';

// ─────────────────────────────────────────────
// 納品処理ページ（発注確定PDFごとの納品記録）
// ─────────────────────────────────────────────

class DeliveryProcessingPage extends StatefulWidget {
  const DeliveryProcessingPage({super.key});

  @override
  State<DeliveryProcessingPage> createState() => _DeliveryProcessingPageState();
}

class _DeliveryProcessingPageState extends State<DeliveryProcessingPage> {
  bool _loading = true;
  String? _error;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _batches = [];
  final Set<String> _localDeliveredKeys = <String>{};
  final Set<String> _selectedDeliveryKeys = <String>{};
  final Map<String, Map<String, dynamic>> _externalDeliveredMaps =
      <String, Map<String, dynamic>>{};
  String _selectedDeliveryStoreId = '';
  int _visibleBatchCount = 5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  Map<String, String> _deliveryStores() {
    final stores = <String, String>{};
    for (final batch in _batches) {
      final rawItems = batch.data()['items'];
      if (rawItems is! List) continue;
      for (final raw in rawItems.whereType<Map>()) {
        final item = Map<String, dynamic>.from(
          raw.map((k, v) => MapEntry(k.toString(), v)),
        );
        final storeId = (item['storeId'] ?? '').toString();
        final storeName = (item['storeName'] ?? '').toString();
        if (storeId.isNotEmpty && storeName.isNotEmpty) {
          stores[storeId] = storeName;
        }
      }
    }
    final entries = stores.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return Map<String, String>.fromEntries(entries);
  }

  Widget _buildStoreSelector() {
    final stores = _deliveryStores();
    if (stores.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '最初に店舗を選択してください',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedDeliveryStoreId.isEmpty
                  ? null
                  : _selectedDeliveryStoreId,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '納品する店舗',
                prefixIcon: Icon(Icons.store),
              ),
              items: [
                for (final entry in stores.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      entry.value,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedDeliveryStoreId = value ?? '';
                  _selectedDeliveryKeys.clear();
                  _visibleBatchCount = 5;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await AppSession.doc('orders')
          .collection('batches')
          .orderBy('createdAt', descending: true)
          .limit(20)
          .get();

      final visibleBatches = snap.docs
          .where((doc) => (doc.data()['status'] ?? '').toString() != 'canceled')
          .toList();

      final externalDeliveredMaps = <String, Map<String, dynamic>>{};

      // まず、既存の orders ドキュメント内に保存した軽量な納品済み情報を読む。
      // orders は発注・納品予定で既に使っているため、新規ドキュメントより権限面で安全。
      final ordersData = await AppSession.doc(
        'orders',
      ).get().timeout(const Duration(seconds: 8));
      final rawDeliveredBatches = ordersData.data()?['_deliveredBatches'];
      if (rawDeliveredBatches is Map) {
        for (final entry in rawDeliveredBatches.entries) {
          final batchId = entry.key.toString();
          final deliveredMap = entry.value;
          if (deliveredMap is Map) {
            externalDeliveredMaps[batchId] = Map<String, dynamic>.from(
              deliveredMap.map((k, v) => MapEntry(k.toString(), v)),
            );
          }
        }
      }

      // 旧互換用の order_delivery_status は個別読み込みが多く重いため、
      // 画面表示時には読まない。現在の正しい納品記録は orders._deliveredBatches。

      setState(() {
        _batches = visibleBatches;
        _externalDeliveredMaps
          ..clear()
          ..addAll(externalDeliveredMaps);
        _visibleBatchCount = 5;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  DateTime _batchDate(Map<String, dynamic> data) {
    final ts = data['createdAt'];
    if (ts is Timestamp) return ts.toDate();
    return DateTime.tryParse((data['createdAtLocal'] ?? '').toString()) ??
        DateTime.now();
  }

  String _batchTitle(Map<String, dynamic> data) {
    final d = _batchDate(data);
    return '${d.year}年${d.month}月${d.day}日の発注分';
  }

  String _deliveryKey(Map<String, dynamic> item) {
    final typeKey = (item['typeKey'] ?? item['itemType'] ?? '').toString();
    final storeId = (item['storeId'] ?? '').toString();
    final itemId = (item['itemId'] ?? '').toString();
    return '${typeKey}__${storeId}__$itemId';
  }

  String _selectionKey(String batchId, Map<String, dynamic> item) {
    return '$batchId::${_deliveryKey(item)}';
  }

  bool _isDeliveredInBatch(
    String batchId,
    Map<String, dynamic> batchData,
    Map<String, dynamic> item,
  ) {
    if ((item['status'] ?? '') == 'delivered') return true;
    final key = _deliveryKey(item);
    if (_localDeliveredKeys.contains('$batchId::$key')) return true;

    final externalDeliveredMap = _externalDeliveredMaps[batchId];
    if (externalDeliveredMap != null && externalDeliveredMap.containsKey(key)) {
      return true;
    }

    final deliveredMap = batchData['deliveredMap'];
    return deliveredMap is Map && deliveredMap.containsKey(key);
  }

  Future<void> _deliverItem(
    QueryDocumentSnapshot<Map<String, dynamic>> batchDoc,
    int index,
    Map<String, dynamic> item, {
    bool askConfirm = true,
    bool showResult = true,
  }) async {
    final qty = _toInt(item['qty']);
    final deliveredQty = _toInt(item['deliveredQty']);
    final remaining = max(0, qty - deliveredQty);
    final deliveryKey = _deliveryKey(item);
    final localKey = '${batchDoc.id}::$deliveryKey';
    if (remaining <= 0 ||
        item['status'] == 'delivered' ||
        _localDeliveredKeys.contains(localKey)) {
      return;
    }

    if (askConfirm) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('納品処理'),
          content: Text(
            '${item['storeName']}\n${item['itemName']}\n$remaining個を納品して在庫に加算します。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('納品する'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final storeId = (item['storeId'] ?? '').toString();
    final storeName = (item['storeName'] ?? '').toString();
    final itemId = (item['itemId'] ?? '').toString();
    final itemName = (item['itemName'] ?? '').toString();
    final itemType = (item['itemType'] ?? '').toString();
    final typeKey = (item['typeKey'] ?? '').toString();

    if (storeId.isEmpty || itemId.isEmpty || typeKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('納品処理失敗: 発注データに必要な情報がありません'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    Future<void> showStep(String message) async {
      if (!showResult || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    }

    var deliveryStatusSaved = false;

    Future<void> rollbackDeliveryStatus() async {
      if (!deliveryStatusSaved) return;
      try {
        await AppSession.doc('order_delivery_status')
            .collection('entries')
            .doc(batchDoc.id)
            .update({
              'deliveredMap.$deliveryKey': FieldValue.delete(),
              'updatedAt': FieldValue.serverTimestamp(),
              'updatedAtLocal': DateTime.now().toIso8601String(),
            })
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        // ロールバック失敗は画面エラーを増やさない。
      }
      if (mounted) {
        setState(() {
          _localDeliveredKeys.remove(localKey);
          _externalDeliveredMaps[batchDoc.id]?.remove(deliveryKey);
        });
      }
    }

    try {
      final nowLocal = DateTime.now().toIso8601String();
      final deliveryRecord = {
        'qty': remaining,
        'deliveredAtLocal': nowLocal,
        'deliveredBy': AppSession.nickname,
        'storeId': storeId,
        'storeName': storeName,
        'itemId': itemId,
        'itemName': itemName,
        'itemType': itemType,
        'typeKey': typeKey,
      };
      final stocksRef = itemType == '商品'
          ? AppSession.doc('stocks')
          : AppSession.doc('stocks_v2');

      // 納品記録の保存を先に行うと、権限・キャッシュ・旧データの影響で
      // 在庫加算前に止まることがある。納品処理では在庫加算を最優先にする。
      await showStep('納品処理中: 在庫に加算しています');
      if (itemType == '商品') {
        await stocksRef
            .set({
              storeId: {itemId: FieldValue.increment(remaining)},
            }, SetOptions(merge: true))
            .timeout(
              const Duration(seconds: 12),
              onTimeout: () => throw TimeoutException('在庫加算でタイムアウトしました'),
            );
      } else {
        await stocksRef
            .set({
              typeKey: {
                storeId: {itemId: FieldValue.increment(remaining)},
              },
            }, SetOptions(merge: true))
            .timeout(
              const Duration(seconds: 12),
              onTimeout: () => throw TimeoutException('在庫加算でタイムアウトしました'),
            );
      }

      // 在庫反映後に、店舗在庫一覧の「納品予定」表示を消す。
      // ここは在庫加算とは分離し、失敗しても納品自体は成功扱いにする。
      var orderedCleared = false;
      try {
        await showStep('納品処理中: 納品予定表示を更新しています');
        final ordersRef = AppSession.doc('orders');
        await ordersRef
            .update({
              '$typeKey.$storeId.$itemId': FieldValue.increment(-remaining),
              '_meta.${typeKey}__${storeId}__$itemId': FieldValue.delete(),
              '_deliveredBatches.${batchDoc.id}.$deliveryKey': deliveryRecord,
            })
            .timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw TimeoutException('納品予定表示の更新でタイムアウトしました'),
            );
        orderedCleared = true;
      } catch (_) {
        orderedCleared = false;
      }

      if (mounted) {
        setState(() {
          _localDeliveredKeys.add(localKey);
          _externalDeliveredMaps.putIfAbsent(
            batchDoc.id,
            () => <String, dynamic>{},
          )[deliveryKey] = deliveryRecord;
          _selectedDeliveryKeys.remove(localKey);
        });
      }

      // 互換用: 旧発注表側と別保存先にも書ける場合だけ書く。
      // ここが失敗しても、在庫加算と orders 側の軽量記録を正とする。
      try {
        await batchDoc.reference
            .update({
              'status': 'partial',
              'updatedAt': FieldValue.serverTimestamp(),
              'updatedAtLocal': nowLocal,
            })
            .timeout(const Duration(seconds: 4));
      } catch (_) {}
      try {
        await AppSession.doc('order_delivery_status')
            .collection('entries')
            .doc(batchDoc.id)
            .set({
              'batchId': batchDoc.id,
              'deliveredMap': {deliveryKey: deliveryRecord},
              'updatedAt': FieldValue.serverTimestamp(),
              'updatedAtLocal': nowLocal,
            }, SetOptions(merge: true))
            .timeout(const Duration(seconds: 4));
        deliveryStatusSaved = true;
      } catch (_) {}
      if (showResult && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              orderedCleared
                  ? '$storeName：$itemName を $remaining個 納品しました'
                  : '$storeName：$itemName を $remaining個 納品しました（納品予定表示は更新できませんでした）',
            ),
            backgroundColor: orderedCleared ? Colors.green : Colors.orange,
          ),
        );
      }
    } on TimeoutException catch (e) {
      await rollbackDeliveryStatus();
      if (!showResult) rethrow;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('納品処理失敗: ${e.message}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } on FirebaseException catch (e) {
      await rollbackDeliveryStatus();
      if (!showResult) rethrow;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('納品処理失敗: ${e.message ?? e.code}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      await rollbackDeliveryStatus();
      if (!showResult) rethrow;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('納品処理失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deliverSelectedInBatch(
    QueryDocumentSnapshot<Map<String, dynamic>> batch,
  ) async {
    final data = batch.data();
    final rawItems = data['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map(
                (e) => Map<String, dynamic>.from(
                  e.map((k, v) => MapEntry(k.toString(), v)),
                ),
              )
              .where(
                (item) =>
                    _selectedDeliveryStoreId.isEmpty ||
                    (item['storeId'] ?? '').toString() ==
                        _selectedDeliveryStoreId,
              )
              .toList()
        : <Map<String, dynamic>>[];

    final targets = <MapEntry<int, Map<String, dynamic>>>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final key = _selectionKey(batch.id, item);
      if (_selectedDeliveryKeys.contains(key) &&
          !_isDeliveredInBatch(batch.id, data, item)) {
        targets.add(MapEntry(i, item));
      }
    }

    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('一括納品する商品を選択してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final totalQty = targets.fold<int>(
      0,
      (sum, entry) =>
          sum +
          max(
            0,
            _toInt(entry.value['qty']) - _toInt(entry.value['deliveredQty']),
          ),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('選択一括納品'),
        content: Text('選択した ${targets.length}品目 / 合計$totalQty個 を納品します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('一括納品する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    var success = 0;
    var failed = 0;
    for (final target in targets) {
      try {
        await _deliverItem(
          batch,
          target.key,
          target.value,
          askConfirm: false,
          showResult: false,
        );
        success++;
      } catch (_) {
        failed++;
      }
    }

    if (mounted) {
      setState(() {
        for (final target in targets) {
          if (failed == 0) {
            _selectedDeliveryKeys.remove(_selectionKey(batch.id, target.value));
          }
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failed == 0
                ? '選択した $success品目を納品しました'
                : '一括納品完了: 成功$success品目 / 失敗$failed品目',
          ),
          backgroundColor: failed == 0 ? Colors.green : Colors.orange,
        ),
      );
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('納品処理')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText('読み取りエラー\n\n$_error'),
        ),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('納品処理'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _batches.isEmpty
          ? const Center(child: Text('納品処理待ちの発注はありません'))
          : Column(
              children: [
                _buildStoreSelector(),
                Expanded(
                  child: _selectedDeliveryStoreId.isEmpty
                      ? const Center(
                          child: Text(
                            '店舗を選択すると、その店舗の未納品商品だけ表示されます',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 16),
                          ),
                        )
                      : Builder(
                          builder: (context) {
                            final visibleBatches = _batches
                                .take(_visibleBatchCount)
                                .toList();
                            final hasMore =
                                visibleBatches.length < _batches.length;
                            return ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount:
                                  visibleBatches.length + (hasMore ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index < visibleBatches.length) {
                                  return _buildBatchCard(
                                    visibleBatches[index],
                                    initiallyExpanded: index == 0,
                                  );
                                }
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      setState(() {
                                        _visibleBatchCount = min(
                                          _visibleBatchCount + 5,
                                          _batches.length,
                                        );
                                      });
                                    },
                                    icon: const Icon(Icons.expand_more),
                                    label: Text(
                                      'もっと見る（${visibleBatches.length}/${_batches.length}件）',
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildBatchCard(
    QueryDocumentSnapshot<Map<String, dynamic>> batch, {
    bool initiallyExpanded = false,
  }) {
    final data = batch.data();
    final rawItems = data['items'];
    final items = rawItems is List
        ? rawItems
              .whereType<Map>()
              .map(
                (e) => Map<String, dynamic>.from(
                  e.map((k, v) => MapEntry(k.toString(), v)),
                ),
              )
              .where(
                (item) =>
                    _selectedDeliveryStoreId.isEmpty ||
                    (item['storeId'] ?? '').toString() ==
                        _selectedDeliveryStoreId,
              )
              .toList()
        : <Map<String, dynamic>>[];
    if (items.isEmpty) return const SizedBox.shrink();
    final pending = items
        .where((e) => !_isDeliveredInBatch(batch.id, data, e))
        .length;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded && pending > 0,
        title: Text(
          _batchTitle(data),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('未納品 $pending / 全${items.length}品目'),
        children: [
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          final selectable = items.where(
                            (e) => !_isDeliveredInBatch(batch.id, data, e),
                          );
                          final allSelected = selectable.every(
                            (e) => _selectedDeliveryKeys.contains(
                              _selectionKey(batch.id, e),
                            ),
                          );
                          for (final item in selectable) {
                            final key = _selectionKey(batch.id, item);
                            if (allSelected) {
                              _selectedDeliveryKeys.remove(key);
                            } else {
                              _selectedDeliveryKeys.add(key);
                            }
                          }
                        });
                      },
                      icon: const Icon(Icons.checklist),
                      label: const Text('未納品を全選択/解除'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _deliverSelectedInBatch(batch),
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: const Text('選択一括納品'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          for (int i = 0; i < items.length; i++)
            _buildDeliveryRow(
              batch,
              i,
              items[i],
              _isDeliveredInBatch(batch.id, data, items[i]),
              _selectedDeliveryKeys.contains(_selectionKey(batch.id, items[i])),
            ),
        ],
      ),
    );
  }

  Widget _buildDeliveryRow(
    QueryDocumentSnapshot<Map<String, dynamic>> batch,
    int index,
    Map<String, dynamic> item,
    bool delivered,
    bool selected,
  ) {
    final qty = _toInt(item['qty']);
    final selectionKey = _selectionKey(batch.id, item);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: delivered ? false : selected,
                onChanged: delivered
                    ? null
                    : (value) {
                        setState(() {
                          if (value == true) {
                            _selectedDeliveryKeys.add(selectionKey);
                          } else {
                            _selectedDeliveryKeys.remove(selectionKey);
                          }
                        });
                      },
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.shade50,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.deepPurple.shade200),
                      ),
                      child: Text(
                        '${item['storeName']}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.deepPurple.shade800,
                        ),
                      ),
                    ),
                    Text(
                      '${item['itemName']}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${item['itemType']} / コード:${item['itemCode'] ?? ''}',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$qty個',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: delivered
                ? OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('納品済み'),
                  )
                : ElevatedButton.icon(
                    onPressed: () => _deliverItem(batch, index, item),
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('この商品を納品する'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
          ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}
