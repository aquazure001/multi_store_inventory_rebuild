part of '../main.dart';

class PosPage extends StatefulWidget {
  const PosPage({super.key});

  @override
  State<PosPage> createState() => _PosPageState();
}

class _PosCartLine {
  _PosCartLine({
    required this.type,
    required this.itemId,
    required this.itemCode,
    required this.itemName,
    required this.qty,
    required this.taxRate,
    required this.taxExcludedUnitPrice,
    required this.taxIncludedUnitPrice,
  });

  final String type; // 'product' | 'manual'
  final String itemId;
  final String itemCode;
  final String itemName;
  final int qty;
  final int taxRate;
  final int taxExcludedUnitPrice;
  final int taxIncludedUnitPrice;

  bool get isManual => type == 'manual';
  int get subtotal => taxIncludedUnitPrice * qty;
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
  final List<_PosCartLine> _cart = [];
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

  int get _manualQty {
    final parsed = int.tryParse(_manualQtyController.text.trim()) ?? 1;
    return parsed <= 0 ? 1 : parsed;
  }

  int get _manualTaxIncludedUnitPrice =>
      int.tryParse(_manualAmountController.text.replaceAll(',', '').trim()) ??
      0;

  int get _manualTaxExcludedUnitPrice =>
      (_manualTaxIncludedUnitPrice * 100 / (100 + _manualTaxRate)).round();

  int get _cartTotal => _cart.fold(0, (acc, line) => acc + line.subtotal);

  int get _received =>
      int.tryParse(_receivedController.text.replaceAll(',', '').trim()) ?? 0;

  int get _change => _received - _cartTotal;

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

  void _addProductToCart() {
    final item = _selectedProduct;
    final price = _selectedPrice;
    if (item == null || price == null || price.unitPrice <= 0) {
      _showSnack('商品マスタに税抜価格を登録してください', Colors.orange);
      return;
    }
    final qty = _qty;
    final taxRate = _taxRate;
    final taxExcluded = _taxExcludedUnitPrice;
    final taxIncluded = _taxIncludedUnitPrice;
    setState(() {
      _cart.add(
        _PosCartLine(
          type: 'product',
          itemId: item.id,
          itemCode: item.code,
          itemName: item.name,
          qty: qty,
          taxRate: taxRate,
          taxExcludedUnitPrice: taxExcluded,
          taxIncludedUnitPrice: taxIncluded,
        ),
      );
      _codeController.clear();
      _qtyController.text = '1';
      _selectedProduct = null;
      _message = '${item.name} をカートに追加しました。';
    });
  }

  void _addManualToCart() {
    final itemName = _manualNameController.text.trim().isEmpty
        ? '金額手入力'
        : _manualNameController.text.trim();
    if (_manualTaxIncludedUnitPrice <= 0) {
      _showSnack('税込金額を入力してください', Colors.orange);
      return;
    }
    final qty = _manualQty;
    final taxRate = _manualTaxRate;
    final taxExcluded = _manualTaxExcludedUnitPrice;
    final taxIncluded = _manualTaxIncludedUnitPrice;
    setState(() {
      _cart.add(
        _PosCartLine(
          type: 'manual',
          itemId: '',
          itemCode: '',
          itemName: itemName,
          qty: qty,
          taxRate: taxRate,
          taxExcludedUnitPrice: taxExcluded,
          taxIncludedUnitPrice: taxIncluded,
        ),
      );
      _manualAmountController.clear();
      _manualQtyController.text = '1';
      _message = '$itemName をカートに追加しました。';
    });
  }

  void _removeCartLine(int index) {
    setState(() => _cart.removeAt(index));
  }

