part of '../main.dart';

// ─────────────────────────────────────────────
// 特別発注・新規発注ページ
// ─────────────────────────────────────────────

enum _MasterAddResult { added, alreadyExists, skipped }

class SpecialOrderPage extends StatefulWidget {
  const SpecialOrderPage({super.key, this.showExpiredOnly = false});

  final bool showExpiredOnly;

  @override
  State<SpecialOrderPage> createState() => _SpecialOrderPageState();
}

class _SpecialOrderPageState extends State<SpecialOrderPage> {
  List<SpecialOrderItem> _items = [];
  List<LegacyStore> _stores = [];
  Map<String, Map<String, int>> _orders = {};
  Map<String, Map<String, int>> _deliveries = {};
  Map<String, _HomeCareLotStock> _homeCareLots = {};
  Map<String, Map<String, int>> _homeCareReflectedUnits = {};
  List<_HandoverLogEntry> _handoverLogs = [];
  List<_RemainingAdjustmentEntry> _remainingAdjustments = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, TextEditingController> _homeCareLotControllers = {};
  final Map<String, TextEditingController> _homeCareCustomerControllers = {};
  final Map<String, TextEditingController> _homeCareDeliveryControllers = {};

  static const _kTypes = ['特別発注', '新規発注', 'その他'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final c in _homeCareLotControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareCustomerControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareDeliveryControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final masterDataFuture = _loadMasterData();
      final specialOrdersFuture = AppSession.doc('special_orders').get();
      final masterData = await masterDataFuture;
      final doc = await specialOrdersFuture;
      final stores = List<LegacyStore>.from(masterData.stores);
      final raw = doc.exists
          ? (doc.data() ?? <String, dynamic>{})
          : <String, dynamic>{};

      final rawItems = raw['items'];
      final items = <SpecialOrderItem>[];
      if (rawItems is List) {
        for (final e in rawItems) {
          if (e is Map) {
            final m = e.map((k, v) => MapEntry(k.toString(), v));
            final item = SpecialOrderItem.fromMap(m);
            if (item.id.isNotEmpty) items.add(item);
          }
        }
      }
      Map<String, Map<String, int>> parseNestedQty(dynamic src) {
        final result = <String, Map<String, int>>{};
        if (src is! Map) return result;
        for (final e in src.entries) {
          final itemId = e.key.toString();
          if (e.value is! Map) continue;
          final storeMap = <String, int>{};
          for (final s in (e.value as Map).entries) {
            final v = s.value;
            final qty = v is int ? v : inventoryIntValue(v);
            if (qty > 0) storeMap[s.key.toString()] = qty;
          }
          if (storeMap.isNotEmpty) result[itemId] = storeMap;
        }
        return result;
      }

      Map<String, _HomeCareLotStock> parseHomeCareLots(dynamic src) {
        final result = <String, _HomeCareLotStock>{};
        if (src is! Map) return result;
        for (final e in src.entries) {
          final key = e.key.toString();
          final value = e.value;
          if (key.isEmpty || value is! Map) continue;
          final map = Map<String, dynamic>.from(
            value.map((k, v) => MapEntry(k.toString(), v)),
          );
          result[key] = _HomeCareLotStock.fromMap(key, map);
        }
        return result;
      }

      final homeCareLots = parseHomeCareLots(raw['homeCareLots']);

      final rawHandoverLogs = raw['homeCareHandoverLogs'];
      final handoverLogs = <_HandoverLogEntry>[];
      if (rawHandoverLogs is List) {
        for (final e in rawHandoverLogs) {
          if (e is! Map) continue;
          handoverLogs.add(
            _HandoverLogEntry.fromMap(
              Map<String, dynamic>.from(
                e.map((k, v) => MapEntry(k.toString(), v)),
              ),
            ),
          );
        }
      }

      final rawAdjustments = raw['homeCareRemainingAdjustments'];
      final adjustments = <_RemainingAdjustmentEntry>[];
      if (rawAdjustments is List) {
        for (final e in rawAdjustments) {
          if (e is! Map) continue;
          adjustments.add(
            _RemainingAdjustmentEntry.fromMap(
              Map<String, dynamic>.from(
                e.map((k, v) => MapEntry(k.toString(), v)),
              ),
            ),
          );
        }
      }

      setState(() {
        _items = items;
        _stores = stores;
        _orders = parseNestedQty(raw['orders']);
        _deliveries = parseNestedQty(raw['deliveries']);
        _homeCareLots = homeCareLots;
        _homeCareReflectedUnits = parseNestedQty(raw['homeCareReflectedUnits']);
        _handoverLogs = handoverLogs;
        _remainingAdjustments = adjustments;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  TextEditingController _ctrl(String itemId, String storeId) {
    final key = '${itemId}_$storeId';
    final ordered = (_orders[itemId] ?? {})[storeId] ?? 0;
    return _controllers.putIfAbsent(
      key,
      () => TextEditingController(text: ordered > 0 ? '$ordered' : ''),
    );
  }

  bool _isHomeCareSet(SpecialOrderItem item) {
    final name = item.name.toLowerCase();
    return item.type == '特別発注' &&
        (name.contains('ホームケア') ||
            name.contains('homecare') ||
            name.contains('home care'));
  }

  String _homeCareLotKey(SpecialOrderItem item) {
    final base = _normalizeCode(item.code).isNotEmpty
        ? _normalizeCode(item.code)
        : item.name.trim().toLowerCase();
    return base64Url.encode(utf8.encode(base)).replaceAll('=', '');
  }

  _HomeCareLotStock _homeCareLotFor(SpecialOrderItem item) {
    final key = _homeCareLotKey(item);
    return _homeCareLots[key] ??
        _HomeCareLotStock(
          key: key,
          code: item.code,
          name: item.name,
          lotSize: 1,
          remaining: 0,
        );
  }

  int _positiveIntFromController(
    TextEditingController controller,
    int fallback,
  ) {
    final value = int.tryParse(controller.text.trim());
    if (value == null || value <= 0) return fallback;
    return value;
  }

  TextEditingController _homeCareLotCtrl(SpecialOrderItem item) {
    final lot = _homeCareLotFor(item);
    return _homeCareLotControllers.putIfAbsent(
      lot.key,
      () =>
          TextEditingController(text: lot.lotSize > 0 ? '${lot.lotSize}' : '1'),
    );
  }

  TextEditingController _homeCareCustomerCtrl(SpecialOrderItem item) {
    final key = _homeCareLotKey(item);
    return _homeCareCustomerControllers.putIfAbsent(
      key,
      () => TextEditingController(),
    );
  }

  TextEditingController _homeCareDeliveryQtyCtrl(SpecialOrderItem item) {
    final key = _homeCareLotKey(item);
    return _homeCareDeliveryControllers.putIfAbsent(
      key,
      () => TextEditingController(text: '1'),
    );
  }

  int _homeCareReflectedTotalForItem(SpecialOrderItem item) {
    return (_homeCareReflectedUnits[item.id] ?? {}).values.fold(
      0,
      (a, b) => a + b,
    );
  }

  int _homeCareOrderedLotTotalForItem(SpecialOrderItem item) {
    return (_orders[item.id] ?? {}).values.fold(0, (a, b) => a + b);
  }

  Future<void> _syncHomeCareExistingOrders(SpecialOrderItem item) async {
    if (!_isHomeCareSet(item)) return;
    final storeOrders = Map<String, int>.from(_orders[item.id] ?? {});
    final totalLots = storeOrders.values.fold(0, (a, b) => a + b);
    if (totalLots <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('反映する発注済みロットがありません')));
      return;
    }

    final lot = _homeCareLotFor(item);
    final lotSize = _positiveIntFromController(
      _homeCareLotCtrl(item),
      lot.lotSize <= 0 ? 1 : lot.lotSize,
    );
    final targetUnitsByStore = <String, int>{};
    for (final entry in storeOrders.entries) {
      if (entry.value > 0) {
        targetUnitsByStore[entry.key] = entry.value * lotSize;
      }
    }
    final targetTotal = targetUnitsByStore.values.fold(0, (a, b) => a + b);
    final reflectedTotal = _homeCareReflectedTotalForItem(item);
    final delta = reflectedTotal == 0 && lot.remaining > 0
        ? max(0, targetTotal - lot.remaining)
        : targetTotal - reflectedTotal;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('既存発注を在庫へ反映'),
        content: Text(
          '${item.name}\n発注済み $totalLots ロット × 1ロット $lotSize 個 = $targetTotal 個\n\n引渡可能在庫へ反映します。\n※すでに反映済みの分は二重加算しません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('反映する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await AppSession.doc('special_orders').set({
        'homeCareLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lotSize,
            if (delta > 0)
              'remaining': FieldValue.increment(delta)
            else if (delta < 0)
              'remaining': max(0, lot.remaining + delta),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
        'homeCareReflectedUnits': {item.id: targetUnitsByStore},
      }, SetOptions(merge: true));

      setState(() {
        _homeCareLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          lotSize: lotSize,
          remaining: max(0, lot.remaining + delta),
        );
        _homeCareReflectedUnits[item.id] = targetUnitsByStore;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('既存発注を在庫へ反映しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('反映失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year}年${d.month.toString().padLeft(2, '0')}月'
      '${d.day.toString().padLeft(2, '0')}日';

  int _specialNameGroup(String value) {
    final text = value.trim();
    if (text.isEmpty) return 4;
    final first = text.runes.first;
    if ((first >= 0x3040 && first <= 0x30FF) ||
        (first >= 0x4E00 && first <= 0x9FFF)) {
      return 1;
    }
    if ((first >= 0x41 && first <= 0x5A) ||
        (first >= 0x61 && first <= 0x7A) ||
        (first >= 0xFF21 && first <= 0xFF3A) ||
        (first >= 0xFF41 && first <= 0xFF5A)) {
      return 2;
    }
    if ((first >= 0x30 && first <= 0x39) ||
        (first >= 0xFF10 && first <= 0xFF19)) {
      return 3;
    }
    return 4;
  }

  int _compareSpecialOrderItems(SpecialOrderItem a, SpecialOrderItem b) {
    if (!widget.showExpiredOnly) {
      final expiredCompare = a.isExpired == b.isExpired
          ? 0
          : (a.isExpired ? 1 : -1);
      if (expiredCompare != 0) return expiredCompare;
    }

    final endCompare = widget.showExpiredOnly || a.isExpired
        ? b.salesEnd.compareTo(a.salesEnd)
        : a.salesEnd.compareTo(b.salesEnd);
    if (endCompare != 0) return endCompare;

    final codeCompare = _naturalCompare(
      _normalizeCode(a.code),
      _normalizeCode(b.code),
    );
    if (codeCompare != 0) return codeCompare;

    final groupCompare = _specialNameGroup(
      a.name,
    ).compareTo(_specialNameGroup(b.name));
    if (groupCompare != 0) return groupCompare;

    return _naturalCompare(a.name, b.name);
  }

  bool _matchesSpecialOrderQuery(SpecialOrderItem item) {
    if (widget.showExpiredOnly && !item.isExpired) return false;

    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final normalizedQ = _normalizeCode(q);
    return item.name.toLowerCase().contains(q) ||
        item.type.toLowerCase().contains(q) ||
        _normalizeCode(item.code).contains(normalizedQ);
  }

  Future<void> _placeOrder(
    SpecialOrderItem item,
    String storeId,
    int qty,
  ) async {
    if (qty > 0 && !item.isInSalesPeriod) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            item.isBeforeSales ? '販売期間前のため入力できません' : '販売期間終了のため入力できません',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final storeName = _stores
        .firstWhere(
          (s) => s.id == storeId,
          orElse: () => LegacyStore(id: storeId, code: '', name: storeId),
        )
        .name;
    final oldQty = (_orders[item.id] ?? {})[storeId] ?? 0;

    if (qty <= 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('発注キャンセル確認'),
          content: Text('$storeName の ${item.name} の発注をキャンセルしますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('いいえ'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('キャンセルする'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        final updates = <String, dynamic>{
          'orders.${item.id}.$storeId': FieldValue.delete(),
        };
        if (_isHomeCareSet(item) && oldQty > 0) {
          final lot = _homeCareLotFor(item);
          final reflectedUnits =
              (_homeCareReflectedUnits[item.id] ?? {})[storeId] ?? 0;
          final lotSize = _positiveIntFromController(
            _homeCareLotCtrl(item),
            lot.lotSize <= 0 ? 1 : lot.lotSize,
          );
          if (reflectedUnits > 0) {
            updates['homeCareLots.${lot.key}.remaining'] = max(
              0,
              lot.remaining - reflectedUnits,
            );
          }
          updates['homeCareLots.${lot.key}.lotSize'] = lotSize;
          updates['homeCareLots.${lot.key}.code'] = item.code;
          updates['homeCareLots.${lot.key}.name'] = item.name;
          updates['homeCareLots.${lot.key}.updatedAt'] =
              FieldValue.serverTimestamp();
          updates['homeCareReflectedUnits.${item.id}.$storeId'] =
              FieldValue.delete();
        }
        await AppSession.doc('special_orders').update(updates);
      } on FirebaseException catch (e) {
        if (e.code != 'not-found') rethrow;
      }
      setState(() {
        _orders[item.id]?.remove(storeId);
        if (_orders[item.id]?.isEmpty ?? false) _orders.remove(item.id);
        if (_isHomeCareSet(item) && oldQty > 0) {
          final lot = _homeCareLotFor(item);
          final reflectedUnits =
              (_homeCareReflectedUnits[item.id] ?? {})[storeId] ?? 0;
          final lotSize = _positiveIntFromController(
            _homeCareLotCtrl(item),
            lot.lotSize <= 0 ? 1 : lot.lotSize,
          );
          _homeCareLots[lot.key] = lot.copyWith(
            lotSize: lotSize,
            remaining: max(0, lot.remaining - reflectedUnits),
            code: item.code,
            name: item.name,
          );
          _homeCareReflectedUnits[item.id]?.remove(storeId);
          if (_homeCareReflectedUnits[item.id]?.isEmpty ?? false) {
            _homeCareReflectedUnits.remove(item.id);
          }
        }
      });
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('仮発注確認'),
        content: Text('${item.name}\n$storeName: $qty 個を仮発注します'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仮発注する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final writeData = <String, dynamic>{
        'orders': {
          item.id: {storeId: qty},
        },
      };
      _HomeCareLotStock? homeCareLot;
      int lotSize = 1;
      int addUnits = 0;
      if (_isHomeCareSet(item)) {
        homeCareLot = _homeCareLotFor(item);
        lotSize = _positiveIntFromController(
          _homeCareLotCtrl(item),
          homeCareLot.lotSize <= 0 ? 1 : homeCareLot.lotSize,
        );
        final oldReflectedUnits =
            (_homeCareReflectedUnits[item.id] ?? {})[storeId] ?? 0;
        final newReflectedUnits = qty * lotSize;
        addUnits = newReflectedUnits - oldReflectedUnits;
        writeData['homeCareLots'] = {
          homeCareLot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lotSize,
            if (addUnits > 0)
              'remaining': FieldValue.increment(addUnits)
            else if (addUnits < 0)
              'remaining': max(0, homeCareLot.remaining + addUnits),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        };
        writeData['homeCareReflectedUnits'] = {
          item.id: {storeId: qty * lotSize},
        };
      }

      await AppSession.doc(
        'special_orders',
      ).set(writeData, SetOptions(merge: true));
      setState(() {
        _orders.putIfAbsent(item.id, () => {})[storeId] = qty;
        if (homeCareLot != null) {
          _homeCareLots[homeCareLot.key] = homeCareLot.copyWith(
            code: item.code,
            name: item.name,
            lotSize: lotSize,
            remaining: max(0, homeCareLot.remaining + addUnits),
          );
          _homeCareReflectedUnits.putIfAbsent(item.id, () => {})[storeId] =
              qty * lotSize;
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('仮発注しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deliverHomeCare(SpecialOrderItem item) async {
    final lot = _homeCareLotFor(item);
    final customerCode = _homeCareCustomerCtrl(item).text.trim();
    final qty = int.tryParse(_homeCareDeliveryQtyCtrl(item).text.trim()) ?? 0;

    if (customerCode.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('顧客コードを入力してください')));
      return;
    }
    if (qty <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('納品数量は1以上にしてください')));
      return;
    }
    if (qty > lot.remaining) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('残数が不足しています（残数 ${lot.remaining} 個）'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ホームケア納品確認'),
        content: Text(
          '${lot.name}\n顧客コード: $customerCode\n納品数量: $qty 個\n\n在庫から差し引きます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('納品する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await AppSession.doc('special_orders').set({
        'homeCareLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': _positiveIntFromController(
              _homeCareLotCtrl(item),
              lot.lotSize <= 0 ? 1 : lot.lotSize,
            ),
            'remaining': FieldValue.increment(-qty),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
        'homeCareHandoverLogs': FieldValue.arrayUnion([
          {
            'key': lot.key,
            'code': item.code,
            'name': item.name,
            'customerCode': customerCode,
            'qty': qty,
            'at': Timestamp.now(),
          },
        ]),
      }, SetOptions(merge: true));

      setState(() {
        _homeCareLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          lotSize: _positiveIntFromController(
            _homeCareLotCtrl(item),
            lot.lotSize <= 0 ? 1 : lot.lotSize,
          ),
          remaining: max(0, lot.remaining - qty),
        );
        _homeCareCustomerCtrl(item).clear();
        _homeCareDeliveryQtyCtrl(item).text = '1';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('納品しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('納品失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _editRemaining(SpecialOrderItem item) async {
    if (!AppSession.isSuperAdmin) return;
    final lot = _homeCareLotFor(item);
    final newValueCtrl = TextEditingController(text: '${lot.remaining}');
    final reasonCtrl = TextEditingController();
    try {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('納品可能在庫数を編集（統括管理者）'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${lot.name}\n現在の在庫数: ${lot.remaining} 個'),
              const SizedBox(height: 12),
              TextField(
                controller: newValueCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '新しい在庫数',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '変更理由（任意）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('変更する'),
            ),
          ],
        ),
      );
      if (proceed != true) return;

      final newValue = int.tryParse(newValueCtrl.text.trim());
      if (newValue == null || newValue < 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('正しい数値を入力してください'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
      final oldValue = lot.remaining;
      if (newValue == oldValue) return;
      final reason = reasonCtrl.text.trim();
      if (!mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('在庫数の変更を確定しますか？'),
          content: Text(
            '${lot.name}\n$oldValue 個 → $newValue 個'
            '${reason.isEmpty ? '' : '\n理由: $reason'}'
            '\n\nこの操作は変更履歴に記録されます。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('確定する'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      try {
        await AppSession.doc('special_orders').set({
          'homeCareLots': {
            lot.key: {
              'code': item.code,
              'name': item.name,
              'remaining': newValue,
              'updatedAt': FieldValue.serverTimestamp(),
            },
          },
          'homeCareRemainingAdjustments': FieldValue.arrayUnion([
            {
              'key': lot.key,
              'oldValue': oldValue,
              'newValue': newValue,
              'reason': reason,
              'adjustedBy': AppSession.nickname,
              'adjustedByEmail': AppSession.email,
              'at': Timestamp.now(),
            },
          ]),
        }, SetOptions(merge: true));

        setState(() {
          _homeCareLots[lot.key] = lot.copyWith(
            code: item.code,
            name: item.name,
            remaining: newValue,
          );
          _remainingAdjustments = [
            ..._remainingAdjustments,
            _RemainingAdjustmentEntry(
              key: lot.key,
              oldValue: oldValue,
              newValue: newValue,
              reason: reason,
              adjustedBy: AppSession.nickname,
              at: DateTime.now(),
            ),
          ];
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('在庫数を変更しました'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('変更失敗: $e'), backgroundColor: Colors.red),
          );
        }
      }
    } finally {
      newValueCtrl.dispose();
      reasonCtrl.dispose();
    }
  }

  Future<void> _deliver(SpecialOrderItem item, LegacyStore store) async {
    final orderedQty = (_orders[item.id] ?? {})[store.id] ?? 0;
    if (orderedQty <= 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('納品確認'),
        content: Text('${item.name}\n${store.name}: $orderedQty個を納品済みにします'),
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

    try {
      await AppSession.doc('special_orders').set({
        'orders': {
          item.id: {store.id: FieldValue.delete()},
        },
        'deliveries': {
          item.id: {store.id: orderedQty},
        },
      }, SetOptions(merge: true));
      setState(() {
        _orders[item.id]?.remove(store.id);
        if (_orders[item.id]?.isEmpty ?? false) _orders.remove(item.id);
        _deliveries.putIfAbsent(item.id, () => {})[store.id] = orderedQty;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('納品しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _normalizeCode(String s) => String.fromCharCodes(
    s.runes.map((r) {
      if (r >= 0xFF01 && r <= 0xFF5E) return r - 0xFEE0;
      if (r == 0x3000) return 0x20;
      return r;
    }),
  ).toLowerCase().trim();

  Future<void> _addItem({SpecialOrderItem? template}) async {
    final result = await _showRegistrationDialog(
      initial: template,
      duplicateMode: template != null,
    );
    if (result == null) return;

    final newId = FirebaseFirestore.instance.collection('_').doc().id;
    final newItem = SpecialOrderItem(
      id: newId,
      type: result['type'] as String,
      name: result['name'] as String,
      code: result['code'] as String,
      salesStart: result['salesStart'] as DateTime,
      salesEnd: result['salesEnd'] as DateTime,
      arrival: result['arrival'] as DateTime,
      createdAt: DateTime.now(),
    );

    try {
      await AppSession.doc('special_orders').set({
        'items': FieldValue.arrayUnion([newItem.toMap()]),
      }, SetOptions(merge: true));

      final masterAddResult = result['type'] == 'その他'
          ? _MasterAddResult.skipped
          : await _addToProductAndTesterMastersIfMissing(newItem);

      setState(() => _items.insert(0, newItem));
      if (mounted) {
        final masterMessage = switch (masterAddResult) {
          _MasterAddResult.added => '（商品・テスターマスタに追加済み）',
          _MasterAddResult.alreadyExists => '（商品・テスターマスタは既存コードのため追加なし）',
          _MasterAddResult.skipped => '',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${newItem.name} を登録しました$masterMessage'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登録失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<_MasterAddResult> _addToProductAndTesterMastersIfMissing(
    SpecialOrderItem item,
  ) async {
    final normalizedCode = _normalizeCode(item.code);
    if (normalizedCode.isEmpty) return _MasterAddResult.skipped;

    final results = await Future.wait([
      AppSession.doc('products').get(),
      AppSession.doc('testers').get(),
    ]);

    final products = _parseItemsFromDoc(results[0]);
    final testers = _parseItemsFromDoc(results[1]);

    LegacyItem? existingProduct;
    for (final product in products) {
      if (_normalizeCode(product.code) == normalizedCode) {
        existingProduct = product;
        break;
      }
    }

    LegacyItem? existingTester;
    for (final tester in testers) {
      if (_normalizeCode(tester.code) == normalizedCode) {
        existingTester = tester;
        break;
      }
    }

    final masterId = existingProduct?.id ?? existingTester?.id ?? item.id;
    final masterItem = {'id': masterId, 'code': item.code, 'name': item.name};

    final writes = <Future<void>>[];
    if (existingProduct == null) {
      writes.add(
        AppSession.doc('products').set({
          'items': FieldValue.arrayUnion([masterItem]),
        }, SetOptions(merge: true)),
      );
    }
    if (existingTester == null) {
      writes.add(
        AppSession.doc('testers').set({
          'items': FieldValue.arrayUnion([masterItem]),
        }, SetOptions(merge: true)),
      );
    }

    if (writes.isEmpty) return _MasterAddResult.alreadyExists;
    await Future.wait(writes);
    _clearMasterDataCache();
    return _MasterAddResult.added;
  }

  Future<void> _reflectExistingItemsToMasters() async {
    final targetItems = _items
        .where((item) => item.type == '特別発注' || item.type == '新規発注')
        .where((item) => _normalizeCode(item.code).isNotEmpty)
        .toList();

    if (targetItems.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('反映対象がありません'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('既存分をマスタへ反映'),
        content: Text(
          '特別発注・新規発注の既存登録 ${targetItems.length} 件を確認し、\n'
          '商品マスタ・テスターマスタに未登録のコードだけ追加します。\n\n'
          '同一コードがあるものは追加しません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('反映する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final results = await Future.wait([
        AppSession.doc('products').get(),
        AppSession.doc('testers').get(),
      ]);

      final products = _parseItemsFromDoc(results[0]);
      final testers = _parseItemsFromDoc(results[1]);

      final productByCode = <String, LegacyItem>{};
      for (final product in products) {
        final code = _normalizeCode(product.code);
        if (code.isNotEmpty) productByCode[code] = product;
      }

      final testerByCode = <String, LegacyItem>{};
      for (final tester in testers) {
        final code = _normalizeCode(tester.code);
        if (code.isNotEmpty) testerByCode[code] = tester;
      }

      final productAdds = <Map<String, dynamic>>[];
      final testerAdds = <Map<String, dynamic>>[];
      final productAddCodes = <String>{};
      final testerAddCodes = <String>{};

      for (final item in targetItems) {
        final code = _normalizeCode(item.code);
        final existingProduct = productByCode[code];
        final existingTester = testerByCode[code];
        final masterId = existingProduct?.id ?? existingTester?.id ?? item.id;
        final masterItem = {
          'id': masterId,
          'code': item.code,
          'name': item.name,
        };

        if (existingProduct == null && !productAddCodes.contains(code)) {
          productAdds.add(masterItem);
          productAddCodes.add(code);
        }
        if (existingTester == null && !testerAddCodes.contains(code)) {
          testerAdds.add(masterItem);
          testerAddCodes.add(code);
        }
      }

      final writes = <Future<void>>[];
      if (productAdds.isNotEmpty) {
        writes.add(
          AppSession.doc('products').set({
            'items': FieldValue.arrayUnion(productAdds),
          }, SetOptions(merge: true)),
        );
      }
      if (testerAdds.isNotEmpty) {
        writes.add(
          AppSession.doc('testers').set({
            'items': FieldValue.arrayUnion(testerAdds),
          }, SetOptions(merge: true)),
        );
      }

      if (writes.isNotEmpty) {
        await Future.wait(writes);
        _clearMasterDataCache();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '反映完了：商品 ${productAdds.length} 件、テスター ${testerAdds.length} 件を追加しました',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('反映失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _duplicateItem(SpecialOrderItem item) async {
    await _addItem(template: item);
  }

  Future<void> _editItem(SpecialOrderItem item) async {
    final result = await _showRegistrationDialog(initial: item);
    if (result == null) return;

    final updated = SpecialOrderItem(
      id: item.id,
      type: result['type'] as String,
      name: result['name'] as String,
      code: result['code'] as String,
      salesStart: result['salesStart'] as DateTime,
      salesEnd: result['salesEnd'] as DateTime,
      arrival: result['arrival'] as DateTime,
      createdAt: item.createdAt,
    );

    try {
      final doc = await AppSession.doc('special_orders').get();
      final raw = doc.data() ?? {};
      final rawItems = (raw['items'] as List? ?? []).map((e) {
        if (e is Map && (e['id'] ?? '').toString() == item.id) {
          return updated.toMap();
        }
        return e;
      }).toList();
      await AppSession.doc('special_orders').update({'items': rawItems});

      setState(() {
        final idx = _items.indexWhere((i) => i.id == item.id);
        if (idx >= 0) _items[idx] = updated;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('編集しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('編集失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteItem(SpecialOrderItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('${item.name} を削除しますか？\n発注データもすべて削除されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final doc = await AppSession.doc('special_orders').get();
      final raw = doc.data() ?? {};
      final rawItems = (raw['items'] as List? ?? [])
          .where((e) => !(e is Map && (e['id'] ?? '').toString() == item.id))
          .toList();
      final updates = <String, dynamic>{'items': rawItems};
      if ((raw['orders'] as Map?)?.containsKey(item.id) == true) {
        updates['orders.${item.id}'] = FieldValue.delete();
      }
      if ((raw['deliveries'] as Map?)?.containsKey(item.id) == true) {
        updates['deliveries.${item.id}'] = FieldValue.delete();
      }
      await AppSession.doc('special_orders').update(updates);

      setState(() {
        _items.removeWhere((i) => i.id == item.id);
        _orders.remove(item.id);
        _deliveries.remove(item.id);
        _controllers.removeWhere((k, _) => k.startsWith('${item.id}_'));
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('削除しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _showRegistrationDialog({
    SpecialOrderItem? initial,
    bool duplicateMode = false,
  }) async {
    String selectedType = initial?.type ?? '特別発注';
    final nameCtrl = TextEditingController(text: initial?.name ?? '');
    final codeCtrl = TextEditingController(text: initial?.code ?? '');
    DateTime salesStart = initial?.salesStart ?? DateTime.now();
    DateTime salesEnd =
        initial?.salesEnd ?? DateTime.now().add(const Duration(days: 90));
    DateTime arrival =
        initial?.arrival ?? DateTime.now().add(const Duration(days: 14));
    final isEdit = initial != null && !duplicateMode;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> pickDate(String field) async {
            final init = field == 'start'
                ? salesStart
                : (field == 'end' ? salesEnd : arrival);
            final picked = await showDatePicker(
              context: ctx,
              initialDate: init,
              firstDate: DateTime(2020),
              lastDate: DateTime(2035),
            );
            if (picked == null) return;
            setS(() {
              if (field == 'start') {
                salesStart = picked;
              } else if (field == 'end') {
                salesEnd = picked;
              } else {
                arrival = picked;
              }
            });
          }

          String fmtD(DateTime d) =>
              '${d.year}/${d.month.toString().padLeft(2, '0')}/'
              '${d.day.toString().padLeft(2, '0')}';

          return AlertDialog(
            title: Text(
              isEdit
                  ? '発注情報を編集'
                  : (duplicateMode ? '複製して新規登録' : '特別発注・新規発注 登録'),
            ),
            content: SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '種別',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      children: _kTypes
                          .map(
                            (t) => ChoiceChip(
                              label: Text(t),
                              selected: selectedType == t,
                              onSelected: (_) => setS(() => selectedType = t),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '商品名',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: codeCtrl,
                      decoration: const InputDecoration(
                        labelText: '商品コード',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '販売期間',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => pickDate('start'),
                            child: Text(
                              fmtD(salesStart),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Text('〜'),
                        ),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => pickDate('end'),
                            child: Text(
                              fmtD(salesEnd),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '本店到着予定日',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    OutlinedButton(
                      onPressed: () => pickDate('arrival'),
                      child: Text(fmtD(arrival)),
                    ),
                    if (selectedType == '新規発注')
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.blue.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 14,
                              color: Colors.blue.shade700,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '登録と同時に商品マスタ・テスターマスタに追加されます',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.blue.shade700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('キャンセル'),
              ),
              ElevatedButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  Navigator.of(ctx).pop({
                    'type': selectedType,
                    'name': name,
                    'code': codeCtrl.text.trim(),
                    'salesStart': salesStart,
                    'salesEnd': salesEnd,
                    'arrival': arrival,
                  });
                },
                child: Text(isEdit ? '保存' : '新規登録'),
              ),
            ],
          );
        },
      ),
    );
    nameCtrl.dispose();
    codeCtrl.dispose();
    return result;
  }

  Color _typeColor(String type) {
    switch (type) {
      case '新規発注':
        return Colors.blue;
      case '特別発注':
        return Colors.purple;
      default:
        return Colors.grey.shade600;
    }
  }

  Widget _buildHomeCareLotPanel(SpecialOrderItem item) {
    final lot = _homeCareLotFor(item);
    final customerCtrl = _homeCareCustomerCtrl(item);
    final qtyCtrl = _homeCareDeliveryQtyCtrl(item);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        border: Border.all(color: Colors.blue.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'ホームケアセット在庫',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${lot.name} / コード:${lot.code.isEmpty ? item.code : lot.code}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '納品可能在庫：${lot.remaining} 個',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (AppSession.isSuperAdmin) ...[
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _editRemaining(item),
                        borderRadius: BorderRadius.circular(4),
                        child: Icon(
                          Icons.edit,
                          size: 18,
                          color: Colors.blueGrey.shade400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (AppSession.isAdmin || AppSession.isSuperAdmin) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: customerCtrl,
                    decoration: const InputDecoration(
                      labelText: '顧客コード',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: qtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '数量',
                      suffixText: '個',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: lot.remaining <= 0
                  ? null
                  : () => _deliverHomeCare(item),
              icon: const Icon(Icons.output),
              label: const Text('納品'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '※発注すると上の納品可能在庫に加算され、納品すると減ります。',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
            ),
          ],
          const SizedBox(height: 8),
          _buildHomeCareHistoryTile(lot.key),
        ],
      ),
    );
  }

  Widget _buildHomeCareHistoryTile(String lotKey) {
    final entries = <_LotHistoryEntry>[
      for (final log in _handoverLogs)
        if (log.key == lotKey) _LotHistoryEntry.delivery(log),
      for (final adj in _remainingAdjustments)
        if (adj.key == lotKey) _LotHistoryEntry.adjustment(adj),
    ]..sort((a, b) => b.at.compareTo(a.at));

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 4),
      title: Text(
        '納品・在庫調整履歴（${entries.length}件）',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.blueGrey.shade700,
        ),
      ),
      children: [
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '履歴はまだありません',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          )
        else
          for (final entry in entries) _buildHomeCareHistoryRow(entry),
      ],
    );
  }

  Widget _buildHomeCareHistoryRow(_LotHistoryEntry entry) {
    final isDelivery = entry.type == 'delivery';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isDelivery ? Colors.green.shade100 : Colors.red.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isDelivery ? '納品' : '在庫調整',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: isDelivery ? Colors.green.shade900 : Colors.red.shade900,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isDelivery
                  ? '${_formatDateTime(entry.at)}\n'
                        '顧客コード: ${entry.customerCode.isEmpty ? '-' : entry.customerCode} / ${entry.qty}個'
                  : '${_formatDateTime(entry.at)}\n'
                        '${entry.oldValue}個 → ${entry.newValue}個'
                        '${entry.reason.isEmpty ? '' : ' / 理由: ${entry.reason}'}'
                        '${entry.adjustedBy.isEmpty ? '' : ' / 実施者: ${entry.adjustedBy}'}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeCareOrderLotBox(SpecialOrderItem item) {
    if (!_isHomeCareSet(item)) return const SizedBox.shrink();
    final lot = _homeCareLotFor(item);
    final lotCtrl = _homeCareLotCtrl(item);
    final orderedLots = _homeCareOrderedLotTotalForItem(item);
    final reflectedUnits = _homeCareReflectedTotalForItem(item);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border.all(color: Colors.orange.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'この発注のロット設定',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade900,
                  ),
                ),
              ),
              if (orderedLots > 0)
                Text(
                  '発注済 $orderedLots ロット',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange.shade900,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 132,
                child: TextField(
                  controller: lotCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '1ロット＝何個',
                    suffixText: '個',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '発注ボタンで ${lot.name} の納品可能在庫に反映します。',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          if (orderedLots > 0) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _syncHomeCareExistingOrders(item),
              icon: const Icon(Icons.sync),
              label: Text(reflectedUnits > 0 ? '発注済み分を再計算' : '発注済み分を在庫へ反映'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStoreRow(SpecialOrderItem item, LegacyStore store) {
    final ordered = (_orders[item.id] ?? {})[store.id] ?? 0;
    final delivered = (_deliveries[item.id] ?? {})[store.id] ?? 0;
    final ctrl = _ctrl(item.id, store.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(
                  store.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                width: 64,
                child: TextField(
                  controller: ctrl,
                  enabled: item.isInSalesPeriod,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    border: OutlineInputBorder(),
                    hintText: '0',
                    suffixText: '個',
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (item.isInSalesPeriod) ...[
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    final qty = int.tryParse(ctrl.text.trim()) ?? 0;
                    _placeOrder(item, store.id, qty);
                  },
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('仮発注', style: TextStyle(fontSize: 13)),
                ),
              ],
            ],
          ),
          if (ordered > 0 || delivered > 0)
            Padding(
              padding: const EdgeInsets.only(left: 76, top: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (ordered > 0) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _isHomeCareSet(item)
                            ? '発注済: $ordered ロット'
                            : '納品予定: $ordered 個',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (AppSession.isAdmin || AppSession.isSuperAdmin)
                      InkWell(
                        onTap: () => _deliver(item, store),
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.shade100,
                            border: Border.all(color: Colors.green.shade400),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '納品',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.green.shade800,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                  if (delivered > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '納品済: $delivered 個',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.blue.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const Divider(height: 12),
        ],
      ),
    );
  }

  List<SpecialOrderItem> _uniqueHomeCareItems(List<SpecialOrderItem> items) {
    final byKey = <String, SpecialOrderItem>{};
    for (final item in items) {
      if (!_isHomeCareSet(item)) continue;
      byKey.putIfAbsent(_homeCareLotKey(item), () => item);
    }
    return byKey.values.toList()..sort((a, b) {
      final c = _naturalCompare(_normalizeCode(a.code), _normalizeCode(b.code));
      return c != 0 ? c : _naturalCompare(a.name, b.name);
    });
  }

  Widget _buildHomeCareTopSummary(List<SpecialOrderItem> homeCareItems) {
    final uniqueItems = _uniqueHomeCareItems(homeCareItems);
    if (uniqueItems.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              border: Border.all(color: Colors.blue.shade200),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      color: Colors.blue.shade700,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'ホームケアセット在庫',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '商品コードごとに、今お客様へ納品できる在庫数を表示しています。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.blueGrey.shade700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final item in uniqueItems) _buildHomeCareLotPanel(item),
        ],
      ),
    );
  }

  Widget _buildSpecialOrderList(
    List<SpecialOrderItem> visibleItems, {
    required bool homeCareMode,
  }) {
    final emptyMessage = homeCareMode
        ? 'ホームケアセットの発注はありません'
        : (widget.showExpiredOnly ? '検索に一致する販売終了発注はありません' : '検索に一致する発注はありません');
    final extraTopCount = homeCareMode ? 3 : 2;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount:
          extraTopCount + (visibleItems.isEmpty ? 1 : visibleItems.length),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '商品名・コード・種別で検索',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          );
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              homeCareMode
                  ? 'ホームケアセット：上部に商品コード別残数、その下に各発注を表示'
                  : (widget.showExpiredOnly
                        ? '表示順：販売終了日が新しい順 → コード順 → 商品名順'
                        : '表示順：販売終了日が近い順 → 期間終了は一番下 → コード順'),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          );
        }
        if (homeCareMode && index == 2) {
          return _buildHomeCareTopSummary(visibleItems);
        }
        if (visibleItems.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              emptyMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          );
        }
        return _buildItemCard(visibleItems[index - extraTopCount]);
      },
    );
  }

  Widget _buildItemCard(SpecialOrderItem item) {
    final c = _typeColor(item.type);
    final totalOrdered = (_orders[item.id] ?? {}).values.fold(
      0,
      (a, b) => a + b,
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 20),
          onSelected: (v) {
            if (v == 'edit') {
              _editItem(item);
            } else if (v == 'duplicate') {
              _duplicateItem(item);
            } else if (v == 'delete') {
              _deleteItem(item);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit, size: 16),
                  SizedBox(width: 8),
                  Text('編集'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'duplicate',
              child: Row(
                children: [
                  Icon(Icons.copy, size: 16),
                  SizedBox(width: 8),
                  Text('複製して新規登録'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, size: 16, color: Colors.red),
                  SizedBox(width: 8),
                  Text('削除', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.15),
                border: Border.all(color: c.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                item.type,
                style: TextStyle(
                  fontSize: 10,
                  color: c,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.name,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: item.isInSalesPeriod ? null : Colors.grey,
                  decoration: item.isExpired
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
            if (!item.isInSalesPeriod)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  item.isBeforeSales ? '期間前' : '期間終了',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              )
            else if (totalOrdered > 0)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '合計 $totalOrdered 個',
                  style: TextStyle(fontSize: 10, color: Colors.orange.shade700),
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('コード: ${item.code}', style: const TextStyle(fontSize: 12)),
              Text(
                '販売期間: ${_fmtDate(item.salesStart)} 〜 ${_fmtDate(item.salesEnd)}',
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                '本店到着予定: ${_fmtDate(item.arrival)}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        children: [
          const Divider(height: 1),
          if (_isHomeCareSet(item)) _buildHomeCareOrderLotBox(item),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '各店舗 仮発注数',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          for (final store in _stores) _buildStoreRow(item, store),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredItems = _items.where(_matchesSpecialOrderQuery).toList()
      ..sort(_compareSpecialOrderItems);
    final normalItems = filteredItems
        .where((item) => !_isHomeCareSet(item))
        .toList();
    final q = _query.trim().toLowerCase();
    final normalizedQ = _normalizeCode(q);
    final homeCareItems = _items.where(_isHomeCareSet).where((item) {
      if (q.isEmpty) return true;
      return item.name.toLowerCase().contains(q) ||
          item.type.toLowerCase().contains(q) ||
          _normalizeCode(item.code).contains(normalizedQ);
    }).toList()..sort(_compareSpecialOrderItems);

    Widget buildBody() {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Text('読み込みエラー: $_error'),
        );
      }
      if (_items.isEmpty) {
        return Center(
          child: Text(
            widget.showExpiredOnly
                ? '販売終了した発注はありません'
                : '登録された発注はありません\n＋ボタンから登録してください',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        );
      }
      if (widget.showExpiredOnly) {
        return _buildSpecialOrderList(filteredItems, homeCareMode: false);
      }
      return TabBarView(
        children: [
          _buildSpecialOrderList(normalItems, homeCareMode: false),
          _buildSpecialOrderList(homeCareItems, homeCareMode: true),
        ],
      );
    }

    final scaffold = Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: Text(widget.showExpiredOnly ? '販売終了' : '特別発注・新規発注'),
        bottom: widget.showExpiredOnly
            ? null
            : const TabBar(
                tabs: [
                  Tab(text: '通常発注'),
                  Tab(text: 'ホームケアセット'),
                ],
              ),
        actions: [
          if (!widget.showExpiredOnly) ...[
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: '販売終了ページ',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        const SpecialOrderPage(showExpiredOnly: true),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: '既存分を商品・テスターへ反映',
              onPressed: _reflectExistingItemsToMasters,
            ),
          ],
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '再読み込み',
            onPressed: _load,
          ),
        ],
      ),
      body: buildBody(),
      floatingActionButton: widget.showExpiredOnly
          ? null
          : FloatingActionButton(
              onPressed: _addItem,
              tooltip: '新規登録',
              child: const Icon(Icons.add),
            ),
    );

    if (widget.showExpiredOnly) return scaffold;
    return DefaultTabController(length: 2, child: scaffold);
  }
}

// ─────────────────────────────────────────────
// 利用規約・プライバシーポリシー
// ─────────────────────────────────────────────

class _HomeCareLotStock {
  const _HomeCareLotStock({
    required this.key,
    required this.code,
    required this.name,
    required this.lotSize,
    required this.remaining,
  });

  final String key;
  final String code;
  final String name;
  final int lotSize;
  final int remaining;

  factory _HomeCareLotStock.fromMap(String key, Map<String, dynamic> map) {
    return _HomeCareLotStock(
      key: key,
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      lotSize: inventoryIntValue(map['lotSize']) <= 0
          ? 1
          : inventoryIntValue(map['lotSize']),
      remaining: max(0, inventoryIntValue(map['remaining'])),
    );
  }

  _HomeCareLotStock copyWith({
    String? code,
    String? name,
    int? lotSize,
    int? remaining,
  }) {
    return _HomeCareLotStock(
      key: key,
      code: code ?? this.code,
      name: name ?? this.name,
      lotSize: lotSize ?? this.lotSize,
      remaining: remaining ?? this.remaining,
    );
  }
}

// ホームケアセットの顧客への納品履歴（homeCareHandoverLogs）
class _HandoverLogEntry {
  _HandoverLogEntry({
    required this.key,
    required this.customerCode,
    required this.qty,
    required this.at,
  });

  final String key;
  final String customerCode;
  final int qty;
  final DateTime at;

  factory _HandoverLogEntry.fromMap(Map<String, dynamic> map) {
    return _HandoverLogEntry(
      key: (map['key'] ?? '').toString(),
      customerCode: (map['customerCode'] ?? '').toString(),
      qty: inventoryIntValue(map['qty']),
      at: _readLogTimestamp(map['at']),
    );
  }
}

// 統括管理者による在庫数直接編集の変更履歴（homeCareRemainingAdjustments）
class _RemainingAdjustmentEntry {
  _RemainingAdjustmentEntry({
    required this.key,
    required this.oldValue,
    required this.newValue,
    required this.reason,
    required this.adjustedBy,
    required this.at,
  });

  final String key;
  final int oldValue;
  final int newValue;
  final String reason;
  final String adjustedBy;
  final DateTime at;

  factory _RemainingAdjustmentEntry.fromMap(Map<String, dynamic> map) {
    return _RemainingAdjustmentEntry(
      key: (map['key'] ?? '').toString(),
      oldValue: inventoryIntValue(map['oldValue']),
      newValue: inventoryIntValue(map['newValue']),
      reason: (map['reason'] ?? '').toString(),
      adjustedBy: (map['adjustedBy'] ?? '').toString(),
      at: _readLogTimestamp(map['at']),
    );
  }
}

// ロットの結合履歴表示（納品・在庫調整を新しい順に混在表示するため）
class _LotHistoryEntry {
  _LotHistoryEntry.delivery(_HandoverLogEntry log)
    : type = 'delivery',
      at = log.at,
      customerCode = log.customerCode,
      qty = log.qty,
      oldValue = 0,
      newValue = 0,
      reason = '',
      adjustedBy = '';

  _LotHistoryEntry.adjustment(_RemainingAdjustmentEntry adj)
    : type = 'adjustment',
      at = adj.at,
      customerCode = '',
      qty = 0,
      oldValue = adj.oldValue,
      newValue = adj.newValue,
      reason = adj.reason,
      adjustedBy = adj.adjustedBy;

  final String type; // 'delivery' | 'adjustment'
  final DateTime at;
  final String customerCode;
  final int qty;
  final int oldValue;
  final int newValue;
  final String reason;
  final String adjustedBy;
}

DateTime _readLogTimestamp(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
