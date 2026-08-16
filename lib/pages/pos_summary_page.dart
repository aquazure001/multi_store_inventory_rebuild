part of '../main.dart';

// ─────────────────────────────────────────────
// 過去レジ実績の集計
// ─────────────────────────────────────────────

class _PosSummaryLine {
  _PosSummaryLine({required this.name, required this.type});

  final String name;
  final String type; // 'product' | 'manual'
  int qty = 0;
  int amount = 0;

  bool get isManual => type == 'manual';
}

class PosSummaryPage extends StatefulWidget {
  const PosSummaryPage({super.key});

  @override
  State<PosSummaryPage> createState() => _PosSummaryPageState();
}

class _PosSummaryPageState extends State<PosSummaryPage> {
  DateTime _startDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _endDate = DateTime.now();

  List<LegacyStore> _stores = [];
  LegacyStore? _selectedStore;
  Set<String> _viewableStoreIds = {};
  bool _isRestricted = false;
  List<String> _visibleStoreNames = [];

  bool _loadingStores = true;
  bool _loading = false;
  bool _hasResult = false;
  String? _message;

  int _resultCount = 0;
  int _resultTotal = 0;
  int _resultProductTotal = 0;
  int _resultManualTotal = 0;
  List<_PosSummaryLine> _breakdown = [];

  @override
  void initState() {
    super.initState();
    _loadStores();
  }

