part of '../main.dart';

// ─────────────────────────────────────────────
// 過去の発注表PDF再出力
// ─────────────────────────────────────────────

class PastOrderPdfPage extends StatefulWidget {
  const PastOrderPdfPage({super.key});

  @override
  State<PastOrderPdfPage> createState() => _PastOrderPdfPageState();
}

class _PastOrderPdfPageState extends State<PastOrderPdfPage> {
  bool _loading = true;
  String? _error;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _batches = [];
  int _visibleCount = 20;

  bool get _canViewPastOrders => AppSession.isAdmin || AppSession.isSuperAdmin;

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

  DateTime _batchDate(Map<String, dynamic> data) {
    final ts = data['createdAt'];
    if (ts is Timestamp) return ts.toDate();
    return DateTime.tryParse((data['createdAtLocal'] ?? '').toString()) ??
        DateTime.now();
  }

  String _batchTitle(Map<String, dynamic> data) {
    final d = _batchDate(data);
    return '${d.year}年${d.month}月${d.day}日の発注表';
  }

  List<Map<String, dynamic>> _batchItems(Map<String, dynamic> data) {
    final raw = data['items'];
    if (raw is! List) return <Map<String, dynamic>>[];
    final items = raw
        .whereType<Map>()
        .map(
          (e) => Map<String, dynamic>.from(
            e.map((k, v) => MapEntry(k.toString(), v)),
          ),
        )
        .toList();
    items.sort((a, b) {
      final storeCompare = (a['storeName'] ?? '').toString().compareTo(
        (b['storeName'] ?? '').toString(),
      );
      if (storeCompare != 0) return storeCompare;
      final typeCompare = (a['itemType'] ?? '').toString().compareTo(
        (b['itemType'] ?? '').toString(),
      );
      if (typeCompare != 0) return typeCompare;
      final codeCompare = _naturalCompare(
        (a['itemCode'] ?? '').toString(),
        (b['itemCode'] ?? '').toString(),
      );
      if (codeCompare != 0) return codeCompare;
      return _naturalCompare(
        (a['itemName'] ?? '').toString(),
        (b['itemName'] ?? '').toString(),
      );
    });
    return items;
  }

