part of '../main.dart';

class PosPage extends StatefulWidget {
  const PosPage({super.key});

  @override
  State<PosPage> createState() => _PosPageState();
}

class _PosPageState extends State<PosPage> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _qtyController = TextEditingController(text: '1');
  final TextEditingController _receivedController = TextEditingController();
  final TextEditingController _manualNameController = TextEditingController(
    text: '金額手入力',
  );
  final TextEditingController _manualAmountController = TextEditingController();
  final TextEditingController _manualQtyController = TextEditingController(
    text: '1',
  );
  final TextEditingController _invoiceNumberController =
      TextEditingController();

  List<LegacyStore> _stores = [];
  List<LegacyItem> _products = [];
  Map<String, _PosPrice> _prices = {};
  LegacyStore? _selectedStore;
  LegacyItem? _selectedProduct;
  String? _message;
  bool _loading = true;
  bool _saving = false;
  bool _manualMode = false;
  int _manualTaxRate = 10;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _qtyController.dispose();
    _receivedController.dispose();
    _manualNameController.dispose();
    _manualAmountController.dispose();
    _manualQtyController.dispose();
    _invoiceNumberController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final results = await Future.wait([
        AppSession.doc('stores').get(),
        AppSession.doc('products').get(),
        AppSession.doc('billing_prices').get(),
        AppSession.doc('pos_settings').get(),
      ]);
      final storesDoc = results[0];
      final productsDoc = results[1];
      final priceDoc = results[2];
      final settingsDoc = results[3];

      final stores = _parseStores(storesDoc.data() ?? <String, dynamic>{});
      final products = _parseItemsFromDoc(
        productsDoc,
      ).where((item) => !item.discontinued).toList();
      final prices = <String, _PosPrice>{};
      final rawEntries = priceDoc.data()?['entries'];
      if (rawEntries is Map) {
        for (final entry in rawEntries.entries) {
          final value = entry.value;
          if (value is! Map) continue;
          final map = Map<String, dynamic>.from(
            value.map((k, v) => MapEntry(k.toString(), v)),
          );
          final price = _PosPrice.fromMap(map);
          if (price.itemType == '商品') {
            final key = _priceKey(price.itemCode, price.itemName);
            prices[key] = price;
          }
        }
      }

      final settings = settingsDoc.data() ?? <String, dynamic>{};
      setState(() {
        _stores = stores;
        _products = products;
        _prices = prices;
        _selectedStore = stores.isNotEmpty ? stores.first : null;
        _invoiceNumberController.text = (settings['invoiceNumber'] ?? '')
            .toString();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _message = '読み込みエラー: $e';
        _loading = false;
      });
    }
  }

  static String _priceKey(String code, String name) {
    final codeOrName = code.trim().isEmpty ? name.trim() : code.trim();
    return '商品__$codeOrName';
  }

  _PosPrice? get _selectedPrice {
    final item = _selectedProduct;
    if (item == null) return null;
    if (item.taxExcludedPrice > 0) {
      return _PosPrice(
        itemType: '商品',
        itemCode: item.code,
        itemName: item.name,
        unitPrice: item.taxExcludedPrice,
        taxRate: item.reducedTax ? 8 : 10,
      );
    }
    return _prices[_priceKey(item.code, item.name)];
  }

  int get _qty {
    final parsed = int.tryParse(_qtyController.text.trim()) ?? 1;
    return parsed <= 0 ? 1 : parsed;
  }

  int get _taxRate => _selectedPrice?.taxRate ?? 10;

  int get _taxExcludedUnitPrice => _selectedPrice?.unitPrice ?? 0;

  int get _taxIncludedUnitPrice =>
      (_taxExcludedUnitPrice * (100 + _taxRate) / 100).round();

  int get _total => _taxIncludedUnitPrice * _qty;

  int get _received =>
      int.tryParse(_receivedController.text.replaceAll(',', '').trim()) ?? 0;

  int get _change => _received - _total;

  int get _manualQty {
    final parsed = int.tryParse(_manualQtyController.text.trim()) ?? 1;
    return parsed <= 0 ? 1 : parsed;
  }

  int get _manualTaxIncludedUnitPrice =>
      int.tryParse(_manualAmountController.text.replaceAll(',', '').trim()) ??
      0;

  int get _manualTaxExcludedUnitPrice =>
      (_manualTaxIncludedUnitPrice * 100 / (100 + _manualTaxRate)).round();

  int get _manualTotal => _manualTaxIncludedUnitPrice * _manualQty;

  int get _manualReceived =>
      int.tryParse(_receivedController.text.replaceAll(',', '').trim()) ?? 0;

  int get _manualChange => _manualReceived - _manualTotal;

  void _findProduct() {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    final matches = _products.where((item) => item.code == code).toList();
    setState(() {
      if (matches.isEmpty) {
        _selectedProduct = null;
        _message = '商品コード $code が見つかりません';
      } else {
        _selectedProduct = matches.first;
        _manualMode = false;
        _message = _selectedPrice == null ? '商品マスタに税抜価格が未登録です' : null;
      }
    });
  }

  Future<void> _saveInvoiceNumber() async {
    try {
      await AppSession.doc('pos_settings').set({
        'invoiceNumber': _invoiceNumberController.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtLocal': DateTime.now().toIso8601String(),
        'updatedBy': AppSession.nickname,
        'updatedByEmail': AppSession.email,
      }, SetOptions(merge: true));
      _showSnack('インボイス事業者番号を保存しました', Colors.green);
    } catch (e) {
      _showSnack('保存失敗: $e', Colors.red);
    }
  }

  void _openManualInput() {
    setState(() {
      _manualMode = true;
      _selectedProduct = null;
      _codeController.clear();
      _message = null;
      if (_manualNameController.text.trim().isEmpty) {
        _manualNameController.text = '金額手入力';
      }
    });
  }

  Future<void> _confirmManualSale() async {
    final store = _selectedStore;
    final itemName = _manualNameController.text.trim().isEmpty
        ? '金額手入力'
        : _manualNameController.text.trim();
    if (store == null) {
      _showSnack('店舗を選択してください', Colors.orange);
      return;
    }
    if (_manualTaxIncludedUnitPrice <= 0) {
      _showSnack('税込金額を入力してください', Colors.orange);
      return;
    }
    if (_manualReceived < _manualTotal) {
      _showSnack('預かり金が不足しています', Colors.orange);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手入力会計を確定しますか？'),
        content: Text(
          '${store.name}\n$itemName\n数量 $_manualQty 個\n合計 ￥${_yen(_manualTotal)}\n\n※商品在庫は変更しません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('確定する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      final saleRef = AppSession.posSales.doc();
      final now = DateTime.now();
      await saleRef.set({
        'id': saleRef.id,
        'status': 'completed',
        'saleType': 'manual',
        'soldAt': FieldValue.serverTimestamp(),
        'soldAtLocal': now.toIso8601String(),
        'soldBy': AppSession.nickname,
        'uid': AppSession.uid,
        'storeId': store.id,
        'storeName': store.name,
        'itemType': '手入力',
        'itemId': '',
        'itemCode': '',
        'itemName': itemName,
        'qty': _manualQty,
        'taxRate': _manualTaxRate,
        'reducedTax': _manualTaxRate == 8,
        'taxExcludedUnitPrice': _manualTaxExcludedUnitPrice,
        'taxIncludedUnitPrice': _manualTaxIncludedUnitPrice,
        'total': _manualTotal,
        'received': _manualReceived,
        'change': _manualChange,
        'invoiceNumber': _invoiceNumberController.text.trim(),
        'stockUpdated': false,
      });

      final pdfBytes = await _createReceiptPdf(
        saleId: saleRef.id,
        soldAt: now,
        storeName: store.name,
        itemName: itemName,
        itemCode: '',
        qty: _manualQty,
        taxRate: _manualTaxRate,
        taxExcludedUnitPrice: _manualTaxExcludedUnitPrice,
        taxIncludedUnitPrice: _manualTaxIncludedUnitPrice,
        total: _manualTotal,
        received: _manualReceived,
        change: _manualChange,
        invoiceNumber: _invoiceNumberController.text.trim(),
        stockText: '在庫変更なし',
      );
      await AppSession.posReceiptPdfs.doc(saleRef.id).set({
        'saleId': saleRef.id,
        'soldAtLocal': now.toIso8601String(),
        'storeId': store.id,
        'storeName': store.name,
        'itemCode': '',
        'itemName': itemName,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName': 'レシート_${saleRef.id}.pdf',
      });
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: 'レシート_${saleRef.id}.pdf',
      );

      setState(() {
        _manualAmountController.clear();
        _manualQtyController.text = '1';
        _receivedController.clear();
        _message = '手入力会計を確定しました。';
      });
    } catch (e) {
      _showSnack('会計確定失敗: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmSale() async {
    final store = _selectedStore;
    final item = _selectedProduct;
    final price = _selectedPrice;
    if (store == null) {
      _showSnack('店舗を選択してください', Colors.orange);
      return;
    }
    if (item == null) {
      _showSnack('商品コードを入力してください', Colors.orange);
      return;
    }
    if (price == null || price.unitPrice <= 0) {
      _showSnack('商品マスタに税抜価格を登録してください', Colors.orange);
      return;
    }
    if (_received < _total) {
      _showSnack('預かり金が不足しています', Colors.orange);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('会計を確定しますか？'),
        content: Text(
          '${store.name}\n${item.name}\n数量 $_qty 個\n合計 ￥${_yen(_total)}\n\n確定すると在庫を $_qty 個減らします。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('確定する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      final saleRef = AppSession.posSales.doc();
      final now = DateTime.now();
      int oldStock = 0;
      int newStock = 0;

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final stocksSnap = await tx.get(AppSession.stocksDoc);
        final stocksData = stocksSnap.data() ?? <String, dynamic>{};
        final storeStocksRaw = stocksData[store.id];
        final storeStocks = storeStocksRaw is Map
            ? Map<String, dynamic>.from(
                storeStocksRaw.map((k, v) => MapEntry(k.toString(), v)),
              )
            : <String, dynamic>{};
        oldStock = inventoryIntValue(storeStocks[item.id]);
        if (oldStock < _qty) {
          throw Exception('在庫不足です（現在 $oldStock 個）');
        }
        newStock = oldStock - _qty;
        tx.set(AppSession.stocksDoc, {
          store.id: {item.id: newStock},
        }, SetOptions(merge: true));
        tx.set(saleRef, {
          'id': saleRef.id,
          'status': 'completed',
          'saleType': 'product',
          'soldAt': FieldValue.serverTimestamp(),
          'soldAtLocal': now.toIso8601String(),
          'soldBy': AppSession.nickname,
          'uid': AppSession.uid,
          'storeId': store.id,
          'storeName': store.name,
          'itemType': '商品',
          'itemId': item.id,
          'itemCode': item.code,
          'itemName': item.name,
          'qty': _qty,
          'taxRate': _taxRate,
          'reducedTax': _taxRate == 8,
          'taxExcludedUnitPrice': _taxExcludedUnitPrice,
          'taxIncludedUnitPrice': _taxIncludedUnitPrice,
          'total': _total,
          'received': _received,
          'change': _change,
          'invoiceNumber': _invoiceNumberController.text.trim(),
          'stockUpdated': true,
          'oldStock': oldStock,
          'newStock': newStock,
        });
      });

      final pdfBytes = await _createReceiptPdf(
        saleId: saleRef.id,
        soldAt: now,
        storeName: store.name,
        itemName: item.name,
        itemCode: item.code,
        qty: _qty,
        taxRate: _taxRate,
        taxExcludedUnitPrice: _taxExcludedUnitPrice,
        taxIncludedUnitPrice: _taxIncludedUnitPrice,
        total: _total,
        received: _received,
        change: _change,
        invoiceNumber: _invoiceNumberController.text.trim(),
        stockText: '在庫更新：$oldStock → $newStock',
      );
      await AppSession.posReceiptPdfs.doc(saleRef.id).set({
        'saleId': saleRef.id,
        'soldAtLocal': now.toIso8601String(),
        'storeId': store.id,
        'storeName': store.name,
        'itemCode': item.code,
        'itemName': item.name,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName': 'レシート_${saleRef.id}.pdf',
      });
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: 'レシート_${saleRef.id}.pdf',
      );

      setState(() {
        _codeController.clear();
        _qtyController.text = '1';
        _receivedController.clear();
        _selectedProduct = null;
        _message = '会計を確定しました。在庫を $oldStock → $newStock に更新しました。';
      });
    } catch (e) {
      _showSnack('会計確定失敗: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<Uint8List> _createReceiptPdf({
    required String saleId,
    required DateTime soldAt,
    required String storeName,
    required String itemName,
    required String itemCode,
    required int qty,
    required int taxRate,
    required int taxExcludedUnitPrice,
    required int taxIncludedUnitPrice,
    required int total,
    required int received,
    required int change,
    required String invoiceNumber,
    required String stockText,
  }) async {
    final font = await PdfGoogleFonts.notoSansJPRegular();
    final bold = await PdfGoogleFonts.notoSansJPBold();
    final logoData = await rootBundle.load('assets/billing/restart_logo.png');
    final logo = pw.MemoryImage(logoData.buffer.asUint8List());
    final doc = pw.Document();
    final taxExcludedTotal = taxExcludedUnitPrice * qty;
    final tax = total - taxExcludedTotal;

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('領収書', style: pw.TextStyle(font: bold, fontSize: 28)),
                pw.Image(logo, width: 120),
              ],
            ),
            pw.SizedBox(height: 18),
            pw.Text(
              '発行日：${_dateText(soldAt)}',
              style: pw.TextStyle(font: font),
            ),
            pw.Text('店舗：$storeName', style: pw.TextStyle(font: font)),
            if (invoiceNumber.trim().isNotEmpty)
              pw.Text(
                '登録番号：${invoiceNumber.trim()}',
                style: pw.TextStyle(font: font),
              ),
            pw.Text(
              'No：$saleId',
              style: pw.TextStyle(font: font, fontSize: 10),
            ),
            pw.SizedBox(height: 18),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.blueGrey, width: 1),
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '￥${_yen(total)}',
                    style: pw.TextStyle(font: bold, fontSize: 26),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text('上記正に領収いたしました。', style: pw.TextStyle(font: font)),
                ],
              ),
            ),
            pw.SizedBox(height: 18),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
              columnWidths: const {
                0: pw.FlexColumnWidth(3),
                1: pw.FlexColumnWidth(1),
                2: pw.FlexColumnWidth(1.4),
                3: pw.FlexColumnWidth(1.4),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.blue50),
                  children: [
                    _pdfText('商品名', bold),
                    _pdfText('数量', bold),
                    _pdfText('税込単価', bold),
                    _pdfText('金額', bold),
                  ],
                ),
                pw.TableRow(
                  children: [
                    _pdfText(
                      itemCode.isEmpty ? itemName : '$itemName\nコード:$itemCode',
                      font,
                    ),
                    _pdfText('$qty', font),
                    _pdfText('￥${_yen(taxIncludedUnitPrice)}', font),
                    _pdfText('￥${_yen(total)}', font),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 12),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    '税抜単価：￥${_yen(taxExcludedUnitPrice)}',
                    style: pw.TextStyle(font: font),
                  ),
                  pw.Text(
                    '税抜合計：￥${_yen(taxExcludedTotal)}',
                    style: pw.TextStyle(font: font),
                  ),
                  pw.Text(
                    '消費税（$taxRate%）：￥${_yen(tax)}',
                    style: pw.TextStyle(font: font),
                  ),
                  pw.Text(
                    '税込合計：￥${_yen(total)}',
                    style: pw.TextStyle(font: bold),
                  ),
                  pw.SizedBox(height: 6),
                  pw.Text(
                    '預かり金：￥${_yen(received)}',
                    style: pw.TextStyle(font: font),
                  ),
                  pw.Text(
                    'おつり：￥${_yen(change)}',
                    style: pw.TextStyle(font: bold),
                  ),
                ],
              ),
            ),
            pw.Spacer(),
            pw.Text(
              stockText,
              style: pw.TextStyle(
                font: font,
                fontSize: 10,
                color: PdfColors.grey700,
              ),
            ),
            pw.Divider(),
            pw.Text('株式会社Re,stArt', style: pw.TextStyle(font: bold)),
          ],
        ),
      ),
    );
    return doc.save();
  }

  pw.Widget _pdfText(String text, pw.Font font) => pw.Padding(
    padding: const pw.EdgeInsets.all(6),
    child: pw.Text(text, style: pw.TextStyle(font: font, fontSize: 10)),
  );

  void _showSnack(String text, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
  }

  String _yen(int value) => value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );

  String _dateText(DateTime d) =>
      '${d.year}年${d.month}月${d.day}日 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final item = _selectedProduct;
    final price = _selectedPrice;

    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('レジ'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const PosHistoryPage())),
            icon: const Icon(Icons.history),
            tooltip: '取引履歴',
          ),
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
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<LegacyStore>(
                      initialValue: _selectedStore,
                      decoration: const InputDecoration(
                        labelText: '販売店舗',
                        border: OutlineInputBorder(),
                      ),
                      items: _stores
                          .map(
                            (store) => DropdownMenuItem(
                              value: store,
                              child: Text(store.name),
                            ),
                          )
                          .toList(),
                      onChanged: _saving
                          ? null
                          : (store) => setState(() => _selectedStore = store),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _invoiceNumberController,
                            decoration: const InputDecoration(
                              labelText: 'インボイス事業者番号',
                              hintText: 'Tから始まる登録番号',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _saving ? null : _saveInvoiceNumber,
                          icon: const Icon(Icons.save),
                          label: const Text('保存'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _saving ? null : _openManualInput,
                        icon: const Icon(Icons.edit_note),
                        label: const Text('金額手入力'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            decoration: const InputDecoration(
                              labelText: '商品コード',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                            onSubmitted: (_) => _findProduct(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _saving ? null : _findProduct,
                          icon: const Icon(Icons.search),
                          label: const Text('検索'),
                        ),
                      ],
                    ),
                    if (_message != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _message!,
                        style: TextStyle(
                          color:
                              _message!.contains('エラー') ||
                                  _message!.contains('未登録') ||
                                  _message!.contains('見つかりません')
                              ? Colors.red
                              : Colors.green.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_manualMode) _buildManualAmountCard(),
            if (item != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text('コード: ${item.code}'),
                      const SizedBox(height: 12),
                      if (price == null)
                        const Text(
                          '商品マスタに税抜価格が未登録です。商品マスタ管理で税抜価格を登録してください。',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      else ...[
                        Row(
                          children: [
                            Expanded(
                              child: _amountTile(
                                '税抜単価',
                                '￥${_yen(_taxExcludedUnitPrice)}',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _amountTile(
                                '税込単価',
                                '￥${_yen(_taxIncludedUnitPrice)}',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _qtyController,
                                decoration: const InputDecoration(
                                  labelText: '数量',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _receivedController,
                                decoration: const InputDecoration(
                                  labelText: '預かり金',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _summaryRow('合計', '￥${_yen(_total)}', bold: true),
                        _summaryRow('預かり金', '￥${_yen(_received)}'),
                        _summaryRow(
                          'おつり',
                          _received >= _total ? '￥${_yen(_change)}' : '不足',
                          bold: true,
                          color: _received >= _total
                              ? Colors.green.shade700
                              : Colors.red,
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _saving ? null : _confirmSale,
                            icon: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check_circle),
                            label: const Text('会計確定・レシートPDF印刷'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildManualAmountCard() {
    final shortage = _manualReceived < _manualTotal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '金額手入力',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _manualNameController,
              decoration: const InputDecoration(
                labelText: '内容・品名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualAmountController,
                    decoration: const InputDecoration(
                      labelText: '税込単価',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _manualQtyController,
                    decoration: const InputDecoration(
                      labelText: '数量',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _manualTaxRate,
              decoration: const InputDecoration(
                labelText: '税率',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 10, child: Text('10%')),
                DropdownMenuItem(value: 8, child: Text('8%（軽減税率）')),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _manualTaxRate = value ?? 10),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _receivedController,
              decoration: const InputDecoration(
                labelText: '預かり金',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            _summaryRow('税抜単価', '￥${_yen(_manualTaxExcludedUnitPrice)}'),
            _summaryRow('税込合計', '￥${_yen(_manualTotal)}', bold: true),
            _summaryRow('預かり金', '￥${_yen(_manualReceived)}'),
            _summaryRow(
              'おつり',
              shortage ? '不足' : '￥${_yen(_manualChange)}',
              bold: true,
              color: shortage ? Colors.red : Colors.green.shade700,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _confirmManualSale,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.receipt_long),
                label: const Text('手入力会計確定・レシートPDF印刷'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _amountTile(String label, String value) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.blue.shade50,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.blue.shade100),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.grey.shade700)),
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  Widget _summaryRow(
    String label,
    String value, {
    bool bold = false,
    Color? color,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontWeight: bold ? FontWeight.bold : null),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: bold ? 22 : 16,
            fontWeight: bold ? FontWeight.bold : null,
            color: color,
          ),
        ),
      ],
    ),
  );
}

class PosHistoryPage extends StatefulWidget {
  const PosHistoryPage({super.key});

  @override
  State<PosHistoryPage> createState() => _PosHistoryPageState();
}

class _PosHistoryPageState extends State<PosHistoryPage> {
  bool _opening = false;

  Future<void> _openReceipt(String saleId) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final doc = await AppSession.posReceiptPdfs.doc(saleId).get();
      final data = doc.data() ?? <String, dynamic>{};
      final raw = (data['pdfBase64'] ?? '').toString();
      if (raw.isEmpty) {
        _showSnack('保存PDFが見つかりません', Colors.orange);
        return;
      }
      final bytes = base64Decode(raw);
      final name = (data['pdfFileName'] ?? 'レシート_$saleId.pdf').toString();
      await Printing.sharePdf(bytes: bytes, filename: name);
    } catch (e) {
      _showSnack('レシート印刷失敗: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _showSnack(String text, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
  }

  String _yen(int value) => value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );

  String _formatDate(String value) {
    final date = DateTime.tryParse(value);
    if (date == null) return value;
    return '${date.year}/${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('レジ取引履歴')),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: AppSession.posSales
              .orderBy('soldAtLocal', descending: true)
              .limit(100)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText('読み取りエラー\n\n${snapshot.error}'),
              );
            }
            final docs = snapshot.data?.docs ?? [];
            if (docs.isEmpty) {
              return const Center(child: Text('取引履歴はありません'));
            }
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: docs.length,
              itemBuilder: (context, index) {
                final doc = docs[index];
                final data = doc.data();
                final total = inventoryIntValue(data['total']);
                final received = inventoryIntValue(data['received']);
                final change = inventoryIntValue(data['change']);
                final itemName = (data['itemName'] ?? '').toString();
                final itemCode = (data['itemCode'] ?? '').toString();
                final storeName = (data['storeName'] ?? '').toString();
                final soldAt = (data['soldAtLocal'] ?? '').toString();
                final saleType = (data['saleType'] ?? 'product').toString();
                return Card(
                  child: ListTile(
                    title: Text(
                      itemCode.isEmpty ? itemName : '$itemName / $itemCode',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '$storeName / ${_formatDate(soldAt)}\n'
                      '区分: ${saleType == 'manual' ? '金額手入力' : '商品'} / '
                      '預かり: ￥${_yen(received)} / おつり: ￥${_yen(change)}',
                    ),
                    trailing: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '￥${_yen(total)}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton(
                          onPressed: _opening
                              ? null
                              : () => _openReceipt(doc.id),
                          child: const Text('印刷'),
                        ),
                      ],
                    ),
                    isThreeLine: true,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _PosPrice {
  const _PosPrice({
    required this.itemType,
    required this.itemCode,
    required this.itemName,
    required this.unitPrice,
    required this.taxRate,
  });

  final String itemType;
  final String itemCode;
  final String itemName;
  final int unitPrice;
  final int taxRate;

  factory _PosPrice.fromMap(Map<String, dynamic> map) => _PosPrice(
    itemType: (map['itemType'] ?? '').toString(),
    itemCode: (map['itemCode'] ?? '').toString(),
    itemName: (map['itemName'] ?? '').toString(),
    unitPrice: inventoryIntValue(map['unitPrice']),
    taxRate: inventoryIntValue(map['taxRate']) == 8 ? 8 : 10,
  );
}
