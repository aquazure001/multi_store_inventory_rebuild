part of '../main.dart';

// ─────────────────────────────────────────────
// 納品記録アーカイブ
// orders._deliveredBatches は納品のたびに増え続け、orders を読む全画面
// （店舗在庫・発注リスト・納品処理など）を遅くする。
// 最終納品から一定期間たったバッチの記録は delivered_archive/entries/{batchId}
// に移し、orders からは削除する。記録自体は消さない。
// ─────────────────────────────────────────────

const Duration _deliveredArchiveAge = Duration(days: 30);

// 1回の書き込みが大きくなりすぎないよう、1回で移す記録数の上限。
const int _deliveredArchiveMaxRecordsPerRun = 400;

CollectionReference<Map<String, dynamic>> get _deliveredArchiveEntries =>
    AppSession.doc('delivered_archive').collection('entries');

Map<String, dynamic> _stringKeyedMap(Map raw) =>
    Map<String, dynamic>.from(raw.map((k, v) => MapEntry(k.toString(), v)));

DateTime? _deliveredRecordTime(dynamic record) {
  if (record is! Map) return null;
  final raw = record['deliveredAt'] ?? record['deliveredAtLocal'];
  if (raw is Timestamp) return raw.toDate();
  return DateTime.tryParse((raw ?? '').toString());
}

/// orders._deliveredBatches のうち、最終納品が [_deliveredArchiveAge] より古い
/// バッチをアーカイブへ移す。移したバッチ数を返す。
///
/// アーカイブへの書き込みと orders からの削除は1つの WriteBatch で行うため、
/// 途中で失敗しても記録が消えたり二重になったりしない。
/// orders からは記録単位で削除するので、同時に同じバッチへ納品があっても消さない。
Future<int> _archiveOldDeliveredBatches(Map<String, dynamic> ordersData) async {
  final rawBatches = ordersData['_deliveredBatches'];
  if (rawBatches is! Map) return 0;

  final cutoff = DateTime.now().subtract(_deliveredArchiveAge);
  final writes = FirebaseFirestore.instance.batch();
  final ordersUpdates = <Object, Object?>{};
  var batchCount = 0;
  var recordCount = 0;

  for (final entry in rawBatches.entries) {
    if (recordCount >= _deliveredArchiveMaxRecordsPerRun) break;
    final batchId = entry.key.toString();
    final rawMap = entry.value;
    if (rawMap is! Map) continue;

    // 以前のアーカイブで空になったバッチは枠ごと削除する。
    if (rawMap.isEmpty) {
      ordersUpdates[FieldPath(['_deliveredBatches', batchId])] =
          FieldValue.delete();
      continue;
    }

    DateTime? latest;
    var hasUnknownTime = false;
    for (final record in rawMap.values) {
      final time = _deliveredRecordTime(record);
      if (time == null) {
        hasUnknownTime = true;
        break;
      }
      if (latest == null || time.isAfter(latest)) latest = time;
    }
    // 日時が読めない記録を含むバッチは安全のため移さない。
    if (hasUnknownTime || latest == null || latest.isAfter(cutoff)) continue;

    final deliveredMap = _stringKeyedMap(rawMap);
    writes.set(_deliveredArchiveEntries.doc(batchId), {
      'batchId': batchId,
      'deliveredMap': deliveredMap,
      'lastDeliveredAtLocal': latest.toIso8601String(),
      'archivedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    for (final key in deliveredMap.keys) {
      ordersUpdates[FieldPath(['_deliveredBatches', batchId, key])] =
          FieldValue.delete();
    }
    batchCount++;
    recordCount += deliveredMap.length;
  }

  if (ordersUpdates.isEmpty) return 0;
  writes.update(AppSession.ordersDoc, ordersUpdates);
  await writes.commit();
  return batchCount;
}

/// 指定した発注バッチのアーカイブ済み納品記録を batchId ごとに返す。
Future<Map<String, Map<String, dynamic>>> _loadArchivedDeliveredMaps(
  Iterable<String> batchIds,
) async {
  final ids = batchIds.where((id) => id.isNotEmpty).toSet().toList();
  final result = <String, Map<String, dynamic>>{};
  for (var i = 0; i < ids.length; i += 10) {
    final chunk = ids.sublist(i, min(i + 10, ids.length));
    final snap = await _deliveredArchiveEntries
        .where(FieldPath.documentId, whereIn: chunk)
        .get();
    for (final doc in snap.docs) {
      final map = doc.data()['deliveredMap'];
      if (map is Map) result[doc.id] = _stringKeyedMap(map);
    }
  }
  return result;
}

/// [since] より後に納品があったアーカイブ済み納品記録をすべて返す。
Future<List<Map<String, dynamic>>> _loadArchivedDeliveriesSince(
  DateTime since,
) async {
  final snap = await _deliveredArchiveEntries
      .where('lastDeliveredAtLocal', isGreaterThan: since.toIso8601String())
      .get();
  final records = <Map<String, dynamic>>[];
  for (final doc in snap.docs) {
    final map = doc.data()['deliveredMap'];
    if (map is! Map) continue;
    for (final raw in map.values) {
      if (raw is Map) records.add(_stringKeyedMap(raw));
    }
  }
  return records;
}