  Future<void> _load() async {
    if (!_canViewPastOrders) {
      setState(() {
        _loading = false;
        _error = '過去の発注表を確認できるのは管理者・統括管理者のみです';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await AppSession.doc('orders')
          .collection('batches')
          .orderBy('createdAt', descending: true)
          .limit(100)
          .get();
      setState(() {
        _batches = snap.docs
            .where((doc) => (doc.data()['status'] ?? '') != 'canceled')
            .toList();
        _visibleCount = 20;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  pw.Widget _pastOrderPdfCell(
    String text,
    pw.Font font, {
    bool bold = false,
    PdfColor? color,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          font: font,
          fontSize: 10,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: color,
        ),
      ),
    );
  }

  bool _hasSavedPdf(Map<String, dynamic> data) {
    return data['hasSavedPdf'] == true ||
        (data['pdfBase64'] ?? '').toString().isNotEmpty;
  }

  bool _hasEmbeddedPdf(Map<String, dynamic> data) {
    return (data['pdfBase64'] ?? '').toString().isNotEmpty;
  }

  Future<void> _separateEmbeddedPdf(
    QueryDocumentSnapshot<Map<String, dynamic>> batch,
  ) async {
    final data = batch.data();
    final raw = (data['pdfBase64'] ?? '').toString();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('この発注表には分離対象の内蔵PDFがありません'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存PDFを軽量化しますか？'),
        content: const Text(
          'この発注表の中に入っているPDF本体を別の保存場所へ移します。\n\n'
          '発注表の内容やPDFは消えません。\n'
          '一覧表示を軽くするための処理です。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('軽量化する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final savedName = (data['pdfFileName'] ?? '').toString();
      await AppSession.doc(
        'order_saved_pdfs',
      ).collection('entries').doc(batch.id).set({
        'batchId': batch.id,
        'pdfBase64': raw,
        'pdfFileName': savedName,
        'pdfKind': (data['pdfKind'] ?? '').toString(),
        'createdAt': data['createdAt'],
        'createdAtLocal': data['createdAtLocal'],
        'separatedAt': FieldValue.serverTimestamp(),
        'separatedAtLocal': DateTime.now().toIso8601String(),
        'separatedBy': AppSession.nickname,
      }, SetOptions(merge: true));
      await batch.reference.update({
        'hasSavedPdf': true,
        'pdfBase64': FieldValue.delete(),
        'pdfSeparatedAt': FieldValue.serverTimestamp(),
        'pdfSeparatedAtLocal': DateTime.now().toIso8601String(),
      });
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保存PDFを分離して、発注表一覧を軽量化しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF分離失敗: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _openSavedPdf(
    QueryDocumentSnapshot<Map<String, dynamic>> batch,
  ) async {
    final data = batch.data();
    var raw = (data['pdfBase64'] ?? '').toString();
    var savedName = (data['pdfFileName'] ?? '').toString();

    if (raw.isEmpty && data['hasSavedPdf'] == true) {
      final pdfDoc = await AppSession.doc(
        'order_saved_pdfs',
      ).collection('entries').doc(batch.id).get();
      final pdfData = pdfDoc.data() ?? <String, dynamic>{};
      raw = (pdfData['pdfBase64'] ?? '').toString();
      if (savedName.isEmpty) {
        savedName = (pdfData['pdfFileName'] ?? '').toString();
      }
    }

    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('この発注表には保存済みPDFがありません'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    try {
      final bytes = base64Decode(raw);
      final d = _batchDate(data);
      final fallbackName =
          '保存済み発注表_${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}.pdf';
      await Printing.sharePdf(
        bytes: bytes,
        filename: savedName.isEmpty ? fallbackName : savedName,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存PDFを開けません: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _exportPdfByStore(
    QueryDocumentSnapshot<Map<String, dynamic>> batch,
  ) async {
    final data = batch.data();
    final items = _batchItems(data);
    if (items.isEmpty) return;

    final font = await PdfGoogleFonts.notoSansJPRegular();
    final doc = pw.Document();
    final byStore = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final storeName = (item['storeName'] ?? '店舗不明').toString();
      byStore.putIfAbsent(storeName, () => <Map<String, dynamic>>[]).add(item);
    }

    final title = '${_batchTitle(data)}（店舗別）';
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font),
        header: (ctx) => pw.Text(
          title,
          style: pw.TextStyle(
            font: font,
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];
          widgets.add(
            pw.Text(
              '発注確定日時: ${_formatDateTime(_batchDate(data))} / 発注者: ${(data['createdBy'] ?? '').toString()}',
              style: pw.TextStyle(font: font, fontSize: 10),
            ),
          );
          for (final storeName in byStore.keys) {
            final storeItems = byStore[storeName]!;
            widgets.add(pw.SizedBox(height: 12));
            widgets.add(
              pw.Text(
                '■ $storeName',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                columnWidths: {
                  0: const pw.FlexColumnWidth(1.2),
                  1: const pw.FlexColumnWidth(2.7),
                  2: const pw.FlexColumnWidth(1),
                  3: const pw.FlexColumnWidth(0.8),
                  4: const pw.FlexColumnWidth(0.8),
                  5: const pw.FlexColumnWidth(0.9),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.grey200,
                    ),
                    children: [
                      _pastOrderPdfCell('コード', font, bold: true),
                      _pastOrderPdfCell('商品名', font, bold: true),
                      _pastOrderPdfCell('種別', font, bold: true),
                      _pastOrderPdfCell('基準', font, bold: true),
                      _pastOrderPdfCell('現在', font, bold: true),
                      _pastOrderPdfCell('発注数', font, bold: true),
                    ],
                  ),
                  for (final item in storeItems)
                    pw.TableRow(
                      children: [
                        _pastOrderPdfCell(
                          (item['itemCode'] ?? '').toString(),
                          font,
                        ),
                        _pastOrderPdfCell(
                          (item['itemName'] ?? '').toString(),
                          font,
                        ),
                        _pastOrderPdfCell(
                          (item['itemType'] ?? '').toString(),
                          font,
                        ),
                        _pastOrderPdfCell('${_toInt(item['base'])}', font),
                        _pastOrderPdfCell(
                          '${_toInt(item['currentAtOrder'])}',
                          font,
                        ),
                        _pastOrderPdfCell(
                          '${_toInt(item['qty'])}',
                          font,
                          color: PdfColors.blue700,
                        ),
                      ],
                    ),
                ],
              ),
            );
          }
          return widgets;
        },
      ),
    );

    final d = _batchDate(data);
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename:
          '過去の発注表_${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}_店舗別.pdf',
    );
  }

  Future<void> _exportPdfByItem(
    QueryDocumentSnapshot<Map<String, dynamic>> batch,
  ) async {
    final data = batch.data();
    final items = _batchItems(data);
    if (items.isEmpty) return;

    final font = await PdfGoogleFonts.notoSansJPRegular();
    final doc = pw.Document();
    final byTypeByItem = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final item in items) {
      final type = (item['itemType'] ?? '種別不明').toString();
      final itemId = (item['itemId'] ?? '').toString();
      final itemKey = itemId.isEmpty
          ? '${item['itemCode']}__${item['itemName']}'
          : itemId;
      byTypeByItem.putIfAbsent(
        type,
        () => <String, List<Map<String, dynamic>>>{},
      );
      byTypeByItem[type]!
          .putIfAbsent(itemKey, () => <Map<String, dynamic>>[])
          .add(item);
    }

    final title = '${_batchTitle(data)}（商品別）';
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font),
        header: (ctx) => pw.Text(
          title,
          style: pw.TextStyle(
            font: font,
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];
          widgets.add(
            pw.Text(
              '発注確定日時: ${_formatDateTime(_batchDate(data))} / 発注者: ${(data['createdBy'] ?? '').toString()}',
              style: pw.TextStyle(font: font, fontSize: 10),
            ),
          );
          for (final type in ['商品', 'テスター', '備品']) {
            if (!byTypeByItem.containsKey(type)) continue;
            widgets.add(pw.SizedBox(height: 12));
            widgets.add(
              pw.Text(
                '■ $type',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                columnWidths: {
                  0: const pw.FlexColumnWidth(1.2),
                  1: const pw.FlexColumnWidth(2.5),
                  2: const pw.FlexColumnWidth(1.5),
                  3: const pw.FlexColumnWidth(0.8),
                  4: const pw.FlexColumnWidth(0.8),
                  5: const pw.FlexColumnWidth(0.9),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.grey200,
                    ),
                    children: [
                      _pastOrderPdfCell('コード', font, bold: true),
                      _pastOrderPdfCell('商品名', font, bold: true),
                      _pastOrderPdfCell('店舗', font, bold: true),
                      _pastOrderPdfCell('基準', font, bold: true),
                      _pastOrderPdfCell('現在', font, bold: true),
                      _pastOrderPdfCell('発注数', font, bold: true),
                    ],
                  ),
                  for (final itemKey in byTypeByItem[type]!.keys)
                    for (
                      var i = 0;
                      i < byTypeByItem[type]![itemKey]!.length;
                      i++
                    )
                      pw.TableRow(
                        children: [
                          _pastOrderPdfCell(
                            i == 0
                                ? (byTypeByItem[type]![itemKey]!
                                              .first['itemCode'] ??
                                          '')
                                      .toString()
                                : '',
                            font,
                          ),
                          _pastOrderPdfCell(
                            i == 0
                                ? (byTypeByItem[type]![itemKey]!
                                              .first['itemName'] ??
                                          '')
                                      .toString()
                                : '',
                            font,
                          ),
                          _pastOrderPdfCell(
                            (byTypeByItem[type]![itemKey]![i]['storeName'] ??
                                    '')
                                .toString(),
                            font,
                          ),
                          _pastOrderPdfCell(
                            '${_toInt(byTypeByItem[type]![itemKey]![i]['base'])}',
                            font,
                          ),
                          _pastOrderPdfCell(
                            '${_toInt(byTypeByItem[type]![itemKey]![i]['currentAtOrder'])}',
                            font,
                          ),
                          _pastOrderPdfCell(
                            '${_toInt(byTypeByItem[type]![itemKey]![i]['qty'])}',
                            font,
                            color: PdfColors.blue700,
                          ),
                        ],
                      ),
                ],
              ),
            );
          }
          return widgets;
        },
      ),
    );

    final d = _batchDate(data);
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename:
          '過去の発注表_${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}_商品別.pdf',
    );
  }

  Future<void> _cancelBatch(
    QueryDocumentSnapshot<Map<String, dynamic>> batch,
  ) async {
    final data = batch.data();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('発注表を取消しますか？'),
        content: Text(
          '${_batchTitle(data)}を取消します。\n\nこのPDFに含まれる発注数を納品予定から差し引きます。\n在庫数は変更しません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('やめる'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('取消する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final ordersRef = AppSession.doc('orders');
      final ordersSnap = await ordersRef.get();
      final ordersData = ordersSnap.data() ?? <String, dynamic>{};
      final updates = <String, dynamic>{};

      // 発注表取消により納品予定を差し引き。在庫数は変更しない。
      for (final item in _batchItems(data)) {
        final typeKey = (item['typeKey'] ?? '').toString();
        final storeId = (item['storeId'] ?? '').toString();
        final itemId = (item['itemId'] ?? '').toString();
        final qty = _toInt(item['qty']);
        if (typeKey.isEmpty || storeId.isEmpty || itemId.isEmpty || qty <= 0) {
          continue;
        }

        var currentQty = 0;
        final typeRaw = ordersData[typeKey];
        if (typeRaw is Map) {
          final storeRaw = typeRaw[storeId];
          if (storeRaw is Map) currentQty = _toInt(storeRaw[itemId]);
        }
        final nextQty = max(0, currentQty - qty);
        final orderPath = '$typeKey.$storeId.$itemId';
        final metaPath = '_meta.${typeKey}__${storeId}__$itemId';
        if (nextQty <= 0) {
          updates[orderPath] = FieldValue.delete();
          updates[metaPath] = FieldValue.delete();
        } else {
          updates[orderPath] = nextQty;
          updates['$metaPath.lastRequestedQty'] = nextQty;
          updates['$metaPath.requestedAt'] = FieldValue.serverTimestamp();
          updates['$metaPath.requestedBy'] = AppSession.nickname;
        }
      }

      if (updates.isNotEmpty) {
        await ordersRef.update(updates);
      }
      await batch.reference.update({
        'status': 'canceled',
        'canceledAt': FieldValue.serverTimestamp(),
        'canceledAtLocal': DateTime.now().toIso8601String(),
        'canceledBy': AppSession.nickname,
      });
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('発注表を取消し、納品予定から差し引きました'),
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
    }
  }

  Widget _buildBatchCard(QueryDocumentSnapshot<Map<String, dynamic>> batch) {
    final data = batch.data();
    final items = _batchItems(data);
    final deliveredMap = data['deliveredMap'];
    final deliveredCount = deliveredMap is Map ? deliveredMap.length : 0;
    final totalQty = items.fold<int>(
      0,
      (sum, item) => sum + _toInt(item['qty']),
    );
    final canceled = (data['status'] ?? '') == 'canceled';
    final hasSavedPdf = _hasSavedPdf(data);
    final pdfKind = (data['pdfKind'] ?? '').toString();
    final pdfKindLabel = pdfKind == 'store'
        ? '店舗別'
        : (pdfKind == 'item' ? '商品別' : '保存済み');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _batchTitle(data),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '発注確定: ${_formatDateTime(_batchDate(data))}\n発注者: ${(data['createdBy'] ?? '').toString().isEmpty ? '-' : data['createdBy']}\n品目数: ${items.length} / 発注総数: $totalQty / 納品済み: $deliveredCount${hasSavedPdf ? '\n保存PDFあり: $pdfKindLabel' : '\n保存PDFなし: 旧形式のため再作成'}${canceled ? '\n取消済み' : ''}',
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            if (hasSavedPdf) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: canceled ? null : () => _openSavedPdf(batch),
                  icon: const Icon(Icons.picture_as_pdf, size: 18),
                  label: Text('保存PDFを開く（$pdfKindLabel）'),
                ),
              ),
              if (_hasEmbeddedPdf(data)) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: canceled
                        ? null
                        : () => _separateEmbeddedPdf(batch),
                    icon: const Icon(Icons.compress, size: 18),
                    label: const Text('保存PDFを分離して軽量化'),
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: items.isEmpty || canceled
                        ? null
                        : () => _exportPdfByStore(batch),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('店舗別を再作成'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: items.isEmpty || canceled
                        ? null
                        : () => _exportPdfByItem(batch),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('商品別を再作成'),
                  ),
                ),
              ],
            ),
            if (!canceled) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () => _cancelBatch(batch),
                  icon: const Icon(Icons.cancel_outlined, color: Colors.red),
                  label: const Text(
                    'この発注表を取消',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('過去の発注表'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText('読み取りエラー\n\n$_error'),
              )
            : _batches.isEmpty
            ? const Center(child: Text('過去の発注表はありません'))
            : Builder(
                builder: (context) {
                  final visibleBatches = _batches.take(_visibleCount).toList();
                  final hasMore = visibleBatches.length < _batches.length;
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: 2 + visibleBatches.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return const Card(
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              '発注確定PDFを出した時点の発注表を再出力できます。ここでは在庫や発注数は変更しません。',
                            ),
                          ),
                        );
                      }
                      if (index == 1) return const SizedBox(height: 12);
                      final batchIndex = index - 2;
                      if (batchIndex < visibleBatches.length) {
                        return _buildBatchCard(visibleBatches[batchIndex]);
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              _visibleCount = min(
                                _visibleCount + 20,
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
    );
  }
}
