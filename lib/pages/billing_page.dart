part of '../main.dart';

// ─────────────────────────────────────────────
// 請求・受領管理（統括管理者専用）
// ─────────────────────────────────────────────

class BillingPage extends StatefulWidget {
  const BillingPage({super.key});

  @override
  State<BillingPage> createState() => _BillingPageState();
}

class _BillingPageState extends State<BillingPage> {
  bool _loading = true;
  bool _saving = false;
  bool _showBilled = false;
  String? _error;
  String _selectedStoreId = '';
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  final Set<String> _selectedBillingTypes = <String>{'商品', 'テスター', '備品'};
  final List<_BillingLine> _lines = [];
  final List<_BillingInvoiceSummary> _invoices = [];
  final Set<String> _billedKeys = <String>{};
  final Set<String> _issuedMonthStoreKeys = <String>{};
  final Map<String, _BillingPrice> _billingPrices = {};
  final Map<String, _BillingRecipient> _storeRecipients = {};
  final Map<String, TextEditingController> _priceControllers = {};
  final Map<String, TextEditingController> _purchaseRateControllers = {};
  final TextEditingController _repaymentCurrentController =
      TextEditingController();
  final TextEditingController _repaymentTotalController =
      TextEditingController();
  final TextEditingController _repaymentAmountController =
      TextEditingController();
  final TextEditingController _recipientNameController =
      TextEditingController();
  final TextEditingController _recipientPostalController =
      TextEditingController();
  final TextEditingController _recipientAddress1Controller =
      TextEditingController();
  final TextEditingController _recipientAddress2Controller =
      TextEditingController();
  bool _repaymentEnabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _priceControllers.values) {
      controller.dispose();
    }
    for (final controller in _purchaseRateControllers.values) {
      controller.dispose();
    }
    _repaymentCurrentController.dispose();
    _repaymentTotalController.dispose();
    _repaymentAmountController.dispose();
    _recipientNameController.dispose();
    _recipientPostalController.dispose();
    _recipientAddress1Controller.dispose();
    _recipientAddress2Controller.dispose();
    super.dispose();
  }

  int _toInt(dynamic value) => inventoryIntValue(value);

  Future<void> _load() async {
    if (!AppSession.isSuperAdmin) {
      setState(() {
        _loading = false;
        _error = '請求・受領管理を確認できるのは統括管理者のみです';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final invoiceSnap = await AppSession.billingInvoices
          .orderBy('createdAt', descending: true)
          .limit(100)
          .get();
      final billedKeys = <String>{};
      final issuedMonthStoreKeys = <String>{};
      final invoices = <_BillingInvoiceSummary>[];
      for (final doc in invoiceSnap.docs) {
        final data = doc.data();
        if ((data['status'] ?? '').toString() == 'canceled') continue;
        final rawKeys = data['lineKeys'];
        if (rawKeys is List) {
          billedKeys.addAll(rawKeys.map((e) => e.toString()));
        }
        final summary = _BillingInvoiceSummary.fromDoc(doc.id, data);
        invoices.add(summary);
        if (summary.monthStoreKey.isNotEmpty) {
          issuedMonthStoreKeys.add(summary.monthStoreKey);
        }
      }

      final priceDoc = await AppSession.doc('billing_prices').get();
      final priceData = priceDoc.data() ?? <String, dynamic>{};
      final billingPrices = <String, _BillingPrice>{};
      final rawEntries = priceData['entries'];
      if (rawEntries is Map) {
        for (final entry in rawEntries.entries) {
          final value = entry.value;
          if (value is! Map) continue;
          final map = Map<String, dynamic>.from(
            value.map((k, v) => MapEntry(k.toString(), v)),
          );
          billingPrices[entry.key.toString()] = _BillingPrice.fromMap(map);
        }
      }
      final storeRecipients = <String, _BillingRecipient>{};
      final rawRecipients = priceData['storeRecipients'];
      if (rawRecipients is Map) {
        for (final entry in rawRecipients.entries) {
          final value = entry.value;
          if (value is! Map) continue;
          final map = Map<String, dynamic>.from(
            value.map((k, v) => MapEntry(k.toString(), v)),
          );
          storeRecipients[entry.key.toString()] = _BillingRecipient.fromMap(
            map,
          );
        }
      }

      final rawRepayment = priceData['repayment'];
      final repayment = rawRepayment is Map
          ? Map<String, dynamic>.from(
              rawRepayment.map((k, v) => MapEntry(k.toString(), v)),
            )
          : <String, dynamic>{};
      final repaymentEnabled = repayment['enabled'] == true;
      final repaymentCurrent = inventoryIntValue(repayment['current']);
      final repaymentTotal = inventoryIntValue(repayment['total']);
      final repaymentAmount = inventoryIntValue(repayment['monthlyAmount']);
      _repaymentCurrentController.text = repaymentCurrent > 0
          ? repaymentCurrent.toString()
          : '';
      _repaymentTotalController.text = repaymentTotal > 0
          ? repaymentTotal.toString()
          : '';
      _repaymentAmountController.text = repaymentAmount > 0
          ? repaymentAmount.toString()
          : '';

      final batchSnap = await AppSession.orderBatches
          .orderBy('createdAt', descending: true)
          .limit(200)
          .get();
      final lines = <_BillingLine>[];
      for (final batch in batchSnap.docs) {
        final data = batch.data();
        if ((data['status'] ?? '').toString() == 'canceled') continue;
        final orderDate = _batchDate(data);
        final rawItems = data['items'];
        if (rawItems is! List) continue;
        for (int i = 0; i < rawItems.length; i++) {
          final raw = rawItems[i];
          if (raw is! Map) continue;
          final item = Map<String, dynamic>.from(
            raw.map((k, v) => MapEntry(k.toString(), v)),
          );
          final qty = _toInt(item['qty']);
          if (qty <= 0) continue;
          final line = _BillingLine(
            key: '${batch.id}_$i',
            batchId: batch.id,
            batchTitle: _batchTitle(data),
            orderDate: orderDate,
            storeId: (item['storeId'] ?? '').toString(),
            storeName: (item['storeName'] ?? '').toString(),
            itemType: inventoryTypeLabelFromKey(
              (item['typeKey'] ?? item['itemType'] ?? '').toString(),
            ),
            itemCode: (item['itemCode'] ?? '').toString(),
            itemName: (item['itemName'] ?? '').toString(),
            qty: qty,
            billed: billedKeys.contains('${batch.id}_$i'),
          );
          lines.add(line);
        }
      }
      lines.sort((a, b) {
        final billedCompare = a.billed == b.billed ? 0 : (a.billed ? 1 : -1);
        if (billedCompare != 0) return billedCompare;
        final dateCompare = b.orderDate.compareTo(a.orderDate);
        if (dateCompare != 0) return dateCompare;
        final storeCompare = a.storeName.compareTo(b.storeName);
        if (storeCompare != 0) return storeCompare;
        final codeCompare = _naturalCompare(a.itemCode, b.itemCode);
        if (codeCompare != 0) return codeCompare;
        return _naturalCompare(a.itemName, b.itemName);
      });

      for (final line in lines) {
        final master = billingPrices[_priceKeyFor(line)];
        final priceController = _priceControllers.putIfAbsent(line.key, () {
          final controller = TextEditingController();
          controller.addListener(() {
            if (mounted) setState(() {});
          });
          return controller;
        });
        if ((priceController.text.trim().isEmpty || line.billed) &&
            master != null &&
            master.unitPrice > 0) {
          priceController.text = master.unitPrice.toString();
        }
        final rateController = _purchaseRateControllers.putIfAbsent(
          line.key,
          () {
            final controller = TextEditingController();
            controller.addListener(() {
              if (mounted) setState(() {});
            });
            return controller;
          },
        );
        if ((rateController.text.trim().isEmpty || line.billed) &&
            master != null &&
            master.purchaseRate > 0) {
          rateController.text = master.purchaseRate.toString();
        }
      }

      setState(() {
        _billedKeys
          ..clear()
          ..addAll(billedKeys);
        _invoices
          ..clear()
          ..addAll(invoices);
        _issuedMonthStoreKeys
          ..clear()
          ..addAll(issuedMonthStoreKeys);
        _billingPrices
          ..clear()
          ..addAll(billingPrices);
        _storeRecipients
          ..clear()
          ..addAll(storeRecipients);
        _repaymentEnabled = repaymentEnabled;
        _lines
          ..clear()
          ..addAll(lines);
        if (_selectedStoreId.isEmpty) {
          final stores = _storesForMonth(_selectedMonth);
          if (stores.isNotEmpty) _selectedStoreId = stores.keys.first;
        }
        _applyRecipientToControllers(_selectedStoreId);
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

  String _dateText(DateTime dt) => '${dt.year}年${dt.month}月${dt.day}日';

  String _invoiceNo(int sequence) {
    return 'AQU-${sequence.toString().padLeft(5, '0')}';
  }

  int _nextInvoiceSequence() {
    var maxSeq = 0;
    for (final invoice in _invoices) {
      if (invoice.invoiceSeq > maxSeq) maxSeq = invoice.invoiceSeq;
    }
    if (maxSeq <= 0) maxSeq = _invoices.length;
    return maxSeq + 1;
  }

  String _monthKey(DateTime month) {
    return '${month.year}${month.month.toString().padLeft(2, '0')}';
  }

  DateTime _monthStart(DateTime month) => DateTime(month.year, month.month, 1);

  DateTime _monthEnd(DateTime month) =>
      DateTime(month.year, month.month + 1, 0, 23, 59, 59, 999);

  bool _isSameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  bool _inSelectedMonth(_BillingLine line) =>
      _isSameMonth(line.orderDate, _selectedMonth);

  String _periodText(DateTime month) {
    final end = _monthEnd(month);
    return '${month.year}年${month.month}月1日〜${end.month}月${end.day}日';
  }

  String _monthStoreKey(DateTime month, String storeId) =>
      '${_monthKey(month)}__$storeId';

  DateTime _paymentDueDateForMonth(DateTime month) =>
      DateTime(month.year, month.month + 1, 25);

  String _paymentDueTextForMonth(DateTime month) =>
      _dateText(_paymentDueDateForMonth(month));

  List<DateTime> _availableMonths() {
    final keys = <String, DateTime>{};
    for (final line in _lines) {
      final month = DateTime(line.orderDate.year, line.orderDate.month);
      keys[_monthKey(month)] = month;
    }
    keys[_monthKey(_selectedMonth)] = _selectedMonth;
    final months = keys.values.toList()..sort((a, b) => b.compareTo(a));
    return months;
  }

  Map<String, String> _storesForMonth(DateTime month) {
    final map = <String, String>{};
    for (final line in _lines) {
      if (!_isSameMonth(line.orderDate, month)) continue;
      if (line.storeId.isNotEmpty && line.storeName.isNotEmpty) {
        map[line.storeId] = line.storeName;
      }
    }
    final entries = map.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return Map<String, String>.fromEntries(entries);
  }

  Map<String, String> _allBillingStores() {
    final map = <String, String>{};
    for (final line in _lines) {
      if (line.storeId.isNotEmpty && line.storeName.isNotEmpty) {
        map[line.storeId] = line.storeName;
      }
    }
    for (final invoice in _invoices) {
      if (invoice.storeId.isNotEmpty && invoice.storeName.isNotEmpty) {
        map[invoice.storeId] = invoice.storeName;
      }
    }
    final entries = map.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return Map<String, String>.fromEntries(entries);
  }

  _BillingRecipient _recipientForStoreWithName(
    String storeId,
    String storeName,
  ) {
    final saved = _storeRecipients[storeId];
    if (saved != null && saved.name.trim().isNotEmpty) return saved;
    final fallbackName = storeName.trim().isEmpty ? '店舗名未設定' : storeName.trim();
    return _BillingRecipient(
      name: '$fallbackName 様',
      postal: '',
      address1: '',
      address2: '',
    );
  }

  String _selectedStoreName() {
    return _storesForMonth(_selectedMonth)[_selectedStoreId] ?? '';
  }

  _BillingRecipient _recipientForStore(String storeId) {
    final storeName = _storesForMonth(_selectedMonth)[storeId] ?? '店舗名未設定';
    return _recipientForStoreWithName(storeId, storeName);
  }

  _BillingRecipient _currentRecipientFromControllers() => _BillingRecipient(
    name: _recipientNameController.text.trim(),
    postal: _recipientPostalController.text.trim(),
    address1: _recipientAddress1Controller.text.trim(),
    address2: _recipientAddress2Controller.text.trim(),
  );

  void _applyRecipientToControllers(String storeId) {
    if (storeId.isEmpty) return;
    final recipient = _recipientForStore(storeId);
    _recipientNameController.text = recipient.name;
    _recipientPostalController.text = recipient.postal;
    _recipientAddress1Controller.text = recipient.address1;
    _recipientAddress2Controller.text = recipient.address2;
  }

  void _selectStore(String storeId) {
    setState(() {
      _selectedStoreId = storeId;
      _applyRecipientToControllers(storeId);
    });
  }

  Future<void> _saveRecipientForSelectedStore() async {
    if (_selectedStoreId.isEmpty) return;
    final recipient = _currentRecipientFromControllers();
    if (recipient.name.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('宛名を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await AppSession.doc('billing_prices').set({
        'storeRecipients': {_selectedStoreId: recipient.toMap()},
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtLocal': DateTime.now().toIso8601String(),
        'updatedBy': AppSession.nickname,
      }, SetOptions(merge: true));
      setState(() => _storeRecipients[_selectedStoreId] = recipient);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('店舗の宛名を保存しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('宛名保存失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<_BillingLine> _withPrices(List<_BillingLine> lines) {
    return lines
        .map(
          (line) => line.copyWith(
            unitPrice: _billingUnitPriceFor(line),
            listPrice: _priceFor(line),
            purchaseRate: _purchaseRateFor(line),
            taxRate: _taxRateFor(line),
          ),
        )
        .toList();
  }

  String _priceKeyFor(_BillingLine line) {
    final codeOrName = line.itemCode.trim().isEmpty
        ? line.itemName.trim()
        : line.itemCode.trim();
    return '${line.itemType}__$codeOrName';
  }

  int _purchaseRateFor(_BillingLine line) {
    final raw = _purchaseRateControllers[line.key]?.text ?? '';
    return int.tryParse(raw.replaceAll('%', '').trim()) ??
        (_billingPrices[_priceKeyFor(line)]?.purchaseRate ?? 0);
  }

  int _billingUnitPriceFor(_BillingLine line) {
    final listPrice = _priceFor(line);
    final rate = _purchaseRateFor(line);
    if (rate <= 0) return listPrice;
    return (listPrice * rate / 100).round();
  }

  int _taxRateFor(_BillingLine line) {
    return _billingPrices[_priceKeyFor(line)]?.taxRate ?? 10;
  }

  int _subtotalForRate(List<_BillingLine> lines, int taxRate) {
    return lines
        .where((line) => line.taxRate == taxRate)
        .fold<int>(0, (total, line) => total + line.amount);
  }

  int _taxFor(int subtotal, int taxRate) => (subtotal * taxRate / 100).round();

  Future<void> _saveBillingPriceForLine(_BillingLine line) async {
    final key = _priceKeyFor(line);
    final entry = _BillingPrice(
      itemType: line.itemType,
      itemCode: line.itemCode,
      itemName: line.itemName,
      unitPrice: _priceFor(line),
      purchaseRate: _purchaseRateFor(line),
      taxRate: _taxRateFor(line),
    );
    if (entry.unitPrice <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('単価を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await AppSession.doc('billing_prices').set({
        'entries': {key: entry.toMap()},
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtLocal': DateTime.now().toIso8601String(),
        'updatedBy': AppSession.nickname,
      }, SetOptions(merge: true));
      setState(() => _billingPrices[key] = entry);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('単価マスタを保存しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('単価マスタ保存失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveRepaymentSettings() async {
    setState(() => _saving = true);
    try {
      await AppSession.doc('billing_prices').set({
        'repayment': {
          'enabled': _repaymentEnabled,
          'current': inventoryIntValue(_repaymentCurrentController.text),
          'total': inventoryIntValue(_repaymentTotalController.text),
          'monthlyAmount': inventoryIntValue(_repaymentAmountController.text),
        },
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtLocal': DateTime.now().toIso8601String(),
        'updatedBy': AppSession.nickname,
      }, SetOptions(merge: true));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('定期返済設定を保存しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('定期返済設定保存失敗: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _yen(int value) {
    final s = value.toString();
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  int _priceFor(_BillingLine line) {
    final raw = _priceControllers[line.key]?.text ?? '';
    return int.tryParse(raw.replaceAll(',', '').trim()) ?? 0;
  }

  List<String> get _billingTypeOrder => const ['商品', 'テスター', '備品'];

  String get _selectedBillingTypeText {
    final selected = _billingTypeOrder
        .where((type) => _selectedBillingTypes.contains(type))
        .toList();
    return selected.isEmpty ? '未選択' : selected.join('・');
  }

  List<_BillingLine> get _invoiceTargetLines => _visibleLines
      .where((line) => !line.billed && line.storeId == _selectedStoreId)
      .toList();

  List<_BillingLine> get _visibleLines {
    return _lines.where((line) {
      if (!_showBilled && line.billed) return false;
      if (!_selectedBillingTypes.contains(line.itemType)) return false;
      if (!_inSelectedMonth(line)) return false;
      if (_selectedStoreId.isNotEmpty && line.storeId != _selectedStoreId) {
        return false;
      }
      return true;
    }).toList();
  }

  List<_BillingLine> get _targetPricedLines => _withPrices(_invoiceTargetLines);

  int get _targetSubtotal =>
      _targetPricedLines.fold<int>(0, (total, line) => total + line.amount);

  int get _targetSubtotal10 => _subtotalForRate(_targetPricedLines, 10);
  int get _targetSubtotal8 => _subtotalForRate(_targetPricedLines, 8);
  int get _targetTax10 => _taxFor(_targetSubtotal10, 10);
  int get _targetTax8 => _taxFor(_targetSubtotal8, 8);
  int get _targetTotal => _targetSubtotal + _targetTax10 + _targetTax8;

  bool get _alreadyIssuedForSelectedMonthStore => false;

  Future<pw.MemoryImage> _assetImage(String path) async {
    final data = await rootBundle.load(path);
    return pw.MemoryImage(data.buffer.asUint8List());
  }

  Future<_BillingPdfAssets> _loadPdfAssets() async {
    final logo = await _assetImage('assets/billing/restart_logo.png');
    final stamp = await _assetImage('assets/billing/corporate_stamp.png');
    final mascotInvoice = await _assetImage(
      'assets/billing/mascot_invoice.png',
    );
    final mascotReceipt = await _assetImage(
      'assets/billing/mascot_receipt.png',
    );
    final font = await PdfGoogleFonts.notoSansJPRegular();
    final boldFont = await PdfGoogleFonts.notoSansJPBold();
    return _BillingPdfAssets(
      logo: logo,
      stamp: stamp,
      mascotInvoice: mascotInvoice,
      mascotReceipt: mascotReceipt,
      font: font,
      boldFont: boldFont,
    );
  }

  Future<void> _createInvoice() async {
    if (_selectedStoreId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('先に店舗を選択してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (_alreadyIssuedForSelectedMonthStore) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_selectedStoreName()} / ${_periodText(_selectedMonth)} は請求書作成済みです',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_selectedBillingTypes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('商品・テスター・備品のいずれかを選択してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final lines = _invoiceTargetLines;
    if (lines.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('この店舗・この月の未請求明細がありません'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final missingPrice = lines.where((line) => _priceFor(line) <= 0).toList();
    if (missingPrice.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('対象明細すべての単価を入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final storeName = _selectedStoreName();
    final recipient = _currentRecipientFromControllers();
    final periodText = _periodText(_selectedMonth);
    final dueText = _paymentDueTextForMonth(_selectedMonth);
    final pricedLines = _withPrices(lines);
    final subtotal10 = _subtotalForRate(pricedLines, 10);
    final subtotal8 = _subtotalForRate(pricedLines, 8);
    final totalWithTax =
        subtotal10 +
        _taxFor(subtotal10, 10) +
        subtotal8 +
        _taxFor(subtotal8, 8);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('月次請求書を作成しますか？'),
        content: Text(
          '$storeName / $periodText の発注明細 ${lines.length} 件をまとめます。\n'
          'お支払期限: $dueText\n'
          '合計 ￥${_yen(totalWithTax)} の請求書PDFを作成して保存します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('作成する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      final issuedAt = DateTime.now();
      final invoiceSeq = _nextInvoiceSequence();
      final invoiceNo = _invoiceNo(invoiceSeq);
      final asset = await _loadPdfAssets();
      final pdfBytes = await _buildBillingPdf(
        kind: _BillingPdfKind.invoice,
        assets: asset,
        no: invoiceNo,
        date: issuedAt,
        billingMonth: _selectedMonth,
        storeName: storeName,
        billingTypeText: _selectedBillingTypeText,
        recipient: recipient,
        paymentDueTextOverride: null,
        repaymentEnabled: _repaymentEnabled,
        repaymentCurrent: inventoryIntValue(_repaymentCurrentController.text),
        repaymentTotal: inventoryIntValue(_repaymentTotalController.text),
        repaymentMonthlyAmount: inventoryIntValue(
          _repaymentAmountController.text,
        ),
        lines: pricedLines,
      );
      final invoiceRef = AppSession.billingInvoices.doc();
      final invoiceData = _invoiceData(
        invoiceRef.id,
        invoiceNo,
        invoiceSeq,
        issuedAt,
        _selectedMonth,
        _selectedStoreId,
        storeName,
        recipient,
        pricedLines,
      );
      await invoiceRef.set(invoiceData);
      await AppSession.billingInvoicePdfs.doc(invoiceRef.id).set({
        'invoiceId': invoiceRef.id,
        'invoiceNo': invoiceNo,
        'billingMonth': _monthKey(_selectedMonth),
        'storeId': _selectedStoreId,
        'storeName': storeName,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName':
            '請求書_${_monthKey(_selectedMonth)}_${storeName}_$invoiceNo.pdf',
      });
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename:
            '請求書_${_monthKey(_selectedMonth)}_${storeName}_$invoiceNo.pdf',
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('月次請求書を作成して保存しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('請求書作成失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Map<String, dynamic> _invoiceData(
    String id,
    String invoiceNo,
    int invoiceSeq,
    DateTime issuedAt,
    DateTime billingMonth,
    String storeId,
    String storeName,
    _BillingRecipient recipient,
    List<_BillingLine> lines,
  ) {
    final subtotal = lines.fold<int>(0, (total, line) => total + line.amount);
    final subtotal10 = _subtotalForRate(lines, 10);
    final subtotal8 = _subtotalForRate(lines, 8);
    final tax10 = _taxFor(subtotal10, 10);
    final tax8 = _taxFor(subtotal8, 8);
    final dueDate = _paymentDueDateForMonth(billingMonth);
    return {
      'id': id,
      'invoiceNo': invoiceNo,
      'invoiceSeq': invoiceSeq,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtLocal': issuedAt.toIso8601String(),
      'createdBy': AppSession.nickname,
      'status': 'issued',
      'billingMode': 'monthly_store_type_filter',
      'billingItemTypes': _billingTypeOrder
          .where((type) => _selectedBillingTypes.contains(type))
          .toList(),
      'billingMonth': _monthKey(billingMonth),
      'billingYear': billingMonth.year,
      'billingMonthNumber': billingMonth.month,
      'billingPeriodStartLocal': _monthStart(billingMonth).toIso8601String(),
      'billingPeriodEndLocal': _monthEnd(billingMonth).toIso8601String(),
      'paymentDueDateLocal': dueDate.toIso8601String(),
      'paymentDueText': _dateText(dueDate),
      'storeId': storeId,
      'storeName': storeName,
      'recipient': recipient.toMap(),
      'monthStoreKey': _monthStoreKey(billingMonth, storeId),
      'lineKeys': lines.map((line) => line.key).toList(),
      'subtotal': subtotal,
      'subtotal10': subtotal10,
      'subtotal8': subtotal8,
      'tax10': tax10,
      'tax8': tax8,
      'total': subtotal + tax10 + tax8,
      'repaymentEnabled': _repaymentEnabled,
      'repaymentCurrent': inventoryIntValue(_repaymentCurrentController.text),
      'repaymentTotal': inventoryIntValue(_repaymentTotalController.text),
      'repaymentMonthlyAmount': inventoryIntValue(
        _repaymentAmountController.text,
      ),
      'items': lines.map((line) => line.toInvoiceMap(line.unitPrice)).toList(),
      'hasSavedPdf': true,
    };
  }

  Future<void> _openInvoicePdf(_BillingInvoiceSummary invoice) async {
    await _openSavedBillingPdf(
      collection: AppSession.billingInvoicePdfs,
      docId: invoice.id,
      fallbackFileName: '請求書_${invoice.invoiceNo}.pdf',
      emptyMessage: '保存済み請求書PDFがありません',
    );
  }

  Future<void> _openReceiptPdf(_BillingInvoiceSummary invoice) async {
    if (invoice.receiptId.isEmpty) return;
    await _openSavedBillingPdf(
      collection: AppSession.billingReceiptPdfs,
      docId: invoice.receiptId,
      fallbackFileName: '受領書_${invoice.invoiceNo}.pdf',
      emptyMessage: '保存済み受領書PDFがありません',
    );
  }

  Future<void> _openSavedBillingPdf({
    required CollectionReference<Map<String, dynamic>> collection,
    required String docId,
    required String fallbackFileName,
    required String emptyMessage,
  }) async {
    try {
      final doc = await collection.doc(docId).get();
      final data = doc.data() ?? <String, dynamic>{};
      final raw = (data['pdfBase64'] ?? '').toString();
      if (raw.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(emptyMessage), backgroundColor: Colors.orange),
        );
        return;
      }
      final fileName = (data['pdfFileName'] ?? '').toString();
      await Printing.sharePdf(
        bytes: base64Decode(raw),
        filename: fileName.isEmpty ? fallbackFileName : fileName,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDFを開けません: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _createReceipt(_BillingInvoiceSummary invoice) async {
    if (invoice.receiptId.isNotEmpty) {
      await _openReceiptPdf(invoice);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('受領書を作成しますか？'),
        content: Text('請求書 ${invoice.invoiceNo} をもとに受領書PDFを作成して保存します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('作成する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      final invoiceDoc = await AppSession.billingInvoices.doc(invoice.id).get();
      final invoiceData = invoiceDoc.data();
      if (invoiceData == null) throw Exception('請求書データが見つかりません');
      final lines = _BillingLine.fromInvoiceItems(invoiceData['items']);
      final recipient = _BillingRecipient.fromMap(
        invoiceData['recipient'] is Map
            ? Map<String, dynamic>.from(
                (invoiceData['recipient'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v),
                ),
              )
            : <String, dynamic>{},
      );
      final issuedAt = DateTime.now();
      final assets = await _loadPdfAssets();
      final pdfBytes = await _buildBillingPdf(
        kind: _BillingPdfKind.receipt,
        assets: assets,
        no: invoice.invoiceNo,
        date: issuedAt,
        billingMonth: invoice.billingMonthDate,
        storeName: invoice.storeName,
        billingTypeText: invoice.billingItemTypesText,
        recipient: recipient,
        paymentDueTextOverride: null,
        repaymentEnabled: invoice.repaymentEnabled,
        repaymentCurrent: invoice.repaymentCurrent,
        repaymentTotal: invoice.repaymentTotal,
        repaymentMonthlyAmount: invoice.repaymentMonthlyAmount,
        lines: lines,
      );
      final receiptRef = AppSession.billingReceipts.doc();
      await receiptRef.set({
        'id': receiptRef.id,
        'invoiceId': invoice.id,
        'invoiceNo': invoice.invoiceNo,
        'invoiceSeq': invoice.invoiceSeq,
        'billingMonth': invoice.billingMonth,
        'storeId': invoice.storeId,
        'storeName': invoice.storeName,
        'recipient': recipient.toMap(),
        'monthStoreKey': invoice.monthStoreKey,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'status': 'issued',
        'subtotal': invoice.subtotal,
        'tax10': invoice.tax10,
        'tax8': invoice.tax8,
        'total': invoice.total,
        'repaymentEnabled': invoice.repaymentEnabled,
        'repaymentCurrent': invoice.repaymentCurrent,
        'repaymentTotal': invoice.repaymentTotal,
        'repaymentMonthlyAmount': invoice.repaymentMonthlyAmount,
        'items': invoiceData['items'],
        'hasSavedPdf': true,
      });
      await AppSession.billingReceiptPdfs.doc(receiptRef.id).set({
        'receiptId': receiptRef.id,
        'invoiceId': invoice.id,
        'invoiceNo': invoice.invoiceNo,
        'invoiceSeq': invoice.invoiceSeq,
        'billingMonth': invoice.billingMonth,
        'storeId': invoice.storeId,
        'storeName': invoice.storeName,
        'recipient': recipient.toMap(),
        'monthStoreKey': invoice.monthStoreKey,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName': '受領書_${invoice.invoiceNo}.pdf',
      });
      await AppSession.billingInvoices.doc(invoice.id).update({
        'receiptId': receiptRef.id,
        'receiptCreatedAt': FieldValue.serverTimestamp(),
        'receiptCreatedAtLocal': issuedAt.toIso8601String(),
      });
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: '受領書_${invoice.invoiceNo}.pdf',
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('受領書を作成して保存しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('受領書作成失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<Uint8List> _buildBillingPdf({
    required _BillingPdfKind kind,
    required _BillingPdfAssets assets,
    required String no,
    required DateTime date,
    required DateTime billingMonth,
    required String storeName,
    required String billingTypeText,
    required _BillingRecipient recipient,
    String? paymentDueTextOverride,
    required bool repaymentEnabled,
    required int repaymentCurrent,
    required int repaymentTotal,
    required int repaymentMonthlyAmount,
    required List<_BillingLine> lines,
  }) async {
    final pdf = pw.Document();
    final isInvoice = kind == _BillingPdfKind.invoice;
    final subtotal = lines.fold<int>(0, (total, line) => total + line.amount);
    final subtotal10 = _subtotalForRate(lines, 10);
    final subtotal8 = _subtotalForRate(lines, 8);
    final tax10 = _taxFor(subtotal10, 10);
    final tax8 = _taxFor(subtotal8, 8);
    final total = subtotal + tax10 + tax8;
    final title = isInvoice ? 'ご請求書' : '受領書';
    final mascot = isInvoice ? assets.mascotInvoice : assets.mascotReceipt;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        theme: pw.ThemeData.withFont(base: assets.font, bold: assets.boldFont),
        build: (_) => pw.Stack(
          children: [
            _billingPdfBackground(assets.logo, mascot),
            pw.Positioned(
              left: 58,
              right: 58,
              top: 66,
              bottom: 62,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Container(
                        width: 250,
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(
                              title,
                              style: pw.TextStyle(
                                font: assets.boldFont,
                                fontSize: 32,
                                color: PdfColor.fromHex('#2D2522'),
                              ),
                            ),
                            if (isInvoice)
                              pw.Text(
                                'Invoice',
                                style: pw.TextStyle(
                                  fontSize: 12,
                                  color: PdfColor.fromHex('#5F5A56'),
                                ),
                              ),
                            pw.Container(
                              width: 160,
                              height: 2,
                              margin: const pw.EdgeInsets.only(top: 6),
                              color: PdfColor.fromHex('#5A4A40'),
                            ),
                          ],
                        ),
                      ),
                      pw.Spacer(),
                      pw.Container(
                        width: 180,
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.end,
                          children: [
                            pw.Text(
                              '${isInvoice ? '発行日' : '受領日'}：${_dateText(date)}',
                              style: const pw.TextStyle(fontSize: 9),
                            ),
                            pw.Text(
                              '${isInvoice ? '請求書' : '受領書'}No. $no',
                              style: const pw.TextStyle(fontSize: 9),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 48),
                  pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Expanded(
                        child: _billingAddressBlock(
                          title: recipient.name.isEmpty
                              ? '$storeName 様'
                              : recipient.name,
                          lines: recipient.pdfLines,
                          dotColor: PdfColor.fromHex('#2B9BDA'),
                          fontBold: assets.boldFont,
                        ),
                      ),
                      pw.SizedBox(width: 28),
                      pw.Expanded(
                        child: pw.Container(
                          height: 128,
                          child: pw.Stack(
                            children: [
                              _billingAddressBlock(
                                title: '株式会社Re,stArt',
                                lines: const [
                                  '〒942-0061',
                                  '新潟県上越市春日新田2-2-2',
                                  '適格事業者登録番号：T4110001034998',
                                ],
                                dotColor: PdfColor.fromHex('#E785A1'),
                                fontBold: assets.boldFont,
                              ),
                              pw.Positioned(
                                right: 6,
                                top: 58,
                                child: pw.Opacity(
                                  opacity: 0.92,
                                  child: pw.Image(
                                    assets.stamp,
                                    width: 59.5,
                                    height: 59.5,
                                    fit: pw.BoxFit.contain,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 10),
                  pw.Container(
                    margin: const pw.EdgeInsets.symmetric(horizontal: 8),
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromHex('#FFF1F3'),
                      borderRadius: pw.BorderRadius.circular(2),
                    ),
                    child: pw.Text(
                      isInvoice
                          ? '平素は格別のお引き立てを賜り、誠にありがとうございます。\n下記の通りご請求申し上げます。'
                          : '平素は格別のお引き立てを賜り、誠にありがとうございます。\n下記の内容を受領いたしました。',
                      style: const pw.TextStyle(fontSize: 10.2, lineSpacing: 5),
                    ),
                  ),
                  pw.SizedBox(height: 15),
                  pw.Row(
                    children: [
                      pw.Expanded(
                        child: _billingAmountBox(
                          isInvoice ? 'ご請求金額(税込10%)' : '受領金額(税込10%)',
                          total,
                          assets.boldFont,
                        ),
                      ),
                      pw.SizedBox(width: 34),
                      pw.Expanded(
                        child: _billingDateBox(
                          isInvoice ? 'お支払期限' : '受領日',
                          isInvoice
                              ? (paymentDueTextOverride ??
                                    _paymentDueTextForMonth(billingMonth))
                              : _dateText(date),
                          assets.boldFont,
                        ),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 9),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 8),
                    child: pw.Text(
                      repaymentEnabled
                          ? '対象店舗：$storeName　種別：$billingTypeText　対象期間：${_periodText(billingMonth)}　定期返済：第$repaymentCurrent回 / 全$repaymentTotal回　毎月 ￥${_yen(repaymentMonthlyAmount)}'
                          : '対象店舗：$storeName　種別：$billingTypeText　対象期間：${_periodText(billingMonth)}',
                      style: pw.TextStyle(font: assets.boldFont, fontSize: 9.0),
                    ),
                  ),
                  pw.SizedBox(height: 6),
                  _billingPdfTable(lines, assets.boldFont),
                  pw.SizedBox(height: 8),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.end,
                    children: [
                      _billingTotalsBox(
                        subtotal,
                        tax10,
                        tax8,
                        total,
                        assets.boldFont,
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 12),
                  if (isInvoice)
                    _billingBankInfo(assets.boldFont)
                  else
                    pw.Container(
                      padding: const pw.EdgeInsets.all(10),
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#FAFAFA'),
                        border: pw.Border.all(color: PdfColors.grey400),
                        borderRadius: pw.BorderRadius.circular(3),
                      ),
                      child: pw.Text(
                        '備考：本受領書は、上記請求書に基づいて発行されています。',
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return pdf.save();
  }

  pw.Widget _billingPdfBackground(pw.MemoryImage logo, pw.MemoryImage mascot) {
    final sky = PdfColor.fromHex('#DDF4FF');
    final green = PdfColor.fromHex('#8FD35F');
    final brown = PdfColor.fromHex('#5A4A40');
    return pw.FullPage(
      ignoreMargins: true,
      child: pw.Stack(
        children: [
          pw.Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: PdfPageFormat.a4.height - 84,
            child: pw.Container(color: sky),
          ),
          pw.Positioned(
            left: -18,
            top: 24,
            right: -18,
            child: pw.Container(
              height: 28,
              decoration: pw.BoxDecoration(
                color: PdfColors.white,
                borderRadius: pw.BorderRadius.circular(50),
              ),
            ),
          ),
          for (final d in const [
            [65.0, 26.0, 8.0],
            [205.0, 56.0, 7.0],
            [310.0, 22.0, 5.0],
            [442.0, 42.0, 4.5],
            [516.0, 20.0, 4.0],
          ])
            pw.Positioned(
              left: d[0],
              top: d[1],
              child: pw.Container(
                width: d[2] * 2,
                height: d[2] * 2,
                decoration: const pw.BoxDecoration(
                  color: PdfColors.white,
                  shape: pw.BoxShape.circle,
                ),
              ),
            ),
          pw.Positioned(
            left: 0,
            top: PdfPageFormat.a4.height - 104,
            right: 0,
            bottom: 0,
            child: pw.Container(color: PdfColors.white),
          ),
          pw.Positioned(
            left: 78,
            bottom: 28,
            right: 78,
            child: pw.Container(
              height: 38,
              decoration: pw.BoxDecoration(
                color: green,
                borderRadius: pw.BorderRadius.circular(45),
              ),
            ),
          ),
          pw.Positioned(
            left: 0,
            top: PdfPageFormat.a4.height - 34,
            right: 0,
            bottom: 0,
            child: pw.Container(color: brown),
          ),
          pw.Positioned(left: 92, bottom: 38, child: _billingFlowers()),
          pw.Positioned(
            left: 340,
            bottom: 36,
            child: _billingFlowers(small: true),
          ),
          pw.Positioned(
            right: 86,
            bottom: 31,
            child: pw.Opacity(
              opacity: 0.92,
              child: pw.Image(
                mascot,
                width: 56,
                height: 56,
                fit: pw.BoxFit.contain,
              ),
            ),
          ),
          pw.Positioned(
            left: 205,
            right: 205,
            bottom: 13,
            child: pw.Container(
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 4,
              ),
              decoration: pw.BoxDecoration(
                color: PdfColors.white,
                borderRadius: pw.BorderRadius.circular(16),
              ),
              child: pw.Image(logo, height: 30, fit: pw.BoxFit.contain),
            ),
          ),
          pw.Positioned(
            left: 84,
            bottom: 10,
            child: pw.Row(
              children: [
                _billingDot(PdfColor.fromHex('#F5A000'), 5),
                pw.SizedBox(width: 18),
                _billingDot(PdfColor.fromHex('#E4007F'), 4),
                pw.SizedBox(width: 18),
                _billingDot(PdfColor.fromHex('#9ED8F6'), 5),
              ],
            ),
          ),
          pw.Positioned(
            right: 82,
            bottom: 11,
            child: pw.Row(
              children: [
                _billingDot(PdfColor.fromHex('#F7C6D8'), 4),
                pw.SizedBox(width: 18),
                _billingDot(PdfColor.fromHex('#FFCE4A'), 5),
                pw.SizedBox(width: 18),
                _billingDot(PdfColors.white, 3.5),
              ],
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _billingFlowers({bool small = false}) {
    final scale = small ? 0.72 : 1.0;
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        _billingFlower(PdfColor.fromHex('#E4007F'), 19 * scale),
        pw.SizedBox(width: 6 * scale),
        _billingFlower(PdfColor.fromHex('#FFCE4A'), 26 * scale),
        pw.SizedBox(width: 6 * scale),
        _billingFlower(PdfColor.fromHex('#2B9BDA'), 15 * scale),
      ],
    );
  }

  pw.Widget _billingFlower(PdfColor color, double h) => pw.Container(
    width: 10,
    height: h,
    child: pw.Stack(
      children: [
        pw.Positioned(
          left: 4.5,
          bottom: 0,
          child: pw.Container(
            width: 1.2,
            height: h,
            color: PdfColor.fromHex('#59483F'),
          ),
        ),
        pw.Positioned(
          left: 1.5,
          top: 0,
          child: pw.Container(
            width: 7,
            height: 7,
            decoration: pw.BoxDecoration(
              color: color,
              shape: pw.BoxShape.circle,
            ),
          ),
        ),
      ],
    ),
  );

  pw.Widget _billingDot(PdfColor color, double size) => pw.Container(
    width: size,
    height: size,
    decoration: pw.BoxDecoration(color: color, shape: pw.BoxShape.circle),
  );

  pw.Widget _billingAddressBlock({
    required String title,
    required List<String> lines,
    required PdfColor dotColor,
    required pw.Font fontBold,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Container(width: 140, height: 1, color: PdfColors.grey600),
            _billingDot(dotColor, 6),
          ],
        ),
        pw.SizedBox(height: 9),
        for (final line in lines)
          pw.Text(line, style: const pw.TextStyle(fontSize: 8.8)),
        pw.SizedBox(height: 12),
        pw.Text(title, style: pw.TextStyle(font: fontBold, fontSize: 10.5)),
      ],
    );
  }

  pw.Widget _billingAmountBox(
    String label,
    int total,
    pw.Font fontBold,
  ) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text(label, style: pw.TextStyle(font: fontBold, fontSize: 9.5)),
          pw.SizedBox(width: 8),
          pw.Expanded(child: pw.Container(height: 1, color: PdfColors.grey600)),
          _billingDot(PdfColor.fromHex('#E4007F'), 6),
        ],
      ),
      pw.SizedBox(height: 5),
      pw.Text(
        '￥${_yen(total)}',
        style: pw.TextStyle(font: fontBold, fontSize: 18),
      ),
    ],
  );

  pw.Widget _billingDateBox(
    String label,
    String date,
    pw.Font fontBold,
  ) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text(label, style: pw.TextStyle(font: fontBold, fontSize: 9.5)),
          pw.SizedBox(width: 8),
          pw.Expanded(child: pw.Container(height: 1, color: PdfColors.grey600)),
          _billingDot(PdfColor.fromHex('#9ED8F6'), 6),
        ],
      ),
      pw.SizedBox(height: 5),
      pw.Text(date, style: pw.TextStyle(font: fontBold, fontSize: 12)),
    ],
  );

  pw.Widget _billingPdfTable(List<_BillingLine> rows, pw.Font fontBold) {
    final visibleRows = rows.take(9).toList();
    return pw.Table(
      border: pw.TableBorder.symmetric(
        inside: const pw.BorderSide(color: PdfColors.grey500, width: .45),
        outside: pw.BorderSide.none,
      ),
      columnWidths: const {
        0: pw.FlexColumnWidth(2.2),
        1: pw.FlexColumnWidth(.65),
        2: pw.FlexColumnWidth(.6),
        3: pw.FlexColumnWidth(.7),
        4: pw.FlexColumnWidth(1.35),
        5: pw.FlexColumnWidth(1.9),
      },
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F9C5C8')),
          children: ['商品名', '数量', '単位', '税率', '単価', '金額']
              .map(
                (e) => pw.Padding(
                  padding: const pw.EdgeInsets.all(5),
                  child: pw.Text(
                    e,
                    style: pw.TextStyle(font: fontBold, fontSize: 8.2),
                    textAlign: pw.TextAlign.center,
                  ),
                ),
              )
              .toList(),
        ),
        for (int i = 0; i < 9; i++)
          pw.TableRow(
            decoration: i.isOdd
                ? pw.BoxDecoration(color: PdfColor.fromHex('#FDE8E9'))
                : null,
            children: i < visibleRows.length
                ? [
                    _billingPdfCell(
                      '${visibleRows[i].itemName}（コード:${visibleRows[i].itemCode}）',
                    ),
                    _billingPdfCell('${visibleRows[i].qty}', right: true),
                    _billingPdfCell('個', center: true),
                    _billingPdfCell('${visibleRows[i].taxRate}%', center: true),
                    _billingPdfCell(
                      '￥${_yen(visibleRows[i].unitPrice)}',
                      right: true,
                    ),
                    _billingPdfCell(
                      '￥${_yen(visibleRows[i].amount)}',
                      right: true,
                    ),
                  ]
                : [
                    _billingPdfCell(''),
                    _billingPdfCell(''),
                    _billingPdfCell(''),
                    _billingPdfCell(''),
                    _billingPdfCell(''),
                    _billingPdfCell('￥0', right: true),
                  ],
          ),
      ],
    );
  }

  pw.Widget _billingPdfCell(
    String text, {
    bool center = false,
    bool right = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4.5),
    child: pw.Text(
      text,
      style: const pw.TextStyle(fontSize: 8),
      textAlign: right
          ? pw.TextAlign.right
          : center
          ? pw.TextAlign.center
          : pw.TextAlign.left,
    ),
  );

  pw.Widget _billingTotalsBox(
    int subtotal,
    int tax10,
    int tax8,
    int total,
    pw.Font fontBold,
  ) {
    pw.Widget row(
      String label,
      int value, {
      bool bold = false,
      bool fill = false,
    }) => pw.Container(
      color: fill ? PdfColor.fromHex('#F9C5C8') : null,
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              font: bold ? fontBold : null,
              fontSize: bold ? 9.5 : 8.8,
            ),
          ),
          pw.Text(
            '￥${_yen(value)}',
            style: pw.TextStyle(
              font: bold ? fontBold : null,
              fontSize: bold ? 9.5 : 8.8,
            ),
          ),
        ],
      ),
    );
    return pw.Container(
      width: 196,
      child: pw.Column(
        children: [
          row('小計', subtotal),
          row('消費税(10%)', tax10),
          row('消費税(8%)', tax8),
          row('合計', total, bold: true, fill: true),
        ],
      ),
    );
  }

  pw.Widget _billingBankInfo(pw.Font fontBold) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        child: _billingBankBlock(
          'お振込先',
          const [
            '楽天銀行　第四営業支店',
            '普通　7019450',
            '口座名義　株式会社Re,stArt',
            '（カブ リスタート）代表取締役　清水 広美',
          ],
          PdfColor.fromHex('#D86510'),
          fontBold,
        ),
      ),
      pw.SizedBox(width: 24),
      pw.Expanded(
        child: _billingBankBlock(
          'お振込み先２',
          const ['GMOあおぞら銀行　法人営業部', '普通　1589610', '株式会社Re,stArt', 'カ）リスタート'],
          PdfColor.fromHex('#2B9BDA'),
          fontBold,
        ),
      ),
    ],
  );

  pw.Widget _billingBankBlock(
    String title,
    List<String> lines,
    PdfColor color,
    pw.Font fontBold,
  ) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        children: [
          pw.Container(width: 5, height: 5, color: color),
          pw.SizedBox(width: 3),
          pw.Text(title, style: pw.TextStyle(font: fontBold, fontSize: 8.5)),
        ],
      ),
      for (final line in lines)
        pw.Text(line, style: const pw.TextStyle(fontSize: 8)),
      pw.Text(
        '※恐れ入りますが、振込手数料はご負担願います。',
        style: const pw.TextStyle(fontSize: 6.3),
      ),
    ],
  );

  Widget _buildStoreFilter() {
    final months = _availableMonths();
    final stores = _storesForMonth(_selectedMonth);
    final currentStoreMissing =
        _selectedStoreId.isNotEmpty && !stores.containsKey(_selectedStoreId);
    if (currentStoreMissing) {
      _selectedStoreId = stores.isEmpty ? '' : stores.keys.first;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '月次請求を作成',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _monthKey(_selectedMonth),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '対象月',
                prefixIcon: Icon(Icons.calendar_month),
              ),
              items: [
                for (final month in months)
                  DropdownMenuItem(
                    value: _monthKey(month),
                    child: Text('${month.year}年${month.month}月'),
                  ),
              ],
              onChanged: (value) {
                if (value == null || value.length != 6) return;
                final year = int.tryParse(value.substring(0, 4));
                final month = int.tryParse(value.substring(4, 6));
                if (year == null || month == null) return;
                setState(() {
                  _selectedMonth = DateTime(year, month);
                  final monthStores = _storesForMonth(_selectedMonth);
                  _selectedStoreId = monthStores.containsKey(_selectedStoreId)
                      ? _selectedStoreId
                      : (monthStores.isEmpty ? '' : monthStores.keys.first);
                });
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _selectedStoreId,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '店舗',
                prefixIcon: Icon(Icons.store),
              ),
              items: [
                for (final entry in stores.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => _selectStore(value ?? ''),
            ),

            const SizedBox(height: 10),
            const Text('請求書の宛名', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            TextField(
              controller: _recipientNameController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '宛名',
                hintText: '例：本店 様',
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _recipientPostalController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '郵便番号',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _recipientAddress1Controller,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '住所1',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _recipientAddress2Controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '住所2・建物名など',
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _saveRecipientForSelectedStore,
                icon: const Icon(Icons.save),
                label: const Text('宛名を保存'),
              ),
            ),

            const SizedBox(height: 10),
            const Text('請求する種別', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final type in _billingTypeOrder)
                  FilterChip(
                    selected: _selectedBillingTypes.contains(type),
                    label: Text(type),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _selectedBillingTypes.add(type);
                        } else {
                          _selectedBillingTypes.remove(type);
                        }
                      });
                    },
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _showBilled,
              title: const Text('請求済みも表示する'),
              onChanged: (value) => setState(() => _showBilled = value),
            ),

            const Divider(height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _repaymentEnabled,
              title: const Text('定期返済あり'),
              onChanged: (value) => setState(() => _repaymentEnabled = value),
            ),
            if (_repaymentEnabled)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _repaymentCurrentController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: '何回目',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _repaymentTotalController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: '全何回',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _repaymentAmountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: '毎月返済額',
                        prefixText: '￥',
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _saveRepaymentSettings,
                icon: const Icon(Icons.save),
                label: const Text('返済設定を保存'),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '対象: ${_selectedStoreName().isEmpty ? '店舗未選択' : _selectedStoreName()} / ${_periodText(_selectedMonth)}\n'
                '締切: ${_paymentDueTextForMonth(_selectedMonth)} / 未請求 ${_invoiceTargetLines.length}件 / 合計 ￥${_yen(_targetTotal)}\n税10% ￥${_yen(_targetTax10)} / 軽減8% ￥${_yen(_targetTax8)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving || _alreadyIssuedForSelectedMonthStore
                    ? null
                    : _createInvoice,
                icon: const Icon(Icons.picture_as_pdf),
                label: Text(
                  _selectedBillingTypes.isEmpty
                      ? '種別を選択してください'
                      : '選択種別で請求書PDF作成',
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _createManualInvoice,
                icon: const Icon(Icons.edit_note),
                label: const Text('任意項目の請求書を作成'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _createManualReceiptOnly,
                icon: const Icon(Icons.fact_check),
                label: const Text('任意項目の受領書だけ作成'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLineCard(_BillingLine line) {
    final billingUnitPrice = _billingUnitPriceFor(line);
    final amount = line.qty * billingUnitPrice;
    return Card(
      color: line.billed ? Colors.grey.shade100 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    line.itemName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (line.billed)
                  const Chip(
                    label: Text('請求済み'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            Text('${line.storeName} / ${line.itemType} / コード:${line.itemCode}'),
            Text('${line.batchTitle} / 数量 ${line.qty}個'),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _priceControllers[line.key],
                    enabled:
                        !line.billed && !_alreadyIssuedForSelectedMonthStore,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '定価',
                      prefixText: '￥',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _purchaseRateControllers[line.key],
                    enabled:
                        !line.billed && !_alreadyIssuedForSelectedMonthStore,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '仕入率',
                      suffixText: '%',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '請求単価 ￥${_yen(billingUnitPrice)} / 金額 ￥${_yen(amount)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                FilterChip(
                  label: const Text('軽減税率8%'),
                  selected: _taxRateFor(line) == 8,
                  onSelected: line.billed || _alreadyIssuedForSelectedMonthStore
                      ? null
                      : (selected) {
                          final key = _priceKeyFor(line);
                          final current =
                              _billingPrices[key] ??
                              _BillingPrice.fromLine(line);
                          setState(() {
                            _billingPrices[key] = current.copyWith(
                              taxRate: selected ? 8 : 10,
                              unitPrice: _priceFor(line),
                              purchaseRate: _purchaseRateFor(line),
                            );
                          });
                        },
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _saving || line.billed
                      ? null
                      : () => _saveBillingPriceForLine(line),
                  icon: const Icon(Icons.save),
                  label: const Text('単価・率保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cancelInvoice(_BillingInvoiceSummary invoice) async {
    final isManual =
        invoice.billingMode == 'manual' ||
        invoice.billingMode == 'manual_receipt_only';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isManual ? '任意請求書を削除しますか？' : '請求書を取り消しますか？'),
        content: Text(
          isManual
              ? '${invoice.invoiceNo} を削除扱いにします。発注明細への巻き戻しはありません。'
              : '${invoice.invoiceNo} を取り消します。対象明細は未請求に戻ります。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(isManual ? '削除する' : '取り消す'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _saving = true);
    try {
      await AppSession.billingInvoices.doc(invoice.id).set({
        'status': 'canceled',
        'canceledAt': FieldValue.serverTimestamp(),
        'canceledAtLocal': DateTime.now().toIso8601String(),
        'canceledBy': AppSession.nickname,
      }, SetOptions(merge: true));
      if (invoice.receiptId.isNotEmpty) {
        await AppSession.billingReceipts.doc(invoice.receiptId).set({
          'status': 'canceled',
          'canceledAt': FieldValue.serverTimestamp(),
          'canceledAtLocal': DateTime.now().toIso8601String(),
          'canceledBy': AppSession.nickname,
        }, SetOptions(merge: true));
      }
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isManual ? '任意請求書を削除しました' : '請求書を取り消しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('取消失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  DateTime _manualDueDate(DateTime baseMonth, String raw) {
    final text = raw.trim();
    if (text.isEmpty) return DateTime(baseMonth.year, baseMonth.month + 1, 0);
    final normalized = text.replaceAll('/', '-').replaceAll('.', '-');
    return DateTime.tryParse(normalized) ??
        DateTime(baseMonth.year, baseMonth.month + 1, 0);
  }

  DateTime _manualIssueDate(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return DateTime.now();
    final normalized = text.replaceAll('/', '-').replaceAll('.', '-');
    return DateTime.tryParse(normalized) ?? DateTime.now();
  }

  List<_BillingLine> _manualLinesFromRows(
    List<_ManualBillingLineControllers> rows,
    String storeName,
  ) {
    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final lines = <_BillingLine>[];
    for (int i = 0; i < rows.length; i++) {
      final row = rows[i];
      final name = row.name.text.trim();
      if (name.isEmpty) continue;
      final qty = inventoryIntValue(row.qty.text);
      final inputUnit = inventoryIntValue(row.unitPrice.text);
      if (qty <= 0 || inputUnit <= 0) continue;
      final taxRate = row.taxRate == 8 ? 8 : 10;
      final unitPrice = row.taxIncluded
          ? (inputUnit / (1 + taxRate / 100)).round()
          : inputUnit;
      lines.add(
        _BillingLine(
          key: 'manual_${nowMicros}_$i',
          batchId: 'manual',
          batchTitle: '任意項目',
          orderDate: DateTime.now(),
          storeId: _selectedStoreId,
          storeName: storeName,
          itemType: row.type.text.trim().isEmpty ? '任意' : row.type.text.trim(),
          itemCode: row.code.text.trim(),
          itemName: name,
          qty: qty,
          unitPrice: unitPrice,
          listPrice: inputUnit,
          taxRate: taxRate,
        ),
      );
    }
    return lines;
  }

  int _manualPreviewAmount(_ManualBillingLineControllers row) {
    final qty = inventoryIntValue(row.qty.text);
    final inputUnit = inventoryIntValue(row.unitPrice.text);
    if (qty <= 0 || inputUnit <= 0) return 0;
    final taxRate = row.taxRate == 8 ? 8 : 10;
    final unitPrice = row.taxIncluded
        ? (inputUnit / (1 + taxRate / 100)).round()
        : inputUnit;
    return unitPrice * qty;
  }

  String _dateInputText(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  DateTime _dateFromLocalField(
    Map<String, dynamic> data,
    String key,
    DateTime fallback,
  ) {
    return DateTime.tryParse((data[key] ?? '').toString()) ?? fallback;
  }

  Map<String, int> _totalsForLines(List<_BillingLine> lines) {
    final subtotal = lines.fold<int>(0, (total, line) => total + line.amount);
    final subtotal10 = _subtotalForRate(lines, 10);
    final subtotal8 = _subtotalForRate(lines, 8);
    final tax10 = _taxFor(subtotal10, 10);
    final tax8 = _taxFor(subtotal8, 8);
    return {
      'subtotal': subtotal,
      'subtotal10': subtotal10,
      'subtotal8': subtotal8,
      'tax10': tax10,
      'tax8': tax8,
      'total': subtotal + tax10 + tax8,
    };
  }

  List<_BillingLine> _billingLinesFromEditRows(
    List<_ManualBillingLineControllers> rows,
    String fallbackStoreName,
  ) {
    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final lines = <_BillingLine>[];
    for (int i = 0; i < rows.length; i++) {
      final row = rows[i];
      final name = row.name.text.trim();
      if (name.isEmpty) continue;
      final qty = inventoryIntValue(row.qty.text);
      final inputUnit = inventoryIntValue(row.unitPrice.text);
      if (qty <= 0 || inputUnit <= 0) continue;
      final taxRate = row.taxRate == 8 ? 8 : 10;
      final unitPrice = row.taxIncluded
          ? (inputUnit / (1 + taxRate / 100)).round()
          : inputUnit;
      lines.add(
        _BillingLine(
          key: row.sourceKey.isEmpty ? 'edited_${nowMicros}_$i' : row.sourceKey,
          batchId: row.batchId.isEmpty ? 'edited' : row.batchId,
          batchTitle: row.batchTitle.isEmpty ? '編集明細' : row.batchTitle,
          orderDate: row.orderDate ?? DateTime.now(),
          storeId: row.storeId.isEmpty ? _selectedStoreId : row.storeId,
          storeName: row.storeName.isEmpty ? fallbackStoreName : row.storeName,
          itemType: row.type.text.trim().isEmpty ? '任意' : row.type.text.trim(),
          itemCode: row.code.text.trim(),
          itemName: name,
          qty: qty,
          unitPrice: unitPrice,
          listPrice: inputUnit,
          purchaseRate: row.purchaseRate,
          taxRate: taxRate,
        ),
      );
    }
    return lines;
  }

  Future<_ManualEditInput?> _showEditBillingDialog({
    required String title,
    required DateTime initialDate,
    required bool showDueDate,
    String initialDueText = '',
    required String initialRecipientStoreId,
    required String initialRecipientStoreName,
    required List<_BillingLine> initialLines,
  }) async {
    final dateController = TextEditingController(
      text: _dateInputText(initialDate),
    );
    final dueController = TextEditingController(text: initialDueText);
    final recipientStores = _allBillingStores();
    if (initialRecipientStoreId.isNotEmpty &&
        initialRecipientStoreName.isNotEmpty) {
      recipientStores[initialRecipientStoreId] = initialRecipientStoreName;
    }
    String selectedRecipientStoreId = initialRecipientStoreId.isNotEmpty
        ? initialRecipientStoreId
        : (recipientStores.isEmpty ? '' : recipientStores.keys.first);
    final rows = initialLines.isEmpty
        ? <_ManualBillingLineControllers>[_ManualBillingLineControllers()]
        : initialLines
              .map((line) => _ManualBillingLineControllers.fromLine(line))
              .toList();
    final result = await showDialog<_ManualEditInput>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, dialogSetState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 760,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: dateController,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: showDueDate ? '請求書の発行日' : '受領書の発行日',
                      hintText: '例：2026-07-29',
                    ),
                  ),
                  if (showDueDate) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: dueController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: '支払い期限',
                        hintText: '例：2026-08-25',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '宛先の差し替え',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRecipientStoreId.isEmpty
                        ? null
                        : selectedRecipientStoreId,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '保存済み宛先を使う店舗',
                    ),
                    items: [
                      for (final entry in recipientStores.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) => dialogSetState(() {
                      selectedRecipientStoreId =
                          value ?? selectedRecipientStoreId;
                    }),
                  ),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (_) {
                      final selectedStoreName =
                          recipientStores[selectedRecipientStoreId] ??
                          initialRecipientStoreName;
                      final selectedRecipient = _recipientForStoreWithName(
                        selectedRecipientStoreId,
                        selectedStoreName,
                      );
                      final hasSaved =
                          _storeRecipients[selectedRecipientStoreId] != null &&
                          (_storeRecipients[selectedRecipientStoreId]?.name
                                  .trim()
                                  .isNotEmpty ??
                              false);
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: hasSaved
                              ? const Color(0xFFEAF6FF)
                              : const Color(0xFFFFF8E1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: hasSaved
                                ? const Color(0xFF64B5F6)
                                : Colors.orange,
                          ),
                        ),
                        child: Text(
                          [
                            selectedRecipient.name,
                            ...selectedRecipient.pdfLines,
                            if (!hasSaved) '※この店舗の保存済み宛先がないため、店舗名のみを使います',
                          ].where((line) => line.trim().isNotEmpty).join('\n'),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  for (int i = 0; i < rows.length; i++)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '${i + 1}行目',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  tooltip: 'この行を削除',
                                  onPressed: rows.length <= 1
                                      ? null
                                      : () => dialogSetState(() {
                                          final removed = rows.removeAt(i);
                                          removed.dispose();
                                        }),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                            ),
                            TextField(
                              controller: rows[i].name,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: '商品名欄',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: rows[i].code,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: '商品コード',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: rows[i].qty,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => dialogSetState(() {}),
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: '数量',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: rows[i].unitPrice,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => dialogSetState(() {}),
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: '単価',
                              ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<int>(
                              initialValue: rows[i].taxRate,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                labelText: '税率',
                              ),
                              items: const [
                                DropdownMenuItem(value: 10, child: Text('10%')),
                                DropdownMenuItem(value: 8, child: Text('8%')),
                              ],
                              onChanged: (value) => dialogSetState(() {
                                rows[i].taxRate = value ?? 10;
                              }),
                            ),
                            const SizedBox(height: 4),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              dense: true,
                              title: const Text('税込単価'),
                              value: rows[i].taxIncluded,
                              onChanged: (value) => dialogSetState(() {
                                rows[i].taxIncluded = value == true;
                              }),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Container(
                                width: 260,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEAF6FF),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: const Color(0xFF64B5F6),
                                  ),
                                ),
                                child: Text(
                                  '金額（税抜） ￥${_yen(_manualPreviewAmount(rows[i]))}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () => dialogSetState(() {
                        rows.add(_ManualBillingLineControllers());
                      }),
                      icon: const Icon(Icons.add),
                      label: const Text('行を追加'),
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
              onPressed: () => Navigator.of(ctx).pop(
                _ManualEditInput(
                  dateText: dateController.text,
                  dueText: dueController.text,
                  recipient: _recipientForStoreWithName(
                    selectedRecipientStoreId,
                    recipientStores[selectedRecipientStoreId] ??
                        initialRecipientStoreName,
                  ),
                  rows: rows,
                ),
              ),
              child: const Text('保存してPDF再作成'),
            ),
          ],
        ),
      ),
    );
    dateController.dispose();
    dueController.dispose();
    if (result == null) {
      for (final row in rows) {
        row.dispose();
      }
    }
    return result;
  }

  DateTime _billingMonthFromData(
    Map<String, dynamic> data,
    _BillingInvoiceSummary invoice,
  ) {
    final raw = (data['billingMonth'] ?? invoice.billingMonth).toString();
    if (raw.length == 6) {
      final year = int.tryParse(raw.substring(0, 4));
      final month = int.tryParse(raw.substring(4, 6));
      if (year != null && month != null) return DateTime(year, month);
    }
    return invoice.billingMonthDate;
  }

  Future<void> _editInvoicePdf(_BillingInvoiceSummary invoice) async {
    setState(() => _saving = true);
    List<_ManualBillingLineControllers> rowsToDispose = const [];
    try {
      final doc = await AppSession.billingInvoices.doc(invoice.id).get();
      final data = doc.data();
      if (data == null) throw Exception('請求書データが見つかりません');
      final lines = _BillingLine.fromInvoiceItems(data['items']);
      final currentDate = _dateFromLocalField(
        data,
        'pdfDateLocal',
        invoice.createdAt,
      );
      final currentDue = (data['paymentDueText'] ?? invoice.paymentDueText)
          .toString();
      if (mounted) setState(() => _saving = false);
      final input = await _showEditBillingDialog(
        title: '請求書を編集: ${invoice.invoiceNo}',
        initialDate: currentDate,
        showDueDate: true,
        initialDueText: currentDue == '-' ? '' : currentDue,
        initialRecipientStoreId: invoice.storeId,
        initialRecipientStoreName: invoice.storeName,
        initialLines: lines,
      );
      if (input == null) return;
      rowsToDispose = input.rows;
      final editedLines = _billingLinesFromEditRows(
        input.rows,
        invoice.storeName,
      );
      if (editedLines.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('明細を1つ以上入力してください'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      if (mounted) setState(() => _saving = true);
      final issuedAt = _manualIssueDate(input.dateText);
      final dueDate = _manualDueDate(
        _billingMonthFromData(data, invoice),
        input.dueText,
      );
      final recipient = input.recipient;
      final assets = await _loadPdfAssets();
      final pdfBytes = await _buildBillingPdf(
        kind: _BillingPdfKind.invoice,
        assets: assets,
        no: invoice.invoiceNo,
        date: issuedAt,
        billingMonth: _billingMonthFromData(data, invoice),
        storeName: invoice.storeName,
        billingTypeText: invoice.billingItemTypesText,
        recipient: recipient,
        paymentDueTextOverride: _dateText(dueDate),
        repaymentEnabled: invoice.repaymentEnabled,
        repaymentCurrent: invoice.repaymentCurrent,
        repaymentTotal: invoice.repaymentTotal,
        repaymentMonthlyAmount: invoice.repaymentMonthlyAmount,
        lines: editedLines,
      );
      final totals = _totalsForLines(editedLines);
      await AppSession.billingInvoices.doc(invoice.id).set({
        'items': editedLines
            .map((line) => line.toInvoiceMap(line.unitPrice))
            .toList(),
        'subtotal': totals['subtotal'],
        'subtotal10': totals['subtotal10'],
        'subtotal8': totals['subtotal8'],
        'tax10': totals['tax10'],
        'tax8': totals['tax8'],
        'total': totals['total'],
        'paymentDueDateLocal': dueDate.toIso8601String(),
        'paymentDueText': _dateText(dueDate),
        'recipient': recipient.toMap(),
        'pdfDateLocal': issuedAt.toIso8601String(),
        'editedAt': FieldValue.serverTimestamp(),
        'editedAtLocal': DateTime.now().toIso8601String(),
        'editedBy': AppSession.nickname,
      }, SetOptions(merge: true));
      await AppSession.billingInvoicePdfs.doc(invoice.id).set({
        'invoiceId': invoice.id,
        'invoiceNo': invoice.invoiceNo,
        'billingMonth': invoice.billingMonth,
        'storeId': invoice.storeId,
        'storeName': invoice.storeName,
        'recipient': recipient.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtLocal': DateTime.now().toIso8601String(),
        'updatedBy': AppSession.nickname,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName': '請求書_${invoice.invoiceNo}_編集済.pdf',
      }, SetOptions(merge: true));
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: '請求書_${invoice.invoiceNo}_編集済.pdf',
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('請求書PDFを編集・上書き保存しました'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('請求書編集失敗: $e'), backgroundColor: Colors.red),
      );
    } finally {
      for (final row in rowsToDispose) {
        row.dispose();
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editReceiptPdf(_BillingInvoiceSummary invoice) async {
    if (invoice.receiptId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('編集できる受領書がまだありません'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    List<_ManualBillingLineControllers> rowsToDispose = const [];
    try {
      final doc = await AppSession.billingReceipts.doc(invoice.receiptId).get();
      final data = doc.data();
      if (data == null) throw Exception('受領書データが見つかりません');
      final lines = _BillingLine.fromInvoiceItems(data['items']);
      final currentDate = _dateFromLocalField(
        data,
        'pdfDateLocal',
        _dateFromLocalField(data, 'createdAtLocal', invoice.createdAt),
      );
      if (mounted) setState(() => _saving = false);
      final input = await _showEditBillingDialog(
        title: '受領書を編集: ${invoice.invoiceNo}',
        initialDate: currentDate,
        showDueDate: false,
        initialRecipientStoreId: invoice.storeId,
        initialRecipientStoreName: invoice.storeName,
        initialLines: lines,
      );
      if (input == null) return;
      rowsToDispose = input.rows;
      final editedLines = _billingLinesFromEditRows(
        input.rows,
        invoice.storeName,
      );
      if (editedLines.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('明細を1つ以上入力してください'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      if (mounted) setState(() => _saving = true);
      final issuedAt = _manualIssueDate(input.dateText);
      final recipient = input.recipient;
      final billingMonth = _billingMonthFromData(data, invoice);
      final assets = await _loadPdfAssets();
      final pdfBytes = await _buildBillingPdf(
        kind: _BillingPdfKind.receipt,
        assets: assets,
        no: invoice.invoiceNo,
        date: issuedAt,
        billingMonth: billingMonth,
        storeName: invoice.storeName,
        billingTypeText: invoice.billingItemTypesText,
        recipient: recipient,
        paymentDueTextOverride: null,
        repaymentEnabled: invoice.repaymentEnabled,
        repaymentCurrent: invoice.repaymentCurrent,
        repaymentTotal: invoice.repaymentTotal,
        repaymentMonthlyAmount: invoice.repaymentMonthlyAmount,
        lines: editedLines,
      );
      final totals = _totalsForLines(editedLines);
      final updateData = {
        'items': editedLines
            .map((line) => line.toInvoiceMap(line.unitPrice))
            .toList(),
        'subtotal': totals['subtotal'],
        'subtotal10': totals['subtotal10'],
        'subtotal8': totals['subtotal8'],
        'tax10': totals['tax10'],
        'tax8': totals['tax8'],
        'total': totals['total'],
        'recipient': recipient.toMap(),
        'pdfDateLocal': issuedAt.toIso8601String(),
        'editedAt': FieldValue.serverTimestamp(),
        'editedAtLocal': DateTime.now().toIso8601String(),
        'editedBy': AppSession.nickname,
      };
      await AppSession.billingReceipts
          .doc(invoice.receiptId)
          .set(updateData, SetOptions(merge: true));
      await AppSession.billingReceiptPdfs.doc(invoice.receiptId).set({
        'receiptId': invoice.receiptId,
        'invoiceId': data['invoiceId'] ?? invoice.id,
        'invoiceNo': invoice.invoiceNo,
        'billingMonth': invoice.billingMonth,
        'storeId': invoice.storeId,
        'storeName': invoice.storeName,
        'recipient': recipient.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtLocal': DateTime.now().toIso8601String(),
        'updatedBy': AppSession.nickname,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName': '受領書_${invoice.invoiceNo}_編集済.pdf',
      }, SetOptions(merge: true));
      if (invoice.billingMode == 'manual_receipt_only') {
        await AppSession.billingInvoices
            .doc(invoice.id)
            .set(updateData, SetOptions(merge: true));
      }
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: '受領書_${invoice.invoiceNo}_編集済.pdf',
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('受領書PDFを編集・上書き保存しました'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('受領書編集失敗: $e'), backgroundColor: Colors.red),
      );
    } finally {
      for (final row in rowsToDispose) {
        row.dispose();
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createManualInvoice() async {
    if (_selectedStoreId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('先に店舗を選択してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final dueController = TextEditingController();
    final rows = List.generate(8, (_) => _ManualBillingLineControllers());
    final result = await showDialog<_ManualInvoiceInput>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, dialogSetState) => AlertDialog(
          title: const Text('任意請求書を作成'),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '店舗: ${_selectedStoreName()} / 宛名: ${_recipientNameController.text}',
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: dueController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '支払い期限（未入力なら同月末日）',
                      hintText: '例：2026-08-31',
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < rows.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${i + 1}行目',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: TextField(
                                  controller: rows[i].name,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: '商品名欄',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: TextField(
                                  controller: rows[i].qty,
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => dialogSetState(() {}),
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: '数量',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 2,
                                child: TextField(
                                  controller: rows[i].unitPrice,
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => dialogSetState(() {}),
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: '単価',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<int>(
                                  initialValue: rows[i].taxRate,
                                  decoration: const InputDecoration(
                                    labelText: '税率',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 10,
                                      child: Text('10%'),
                                    ),
                                    DropdownMenuItem(
                                      value: 8,
                                      child: Text('8%'),
                                    ),
                                  ],
                                  onChanged: (value) => dialogSetState(() {
                                    rows[i].taxRate = value ?? 10;
                                  }),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  dense: true,
                                  title: const Text('税込単価'),
                                  value: rows[i].taxIncluded,
                                  onChanged: (value) => dialogSetState(() {
                                    rows[i].taxIncluded = value == true;
                                  }),
                                ),
                              ),
                            ],
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              width: 240,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEAF6FF),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF64B5F6),
                                ),
                              ),
                              child: Text(
                                '金額（税抜） ￥${_yen(_manualPreviewAmount(rows[i]))}',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
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
                Navigator.of(ctx).pop(
                  _ManualInvoiceInput(dueText: dueController.text, rows: rows),
                );
              },
              child: const Text('作成する'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;

    final dueDate = _manualDueDate(_selectedMonth, result.dueText);
    final storeName = _selectedStoreName();
    final recipient = _currentRecipientFromControllers();
    final lines = <_BillingLine>[];
    for (int i = 0; i < result.rows.length; i++) {
      final row = result.rows[i];
      final name = row.name.text.trim();
      if (name.isEmpty) continue;
      final qty = inventoryIntValue(row.qty.text);
      final inputUnit = inventoryIntValue(row.unitPrice.text);
      if (qty <= 0 || inputUnit <= 0) continue;
      final taxRate = row.taxRate == 8 ? 8 : 10;
      final unitPrice = row.taxIncluded
          ? (inputUnit / (1 + taxRate / 100)).round()
          : inputUnit;
      lines.add(
        _BillingLine(
          key: 'manual_${DateTime.now().microsecondsSinceEpoch}_$i',
          batchId: 'manual',
          batchTitle: '任意請求',
          orderDate: DateTime.now(),
          storeId: _selectedStoreId,
          storeName: storeName,
          itemType: '任意',
          itemCode: '',
          itemName: name,
          qty: qty,
          unitPrice: unitPrice,
          listPrice: inputUnit,
          taxRate: taxRate,
        ),
      );
    }
    if (lines.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('請求項目を1つ以上入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final issuedAt = DateTime.now();
      final invoiceSeq = _nextInvoiceSequence();
      final invoiceNo = _invoiceNo(invoiceSeq);
      final assets = await _loadPdfAssets();
      final pdfBytes = await _buildBillingPdf(
        kind: _BillingPdfKind.invoice,
        assets: assets,
        no: invoiceNo,
        date: issuedAt,
        billingMonth: _selectedMonth,
        storeName: storeName,
        billingTypeText: '任意',
        recipient: recipient,
        paymentDueTextOverride: _dateText(dueDate),
        repaymentEnabled: false,
        repaymentCurrent: 0,
        repaymentTotal: 0,
        repaymentMonthlyAmount: 0,
        lines: lines,
      );
      final invoiceRef = AppSession.billingInvoices.doc();
      final subtotal = lines.fold<int>(0, (total, line) => total + line.amount);
      final subtotal10 = _subtotalForRate(lines, 10);
      final subtotal8 = _subtotalForRate(lines, 8);
      final tax10 = _taxFor(subtotal10, 10);
      final tax8 = _taxFor(subtotal8, 8);
      await invoiceRef.set({
        'id': invoiceRef.id,
        'invoiceNo': invoiceNo,
        'invoiceSeq': invoiceSeq,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'status': 'issued',
        'billingMode': 'manual',
        'billingItemTypes': ['任意'],
        'billingMonth': _monthKey(_selectedMonth),
        'paymentDueDateLocal': dueDate.toIso8601String(),
        'paymentDueText': _dateText(dueDate),
        'storeId': _selectedStoreId,
        'storeName': storeName,
        'recipient': recipient.toMap(),
        'lineKeys': <String>[],
        'subtotal': subtotal,
        'subtotal10': subtotal10,
        'subtotal8': subtotal8,
        'tax10': tax10,
        'tax8': tax8,
        'total': subtotal + tax10 + tax8,
        'items': lines
            .map((line) => line.toInvoiceMap(line.unitPrice))
            .toList(),
        'hasSavedPdf': true,
      });
      await AppSession.billingInvoicePdfs.doc(invoiceRef.id).set({
        'invoiceId': invoiceRef.id,
        'invoiceNo': invoiceNo,
        'billingMonth': _monthKey(_selectedMonth),
        'storeId': _selectedStoreId,
        'storeName': storeName,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName': '任意請求書_${storeName}_$invoiceNo.pdf',
      });
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: '任意請求書_${storeName}_$invoiceNo.pdf',
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('任意請求書作成失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      for (final row in rows) {
        row.dispose();
      }
      dueController.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createManualReceiptOnly() async {
    if (_selectedStoreId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('先に店舗を選択してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final issueDateController = TextEditingController();
    final rows = List.generate(8, (_) => _ManualBillingLineControllers());
    final result = await showDialog<_ManualReceiptInput>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, dialogSetState) => AlertDialog(
          title: const Text('任意受領書を作成'),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '店舗: ${_selectedStoreName()} / 宛名: ${_recipientNameController.text}',
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: issueDateController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '発行日・受領日（未入力なら当日）',
                      hintText: '例：2026-07-29',
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < rows.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${i + 1}行目',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: TextField(
                                  controller: rows[i].name,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: '商品名欄',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: TextField(
                                  controller: rows[i].qty,
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => dialogSetState(() {}),
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: '数量',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 2,
                                child: TextField(
                                  controller: rows[i].unitPrice,
                                  keyboardType: TextInputType.number,
                                  onChanged: (_) => dialogSetState(() {}),
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    labelText: '単価',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<int>(
                                  initialValue: rows[i].taxRate,
                                  decoration: const InputDecoration(
                                    labelText: '税率',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 10,
                                      child: Text('10%'),
                                    ),
                                    DropdownMenuItem(
                                      value: 8,
                                      child: Text('8%'),
                                    ),
                                  ],
                                  onChanged: (value) => dialogSetState(() {
                                    rows[i].taxRate = value ?? 10;
                                  }),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  dense: true,
                                  title: const Text('税込単価'),
                                  value: rows[i].taxIncluded,
                                  onChanged: (value) => dialogSetState(() {
                                    rows[i].taxIncluded = value == true;
                                  }),
                                ),
                              ),
                            ],
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              width: 240,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEAF6FF),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF64B5F6),
                                ),
                              ),
                              child: Text(
                                '金額（税抜） ￥${_yen(_manualPreviewAmount(rows[i]))}',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
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
                Navigator.of(ctx).pop(
                  _ManualReceiptInput(
                    issueDateText: issueDateController.text,
                    rows: rows,
                  ),
                );
              },
              child: const Text('作成する'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;

    final storeName = _selectedStoreName();
    final recipient = _currentRecipientFromControllers();
    final issuedAt = _manualIssueDate(result.issueDateText);
    final lines = _manualLinesFromRows(result.rows, storeName);
    if (lines.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('受領項目を1つ以上入力してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final invoiceSeq = _nextInvoiceSequence();
      final receiptNo = _invoiceNo(invoiceSeq);
      final assets = await _loadPdfAssets();
      final pdfBytes = await _buildBillingPdf(
        kind: _BillingPdfKind.receipt,
        assets: assets,
        no: receiptNo,
        date: issuedAt,
        billingMonth: _selectedMonth,
        storeName: storeName,
        billingTypeText: '任意受領',
        recipient: recipient,
        paymentDueTextOverride: null,
        repaymentEnabled: false,
        repaymentCurrent: 0,
        repaymentTotal: 0,
        repaymentMonthlyAmount: 0,
        lines: lines,
      );
      final subtotal = lines.fold<int>(0, (total, line) => total + line.amount);
      final subtotal10 = _subtotalForRate(lines, 10);
      final subtotal8 = _subtotalForRate(lines, 8);
      final tax10 = _taxFor(subtotal10, 10);
      final tax8 = _taxFor(subtotal8, 8);
      final total = subtotal + tax10 + tax8;
      final receiptRef = AppSession.billingReceipts.doc();
      await receiptRef.set({
        'id': receiptRef.id,
        'invoiceId': '',
        'invoiceNo': receiptNo,
        'invoiceSeq': invoiceSeq,
        'billingMode': 'manual_receipt_only',
        'billingItemTypes': ['任意受領'],
        'billingMonth': _monthKey(_selectedMonth),
        'storeId': _selectedStoreId,
        'storeName': storeName,
        'recipient': recipient.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'status': 'issued',
        'subtotal': subtotal,
        'subtotal10': subtotal10,
        'subtotal8': subtotal8,
        'tax10': tax10,
        'tax8': tax8,
        'total': total,
        'items': lines
            .map((line) => line.toInvoiceMap(line.unitPrice))
            .toList(),
        'hasSavedPdf': true,
      });
      await AppSession.billingReceiptPdfs.doc(receiptRef.id).set({
        'receiptId': receiptRef.id,
        'invoiceId': '',
        'invoiceNo': receiptNo,
        'invoiceSeq': invoiceSeq,
        'billingMode': 'manual_receipt_only',
        'billingMonth': _monthKey(_selectedMonth),
        'storeId': _selectedStoreId,
        'storeName': storeName,
        'recipient': recipient.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName': '任意受領書_${storeName}_$receiptNo.pdf',
      });
      final summaryRef = AppSession.billingInvoices.doc();
      await summaryRef.set({
        'id': summaryRef.id,
        'invoiceNo': receiptNo,
        'invoiceSeq': invoiceSeq,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'status': 'issued',
        'billingMode': 'manual_receipt_only',
        'billingItemTypes': ['任意受領'],
        'billingMonth': _monthKey(_selectedMonth),
        'storeId': _selectedStoreId,
        'storeName': storeName,
        'recipient': recipient.toMap(),
        'lineKeys': <String>[],
        'subtotal': subtotal,
        'subtotal10': subtotal10,
        'subtotal8': subtotal8,
        'tax10': tax10,
        'tax8': tax8,
        'total': total,
        'items': lines
            .map((line) => line.toInvoiceMap(line.unitPrice))
            .toList(),
        'receiptId': receiptRef.id,
        'hasSavedPdf': true,
      });
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: '任意受領書_${storeName}_$receiptNo.pdf',
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('任意受領書作成失敗: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      for (final row in rows) {
        row.dispose();
      }
      issueDateController.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildInvoices() {
    if (_invoices.isEmpty) {
      return const Card(child: ListTile(title: Text('発行済みの請求書はまだありません')));
    }
    return Card(
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: const Icon(Icons.receipt_long),
        title: const Text('発行済み請求書・受領書'),
        subtitle: Text('${_invoices.length}件'),
        children: [
          for (final invoice in _invoices)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE6D9EA)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${invoice.invoiceNo} / ${invoice.storeName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '￥${_yen(invoice.total)}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${invoice.billingMonthLabel} / ${invoice.billingItemTypesText} / 締切 ${invoice.paymentDueText} / ${invoice.itemCount}明細',
                      softWrap: true,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (invoice.billingMode != 'manual_receipt_only') ...[
                          OutlinedButton(
                            onPressed: _saving
                                ? null
                                : () => _openInvoicePdf(invoice),
                            child: const Text('請求書'),
                          ),
                          OutlinedButton(
                            onPressed: _saving
                                ? null
                                : () => _editInvoicePdf(invoice),
                            child: const Text('請求編集'),
                          ),
                        ],
                        ElevatedButton(
                          onPressed: _saving
                              ? null
                              : () => _createReceipt(invoice),
                          child: Text(
                            invoice.receiptId.isEmpty ? '受領書作成' : '受領書',
                          ),
                        ),
                        if (invoice.receiptId.isNotEmpty)
                          OutlinedButton(
                            onPressed: _saving
                                ? null
                                : () => _editReceiptPdf(invoice),
                            child: const Text('受領編集'),
                          ),
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => _cancelInvoice(invoice),
                          child: Text(
                            invoice.billingMode == 'manual' ||
                                    invoice.billingMode == 'manual_receipt_only'
                                ? '削除'
                                : '取消',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('請求・受領管理'),
        actions: [
          IconButton(
            onPressed: _saving ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText(_error!),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    '統括管理者専用',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.deepPurple,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildStoreFilter(),
                  const SizedBox(height: 8),
                  _buildInvoices(),
                  const SizedBox(height: 8),
                  if (_visibleLines.isEmpty)
                    const Card(child: ListTile(title: Text('表示できる未請求明細がありません')))
                  else
                    for (final line in _visibleLines) _buildLineCard(line),
                ],
              ),
      ),
    );
  }
}

enum _BillingPdfKind { invoice, receipt }

class _BillingPdfAssets {
  const _BillingPdfAssets({
    required this.logo,
    required this.stamp,
    required this.mascotInvoice,
    required this.mascotReceipt,
    required this.font,
    required this.boldFont,
  });

  final pw.MemoryImage logo;
  final pw.MemoryImage stamp;
  final pw.MemoryImage mascotInvoice;
  final pw.MemoryImage mascotReceipt;
  final pw.Font font;
  final pw.Font boldFont;
}

class _BillingLine {
  const _BillingLine({
    required this.key,
    required this.batchId,
    required this.batchTitle,
    required this.orderDate,
    required this.storeId,
    required this.storeName,
    required this.itemType,
    required this.itemCode,
    required this.itemName,
    required this.qty,
    this.unitPrice = 0,
    this.listPrice = 0,
    this.purchaseRate = 0,
    this.taxRate = 10,
    this.billed = false,
  });

  final String key;
  final String batchId;
  final String batchTitle;
  final DateTime orderDate;
  final String storeId;
  final String storeName;
  final String itemType;
  final String itemCode;
  final String itemName;
  final int qty;
  final int unitPrice;
  final int listPrice;
  final int purchaseRate;
  final int taxRate;
  final bool billed;

  int get amount => qty * unitPrice;

  _BillingLine copyWith({
    int? unitPrice,
    int? listPrice,
    int? purchaseRate,
    int? taxRate,
    bool? billed,
  }) {
    return _BillingLine(
      key: key,
      batchId: batchId,
      batchTitle: batchTitle,
      orderDate: orderDate,
      storeId: storeId,
      storeName: storeName,
      itemType: itemType,
      itemCode: itemCode,
      itemName: itemName,
      qty: qty,
      unitPrice: unitPrice ?? this.unitPrice,
      listPrice: listPrice ?? this.listPrice,
      purchaseRate: purchaseRate ?? this.purchaseRate,
      taxRate: taxRate ?? this.taxRate,
      billed: billed ?? this.billed,
    );
  }

  Map<String, dynamic> toInvoiceMap(int price) {
    return {
      'lineKey': key,
      'batchId': batchId,
      'batchTitle': batchTitle,
      'orderDateLocal': orderDate.toIso8601String(),
      'storeId': storeId,
      'storeName': storeName,
      'itemType': itemType,
      'itemCode': itemCode,
      'itemName': itemName,
      'qty': qty,
      'unitPrice': price,
      'listPrice': listPrice,
      'purchaseRate': purchaseRate,
      'taxRate': taxRate,
      'amount': qty * price,
    };
  }

  static List<_BillingLine> fromInvoiceItems(dynamic raw) {
    if (raw is! List) return <_BillingLine>[];
    return raw.whereType<Map>().map((item) {
      final map = Map<String, dynamic>.from(
        item.map((k, v) => MapEntry(k.toString(), v)),
      );
      final price = inventoryIntValue(map['unitPrice']);
      final qty = inventoryIntValue(map['qty']);
      return _BillingLine(
        key: (map['lineKey'] ?? '').toString(),
        batchId: (map['batchId'] ?? '').toString(),
        batchTitle: (map['batchTitle'] ?? '').toString(),
        orderDate:
            DateTime.tryParse((map['orderDateLocal'] ?? '').toString()) ??
            DateTime.now(),
        storeId: (map['storeId'] ?? '').toString(),
        storeName: (map['storeName'] ?? '').toString(),
        itemType: (map['itemType'] ?? '').toString(),
        itemCode: (map['itemCode'] ?? '').toString(),
        itemName: (map['itemName'] ?? '').toString(),
        qty: qty,
        unitPrice: price,
        listPrice: inventoryIntValue(map['listPrice']),
        purchaseRate: inventoryIntValue(map['purchaseRate']),
        taxRate: inventoryIntValue(map['taxRate']) == 8 ? 8 : 10,
      );
    }).toList();
  }
}

class _BillingPrice {
  const _BillingPrice({
    required this.itemType,
    required this.itemCode,
    required this.itemName,
    required this.unitPrice,
    required this.purchaseRate,
    required this.taxRate,
  });

  final String itemType;
  final String itemCode;
  final String itemName;
  final int unitPrice;
  final int purchaseRate;
  final int taxRate;

  factory _BillingPrice.fromLine(_BillingLine line) => _BillingPrice(
    itemType: line.itemType,
    itemCode: line.itemCode,
    itemName: line.itemName,
    unitPrice: line.unitPrice,
    purchaseRate: line.purchaseRate,
    taxRate: line.taxRate,
  );

  factory _BillingPrice.fromMap(Map<String, dynamic> map) => _BillingPrice(
    itemType: (map['itemType'] ?? '').toString(),
    itemCode: (map['itemCode'] ?? '').toString(),
    itemName: (map['itemName'] ?? '').toString(),
    unitPrice: inventoryIntValue(map['unitPrice']),
    purchaseRate: inventoryIntValue(map['purchaseRate']),
    taxRate: inventoryIntValue(map['taxRate']) == 8 ? 8 : 10,
  );

  _BillingPrice copyWith({int? unitPrice, int? purchaseRate, int? taxRate}) {
    return _BillingPrice(
      itemType: itemType,
      itemCode: itemCode,
      itemName: itemName,
      unitPrice: unitPrice ?? this.unitPrice,
      purchaseRate: purchaseRate ?? this.purchaseRate,
      taxRate: taxRate ?? this.taxRate,
    );
  }

  Map<String, dynamic> toMap() => {
    'itemType': itemType,
    'itemCode': itemCode,
    'itemName': itemName,
    'unitPrice': unitPrice,
    'purchaseRate': purchaseRate,
    'taxRate': taxRate,
  };
}

class _BillingRecipient {
  const _BillingRecipient({
    required this.name,
    required this.postal,
    required this.address1,
    required this.address2,
  });

  final String name;
  final String postal;
  final String address1;
  final String address2;

  List<String> get pdfLines => [
    if (postal.trim().isNotEmpty) postal.trim(),
    if (address1.trim().isNotEmpty) address1.trim(),
    if (address2.trim().isNotEmpty) address2.trim(),
  ];

  factory _BillingRecipient.fromMap(Map<String, dynamic> map) =>
      _BillingRecipient(
        name: (map['name'] ?? '').toString(),
        postal: (map['postal'] ?? '').toString(),
        address1: (map['address1'] ?? '').toString(),
        address2: (map['address2'] ?? '').toString(),
      );

  Map<String, dynamic> toMap() => {
    'name': name,
    'postal': postal,
    'address1': address1,
    'address2': address2,
  };
}

class _ManualBillingLineControllers {
  _ManualBillingLineControllers();

  _ManualBillingLineControllers.fromLine(_BillingLine line) {
    sourceKey = line.key;
    batchId = line.batchId;
    batchTitle = line.batchTitle;
    orderDate = line.orderDate;
    storeId = line.storeId;
    storeName = line.storeName;
    type.text = line.itemType.isEmpty ? '任意' : line.itemType;
    code.text = line.itemCode;
    name.text = line.itemName;
    qty.text = line.qty.toString();
    unitPrice.text = line.unitPrice.toString();
    purchaseRate = line.purchaseRate;
    taxRate = line.taxRate == 8 ? 8 : 10;
  }

  final TextEditingController type = TextEditingController(text: '任意');
  final TextEditingController code = TextEditingController();
  final TextEditingController name = TextEditingController();
  final TextEditingController qty = TextEditingController(text: '1');
  final TextEditingController unitPrice = TextEditingController();
  String sourceKey = '';
  String batchId = '';
  String batchTitle = '';
  DateTime? orderDate;
  String storeId = '';
  String storeName = '';
  int purchaseRate = 0;
  int taxRate = 10;
  bool taxIncluded = false;

  void dispose() {
    type.dispose();
    code.dispose();
    name.dispose();
    qty.dispose();
    unitPrice.dispose();
  }
}

class _ManualEditInput {
  const _ManualEditInput({
    required this.dateText,
    required this.dueText,
    required this.recipient,
    required this.rows,
  });

  final String dateText;
  final String dueText;
  final _BillingRecipient recipient;
  final List<_ManualBillingLineControllers> rows;
}

class _ManualInvoiceInput {
  const _ManualInvoiceInput({required this.dueText, required this.rows});

  final String dueText;
  final List<_ManualBillingLineControllers> rows;
}

class _ManualReceiptInput {
  const _ManualReceiptInput({required this.issueDateText, required this.rows});

  final String issueDateText;
  final List<_ManualBillingLineControllers> rows;
}

class _BillingInvoiceSummary {
  const _BillingInvoiceSummary({
    required this.id,
    required this.invoiceNo,
    required this.invoiceSeq,
    required this.createdAt,
    required this.billingMonth,
    required this.storeId,
    required this.storeName,
    required this.monthStoreKey,
    required this.paymentDueText,
    required this.billingItemTypes,
    required this.billingMode,
    required this.subtotal,
    required this.tax10,
    required this.tax8,
    required this.total,
    required this.repaymentEnabled,
    required this.repaymentCurrent,
    required this.repaymentTotal,
    required this.repaymentMonthlyAmount,
    required this.itemCount,
    required this.receiptId,
  });

  final String id;
  final String invoiceNo;
  final int invoiceSeq;
  final DateTime createdAt;
  final String billingMonth;
  final String storeId;
  final String storeName;
  final String monthStoreKey;
  final String paymentDueText;
  final List<String> billingItemTypes;
  final String billingMode;
  final int subtotal;
  final int tax10;
  final int tax8;
  final int total;
  final bool repaymentEnabled;
  final int repaymentCurrent;
  final int repaymentTotal;
  final int repaymentMonthlyAmount;
  final int itemCount;
  final String receiptId;

  DateTime get billingMonthDate {
    if (billingMonth.length == 6) {
      final year = int.tryParse(billingMonth.substring(0, 4));
      final month = int.tryParse(billingMonth.substring(4, 6));
      if (year != null && month != null) return DateTime(year, month);
    }
    return DateTime(createdAt.year, createdAt.month);
  }

  String get billingMonthLabel =>
      '${billingMonthDate.year}年${billingMonthDate.month}月分';

  String get billingItemTypesText =>
      billingItemTypes.isEmpty ? '商品・テスター・備品' : billingItemTypes.join('・');

  factory _BillingInvoiceSummary.fromDoc(String id, Map<String, dynamic> data) {
    final ts = data['createdAt'];
    final createdAt = ts is Timestamp
        ? ts.toDate()
        : DateTime.tryParse((data['createdAtLocal'] ?? '').toString()) ??
              DateTime.now();
    final rawItems = data['items'];
    final invoiceNo = (data['invoiceNo'] ?? id).toString();
    final parsedSeq = RegExp(r'AQU-(\d+)$').firstMatch(invoiceNo);
    final invoiceSeq = inventoryIntValue(data['invoiceSeq']) > 0
        ? inventoryIntValue(data['invoiceSeq'])
        : (parsedSeq == null ? 0 : int.tryParse(parsedSeq.group(1)!) ?? 0);
    final billingMonth = (data['billingMonth'] ?? '').toString();
    final storeId = (data['storeId'] ?? '').toString();
    final storeName = (data['storeName'] ?? '').toString();
    final monthStoreKey = (data['monthStoreKey'] ?? '').toString();
    final dueText = (data['paymentDueText'] ?? '').toString();
    final rawTypes = data['billingItemTypes'];
    final billingItemTypes = rawTypes is List
        ? rawTypes.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];
    return _BillingInvoiceSummary(
      id: id,
      invoiceNo: invoiceNo,
      invoiceSeq: invoiceSeq,
      createdAt: createdAt,
      billingMonth: billingMonth,
      storeId: storeId,
      storeName: storeName.isEmpty ? '店舗未設定' : storeName,
      monthStoreKey: monthStoreKey,
      paymentDueText: dueText.isEmpty ? '-' : dueText,
      billingItemTypes: billingItemTypes,
      billingMode: (data['billingMode'] ?? '').toString(),
      subtotal: inventoryIntValue(data['subtotal']),
      tax10: inventoryIntValue(data['tax10']),
      tax8: inventoryIntValue(data['tax8']),
      total: inventoryIntValue(data['total']),
      repaymentEnabled: data['repaymentEnabled'] == true,
      repaymentCurrent: inventoryIntValue(data['repaymentCurrent']),
      repaymentTotal: inventoryIntValue(data['repaymentTotal']),
      repaymentMonthlyAmount: inventoryIntValue(data['repaymentMonthlyAmount']),
      itemCount: rawItems is List ? rawItems.length : 0,
      receiptId: (data['receiptId'] ?? '').toString(),
    );
  }
}