  Future<void> _loadStores() async {
    setState(() => _loadingStores = true);
    try {
      final storesDoc = await AppSession.doc('stores').get();
      final allStores = _parseStores(storesDoc.data() ?? <String, dynamic>{});
      final allStoreIds = allStores.map((s) => s.id).toList();
      final viewableIds = AppSession.viewableStoreIds(allStoreIds).toSet();
      final visibleStores = allStores
          .where((s) => viewableIds.contains(s.id))
          .toList();
      setState(() {
        _stores = visibleStores;
        _viewableStoreIds = viewableIds;
        _isRestricted = visibleStores.length < allStores.length;
        _visibleStoreNames = visibleStores.map((s) => s.name).toList();
        _loadingStores = false;
      });
    } catch (e) {
      setState(() {
        _message = '店舗一覧の読み込みに失敗しました: $e';
        _loadingStores = false;
      });
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _startDate : _endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      locale: const Locale('ja'),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = DateTime(picked.year, picked.month, picked.day);
        if (_endDate.isBefore(_startDate)) _endDate = _startDate;
      } else {
        _endDate = DateTime(picked.year, picked.month, picked.day);
        if (_startDate.isAfter(_endDate)) _startDate = _endDate;
      }
    });
  }

  String _dateLabel(DateTime d) => '${d.year}年${d.month}月${d.day}日';

  Future<void> _runAggregation() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final startIso = DateTime(
        _startDate.year,
        _startDate.month,
        _startDate.day,
      ).toIso8601String();
      final endIso = DateTime(
        _endDate.year,
        _endDate.month,
        _endDate.day,
        23,
        59,
        59,
        999,
      ).toIso8601String();

      final snap = await AppSession.posSales
          .where('soldAtLocal', isGreaterThanOrEqualTo: startIso)
          .where('soldAtLocal', isLessThanOrEqualTo: endIso)
          .orderBy('soldAtLocal', descending: true)
          .get();

      var count = 0;
      var total = 0;
      var productTotal = 0;
      var manualTotal = 0;
      final breakdown = <String, _PosSummaryLine>{};

      void addBreakdown(String type, String name, int qty, int amount) {
        final key = '${type}__$name';
        final line = breakdown.putIfAbsent(
          key,
          () => _PosSummaryLine(
            name: name.isEmpty ? '（名称未設定）' : name,
            type: type == 'manual' ? 'manual' : 'product',
          ),
        );
        line.qty += qty;
        line.amount += amount;
      }

      for (final doc in snap.docs) {
        final data = doc.data();
        final storeId = (data['storeId'] ?? '').toString();
        if (!_viewableStoreIds.contains(storeId)) continue;
        if (_selectedStore != null && storeId != _selectedStore!.id) continue;

        count++;
        final docTotal = inventoryIntValue(data['total']);
        total += docTotal;

        final rawItems = data['items'];
        if (rawItems is List && rawItems.isNotEmpty) {
          for (final rawItem in rawItems) {
            if (rawItem is! Map) continue;
            final type = (rawItem['type'] ?? 'product').toString();
            final name = (rawItem['itemName'] ?? '').toString();
            final qty = inventoryIntValue(rawItem['qty']);
            final subtotal = inventoryIntValue(rawItem['subtotal']);
            if (type == 'manual') {
              manualTotal += subtotal;
            } else {
              productTotal += subtotal;
            }
            addBreakdown(type, name, qty, subtotal);
          }
        } else {
          // 旧形式（カート導入前・単一商品）の取引に対するフォールバック集計
          final saleType = (data['saleType'] ?? 'product').toString();
          final itemName = (data['itemName'] ?? '').toString();
          final qty = inventoryIntValue(data['qty']);
          if (saleType == 'manual') {
            manualTotal += docTotal;
          } else {
            productTotal += docTotal;
          }
          addBreakdown(saleType, itemName, qty, docTotal);
        }
      }

      final sorted = breakdown.values.toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));

      setState(() {
        _resultCount = count;
        _resultTotal = total;
        _resultProductTotal = productTotal;
        _resultManualTotal = manualTotal;
        _breakdown = sorted;
        _hasResult = true;
      });
    } catch (e) {
      setState(() => _message = '集計失敗: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _exportPdf() async {
    try {
      final pdfBytes = await _createSummaryPdf();
      final fileName =
          'レジ実績集計_'
          '${_startDate.year}${_startDate.month.toString().padLeft(2, '0')}${_startDate.day.toString().padLeft(2, '0')}'
          '-'
          '${_endDate.year}${_endDate.month.toString().padLeft(2, '0')}${_endDate.day.toString().padLeft(2, '0')}'
          '.pdf';
      await Printing.sharePdf(bytes: pdfBytes, filename: fileName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF出力失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<Uint8List> _createSummaryPdf() async {
    final font = await PdfGoogleFonts.notoSansJPRegular();
    final bold = await PdfGoogleFonts.notoSansJPBold();
    final logoData = await rootBundle.load('assets/billing/restart_logo.png');
    final logo = pw.MemoryImage(logoData.buffer.asUint8List());
    final doc = pw.Document();
    final storeLabel = _selectedStore?.name ?? '全店舗';
    final periodLabel = '${_dateLabel(_startDate)} 〜 ${_dateLabel(_endDate)}';

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
                pw.Text(
                  'レジ実績集計表',
                  style: pw.TextStyle(font: bold, fontSize: 24),
                ),
                pw.Image(logo, width: 110),
              ],
            ),
            pw.SizedBox(height: 16),
            pw.Text('対象期間：$periodLabel', style: pw.TextStyle(font: font)),
            pw.Text('対象店舗：$storeLabel', style: pw.TextStyle(font: font)),
            pw.Text(
              '出力日時：${_dateLabel(DateTime.now())}',
              style: pw.TextStyle(font: font, fontSize: 10),
            ),
            pw.SizedBox(height: 16),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.blueGrey, width: 1),
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('件数', style: pw.TextStyle(font: font)),
                      pw.Text(
                        '$_resultCount 件',
                        style: pw.TextStyle(font: bold, fontSize: 18),
                      ),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('商品売上', style: pw.TextStyle(font: font)),
                      pw.Text(
                        '￥${_yen(_resultProductTotal)}',
                        style: pw.TextStyle(font: bold, fontSize: 18),
                      ),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('手入力売上', style: pw.TextStyle(font: font)),
                      pw.Text(
                        '￥${_yen(_resultManualTotal)}',
                        style: pw.TextStyle(font: bold, fontSize: 18),
                      ),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('合計売上', style: pw.TextStyle(font: font)),
                      pw.Text(
                        '￥${_yen(_resultTotal)}',
                        style: pw.TextStyle(font: bold, fontSize: 20),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),
            pw.Text('商品別売上内訳', style: pw.TextStyle(font: bold, fontSize: 14)),
            pw.SizedBox(height: 8),
            if (_breakdown.isEmpty)
              pw.Text('対象期間の取引はありません。', style: pw.TextStyle(font: font))
            else
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.grey500,
                  width: 0.5,
                ),
                columnWidths: const {
                  0: pw.FlexColumnWidth(3),
                  1: pw.FlexColumnWidth(1.2),
                  2: pw.FlexColumnWidth(1),
                  3: pw.FlexColumnWidth(1.4),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.blue50),
                    children: [
                      _pdfCell('品名', bold),
                      _pdfCell('区分', bold),
                      _pdfCell('数量', bold),
                      _pdfCell('金額', bold),
                    ],
                  ),
                  for (final line in _breakdown)
                    pw.TableRow(
                      children: [
                        _pdfCell(line.name, font),
                        _pdfCell(line.isManual ? '手入力' : '商品', font),
                        _pdfCell('${line.qty}', font),
                        _pdfCell('￥${_yen(line.amount)}', font),
                      ],
                    ),
                ],
              ),
            pw.Spacer(),
            pw.Divider(),
            pw.Text('株式会社Re,stArt', style: pw.TextStyle(font: bold)),
          ],
        ),
      ),
    );
    return doc.save();
  }

  pw.Widget _pdfCell(String text, pw.Font font) => pw.Padding(
    padding: const pw.EdgeInsets.all(6),
    child: pw.Text(text, style: pw.TextStyle(font: font, fontSize: 10)),
  );

  String _yen(int value) => value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
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

  Widget _statTile(String label, String value, {Color? color}) => Expanded(
    child: Container(
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
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('レジ実績集計')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_loadingStores && _isRestricted)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 16),
                color: Colors.orange.shade50,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
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
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '集計条件',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<LegacyStore?>(
                      initialValue: _selectedStore,
                      decoration: const InputDecoration(
                        labelText: '対象店舗',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<LegacyStore?>(
                          value: null,
                          child: Text('全店舗'),
                        ),
                        ..._stores.map(
                          (store) => DropdownMenuItem<LegacyStore?>(
                            value: store,
                            child: Text(store.name),
                          ),
                        ),
                      ],
                      onChanged: (_loading || _loadingStores)
                          ? null
                          : (store) => setState(() => _selectedStore = store),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading
                                ? null
                                : () => _pickDate(isStart: true),
                            icon: const Icon(Icons.calendar_month),
                            label: Text('開始日: ${_dateLabel(_startDate)}'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading
                                ? null
                                : () => _pickDate(isStart: false),
                            icon: const Icon(Icons.event),
                            label: Text('終了日: ${_dateLabel(_endDate)}'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _runAggregation,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.query_stats),
                        label: Text(_loading ? '集計中...' : '集計する'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_message != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _message!,
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (_hasResult) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '集計結果（${_dateLabel(_startDate)} 〜 ${_dateLabel(_endDate)}）',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _statTile('件数', '$_resultCount 件'),
                          const SizedBox(width: 8),
                          _statTile(
                            '合計売上',
                            '￥${_yen(_resultTotal)}',
                            color: Colors.green.shade700,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _statTile('商品売上', '￥${_yen(_resultProductTotal)}'),
                          const SizedBox(width: 8),
                          _statTile('手入力売上', '￥${_yen(_resultManualTotal)}'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _resultCount == 0 ? null : _exportPdf,
                          icon: const Icon(Icons.picture_as_pdf),
                          label: const Text('集計結果をPDFで出力'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '商品別売上内訳',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_breakdown.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            '対象期間の取引はありません',
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        )
                      else
                        for (int i = 0; i < _breakdown.length; i++) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                _typeTag(_breakdown[i].isManual),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _breakdown[i].name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '数量 ${_breakdown[i].qty}',
                                        style: TextStyle(
                                          color: Colors.grey.shade700,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  '￥${_yen(_breakdown[i].amount)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (i < _breakdown.length - 1)
                            const Divider(height: 1),
                        ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
