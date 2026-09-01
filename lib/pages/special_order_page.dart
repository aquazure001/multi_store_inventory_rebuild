part of '../main.dart';

// ─────────────────────────────────────────────
// 特別発注・新商品発注ページ
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
  final Map<String, _HomeCareCustomerOrderEntry> _homeCareCustomerOrders = {};
  List<_HandoverLogEntry> _handoverLogs = [];
  Map<String, _NewProductLotStock> _newProductLots = {};
  final Map<String, _NewProductCustomerOrderEntry> _newProductCustomerOrders =
      {};
  bool _loading = true;
  String? _error;
  bool _isRestricted = false;
  bool _noViewableStores = false;
  List<String> _visibleStoreNames = [];
  String _query = '';
  final Map<String, TextEditingController> _homeCareLotControllers = {};
  final Map<String, TextEditingController> _homeCareCustomerControllers = {};
  final Map<String, TextEditingController> _homeCareCustomerNameControllers =
      {};
  final Map<String, TextEditingController> _homeCareStoreNameControllers = {};
  final Map<String, TextEditingController>
  _homeCareCustomerOrderQtyControllers = {};
  final Map<String, TextEditingController> _homeCareRemainingControllers = {};
  final Map<String, TextEditingController> _homeCareCurrentStockControllers =
      {};
  final Map<String, TextEditingController> _homeCareDeliveredControllers = {};
  final Map<String, TextEditingController> _newProductCustomerControllers = {};
  final Map<String, TextEditingController> _newProductCustomerNameControllers =
      {};
  final Map<String, TextEditingController> _newProductStoreNameControllers = {};
  final Map<String, TextEditingController>
  _newProductCustomerOrderQtyControllers = {};
  final Map<String, TextEditingController> _newProductRemainingControllers = {};
  final Map<String, TextEditingController> _newProductCurrentStockControllers =
      {};
  final Map<String, TextEditingController> _newProductDeliveredControllers = {};

  static const _kTypes = ['特別発注', '新規発注', 'その他'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _canManageSpecialStock =>
      AppSession.isAdmin || AppSession.isSuperAdmin;

  @override
  void dispose() {
    for (final c in _homeCareLotControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareCustomerControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareCustomerNameControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareStoreNameControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareCustomerOrderQtyControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareRemainingControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareCurrentStockControllers.values) {
      c.dispose();
    }
    for (final c in _homeCareDeliveredControllers.values) {
      c.dispose();
    }
    for (final c in _newProductCustomerControllers.values) {
      c.dispose();
    }
    for (final c in _newProductCustomerNameControllers.values) {
      c.dispose();
    }
    for (final c in _newProductStoreNameControllers.values) {
      c.dispose();
    }
    for (final c in _newProductCustomerOrderQtyControllers.values) {
      c.dispose();
    }
    for (final c in _newProductRemainingControllers.values) {
      c.dispose();
    }
    for (final c in _newProductCurrentStockControllers.values) {
      c.dispose();
    }
    for (final c in _newProductDeliveredControllers.values) {
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
      final allStores = List<LegacyStore>.from(masterData.stores);
      final allStoreIds = allStores.map((s) => s.id).toList();
      final viewableIds = AppSession.operationalStoreIds(allStoreIds).toSet();
      final stores = allStores
          .where((s) => viewableIds.contains(s.id))
          .toList();
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

      Map<String, _NewProductLotStock> parseNewProductLots(dynamic src) {
        final result = <String, _NewProductLotStock>{};
        if (src is! Map) return result;
        for (final e in src.entries) {
          final key = e.key.toString();
          final value = e.value;
          if (key.isEmpty || value is! Map) continue;
          final map = Map<String, dynamic>.from(
            value.map((k, v) => MapEntry(k.toString(), v)),
          );
          result[key] = _NewProductLotStock.fromMap(key, map);
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

      final rawCustomerOrders = raw['homeCareCustomerOrders'];
      final customerOrders = <String, _HomeCareCustomerOrderEntry>{};
      if (rawCustomerOrders is Map) {
        for (final e in rawCustomerOrders.entries) {
          final value = e.value;
          if (value is! Map) continue;
          final map = Map<String, dynamic>.from(
            value.map((k, v) => MapEntry(k.toString(), v)),
          );
          final entry = _HomeCareCustomerOrderEntry.fromMap(
            e.key.toString(),
            map,
          );
          if (entry.id.isNotEmpty) customerOrders[entry.id] = entry;
        }
      }

      final newProductLots = parseNewProductLots(raw['newProductLots']);

      final rawNewProductCustomerOrders = raw['newProductCustomerOrders'];
      final newProductCustomerOrders =
          <String, _NewProductCustomerOrderEntry>{};
      if (rawNewProductCustomerOrders is Map) {
        for (final e in rawNewProductCustomerOrders.entries) {
          final value = e.value;
          if (value is! Map) continue;
          final map = Map<String, dynamic>.from(
            value.map((k, v) => MapEntry(k.toString(), v)),
          );
          final entry = _NewProductCustomerOrderEntry.fromMap(
            e.key.toString(),
            map,
          );
          if (entry.id.isNotEmpty) newProductCustomerOrders[entry.id] = entry;
        }
      }

      setState(() {
        _items = items;
        _stores = stores;
        _isRestricted = stores.length < allStores.length;
        _noViewableStores = stores.isEmpty;
        _visibleStoreNames = stores.map((s) => s.name).toList();
        _orders = parseNestedQty(raw['orders']);
        _deliveries = parseNestedQty(raw['deliveries']);
        _homeCareLots = homeCareLots;
        _homeCareCustomerOrders
          ..clear()
          ..addAll(customerOrders);
        _handoverLogs = handoverLogs;
        _newProductLots = newProductLots;
        _newProductCustomerOrders
          ..clear()
          ..addAll(newProductCustomerOrders);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
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
          currentStock: 0,
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

  TextEditingController _homeCareCustomerNameCtrl(SpecialOrderItem item) {
    final key = _homeCareLotKey(item);
    return _homeCareCustomerNameControllers.putIfAbsent(
      key,
      () => TextEditingController(),
    );
  }

  TextEditingController _homeCareStoreNameCtrl(SpecialOrderItem item) {
    final key = _homeCareLotKey(item);
    return _homeCareStoreNameControllers.putIfAbsent(
      key,
      () => TextEditingController(),
    );
  }

  String _knownCustomerNameForCode(String customerCode) {
    final code = customerCode.trim();
    if (code.isEmpty) return '';
    final matches =
        _homeCareCustomerOrders.values
            .where(
              (entry) =>
                  entry.customerCode.trim() == code &&
                  entry.customerName.trim().isNotEmpty,
            )
            .toList()
          ..sort((a, b) => b.orderedAt.compareTo(a.orderedAt));
    return matches.isEmpty ? '' : matches.first.customerName.trim();
  }

  void _applyKnownCustomerName(
    String customerCode,
    TextEditingController nameCtrl, {
    bool overwrite = false,
  }) {
    final name = _knownCustomerNameForCode(customerCode);
    if (name.isEmpty) return;
    if (!overwrite && nameCtrl.text.trim().isNotEmpty) return;
    nameCtrl.text = name;
  }

  TextEditingController _homeCareCustomerOrderQtyCtrl(SpecialOrderItem item) {
    final key = _homeCareLotKey(item);
    return _homeCareCustomerOrderQtyControllers.putIfAbsent(
      key,
      () => TextEditingController(text: '1'),
    );
  }

  TextEditingController _homeCareRemainingCtrl(SpecialOrderItem item) {
    final lot = _homeCareLotFor(item);
    return _homeCareRemainingControllers.putIfAbsent(
      lot.key,
      () => TextEditingController(text: '${lot.remaining}'),
    );
  }

  TextEditingController _homeCareCurrentStockCtrl(SpecialOrderItem item) {
    final lot = _homeCareLotFor(item);
    return _homeCareCurrentStockControllers.putIfAbsent(
      lot.key,
      () => TextEditingController(text: '${_homeCareCurrentStockForLot(lot)}'),
    );
  }

  TextEditingController _homeCareDeliveredCtrl(SpecialOrderItem item) {
    final lot = _homeCareLotFor(item);
    return _homeCareDeliveredControllers.putIfAbsent(
      lot.key,
      () => TextEditingController(text: '0'),
    );
  }

  int _homeCareOrderedLotTotalForItem(SpecialOrderItem item) {
    return (_orders[item.id] ?? {}).values.fold(0, (a, b) => a + b);
  }

  List<_HomeCareCustomerOrderEntry> _homeCareCustomerOrdersForItem(
    SpecialOrderItem item,
  ) {
    final result = _homeCareCustomerOrders.values
        .where((entry) => entry.itemId == item.id)
        .toList();
    result.sort((a, b) => b.orderedAt.compareTo(a.orderedAt));
    return result;
  }

  int _homeCareCustomerOrderTotalForItem(SpecialOrderItem item) {
    return _homeCareCustomerOrdersForItem(
      item,
    ).fold(0, (total, entry) => total + entry.qty);
  }

  int _homeCareCustomerDeliveredTotalForItem(SpecialOrderItem item) {
    return _homeCareCustomerOrdersForItem(item)
        .where((entry) => entry.delivered)
        .fold(0, (total, entry) => total + entry.qty);
  }

  // ロット（商品コード）単位で、期間をまたいだ全ての顧客別仮発注を集計する。
  List<_HomeCareCustomerOrderEntry> _homeCareCustomerOrdersForLot(
    String lotKey,
  ) {
    final result = _homeCareCustomerOrders.values
        .where((entry) => entry.lotKey == lotKey)
        .toList();
    result.sort((a, b) => b.orderedAt.compareTo(a.orderedAt));
    return result;
  }

  // ── 新商品タブ：ロット在庫・顧客別仮発注 ─────────────────────
  // コード単位で共有するキー（ホームケアセットと同様、販売期間①〜⑪等をまたいで
  // 同じ在庫を参照できるようにする）。
  String _newProductLotKey(SpecialOrderItem item) {
    final base = _normalizeCode(item.code).isNotEmpty
        ? _normalizeCode(item.code)
        : item.name.trim().toLowerCase();
    return 'np_${base64Url.encode(utf8.encode(base)).replaceAll('=', '')}';
  }

  _NewProductLotStock _newProductLotFor(SpecialOrderItem item) {
    final key = _newProductLotKey(item);
    return _newProductLots[key] ??
        _NewProductLotStock(
          key: key,
          code: item.code,
          name: item.name,
          lotSize: 1,
          remaining: 0,
          currentStock: 0,
        );
  }

  TextEditingController _newProductCustomerCtrl(SpecialOrderItem item) {
    final key = _newProductLotKey(item);
    return _newProductCustomerControllers.putIfAbsent(
      key,
      () => TextEditingController(),
    );
  }

  TextEditingController _newProductCustomerNameCtrl(SpecialOrderItem item) {
    final key = _newProductLotKey(item);
    return _newProductCustomerNameControllers.putIfAbsent(
      key,
      () => TextEditingController(),
    );
  }

  TextEditingController _newProductStoreNameCtrl(SpecialOrderItem item) {
    final key = _newProductLotKey(item);
    return _newProductStoreNameControllers.putIfAbsent(
      key,
      () => TextEditingController(),
    );
  }

  TextEditingController _newProductCustomerOrderQtyCtrl(SpecialOrderItem item) {
    final key = _newProductLotKey(item);
    return _newProductCustomerOrderQtyControllers.putIfAbsent(
      key,
      () => TextEditingController(text: '1'),
    );
  }

  TextEditingController _newProductRemainingCtrl(SpecialOrderItem item) {
    final lot = _newProductLotFor(item);
    return _newProductRemainingControllers.putIfAbsent(
      lot.key,
      () => TextEditingController(text: '${lot.remaining}'),
    );
  }

  TextEditingController _newProductCurrentStockCtrl(SpecialOrderItem item) {
    final lot = _newProductLotFor(item);
    return _newProductCurrentStockControllers.putIfAbsent(
      lot.key,
      () => TextEditingController(text: '${lot.currentStock}'),
    );
  }

  TextEditingController _newProductDeliveredCtrl(SpecialOrderItem item) {
    final lot = _newProductLotFor(item);
    return _newProductDeliveredControllers.putIfAbsent(
      lot.key,
      () => TextEditingController(text: '0'),
    );
  }

  String _newProductKnownCustomerNameForCode(String customerCode) {
    final code = customerCode.trim();
    if (code.isEmpty) return '';
    final matches =
        _newProductCustomerOrders.values
            .where(
              (entry) =>
                  entry.customerCode.trim() == code &&
                  entry.customerName.trim().isNotEmpty,
            )
            .toList()
          ..sort((a, b) => b.orderedAt.compareTo(a.orderedAt));
    return matches.isEmpty ? '' : matches.first.customerName.trim();
  }

  void _applyKnownNewProductCustomerName(
    String customerCode,
    TextEditingController nameCtrl, {
    bool overwrite = false,
  }) {
    final name = _newProductKnownCustomerNameForCode(customerCode);
    if (name.isEmpty) return;
    if (!overwrite && nameCtrl.text.trim().isNotEmpty) return;
    nameCtrl.text = name;
  }

  List<_NewProductCustomerOrderEntry> _newProductCustomerOrdersForItem(
    SpecialOrderItem item,
  ) {
    final result = _newProductCustomerOrders.values
        .where((entry) => entry.itemId == item.id)
        .toList();
    result.sort((a, b) => b.orderedAt.compareTo(a.orderedAt));
    return result;
  }

  int _newProductCustomerOrderTotalForItem(SpecialOrderItem item) {
    return _newProductCustomerOrdersForItem(
      item,
    ).fold(0, (total, entry) => total + entry.qty);
  }

  int _newProductCustomerDeliveredTotalForItem(SpecialOrderItem item) {
    return _newProductCustomerOrdersForItem(item)
        .where((entry) => entry.delivered)
        .fold(0, (total, entry) => total + entry.qty);
  }

  String _fmtDate(DateTime d) =>
      '${d.year}年${d.month.toString().padLeft(2, '0')}月'
      '${d.day.toString().padLeft(2, '0')}日';

  String _fmtDateSlash(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/'
      '${d.day.toString().padLeft(2, '0')}';

  // ホームケア顧客別仮発注一覧の「納品日」表示：
  // 対象2期間はデフォルト日（8/5, 8/20）を基準にし、
  // orderedAtの日付がsalesEndより後であれば編集ダイアログで
  // 個別に変更された値とみなしてそちらを表示する。
  DateTime _homeCareCustomerDeliveryDisplayDate(
    SpecialOrderItem item,
    _HomeCareCustomerOrderEntry entry,
  ) {
    final defaultDate = _homeCareDeliveryDefaultDate(item);
    if (defaultDate == null) return item.arrival;
    final orderedDateOnly = DateTime(
      entry.orderedAt.year,
      entry.orderedAt.month,
      entry.orderedAt.day,
    );
    final salesEndOnly = DateTime(
      item.salesEnd.year,
      item.salesEnd.month,
      item.salesEnd.day,
    );
    return orderedDateOnly.isAfter(salesEndOnly)
        ? orderedDateOnly
        : defaultDate;
  }

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

  // 販売期間前でも、同じ商品コードの「直前のロット」の販売期間が
  // すでに終了していれば、前倒しで入力を開始できるようにする。
  // また、締切後の顧客別仮発注は管理者・統括管理者だけ入力可能にする。
  bool _canAddOrderForItem(SpecialOrderItem item) {
    if (item.isInSalesPeriod) return true;
    if (item.isExpired) return _canManageSpecialStock;
    if (!item.isBeforeSales) return false;

    final normalizedCode = _normalizeCode(item.code);
    if (normalizedCode.isEmpty) return false;

    final startOnly = DateTime(
      item.salesStart.year,
      item.salesStart.month,
      item.salesStart.day,
    );

    SpecialOrderItem? previousItem;
    for (final other in _items) {
      if (other.id == item.id) continue;
      if (_normalizeCode(other.code) != normalizedCode) continue;
      final otherEndOnly = DateTime(
        other.salesEnd.year,
        other.salesEnd.month,
        other.salesEnd.day,
      );
      if (!otherEndOnly.isBefore(startOnly)) continue;
      if (previousItem == null || otherEndOnly.isAfter(previousItem.salesEnd)) {
        previousItem = other;
      }
    }
    if (previousItem == null) return false;

    final prevEndOnly = DateTime(
      previousItem.salesEnd.year,
      previousItem.salesEnd.month,
      previousItem.salesEnd.day,
    );
    final todayOnly = DateTime.now();
    final today = DateTime(todayOnly.year, todayOnly.month, todayOnly.day);
    return today.isAfter(prevEndOnly);
  }

  String _orderClosedMessage(SpecialOrderItem item) {
    if (_canAddOrderForItem(item)) return '';
    return item.isBeforeSales ? '販売期間前のため入力できません' : '販売期間終了のため新規入力できません';
  }

  bool _canModifyCustomerOrderForItem(SpecialOrderItem item) {
    if (_canAddOrderForItem(item)) return true;
    if (item.isExpired && _canManageSpecialStock) return true;
    return false;
  }

  // ホームケア納品日の手動指定：入荷予定日が離れている特定2期間のみ、
  // 納品日を入荷予定日基準で選び直せるようにする（それ以外は常に現在日時）。
  DateTime? _homeCareDeliveryDefaultDate(SpecialOrderItem item) {
    final start = DateTime(
      item.salesStart.year,
      item.salesStart.month,
      item.salesStart.day,
    );
    final end = DateTime(
      item.salesEnd.year,
      item.salesEnd.month,
      item.salesEnd.day,
    );
    if (start == DateTime(2026, 7, 16) && end == DateTime(2026, 7, 22)) {
      return DateTime(2026, 8, 5);
    }
    if (start == DateTime(2026, 7, 30) && end == DateTime(2026, 8, 6)) {
      return DateTime(2026, 8, 20);
    }
    return null;
  }

  // 選択された「日付」部分と、現在の「時刻」部分を組み合わせる
  // （ユーザーは日付だけ選べればよく、時刻はその場の操作時刻でよいため）。
  DateTime _combineDateWithNowTime(DateTime date) {
    final now = DateTime.now();
    return DateTime(
      date.year,
      date.month,
      date.day,
      now.hour,
      now.minute,
      now.second,
      now.millisecond,
    );
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

  Future<void> _placeHomeCareCustomerOrder(SpecialOrderItem item) async {
    if (!_canAddOrderForItem(item)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_orderClosedMessage(item)),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final customerCode = _homeCareCustomerCtrl(item).text.trim();
    final customerName = _homeCareCustomerNameCtrl(item).text.trim();
    final storeName = _homeCareStoreNameCtrl(item).text.trim();
    final qty =
        int.tryParse(_homeCareCustomerOrderQtyCtrl(item).text.trim()) ?? 0;
    if (customerCode.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('顧客コードを入力してください')));
      return;
    }
    if (qty <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('発注数は1以上にしてください')));
      return;
    }
    final lot = _homeCareLotFor(item);
    final now = DateTime.now();
    final entryId =
        'hco_${now.microsecondsSinceEpoch}_${customerCode.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '')}';
    final entry = _HomeCareCustomerOrderEntry(
      id: entryId,
      itemId: item.id,
      lotKey: lot.key,
      itemCode: item.code,
      itemName: item.name,
      customerCode: customerCode,
      customerName: customerName,
      storeName: storeName,
      qty: qty,
      delivered: false,
      reserved: false,
      orderedAt: now,
      deliveredAt: null,
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ホームケア仮発注確認'),
        content: Text(
          '${item.name}\n顧客コード: $customerCode\n顧客名: ${customerName.isEmpty ? '-' : customerName}\n数量: $qty 個\n\nこの内容で仮発注します。',
        ),
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
      await AppSession.doc('special_orders').set({
        'homeCareLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': _positiveIntFromController(
              _homeCareLotCtrl(item),
              lot.lotSize <= 0 ? 1 : lot.lotSize,
            ),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
        'homeCareCustomerOrders': {entryId: entry.toMap()},
      }, SetOptions(merge: true));
      setState(() {
        _homeCareCustomerOrders[entryId] = entry;
        _homeCareCustomerCtrl(item).clear();
        _homeCareCustomerNameCtrl(item).clear();
        _homeCareStoreNameCtrl(item).clear();
        _homeCareCustomerOrderQtyCtrl(item).text = '1';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('顧客別に仮発注しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('仮発注失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggleHomeCareCustomerDelivered(
    SpecialOrderItem item,
    _HomeCareCustomerOrderEntry entry,
    bool delivered,
  ) async {
    if (entry.delivered == delivered) return;
    final lot = _homeCareLotFor(item);
    final currentStock = _homeCareCurrentStockForLot(lot);
    if (delivered && entry.qty > currentStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('在庫が不足しています（現在在庫 $currentStock 個）'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(delivered ? '引渡し済みにしますか？' : '引渡し済みを解除しますか？'),
        content: Text(
          '${entry.customerCode} / ${entry.customerName.isEmpty ? '-' : entry.customerName}\n${entry.qty} 個\n\n${delivered ? '在庫から数量を減らします。' : '在庫へ数量を戻します。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(delivered ? '引渡し済みにする' : '解除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final now = DateTime.now();
    final updated = entry.copyWith(
      delivered: delivered,
      deliveredAt: delivered ? now : null,
    );
    final stockDelta = delivered ? -entry.qty : entry.qty;
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
            'currentStock': max(0, currentStock + stockDelta),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
        'homeCareCustomerOrders': {entry.id: updated.toMap()},
        'homeCareHandoverLogs': FieldValue.arrayUnion([
          {
            'key': lot.key,
            'code': item.code,
            'name': item.name,
            'customerCode': entry.customerCode,
            'qty': delivered ? entry.qty : -entry.qty,
            'at': Timestamp.now(),
          },
        ]),
      }, SetOptions(merge: true));
      setState(() {
        _homeCareLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          currentStock: max(0, currentStock + stockDelta),
        );
        _homeCareCustomerOrders[entry.id] = updated;
        _handoverLogs.add(
          _HandoverLogEntry(
            key: lot.key,
            customerCode: entry.customerCode,
            qty: delivered ? entry.qty : -entry.qty,
            at: now,
          ),
        );
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('引渡し更新失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggleHomeCareCustomerReserved(
    _HomeCareCustomerOrderEntry entry,
    bool reserved,
  ) async {
    if (!_canManageSpecialStock) return;
    if (entry.reserved == reserved) return;
    final updated = entry.copyWith(reserved: reserved);
    try {
      await AppSession.doc('special_orders').set({
        'homeCareCustomerOrders': {entry.id: updated.toMap()},
      }, SetOptions(merge: true));
      setState(() {
        _homeCareCustomerOrders[entry.id] = updated;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('取置き更新失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _editHomeCareCustomerOrder(
    SpecialOrderItem item,
    _HomeCareCustomerOrderEntry entry,
  ) async {
    final codeCtrl = TextEditingController(text: entry.customerCode);
    final nameCtrl = TextEditingController(text: entry.customerName);
    final storeCtrl = TextEditingController(text: entry.storeName);
    final qtyCtrl = TextEditingController(text: '${entry.qty}');
    DateTime? selectedOrderedDate = _homeCareDeliveryDefaultDate(item);

    try {
      final updatedInput = await showDialog<_HomeCareCustomerOrderEntry?>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('仮発注を編集'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: storeCtrl,
                    decoration: const InputDecoration(
                      labelText: '店舗名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: codeCtrl,
                    onChanged: (value) => _applyKnownCustomerName(
                      value,
                      nameCtrl,
                      overwrite: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '顧客コード',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '顧客名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: qtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '発注数',
                      suffixText: '個',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (selectedOrderedDate != null) ...[
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: selectedOrderedDate!,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                          locale: const Locale('ja'),
                        );
                        if (picked == null) return;
                        setDialogState(() {
                          selectedOrderedDate = DateTime(
                            picked.year,
                            picked.month,
                            picked.day,
                          );
                        });
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '日付',
                          isDense: true,
                          border: OutlineInputBorder(),
                          suffixIcon: Icon(Icons.calendar_today, size: 18),
                        ),
                        child: Text(_fmtDate(selectedOrderedDate!)),
                      ),
                    ),
                  ],
                  if (entry.delivered) ...[
                    const SizedBox(height: 8),
                    Text(
                      '※引渡し済みのため、数量を変えると在庫数も自動で調整します。',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('キャンセル'),
              ),
              ElevatedButton(
                onPressed: () {
                  final customerCode = codeCtrl.text.trim();
                  final customerName = nameCtrl.text.trim();
                  final storeName = storeCtrl.text.trim();
                  final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
                  if (customerCode.isEmpty || qty <= 0) return;
                  Navigator.of(ctx).pop(
                    entry.copyWith(
                      customerCode: customerCode,
                      customerName: customerName,
                      storeName: storeName,
                      qty: qty,
                      orderedAt: selectedOrderedDate == null
                          ? null
                          : _combineDateWithNowTime(selectedOrderedDate!),
                    ),
                  );
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
      if (updatedInput == null) return;
      if (!mounted) return;

      final lot = _homeCareLotFor(item);
      final stockDelta = entry.delivered ? entry.qty - updatedInput.qty : 0;
      if (stockDelta < 0 && lot.remaining < stockDelta.abs()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('在庫が不足しています（在庫 ${lot.remaining} 個）'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      final data = <String, dynamic>{
        'homeCareCustomerOrders': {entry.id: updatedInput.toMap()},
      };
      if (stockDelta != 0) {
        data['homeCareLots'] = {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': _positiveIntFromController(
              _homeCareLotCtrl(item),
              lot.lotSize <= 0 ? 1 : lot.lotSize,
            ),
            'currentStock': max(0, lot.currentStock + stockDelta),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        };
        data['homeCareHandoverLogs'] = FieldValue.arrayUnion([
          {
            'key': lot.key,
            'code': item.code,
            'name': item.name,
            'customerCode': updatedInput.customerCode,
            'qty': stockDelta,
            'at': Timestamp.now(),
          },
        ]);
      }

      await AppSession.doc('special_orders').set(data, SetOptions(merge: true));
      setState(() {
        if (stockDelta != 0) {
          _homeCareLots[lot.key] = lot.copyWith(
            code: item.code,
            name: item.name,
            remaining: max(0, lot.remaining + stockDelta),
          );
          _handoverLogs.add(
            _HandoverLogEntry(
              key: lot.key,
              customerCode: updatedInput.customerCode,
              qty: stockDelta,
              at: DateTime.now(),
            ),
          );
        }
        _homeCareCustomerOrders[entry.id] = updatedInput;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('仮発注を修正しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('修正失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      codeCtrl.dispose();
      nameCtrl.dispose();
      storeCtrl.dispose();
      qtyCtrl.dispose();
    }
  }

  Future<void> _deleteHomeCareCustomerOrder(
    SpecialOrderItem item,
    _HomeCareCustomerOrderEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('仮発注を削除'),
        content: Text(
          '${entry.customerCode} / ${entry.customerName.isEmpty ? '-' : entry.customerName}\n${entry.qty} 個\n\nこの仮発注を削除しますか？${entry.delivered ? '\n※引渡し済み分は在庫へ戻します。' : ''}',
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
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final lot = _homeCareLotFor(item);
    final stockDelta = entry.delivered ? entry.qty : 0;
    try {
      final data = <String, dynamic>{
        'homeCareCustomerOrders.${entry.id}': FieldValue.delete(),
      };
      if (stockDelta != 0) {
        data['homeCareLots.${lot.key}.code'] = item.code;
        data['homeCareLots.${lot.key}.name'] = item.name;
        data['homeCareLots.${lot.key}.lotSize'] = _positiveIntFromController(
          _homeCareLotCtrl(item),
          lot.lotSize <= 0 ? 1 : lot.lotSize,
        );
        data['homeCareLots.${lot.key}.remaining'] = FieldValue.increment(
          stockDelta,
        );
        data['homeCareLots.${lot.key}.updatedAt'] =
            FieldValue.serverTimestamp();
        data['homeCareHandoverLogs'] = FieldValue.arrayUnion([
          {
            'key': lot.key,
            'code': item.code,
            'name': item.name,
            'customerCode': entry.customerCode,
            'qty': -entry.qty,
            'at': Timestamp.now(),
          },
        ]);
      }

      await AppSession.doc('special_orders').update(data);
      setState(() {
        _homeCareCustomerOrders.remove(entry.id);
        if (stockDelta != 0) {
          _homeCareLots[lot.key] = lot.copyWith(
            code: item.code,
            name: item.name,
            remaining: lot.remaining + stockDelta,
          );
          _handoverLogs.add(
            _HandoverLogEntry(
              key: lot.key,
              customerCode: entry.customerCode,
              qty: -entry.qty,
              at: DateTime.now(),
            ),
          );
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('仮発注を削除しました'),
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

  // ── 新商品タブ：顧客別仮発注のCRUD ─────────────────────
  Future<void> _placeNewProductCustomerOrder(SpecialOrderItem item) async {
    if (!_canAddOrderForItem(item)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_orderClosedMessage(item)),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final customerCode = _newProductCustomerCtrl(item).text.trim();
    final customerName = _newProductCustomerNameCtrl(item).text.trim();
    final storeName = _newProductStoreNameCtrl(item).text.trim();
    final qty =
        int.tryParse(_newProductCustomerOrderQtyCtrl(item).text.trim()) ?? 0;
    if (customerCode.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('顧客コードを入力してください')));
      return;
    }
    if (qty <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('発注数は1以上にしてください')));
      return;
    }
    final lot = _newProductLotFor(item);
    final now = DateTime.now();
    final entryId =
        'npo_${now.microsecondsSinceEpoch}_${customerCode.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '')}';
    final entry = _NewProductCustomerOrderEntry(
      id: entryId,
      itemId: item.id,
      lotKey: lot.key,
      itemCode: item.code,
      itemName: item.name,
      customerCode: customerCode,
      customerName: customerName,
      storeName: storeName,
      qty: qty,
      delivered: false,
      reserved: false,
      orderedAt: now,
      deliveredAt: null,
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新商品 仮発注確認'),
        content: Text(
          '${item.name}\n顧客コード: $customerCode\n顧客名: ${customerName.isEmpty ? '-' : customerName}\n数量: $qty 個\n\nこの内容で仮発注します。',
        ),
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
      await AppSession.doc('special_orders').set({
        'newProductLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
        'newProductCustomerOrders': {entryId: entry.toMap()},
      }, SetOptions(merge: true));
      setState(() {
        _newProductCustomerOrders[entryId] = entry;
        _newProductCustomerCtrl(item).clear();
        _newProductCustomerNameCtrl(item).clear();
        _newProductStoreNameCtrl(item).clear();
        _newProductCustomerOrderQtyCtrl(item).text = '1';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('顧客別に仮発注しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('仮発注失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggleNewProductCustomerDelivered(
    SpecialOrderItem item,
    _NewProductCustomerOrderEntry entry,
    bool delivered,
  ) async {
    if (entry.delivered == delivered) return;
    final lot = _newProductLotFor(item);
    if (delivered && entry.qty > lot.currentStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('在庫が不足しています（現在在庫 ${lot.currentStock} 個）'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(delivered ? '引渡し済みにしますか？' : '引渡し済みを解除しますか？'),
        content: Text(
          '${entry.customerCode} / ${entry.customerName.isEmpty ? '-' : entry.customerName}\n${entry.qty} 個\n\n'
          '${delivered ? '納品予定数から数量を減らします。' : '納品予定数へ数量を戻します。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(delivered ? '引渡し済みにする' : '解除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final updated = entry.copyWith(
      delivered: delivered,
      deliveredAt: delivered ? DateTime.now() : null,
    );
    final stockDelta = delivered ? -entry.qty : entry.qty;
    try {
      await AppSession.doc('special_orders').set({
        'newProductLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'remaining': FieldValue.increment(stockDelta),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
        'newProductCustomerOrders': {entry.id: updated.toMap()},
      }, SetOptions(merge: true));
      setState(() {
        _newProductLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          currentStock: max(0, lot.currentStock + stockDelta),
        );
        _newProductCustomerOrders[entry.id] = updated;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('引渡し更新失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggleNewProductCustomerReserved(
    _NewProductCustomerOrderEntry entry,
    bool reserved,
  ) async {
    if (!_canManageSpecialStock) return;
    if (entry.reserved == reserved) return;
    final updated = entry.copyWith(reserved: reserved);
    try {
      await AppSession.doc('special_orders').set({
        'newProductCustomerOrders': {entry.id: updated.toMap()},
      }, SetOptions(merge: true));
      setState(() {
        _newProductCustomerOrders[entry.id] = updated;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('取置き更新失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _editNewProductCustomerOrder(
    SpecialOrderItem item,
    _NewProductCustomerOrderEntry entry,
  ) async {
    final codeCtrl = TextEditingController(text: entry.customerCode);
    final nameCtrl = TextEditingController(text: entry.customerName);
    final storeCtrl = TextEditingController(text: entry.storeName);
    final qtyCtrl = TextEditingController(text: '${entry.qty}');

    try {
      final updatedInput = await showDialog<_NewProductCustomerOrderEntry?>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('仮発注を編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: storeCtrl,
                  decoration: const InputDecoration(
                    labelText: '店舗名',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: codeCtrl,
                  onChanged: (value) => _applyKnownNewProductCustomerName(
                    value,
                    nameCtrl,
                    overwrite: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '顧客コード',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '顧客名',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: qtyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '発注数',
                    suffixText: '個',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (entry.delivered) ...[
                  const SizedBox(height: 8),
                  Text(
                    '※引渡し済みのため、数量を変えると納品予定数も自動で調整します。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade800,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () {
                final customerCode = codeCtrl.text.trim();
                final customerName = nameCtrl.text.trim();
                final storeName = storeCtrl.text.trim();
                final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
                if (customerCode.isEmpty || qty <= 0) return;
                Navigator.of(ctx).pop(
                  entry.copyWith(
                    customerCode: customerCode,
                    customerName: customerName,
                    storeName: storeName,
                    qty: qty,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (updatedInput == null) return;
      if (!mounted) return;

      final lot = _newProductLotFor(item);
      final stockDelta = entry.delivered ? entry.qty - updatedInput.qty : 0;
      if (stockDelta < 0 && lot.remaining < stockDelta.abs()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('納品予定数が不足しています（残 ${lot.remaining} 個）'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      final data = <String, dynamic>{
        'newProductCustomerOrders': {entry.id: updatedInput.toMap()},
      };
      if (stockDelta != 0) {
        data['newProductLots'] = {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'remaining': FieldValue.increment(stockDelta),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        };
      }

      await AppSession.doc('special_orders').set(data, SetOptions(merge: true));
      setState(() {
        if (stockDelta != 0) {
          _newProductLots[lot.key] = lot.copyWith(
            code: item.code,
            name: item.name,
            remaining: max(0, lot.remaining + stockDelta),
          );
        }
        _newProductCustomerOrders[entry.id] = updatedInput;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('仮発注を修正しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('修正失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      codeCtrl.dispose();
      nameCtrl.dispose();
      storeCtrl.dispose();
      qtyCtrl.dispose();
    }
  }

  Future<void> _deleteNewProductCustomerOrder(
    SpecialOrderItem item,
    _NewProductCustomerOrderEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('仮発注を削除'),
        content: Text(
          '${entry.customerCode} / ${entry.customerName.isEmpty ? '-' : entry.customerName}\n${entry.qty} 個\n\n'
          'この仮発注を削除しますか？${entry.delivered ? '\n※引渡し済み分は納品予定数へ戻します。' : ''}',
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
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final lot = _newProductLotFor(item);
    final stockDelta = entry.delivered ? entry.qty : 0;
    try {
      final data = <String, dynamic>{
        'newProductCustomerOrders.${entry.id}': FieldValue.delete(),
      };
      if (stockDelta != 0) {
        data['newProductLots.${lot.key}.code'] = item.code;
        data['newProductLots.${lot.key}.name'] = item.name;
        data['newProductLots.${lot.key}.lotSize'] = lot.lotSize <= 0
            ? 1
            : lot.lotSize;
        data['newProductLots.${lot.key}.remaining'] = FieldValue.increment(
          stockDelta,
        );
        data['newProductLots.${lot.key}.updatedAt'] =
            FieldValue.serverTimestamp();
      }

      await AppSession.doc('special_orders').update(data);
      setState(() {
        _newProductCustomerOrders.remove(entry.id);
        if (stockDelta != 0) {
          _newProductLots[lot.key] = lot.copyWith(
            code: item.code,
            name: item.name,
            remaining: lot.remaining + stockDelta,
          );
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('仮発注を削除しました'),
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

  Future<void> _saveNewProductRemaining(SpecialOrderItem item) async {
    if (!_canManageSpecialStock) return;
    final lot = _newProductLotFor(item);
    final newValue = int.tryParse(_newProductRemainingCtrl(item).text.trim());
    if (newValue == null || newValue < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正しい数値を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    try {
      await AppSession.doc('special_orders').set({
        'newProductLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'remaining': newValue,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
      }, SetOptions(merge: true));
      setState(() {
        _newProductLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          remaining: newValue,
        );
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('納品予定数を変更しました'),
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
  }

  Future<void> _saveHomeCareRemaining(SpecialOrderItem item) async {
    if (!_canManageSpecialStock) return;
    final lot = _homeCareLotFor(item);
    final newValue = int.tryParse(_homeCareRemainingCtrl(item).text.trim());
    if (newValue == null || newValue < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正しい数値を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    try {
      await AppSession.doc('special_orders').set({
        'homeCareLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'remaining': newValue,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
      }, SetOptions(merge: true));
      setState(() {
        _homeCareLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          remaining: newValue,
        );
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('納品予定数を変更しました'),
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
  }

  Future<void> _saveHomeCareCurrentStock(SpecialOrderItem item) async {
    if (!_canManageSpecialStock) return;
    final lot = _homeCareLotFor(item);
    final newValue = int.tryParse(_homeCareCurrentStockCtrl(item).text.trim());
    if (newValue == null || newValue < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正しい在庫数を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    try {
      await AppSession.doc('special_orders').set({
        'homeCareLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'currentStock': newValue,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
      }, SetOptions(merge: true));
      setState(() {
        _homeCareLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          currentStock: newValue,
        );
        _homeCareCurrentStockCtrl(item).text = '$newValue';
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
  }

  Future<void> _saveNewProductCurrentStock(SpecialOrderItem item) async {
    if (!_canManageSpecialStock) return;
    final lot = _newProductLotFor(item);
    final newValue = int.tryParse(
      _newProductCurrentStockCtrl(item).text.trim(),
    );
    if (newValue == null || newValue < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正しい在庫数を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    try {
      await AppSession.doc('special_orders').set({
        'newProductLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'currentStock': newValue,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
      }, SetOptions(merge: true));
      setState(() {
        _newProductLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          currentStock: newValue,
        );
        _newProductCurrentStockCtrl(item).text = '$newValue';
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
  }

  Future<void> _saveHomeCareDeliveredCount(SpecialOrderItem item) async {
    if (!_canManageSpecialStock) return;
    final lot = _homeCareLotFor(item);
    final delivered = int.tryParse(_homeCareDeliveredCtrl(item).text.trim());
    if (delivered == null || delivered < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正しい納品済み数を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (delivered == 0) return;
    if (delivered > lot.remaining) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('納品予定数を超えています（納品予定 ${lot.remaining} 個）'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('納品済み数を反映'),
        content: Text('${lot.name}\n$delivered 個を納品済みにして、納品予定数から差し引きます。'),
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
    final currentStock = _homeCareCurrentStockForLot(lot);
    final nextRemaining = max(0, lot.remaining - delivered);
    final nextCurrentStock = currentStock + delivered;
    try {
      await AppSession.doc('special_orders').set({
        'homeCareLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'remaining': FieldValue.increment(-delivered),
            'currentStock': nextCurrentStock,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
        'homeCareHandoverLogs': FieldValue.arrayUnion([
          {
            'key': lot.key,
            'code': item.code,
            'name': item.name,
            'customerCode': '納品済み手動反映',
            'qty': delivered,
            'at': Timestamp.now(),
          },
        ]),
      }, SetOptions(merge: true));
      setState(() {
        _homeCareLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          remaining: nextRemaining,
          currentStock: nextCurrentStock,
        );
        _homeCareRemainingCtrl(item).text = '$nextRemaining';
        _homeCareDeliveredCtrl(item).text = '0';
        _handoverLogs.add(
          _HandoverLogEntry(
            key: lot.key,
            customerCode: '納品済み手動反映',
            qty: delivered,
            at: DateTime.now(),
          ),
        );
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('納品済み数を反映しました'),
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

  Future<void> _saveNewProductDeliveredCount(SpecialOrderItem item) async {
    if (!_canManageSpecialStock) return;
    final lot = _newProductLotFor(item);
    final delivered = int.tryParse(_newProductDeliveredCtrl(item).text.trim());
    if (delivered == null || delivered < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正しい納品済み数を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (delivered == 0) return;
    if (delivered > lot.remaining) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('納品予定数を超えています（納品予定 ${lot.remaining} 個）'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('納品済み数を反映'),
        content: Text('${lot.name}\n$delivered 個を納品済みにして、納品予定数から差し引きます。'),
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
    final nextRemaining = max(0, lot.remaining - delivered);
    final nextCurrentStock = lot.currentStock + delivered;
    try {
      await AppSession.doc('special_orders').set({
        'newProductLots': {
          lot.key: {
            'code': item.code,
            'name': item.name,
            'lotSize': lot.lotSize <= 0 ? 1 : lot.lotSize,
            'remaining': FieldValue.increment(-delivered),
            'currentStock': nextCurrentStock,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        },
      }, SetOptions(merge: true));
      setState(() {
        _newProductLots[lot.key] = lot.copyWith(
          code: item.code,
          name: item.name,
          remaining: nextRemaining,
          currentStock: nextCurrentStock,
        );
        _newProductRemainingCtrl(item).text = '$nextRemaining';
        _newProductDeliveredCtrl(item).text = '0';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('納品済み数を反映しました'),
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
      taxExcludedPrice: result['taxExcludedPrice'] as int,
      reducedTax: result['reducedTax'] as bool,
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
    final masterItem = {
      'id': masterId,
      'code': item.code,
      'name': item.name,
      'taxExcludedPrice': item.taxExcludedPrice,
      'reducedTax': item.reducedTax,
    };

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
          '特別発注・新商品発注の既存登録 ${targetItems.length} 件を確認し、\n'
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
          'taxExcludedPrice': item.taxExcludedPrice,
          'reducedTax': item.reducedTax,
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
      taxExcludedPrice: result['taxExcludedPrice'] as int,
      reducedTax: result['reducedTax'] as bool,
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
    final priceCtrl = TextEditingController(
      text: (initial != null && initial.taxExcludedPrice > 0)
          ? initial.taxExcludedPrice.toString()
          : '',
    );
    bool reducedTax = initial?.reducedTax ?? false;
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
              locale: const Locale('ja'),
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

          Future<void> autoFillPriceFromCode(String rawCode) async {
            final normalized = _normalizeCode(rawCode);
            if (normalized.isEmpty) return;

            final masterData = await _loadMasterData();
            LegacyItem? matchedProduct;
            for (final product in masterData.products) {
              if (_normalizeCode(product.code) == normalized) {
                matchedProduct = product;
                break;
              }
            }

            int? foundPrice;
            bool? foundReducedTax;
            if (matchedProduct != null) {
              foundPrice = matchedProduct.taxExcludedPrice;
              foundReducedTax = matchedProduct.reducedTax;
            } else {
              SpecialOrderItem? matchedSpecialItem;
              for (final existingItem in _items) {
                if (_normalizeCode(existingItem.code) == normalized) {
                  matchedSpecialItem = existingItem;
                  break;
                }
              }
              if (matchedSpecialItem != null) {
                foundPrice = matchedSpecialItem.taxExcludedPrice;
                foundReducedTax = matchedSpecialItem.reducedTax;
              }
            }

            if (foundPrice == null) return;
            setS(() {
              priceCtrl.text = foundPrice! > 0 ? foundPrice.toString() : '';
              reducedTax = foundReducedTax ?? false;
            });
          }

          return AlertDialog(
            title: Text(
              isEdit
                  ? '発注情報を編集'
                  : (duplicateMode ? '複製して新規登録' : '特別発注・新商品発注 登録'),
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
                      onChanged: autoFillPriceFromCode,
                      decoration: const InputDecoration(
                        labelText: '商品コード',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: priceCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setS(() {}),
                      decoration: const InputDecoration(
                        labelText: '税抜価格',
                        prefixText: '￥',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Builder(
                      builder: (_) {
                        final price = inventoryIntValue(priceCtrl.text);
                        final taxRate = reducedTax ? 8 : 10;
                        final included = (price * (100 + taxRate) / 100)
                            .round();
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            price > 0
                                ? '税込価格：￥${included.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',')}（$taxRate%）'
                                : '税込価格：未設定',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        );
                      },
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: reducedTax,
                      onChanged: (value) {
                        setS(() {
                          reducedTax = value == true;
                        });
                      },
                      title: const Text('軽減税率（8%）'),
                      subtitle: const Text('チェックなしは10%で計算'),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    const SizedBox(height: 4),
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
                    'taxExcludedPrice': inventoryIntValue(priceCtrl.text),
                    'reducedTax': reducedTax,
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

  Future<void> _editHomeCareLegacyOrder(
    SpecialOrderItem item,
    String storeId,
    String storeName,
    int currentQty,
  ) async {
    final ctrl = TextEditingController(text: '$currentQty');
    try {
      final result = await showDialog<int?>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('旧方式発注分を修正'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(storeName),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '発注数',
                  suffixText: '個',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '0にすると削除します。これは旧方式の入力数だけを修正します。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () {
                final value = int.tryParse(ctrl.text.trim());
                if (value == null || value < 0) return;
                Navigator.of(ctx).pop(value);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (result == null) return;
      if (!mounted) return;

      if (result <= 0) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('旧方式発注分を削除'),
            content: Text('$storeName の ${item.name} の旧方式発注分を削除しますか？'),
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
                child: const Text('削除する'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        await AppSession.doc(
          'special_orders',
        ).update({'orders.${item.id}.$storeId': FieldValue.delete()});
        setState(() {
          _orders[item.id]?.remove(storeId);
          if (_orders[item.id]?.isEmpty ?? false) _orders.remove(item.id);
        });
      } else {
        await AppSession.doc('special_orders').set({
          'orders': {
            item.id: {storeId: result},
          },
        }, SetOptions(merge: true));
        setState(() {
          _orders.putIfAbsent(item.id, () => {})[storeId] = result;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('旧方式発注分を修正しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('修正失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      ctrl.dispose();
    }
  }

  Widget _buildHomeCareLegacyOrderBox(SpecialOrderItem item) {
    final viewableStoreIds = _stores.map((store) => store.id).toSet();
    final storeOrders =
        (_orders[item.id] ?? {}).entries
            .where(
              (entry) =>
                  entry.value > 0 && viewableStoreIds.contains(entry.key),
            )
            .toList()
          ..sort((a, b) {
            final storeA = _stores.firstWhere(
              (store) => store.id == a.key,
              orElse: () => LegacyStore(id: a.key, code: '', name: a.key),
            );
            final storeB = _stores.firstWhere(
              (store) => store.id == b.key,
              orElse: () => LegacyStore(id: b.key, code: '', name: b.key),
            );
            final codeCompare = storeA.code.compareTo(storeB.code);
            if (codeCompare != 0) return codeCompare;
            return storeA.name.compareTo(storeB.name);
          });

    if (storeOrders.isEmpty) return const SizedBox.shrink();

    final totalQty = storeOrders.fold<int>(
      0,
      (total, entry) => total + entry.value,
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border.all(color: Colors.orange.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.history, color: Colors.orange.shade800),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '旧方式の発注分',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade900,
                  ),
                ),
              ),
              Text(
                '合計 $totalQty 個',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange.shade900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '以前の店舗別入力分です。スタッフ入力の個数として表示しています。',
            style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
          ),
          const SizedBox(height: 8),
          for (final entry in storeOrders)
            Builder(
              builder: (context) {
                final store = _stores.firstWhere(
                  (store) => store.id == entry.key,
                  orElse: () =>
                      LegacyStore(id: entry.key, code: '', name: entry.key),
                );
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.orange.shade100),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          store.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Text(
                        '${entry.value} 個',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () => _editHomeCareLegacyOrder(
                          item,
                          entry.key,
                          store.name,
                          entry.value,
                        ),
                        child: const Text('修正'),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildHomeCareCustomerOrderBox(SpecialOrderItem item) {
    final codeCtrl = _homeCareCustomerCtrl(item);
    final nameCtrl = _homeCareCustomerNameCtrl(item);
    final storeCtrl = _homeCareStoreNameCtrl(item);
    final qtyCtrl = _homeCareCustomerOrderQtyCtrl(item);
    final orders = _homeCareCustomerOrdersForItem(item);
    final total = _homeCareCustomerOrderTotalForItem(item);
    final deliveredTotal = _homeCareCustomerDeliveredTotalForItem(item);
    final pendingTotal = max(0, total - deliveredTotal);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border.all(color: Colors.green.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.people_alt_outlined, color: Colors.green.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '顧客別 仮発注',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade900,
                  ),
                ),
              ),
              Text(
                '期間合計 $total 個 / 未引渡し $pendingTotal 個',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.green.shade900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_canAddOrderForItem(item)) ...[
            TextField(
              controller: storeCtrl,
              decoration: const InputDecoration(
                labelText: '店舗名',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: codeCtrl,
                    onChanged: (value) => _applyKnownCustomerName(
                      value,
                      nameCtrl,
                      overwrite: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '顧客コード',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '顧客名',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
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
              onPressed: () => _placeHomeCareCustomerOrder(item),
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('顧客別に仮発注'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ] else
            Text(
              item.isBeforeSales ? '発注期間前のため入力できません' : '発注期間終了のため入力できません',
              style: TextStyle(color: Colors.grey.shade700),
            ),
          const Divider(height: 18),
          if (orders.isEmpty)
            Text(
              '顧客別の仮発注はまだありません',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            )
          else
            for (final entry in orders)
              _buildHomeCareCustomerOrderRow(item, entry),
        ],
      ),
    );
  }

  Widget _buildHomeCareCustomerOrderRow(
    SpecialOrderItem item,
    _HomeCareCustomerOrderEntry entry,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: entry.delivered ? Colors.grey.shade100 : Colors.white,
        border: Border.all(
          color: entry.delivered ? Colors.grey.shade300 : Colors.green.shade100,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.storeName.isNotEmpty)
                  Text(
                    '店舗名: ${entry.storeName}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                Text(
                  '顧客コード: ${entry.customerCode} / 顧客名: ${entry.customerName.isEmpty ? '-' : entry.customerName}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '発注数: ${entry.qty}個',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                Text(
                  '発注期間: ${_fmtDateSlash(item.salesStart)}〜'
                  '${_fmtDateSlash(item.salesEnd)} / '
                  '納品日: '
                  '${_fmtDateSlash(_homeCareCustomerDeliveryDisplayDate(item, entry))}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: entry.reserved,
                    onChanged: _canManageSpecialStock
                        ? (value) => _toggleHomeCareCustomerReserved(
                            entry,
                            value == true,
                          )
                        : null,
                  ),
                  const Text('取置き済み'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: entry.delivered,
                    onChanged: (value) => _toggleHomeCareCustomerDelivered(
                      item,
                      entry,
                      value == true,
                    ),
                  ),
                  const Text('引渡し済み'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _canModifyCustomerOrderForItem(item)
                        ? () => _editHomeCareCustomerOrder(item, entry)
                        : null,
                    child: const Text('編集'),
                  ),
                  TextButton(
                    onPressed: _canModifyCustomerOrderForItem(item)
                        ? () => _deleteHomeCareCustomerOrder(item, entry)
                        : null,
                    child: const Text(
                      '削除',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _homeCareManualDeliveredTotalForLot(String lotKey) {
    return _handoverLogs
        .where(
          (entry) => entry.key == lotKey && entry.customerCode == '納品済み手動反映',
        )
        .fold(0, (total, entry) => total + entry.qty);
  }

  int _homeCareCurrentStockForLot(_HomeCareLotStock lot) {
    if (lot.currentStock > 0) return lot.currentStock;
    final deliveredByCustomer = _homeCareCustomerOrdersForLot(lot.key)
        .where((entry) => entry.delivered)
        .fold(0, (total, entry) => total + entry.qty);
    return max(
      0,
      _homeCareManualDeliveredTotalForLot(lot.key) - deliveredByCustomer,
    );
  }

  int _reservedTotalForHomeCareLot(String lotKey) {
    return _homeCareCustomerOrdersForLot(lotKey)
        .where((entry) => entry.reserved && !entry.delivered)
        .fold(0, (total, entry) => total + entry.qty);
  }

  String _reservedStoreBreakdownForHomeCareLot(String lotKey) {
    final byStore = <String, int>{};
    for (final entry in _homeCareCustomerOrdersForLot(lotKey)) {
      if (!entry.reserved || entry.delivered) continue;
      final storeName = entry.storeName.trim().isEmpty
          ? '店舗未入力'
          : entry.storeName.trim();
      byStore[storeName] = (byStore[storeName] ?? 0) + entry.qty;
    }
    if (byStore.isEmpty) return '';
    final keys = byStore.keys.toList()..sort(_naturalCompare);
    return keys.map((key) => '$key ${byStore[key]}個').join(' / ');
  }

  int _reservedTotalForNewProductLot(String lotKey) {
    return _newProductCustomerOrders.values
        .where(
          (entry) =>
              entry.lotKey == lotKey && entry.reserved && !entry.delivered,
        )
        .fold(0, (total, entry) => total + entry.qty);
  }

  String _reservedStoreBreakdownForNewProductLot(String lotKey) {
    final byStore = <String, int>{};
    for (final entry in _newProductCustomerOrders.values) {
      if (entry.lotKey != lotKey || !entry.reserved || entry.delivered) {
        continue;
      }
      final storeName = entry.storeName.trim().isEmpty
          ? '店舗未入力'
          : entry.storeName.trim();
      byStore[storeName] = (byStore[storeName] ?? 0) + entry.qty;
    }
    if (byStore.isEmpty) return '';
    final keys = byStore.keys.toList()..sort(_naturalCompare);
    return keys.map((key) => '$key ${byStore[key]}個').join(' / ');
  }

  // ── 新商品タブ：集計表示ボックス（顧客コード欄なし） ─────────────
  // 「新商品」「ホームケアセット」共通の集計表示ボックス（青いボックス、
  // 顧客コード欄なし）。件数・合計・未引渡し・納品予定数を表示し、
  // 納品予定数は統括管理者のみ編集できる。
  Widget _buildLotSummaryBox({
    required String title,
    String? subtitle,
    required int count,
    required int total,
    required int pendingTotal,
    required int deliveredTotal,
    required int reservedTotal,
    required int remaining,
    required int currentStock,
    required String reservedStoreBreakdown,
    required TextEditingController remainingCtrl,
    required TextEditingController currentStockCtrl,
    required TextEditingController deliveredCtrl,
    required VoidCallback onSaveRemaining,
    required VoidCallback onSaveCurrentStock,
    required VoidCallback onSaveDelivered,
  }) {
    Widget statChip(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade800,
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              statChip('件数 $count 件', Colors.blue.shade800),
              statChip('仮発注合計 $total 個', Colors.blue.shade800),
              statChip('取置き中 $reservedTotal 個', Colors.purple.shade800),
              statChip('引渡し済み $deliveredTotal 個', Colors.grey.shade800),
              statChip('現在在庫 $currentStock 個', Colors.green.shade800),
              statChip('納品予定 $remaining 個', Colors.orange.shade800),
            ],
          ),
          if (reservedStoreBreakdown.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '店舗別取置き: $reservedStoreBreakdown',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.purple.shade800,
              ),
            ),
          ],
          if (_canManageSpecialStock) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 132,
                  child: TextField(
                    controller: remainingCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '納品予定数',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: onSaveRemaining,
                  child: const Text('予定数保存'),
                ),
                SizedBox(
                  width: 132,
                  child: TextField(
                    controller: currentStockCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '現在在庫',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: onSaveCurrentStock,
                  child: const Text('在庫保存'),
                ),
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: deliveredCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '納品済みにする数',
                      suffixText: '個',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: onSaveDelivered,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('納品済み反映'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '※在庫数・納品予定数・納品済み反映・取置き済みは管理者/統括管理者のみ変更できます。',
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNewProductSummaryBox(SpecialOrderItem item) {
    final lot = _newProductLotFor(item);
    final orders = _newProductCustomerOrdersForItem(item);
    final count = orders.length;
    final total = orders.fold(0, (total, entry) => total + entry.qty);
    final deliveredTotal = _newProductCustomerDeliveredTotalForItem(item);
    final pendingTotal = max(0, total - deliveredTotal);

    return _buildLotSummaryBox(
      title: '新商品 在庫サマリー',
      count: count,
      total: total,
      pendingTotal: pendingTotal,
      deliveredTotal: deliveredTotal,
      reservedTotal: _reservedTotalForNewProductLot(lot.key),
      remaining: lot.remaining,
      currentStock: lot.currentStock,
      reservedStoreBreakdown: _reservedStoreBreakdownForNewProductLot(lot.key),
      remainingCtrl: _newProductRemainingCtrl(item),
      currentStockCtrl: _newProductCurrentStockCtrl(item),
      deliveredCtrl: _newProductDeliveredCtrl(item),
      onSaveRemaining: () => _saveNewProductRemaining(item),
      onSaveCurrentStock: () => _saveNewProductCurrentStock(item),
      onSaveDelivered: () => _saveNewProductDeliveredCount(item),
    );
  }

  // ── 新商品タブ：顧客別仮発注ボックス（緑ボックス、ホームケアと同UI） ──
  Widget _buildNewProductCustomerOrderBox(SpecialOrderItem item) {
    final codeCtrl = _newProductCustomerCtrl(item);
    final nameCtrl = _newProductCustomerNameCtrl(item);
    final storeCtrl = _newProductStoreNameCtrl(item);
    final qtyCtrl = _newProductCustomerOrderQtyCtrl(item);
    final orders = _newProductCustomerOrdersForItem(item);
    final total = _newProductCustomerOrderTotalForItem(item);
    final deliveredTotal = _newProductCustomerDeliveredTotalForItem(item);
    final pendingTotal = max(0, total - deliveredTotal);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border.all(color: Colors.green.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.people_alt_outlined, color: Colors.green.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '顧客別 仮発注',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade900,
                  ),
                ),
              ),
              Text(
                '期間合計 $total 個 / 未引渡し $pendingTotal 個',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.green.shade900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_canAddOrderForItem(item)) ...[
            TextField(
              controller: storeCtrl,
              decoration: const InputDecoration(
                labelText: '店舗名',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: codeCtrl,
                    onChanged: (value) => _applyKnownNewProductCustomerName(
                      value,
                      nameCtrl,
                      overwrite: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '顧客コード',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '顧客名',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
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
              onPressed: () => _placeNewProductCustomerOrder(item),
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('顧客別に仮発注'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ] else
            Text(
              item.isBeforeSales ? '発注期間前のため入力できません' : '発注期間終了のため入力できません',
              style: TextStyle(color: Colors.grey.shade700),
            ),
          const Divider(height: 18),
          if (orders.isEmpty)
            Text(
              '顧客別の仮発注はまだありません',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            )
          else
            for (final entry in orders)
              _buildNewProductCustomerOrderRow(item, entry),
        ],
      ),
    );
  }

  Widget _buildNewProductCustomerOrderRow(
    SpecialOrderItem item,
    _NewProductCustomerOrderEntry entry,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: entry.delivered ? Colors.grey.shade100 : Colors.white,
        border: Border.all(
          color: entry.delivered ? Colors.grey.shade300 : Colors.green.shade100,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.storeName.isNotEmpty)
                  Text(
                    '店舗名: ${entry.storeName}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                Text(
                  '顧客コード: ${entry.customerCode} / 顧客名: ${entry.customerName.isEmpty ? '-' : entry.customerName}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '発注数: ${entry.qty}個',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                Text(
                  '発注日: ${_fmtDateSlash(entry.orderedAt)} / '
                  '本店到着予定: ${_fmtDateSlash(item.arrival)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: entry.reserved,
                    onChanged: _canManageSpecialStock
                        ? (value) => _toggleNewProductCustomerReserved(
                            entry,
                            value == true,
                          )
                        : null,
                  ),
                  const Text('取置き済み'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: entry.delivered,
                    onChanged: (value) => _toggleNewProductCustomerDelivered(
                      item,
                      entry,
                      value == true,
                    ),
                  ),
                  const Text('引渡し済み'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _canModifyCustomerOrderForItem(item)
                        ? () => _editNewProductCustomerOrder(item, entry)
                        : null,
                    child: const Text('編集'),
                  ),
                  TextButton(
                    onPressed: _canModifyCustomerOrderForItem(item)
                        ? () => _deleteNewProductCustomerOrder(item, entry)
                        : null,
                    child: const Text(
                      '削除',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHomeCareLotPanel(SpecialOrderItem item) {
    final lot = _homeCareLotFor(item);
    final orders = _homeCareCustomerOrdersForLot(lot.key);
    final count = orders.length;
    final total = orders.fold(0, (total, entry) => total + entry.qty);
    final deliveredTotal = orders
        .where((entry) => entry.delivered)
        .fold(0, (total, entry) => total + entry.qty);
    final pendingTotal = max(0, total - deliveredTotal);

    return _buildLotSummaryBox(
      title: 'ホームケアセット 在庫サマリー',
      subtitle: '${lot.name} / コード:${lot.code.isEmpty ? item.code : lot.code}',
      count: count,
      total: total,
      pendingTotal: pendingTotal,
      deliveredTotal: deliveredTotal,
      reservedTotal: _reservedTotalForHomeCareLot(lot.key),
      remaining: lot.remaining,
      currentStock: _homeCareCurrentStockForLot(lot),
      reservedStoreBreakdown: _reservedStoreBreakdownForHomeCareLot(lot.key),
      remainingCtrl: _homeCareRemainingCtrl(item),
      currentStockCtrl: _homeCareCurrentStockCtrl(item),
      deliveredCtrl: _homeCareDeliveredCtrl(item),
      onSaveRemaining: () => _saveHomeCareRemaining(item),
      onSaveCurrentStock: () => _saveHomeCareCurrentStock(item),
      onSaveDelivered: () => _saveHomeCareDeliveredCount(item),
    );
  }

  Widget _buildHomeCareOrderLotBox(SpecialOrderItem item) {
    if (!_isHomeCareSet(item)) return const SizedBox.shrink();
    final lot = _homeCareLotFor(item);
    final lotCtrl = _homeCareLotCtrl(item);
    final orderedLots = _homeCareOrderedLotTotalForItem(item);
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
                  '旧入力 $orderedLots 個',
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
            Text(
              '旧方式の入力分は下に個数で表示されます。実際に仕入れた在庫数は、このロット設定で発注するか、納品可能在庫を修正してください。',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
            ),
          ],
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
                  '統括管理者が設定した納品予定数から、顧客別仮発注の引渡し済み数量を差し引いた在庫数です。',
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
    // 先頭固定行: 検索欄・説明文（ホームケアは集計表示も）＋ 広告カード1行。
    final extraTopCount = homeCareMode ? 4 : 3;
    final adIndex = extraTopCount - 1;
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
        if (index == adIndex) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: AdInlineCardWidget(compact: true),
          );
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
    final totalOrdered = _isHomeCareSet(item)
        ? _homeCareCustomerOrderTotalForItem(item)
        : _newProductCustomerOrderTotalForItem(item);

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
              ),
            if (totalOrdered > 0)
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
          if (_isHomeCareSet(item)) ...[
            if (AppSession.isAdmin || AppSession.isSuperAdmin)
              _buildHomeCareOrderLotBox(item),
            _buildHomeCareCustomerOrderBox(item),
            _buildHomeCareLegacyOrderBox(item),
          ] else ...[
            _buildNewProductSummaryBox(item),
            _buildNewProductCustomerOrderBox(item),
          ],
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
      if (_noViewableStores) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 40, color: Colors.red.shade400),
                const SizedBox(height: 12),
                const Text(
                  '閲覧できる店舗がありません。\n管理者にお問い合わせください。',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
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
        title: Text(widget.showExpiredOnly ? '販売終了' : '特別発注・新商品発注'),
        bottom: widget.showExpiredOnly
            ? null
            : const TabBar(
                tabs: [
                  Tab(text: '新商品'),
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
      body: Column(
        children: [
          if (!_loading &&
              _error == null &&
              _isRestricted &&
              !_noViewableStores)
            Container(
              width: double.infinity,
              color: Colors.orange.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Colors.orange.shade800,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '閲覧が許可されている店舗のみ対象にしています：'
                      '${_visibleStoreNames.join('、')}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange.shade900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: buildBody()),
        ],
      ),
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
    required this.currentStock,
  });

  final String key;
  final String code;
  final String name;
  final int lotSize;
  final int remaining;
  final int currentStock;

  factory _HomeCareLotStock.fromMap(String key, Map<String, dynamic> map) {
    return _HomeCareLotStock(
      key: key,
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      lotSize: inventoryIntValue(map['lotSize']) <= 0
          ? 1
          : inventoryIntValue(map['lotSize']),
      remaining: max(0, inventoryIntValue(map['remaining'])),
      currentStock: max(0, inventoryIntValue(map['currentStock'])),
    );
  }

  _HomeCareLotStock copyWith({
    String? code,
    String? name,
    int? lotSize,
    int? remaining,
    int? currentStock,
  }) {
    return _HomeCareLotStock(
      key: key,
      code: code ?? this.code,
      name: name ?? this.name,
      lotSize: lotSize ?? this.lotSize,
      remaining: remaining ?? this.remaining,
      currentStock: currentStock ?? this.currentStock,
    );
  }
}

class _HomeCareCustomerOrderEntry {
  const _HomeCareCustomerOrderEntry({
    required this.id,
    required this.itemId,
    required this.lotKey,
    required this.itemCode,
    required this.itemName,
    required this.customerCode,
    required this.customerName,
    required this.storeName,
    required this.qty,
    required this.delivered,
    required this.reserved,
    required this.orderedAt,
    required this.deliveredAt,
  });

  final String id;
  final String itemId;
  final String lotKey;
  final String itemCode;
  final String itemName;
  final String customerCode;
  final String customerName;
  final String storeName;
  final int qty;
  final bool delivered;
  final bool reserved;
  final DateTime orderedAt;
  final DateTime? deliveredAt;

  factory _HomeCareCustomerOrderEntry.fromMap(
    String fallbackId,
    Map<String, dynamic> map,
  ) {
    return _HomeCareCustomerOrderEntry(
      id: (map['id'] ?? fallbackId).toString(),
      itemId: (map['itemId'] ?? '').toString(),
      lotKey: (map['lotKey'] ?? map['key'] ?? '').toString(),
      itemCode: (map['itemCode'] ?? map['code'] ?? '').toString(),
      itemName: (map['itemName'] ?? map['name'] ?? '').toString(),
      customerCode: (map['customerCode'] ?? '').toString(),
      customerName: (map['customerName'] ?? '').toString(),
      storeName: (map['storeName'] ?? '').toString(),
      qty: max(0, inventoryIntValue(map['qty'])),
      delivered: map['delivered'] == true,
      reserved: map['reserved'] == true,
      orderedAt: _readLogTimestamp(map['orderedAt'] ?? map['at']),
      deliveredAt: map['deliveredAt'] == null
          ? null
          : _readLogTimestamp(map['deliveredAt']),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'itemId': itemId,
    'lotKey': lotKey,
    'itemCode': itemCode,
    'itemName': itemName,
    'customerCode': customerCode,
    'customerName': customerName,
    'storeName': storeName,
    'qty': qty,
    'delivered': delivered,
    'reserved': reserved,
    'orderedAt': Timestamp.fromDate(orderedAt),
    if (deliveredAt != null) 'deliveredAt': Timestamp.fromDate(deliveredAt!),
  };

  _HomeCareCustomerOrderEntry copyWith({
    String? customerCode,
    String? customerName,
    String? storeName,
    int? qty,
    bool? delivered,
    bool? reserved,
    DateTime? orderedAt,
    DateTime? deliveredAt,
  }) {
    return _HomeCareCustomerOrderEntry(
      id: id,
      itemId: itemId,
      lotKey: lotKey,
      itemCode: itemCode,
      itemName: itemName,
      customerCode: customerCode ?? this.customerCode,
      customerName: customerName ?? this.customerName,
      storeName: storeName ?? this.storeName,
      qty: qty ?? this.qty,
      delivered: delivered ?? this.delivered,
      reserved: reserved ?? this.reserved,
      orderedAt: orderedAt ?? this.orderedAt,
      deliveredAt: deliveredAt,
    );
  }
}

// 新商品タブのロット在庫（newProductLots）。コード単位で共有し、
// ホームケアセットと同様に複数の販売期間をまたいで同じ在庫を参照する。
class _NewProductLotStock {
  const _NewProductLotStock({
    required this.key,
    required this.code,
    required this.name,
    required this.lotSize,
    required this.remaining,
    required this.currentStock,
  });

  final String key;
  final String code;
  final String name;
  final int lotSize;
  final int remaining;
  final int currentStock;

  factory _NewProductLotStock.fromMap(String key, Map<String, dynamic> map) {
    return _NewProductLotStock(
      key: key,
      code: (map['code'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      lotSize: inventoryIntValue(map['lotSize']) <= 0
          ? 1
          : inventoryIntValue(map['lotSize']),
      remaining: max(0, inventoryIntValue(map['remaining'])),
      currentStock: max(0, inventoryIntValue(map['currentStock'])),
    );
  }

  _NewProductLotStock copyWith({
    String? code,
    String? name,
    int? lotSize,
    int? remaining,
    int? currentStock,
  }) {
    return _NewProductLotStock(
      key: key,
      code: code ?? this.code,
      name: name ?? this.name,
      lotSize: lotSize ?? this.lotSize,
      remaining: remaining ?? this.remaining,
      currentStock: currentStock ?? this.currentStock,
    );
  }
}

// 新商品タブの顧客別仮発注（newProductCustomerOrders）。
class _NewProductCustomerOrderEntry {
  const _NewProductCustomerOrderEntry({
    required this.id,
    required this.itemId,
    required this.lotKey,
    required this.itemCode,
    required this.itemName,
    required this.customerCode,
    required this.customerName,
    required this.storeName,
    required this.qty,
    required this.delivered,
    required this.reserved,
    required this.orderedAt,
    required this.deliveredAt,
  });

  final String id;
  final String itemId;
  final String lotKey;
  final String itemCode;
  final String itemName;
  final String customerCode;
  final String customerName;
  final String storeName;
  final int qty;
  final bool delivered;
  final bool reserved;
  final DateTime orderedAt;
  final DateTime? deliveredAt;

  factory _NewProductCustomerOrderEntry.fromMap(
    String fallbackId,
    Map<String, dynamic> map,
  ) {
    return _NewProductCustomerOrderEntry(
      id: (map['id'] ?? fallbackId).toString(),
      itemId: (map['itemId'] ?? '').toString(),
      lotKey: (map['lotKey'] ?? '').toString(),
      itemCode: (map['itemCode'] ?? '').toString(),
      itemName: (map['itemName'] ?? '').toString(),
      customerCode: (map['customerCode'] ?? '').toString(),
      customerName: (map['customerName'] ?? '').toString(),
      storeName: (map['storeName'] ?? '').toString(),
      qty: max(0, inventoryIntValue(map['qty'])),
      delivered: map['delivered'] == true,
      reserved: map['reserved'] == true,
      orderedAt: _readLogTimestamp(map['orderedAt']),
      deliveredAt: map['deliveredAt'] == null
          ? null
          : _readLogTimestamp(map['deliveredAt']),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'itemId': itemId,
    'lotKey': lotKey,
    'itemCode': itemCode,
    'itemName': itemName,
    'customerCode': customerCode,
    'customerName': customerName,
    'storeName': storeName,
    'qty': qty,
    'delivered': delivered,
    'reserved': reserved,
    'orderedAt': Timestamp.fromDate(orderedAt),
    if (deliveredAt != null) 'deliveredAt': Timestamp.fromDate(deliveredAt!),
  };

  _NewProductCustomerOrderEntry copyWith({
    String? customerCode,
    String? customerName,
    String? storeName,
    int? qty,
    bool? delivered,
    bool? reserved,
    DateTime? orderedAt,
    DateTime? deliveredAt,
  }) {
    return _NewProductCustomerOrderEntry(
      id: id,
      itemId: itemId,
      lotKey: lotKey,
      itemCode: itemCode,
      itemName: itemName,
      customerCode: customerCode ?? this.customerCode,
      customerName: customerName ?? this.customerName,
      storeName: storeName ?? this.storeName,
      qty: qty ?? this.qty,
      delivered: delivered ?? this.delivered,
      reserved: reserved ?? this.reserved,
      orderedAt: orderedAt ?? this.orderedAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
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

DateTime _readLogTimestamp(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