  Future<void> _confirmCartSale() async {
    final store = _selectedStore;
    if (store == null) {
      _showSnack('店舗を選択してください', Colors.orange);
      return;
    }
    if (_cart.isEmpty) {
      _showSnack('カートに商品がありません', Colors.orange);
      return;
    }
    if (_received < _cartTotal) {
      _showSnack('預かり金が不足しています', Colors.orange);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('会計を確定しますか？'),
        content: Text(
          '${store.name}\n${_cart.length}点\n合計 ￥${_yen(_cartTotal)}\n\n確定すると対象商品の在庫を減らします。',
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
      final lineResults = <Map<String, dynamic>>[];
      final stockTexts = <String>[];
      final total = _cartTotal;
      final received = _received;
      final change = _change;
      final cartSnapshot = List<_PosCartLine>.from(_cart);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final stocksSnap = await tx.get(AppSession.stocksDoc);
        final stocksData = stocksSnap.data() ?? <String, dynamic>{};
        final storeStocksRaw = stocksData[store.id];
        final storeStocks = storeStocksRaw is Map
            ? Map<String, dynamic>.from(
                storeStocksRaw.map((k, v) => MapEntry(k.toString(), v)),
              )
            : <String, dynamic>{};
        final workingStocks = <String, int>{
          for (final entry in storeStocks.entries)
            entry.key: inventoryIntValue(entry.value),
        };
        final finalStocks = <String, int>{};

        for (final line in cartSnapshot) {
          if (line.type != 'product') continue;
          final oldStock = workingStocks[line.itemId] ?? 0;
          if (oldStock < line.qty) {
            throw Exception('「${line.itemName}」の在庫が不足しています（現在 $oldStock 個）');
          }
          final newStock = oldStock - line.qty;
          workingStocks[line.itemId] = newStock;
          finalStocks[line.itemId] = newStock;
          stockTexts.add('${line.itemName}: $oldStock→$newStock');
          lineResults.add({
            'type': line.type,
            'itemId': line.itemId,
            'itemCode': line.itemCode,
            'itemName': line.itemName,
            'qty': line.qty,
            'taxRate': line.taxRate,
            'reducedTax': line.taxRate == 8,
            'taxExcludedUnitPrice': line.taxExcludedUnitPrice,
            'taxIncludedUnitPrice': line.taxIncludedUnitPrice,
            'subtotal': line.subtotal,
            'stockUpdated': true,
            'oldStock': oldStock,
            'newStock': newStock,
          });
        }
        for (final line in cartSnapshot) {
          if (line.type == 'product') continue;
          lineResults.add({
            'type': line.type,
            'itemId': '',
            'itemCode': '',
            'itemName': line.itemName,
            'qty': line.qty,
            'taxRate': line.taxRate,
            'reducedTax': line.taxRate == 8,
            'taxExcludedUnitPrice': line.taxExcludedUnitPrice,
            'taxIncludedUnitPrice': line.taxIncludedUnitPrice,
            'subtotal': line.subtotal,
            'stockUpdated': false,
          });
        }

        if (finalStocks.isNotEmpty) {
          tx.set(AppSession.stocksDoc, {
            store.id: finalStocks,
          }, SetOptions(merge: true));
        }

        final hasProduct = cartSnapshot.any((l) => l.type == 'product');
        final hasManual = cartSnapshot.any((l) => l.type == 'manual');
        final saleType = hasProduct && hasManual
            ? 'mixed'
            : (hasProduct ? 'product' : 'manual');

        tx.set(saleRef, {
          'id': saleRef.id,
          'status': 'completed',
          'saleType': saleType,
          'soldAt': FieldValue.serverTimestamp(),
          'soldAtLocal': now.toIso8601String(),
          'soldBy': AppSession.nickname,
          'uid': AppSession.uid,
          'storeId': store.id,
          'storeName': store.name,
          'items': lineResults,
          'itemCount': cartSnapshot.length,
          'total': total,
          'received': received,
          'change': change,
          'invoiceNumber': _invoiceNumberController.text.trim(),
        });
      });

      final pdfBytes = await _createReceiptPdf(
        saleId: saleRef.id,
        soldAt: now,
        storeName: store.name,
        lines: cartSnapshot,
        total: total,
        received: received,
        change: change,
        invoiceNumber: _invoiceNumberController.text.trim(),
        stockTexts: stockTexts,
      );
      await AppSession.posReceiptPdfs.doc(saleRef.id).set({
        'saleId': saleRef.id,
        'soldAtLocal': now.toIso8601String(),
        'storeId': store.id,
        'storeName': store.name,
        'itemCount': cartSnapshot.length,
        'pdfBase64': base64Encode(pdfBytes),
        'pdfFileName': 'レシート_${saleRef.id}.pdf',
      });
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: 'レシート_${saleRef.id}.pdf',
      );

