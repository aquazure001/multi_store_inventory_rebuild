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
  final List<_BillingLine> _lines = [];
  final List<_BillingInvoiceSummary> _invoices = [];
  final Set<String> _billedKeys = <String>{};
  final Set<String> _issuedMonthStoreKeys = <String>{};
  final Map<String, TextEditingController> _priceControllers = {};

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
        _priceControllers.putIfAbsent(line.key, () {
          final controller = TextEditingController();
          controller.addListener(() {
            if (mounted) setState(() {});
          });
          return controller;
        });
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
        _lines
          ..clear()
          ..addAll(lines);
        if (_selectedStoreId.isEmpty) {
          final stores = _storesForMonth(_selectedMonth);
          if (stores.isNotEmpty) _selectedStoreId = stores.keys.first;
        }
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

  String _selectedStoreName() {
    return _storesForMonth(_selectedMonth)[_selectedStoreId] ?? '';
  }

  List<_BillingLine> _withPrices(List<_BillingLine> lines) {
    return lines
        .map((line) => line.copyWith(unitPrice: _priceFor(line)))
        .toList();
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

  List<_BillingLine> get _visibleLines {
    return _lines.where((line) {
      if (!_showBilled && line.billed) return false;
      if (!_inSelectedMonth(line)) return false;
      if (_selectedStoreId.isNotEmpty && line.storeId != _selectedStoreId) {
        return false;
      }
      return true;
    }).toList();
  }

  List<_BillingLine> get _invoiceTargetLines => _visibleLines
      .where((line) => !line.billed && line.storeId == _selectedStoreId)
      .toList();

  int get _targetSubtotal {
    var total = 0;
    for (final line in _invoiceTargetLines) {
      total += line.qty * _priceFor(line);
    }
    return total;
  }

  int get _targetTax => (_targetSubtotal * 0.1).round();
  int get _targetTotal => _targetSubtotal + _targetTax;

  bool get _alreadyIssuedForSelectedMonthStore =>
      _selectedStoreId.isNotEmpty &&
      _issuedMonthStoreKeys.contains(
        _monthStoreKey(_selectedMonth, _selectedStoreId),
      );

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

    final lines = _invoiceTargetLines;
    if (lines.isEmpty) {
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
    final periodText = _periodText(_selectedMonth);
    final dueText = _paymentDueTextForMonth(_selectedMonth);
    final pricedLines = _withPrices(lines);
    final total = pricedLines.fold<int>(
      0,
      (total, line) => total + line.amount,
    );
    final totalWithTax = total + (total * 0.1).round();

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
    List<_BillingLine> lines,
  ) {
    final subtotal = lines.fold<int>(0, (total, line) => total + line.amount);
    final tax = (subtotal * 0.1).round();
    final dueDate = _paymentDueDateForMonth(billingMonth);
    return {
      'id': id,
      'invoiceNo': invoiceNo,
      'invoiceSeq': invoiceSeq,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtLocal': issuedAt.toIso8601String(),
      'createdBy': AppSession.nickname,
      'status': 'issued',
      'billingMode': 'monthly_store',
      'billingMonth': _monthKey(billingMonth),
      'billingYear': billingMonth.year,
      'billingMonthNumber': billingMonth.month,
      'billingPeriodStartLocal': _monthStart(billingMonth).toIso8601String(),
      'billingPeriodEndLocal': _monthEnd(billingMonth).toIso8601String(),
      'paymentDueDateLocal': dueDate.toIso8601String(),
      'paymentDueText': _dateText(dueDate),
      'storeId': storeId,
      'storeName': storeName,
      'monthStoreKey': _monthStoreKey(billingMonth, storeId),
      'lineKeys': lines.map((line) => line.key).toList(),
      'subtotal': subtotal,
      'tax10': tax,
      'tax8': 0,
      'total': subtotal + tax,
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
      final issuedAt = DateTime.now();
      final assets = await _loadPdfAssets();
      final pdfBytes = await _buildBillingPdf(
        kind: _BillingPdfKind.receipt,
        assets: assets,
        no: invoice.invoiceNo,
        date: issuedAt,
        billingMonth: invoice.billingMonthDate,
        storeName: invoice.storeName,
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
        'monthStoreKey': invoice.monthStoreKey,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtLocal': issuedAt.toIso8601String(),
        'createdBy': AppSession.nickname,
        'status': 'issued',
        'subtotal': invoice.subtotal,
        'tax10': invoice.tax10,
        'tax8': 0,
        'total': invoice.total,
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
    required List<_BillingLine> lines,
  }) async {
    final pdf = pw.Document();
    final isInvoice = kind == _BillingPdfKind.invoice;
    final subtotal = lines.fold<int>(
      0,
      (total, line) => total + line.qty * line.unitPrice,
    );
    final tax = (subtotal * 0.1).round();
    final total = subtotal + tax;
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
                          title: '金只 歩 様',
                          lines: const ['〒278-0022', '千葉県野田市山崎2267-50'],
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
                              ? _paymentDueTextForMonth(billingMonth)
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
                      '対象店舗：$storeName　対象期間：${_periodText(billingMonth)}',
                      style: pw.TextStyle(font: assets.boldFont, fontSize: 9.5),
                    ),
                  ),
                  pw.SizedBox(height: 6),
                  _billingPdfTable(lines, assets.boldFont),
                  pw.SizedBox(height: 8),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.end,
                    children: [
                      _billingTotalsBox(subtotal, tax, total, assets.boldFont),
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
        0: pw.FlexColumnWidth(2.7),
        1: pw.FlexColumnWidth(.8),
        2: pw.FlexColumnWidth(.8),
        3: pw.FlexColumnWidth(1.1),
        4: pw.FlexColumnWidth(1.8),
      },
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F9C5C8')),
          children: ['商品名', '数量', '単位', '単価', '金額']
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
    int tax,
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
          row('消費税(10%)', tax),
          row('消費税(8%)', 0),
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
              onChanged: (value) =>
                  setState(() => _selectedStoreId = value ?? ''),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _showBilled,
              title: const Text('請求済みも表示する'),
              onChanged: (value) => setState(() => _showBilled = value),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '対象: ${_selectedStoreName().isEmpty ? '店舗未選択' : _selectedStoreName()} / ${_periodText(_selectedMonth)}\n'
                '締切: ${_paymentDueTextForMonth(_selectedMonth)} / 未請求 ${_invoiceTargetLines.length}件 / 合計 ￥${_yen(_targetTotal)}',
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
                  _alreadyIssuedForSelectedMonthStore
                      ? 'この月・店舗は請求書作成済み'
                      : 'この月・店舗で請求書PDF作成',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLineCard(_BillingLine line) {
    final price = _priceFor(line);
    final amount = line.qty * price;
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
                  width: 130,
                  child: TextField(
                    controller: _priceControllers[line.key],
                    enabled:
                        !line.billed && !_alreadyIssuedForSelectedMonthStore,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '単価',
                      prefixText: '￥',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '金額 ￥${_yen(amount)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
            ListTile(
              title: Text(
                '${invoice.invoiceNo} / ${invoice.storeName} / ￥${_yen(invoice.total)}',
              ),
              subtitle: Text(
                '${invoice.billingMonthLabel} / 締切 ${invoice.paymentDueText} / ${invoice.itemCount}明細',
              ),
              trailing: Wrap(
                spacing: 6,
                children: [
                  OutlinedButton(
                    onPressed: _saving ? null : () => _openInvoicePdf(invoice),
                    child: const Text('請求書'),
                  ),
                  ElevatedButton(
                    onPressed: _saving ? null : () => _createReceipt(invoice),
                    child: Text(invoice.receiptId.isEmpty ? '受領書作成' : '受領書'),
                  ),
                ],
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
  final bool billed;

  int get amount => qty * unitPrice;

  _BillingLine copyWith({int? unitPrice, bool? billed}) {
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
      );
    }).toList();
  }
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
    required this.subtotal,
    required this.tax10,
    required this.total,
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
  final int subtotal;
  final int tax10;
  final int total;
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
      subtotal: inventoryIntValue(data['subtotal']),
      tax10: inventoryIntValue(data['tax10']),
      total: inventoryIntValue(data['total']),
      itemCount: rawItems is List ? rawItems.length : 0,
      receiptId: (data['receiptId'] ?? '').toString(),
    );
  }
}