      setState(() {
        _cart.clear();
        _receivedController.clear();
        _message = '会計を確定しました（${cartSnapshot.length}点 / 合計￥${_yen(total)}）。';
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
    required List<_PosCartLine> lines,
    required int total,
    required int received,
    required int change,
    required String invoiceNumber,
    required List<String> stockTexts,
  }) async {
    final font = await PdfGoogleFonts.notoSansJPRegular();
    final bold = await PdfGoogleFonts.notoSansJPBold();
    final logoData = await rootBundle.load('assets/billing/restart_logo.png');
    final logo = pw.MemoryImage(logoData.buffer.asUint8List());
    final doc = pw.Document();
    final taxExcludedTotal = lines.fold<int>(
      0,
      (acc, line) => acc + line.taxExcludedUnitPrice * line.qty,
    );
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
                    _pdfText('品名', bold),
                    _pdfText('数量', bold),
                    _pdfText('税込単価', bold),
                    _pdfText('小計', bold),
                  ],
                ),
                for (final line in lines)
                  pw.TableRow(
                    children: [
                      _pdfText(
                        line.isManual
                            ? '${line.itemName}（手入力）'
                            : (line.itemCode.isEmpty
                                  ? line.itemName
                                  : '${line.itemName}\nコード:${line.itemCode}'),
                        font,
                      ),
                      _pdfText('${line.qty}', font),
                      _pdfText('￥${_yen(line.taxIncludedUnitPrice)}', font),
                      _pdfText('￥${_yen(line.subtotal)}', font),
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
                    '税抜合計：￥${_yen(taxExcludedTotal)}',
                    style: pw.TextStyle(font: font),
                  ),
                  pw.Text('消費税：￥${_yen(tax)}', style: pw.TextStyle(font: font)),
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
              stockTexts.isEmpty ? '在庫変更なし' : '在庫更新：${stockTexts.join(' / ')}',
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
                                  _message!.contains('見つかりません') ||
                                  _message!.contains('不足')
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
            if (_manualMode) _buildManualAddCard(),
            if (!_manualMode && item != null) _buildProductAddCard(item, price),
            if (_cart.isNotEmpty) _buildCartCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildProductAddCard(LegacyItem item, _PosPrice? price) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
              TextField(
                controller: _qtyController,
                decoration: const InputDecoration(
                  labelText: '数量',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              _summaryRow(
                '小計',
                '￥${_yen(_taxIncludedUnitPrice * _qty)}',
                bold: true,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _addProductToCart,
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('カートに追加'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildManualAddCard() {
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
            _summaryRow('税抜単価', '￥${_yen(_manualTaxExcludedUnitPrice)}'),
            _summaryRow(
              '小計',
              '￥${_yen(_manualTaxIncludedUnitPrice * _manualQty)}',
              bold: true,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _addManualToCart,
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('カートに追加'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCartCard() {
    final shortage = _received < _cartTotal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'カート（${_cart.length}点）',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < _cart.length; i++) ...[
              _cartLineTile(i, _cart[i]),
              if (i < _cart.length - 1) const Divider(height: 1),
            ],
            const Divider(),
            _summaryRow('合計', '￥${_yen(_cartTotal)}', bold: true),
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
            _summaryRow('預かり金', '￥${_yen(_received)}'),
            _summaryRow(
              'おつり',
              shortage ? '不足' : '￥${_yen(_change)}',
              bold: true,
              color: shortage ? Colors.red : Colors.green.shade700,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _confirmCartSale,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle),
                label: const Text('会計確定・レシートPDF発行'),
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

  Widget _cartLineTile(int index, _PosCartLine line) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _typeTag(line.isManual),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                line.itemName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                '${line.qty}個 × ￥${_yen(line.taxIncludedUnitPrice)}',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
              ),
            ],
          ),
        ),
        Text(
          '￥${_yen(line.subtotal)}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          tooltip: 'カートから削除',
          onPressed: _saving ? null : () => _removeCartLine(index),
        ),
      ],
    ),
  );

  Widget _typeTag(bool isManual) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: isManual ? Colors.orange.shade100 : Colors.blue.shade100,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      isManual ? '手入力' : '商品',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: isManual ? Colors.orange.shade900 : Colors.blue.shade900,
      ),
    ),
  );

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
                final storeName = (data['storeName'] ?? '').toString();
                final soldAt = (data['soldAtLocal'] ?? '').toString();
                final saleType = (data['saleType'] ?? 'product').toString();

                String titleText;
                String saleTypeLabel;
                final rawItems = data['items'];
                if (rawItems is List && rawItems.isNotEmpty) {
                  final names = rawItems
                      .map(
                        (e) => e is Map ? (e['itemName'] ?? '').toString() : '',
                      )
                      .where((s) => s.isNotEmpty)
                      .toList();
                  titleText = names.isEmpty
                      ? '${rawItems.length}点'
                      : (names.length == 1
                            ? names.first
                            : '${names.first} ほか${names.length - 1}点');
                  saleTypeLabel = saleType == 'mixed'
                      ? '商品+手入力'
                      : (saleType == 'manual' ? '金額手入力' : '商品');
                } else {
                  // 旧形式（単一商品）の取引に対するフォールバック表示
                  final itemName = (data['itemName'] ?? '').toString();
                  final itemCode = (data['itemCode'] ?? '').toString();
                  titleText = itemCode.isEmpty
                      ? itemName
                      : '$itemName / $itemCode';
                  saleTypeLabel = saleType == 'manual' ? '金額手入力' : '商品';
                }

                return Card(
                  child: ListTile(
                    title: Text(
                      titleText,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '$storeName / ${_formatDate(soldAt)}\n'
                      '区分: $saleTypeLabel / '
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
