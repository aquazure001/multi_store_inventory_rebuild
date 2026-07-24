part of '../main.dart';

// ─────────────────────────────────────────────
// セッション（グローバル状態）
// ─────────────────────────────────────────────

class AppSession {
  static String uid = '';
  static String orgId = '';
  static String role = '';
  static String email = '';
  static String orgName = '';
  static String logoUrl = '';
  static String nickname = '';
  static int adSlotBase = -1;
  static List<_AdEntry> distributedAds = [];
  static bool approved = true; // 既存組織はデフォルト承認済み
  static bool adViewEnabled = true; // 広告表示（デフォルトON）

  static bool get isAdmin => role == 'admin';
  static bool get hasOrg => orgId.isNotEmpty;
  static bool get isSuperAdmin => email == 're.start.niigata@gmail.com';

  static void clear() {
    uid = orgId = role = email = orgName = logoUrl = nickname = '';
    adSlotBase = -1;
    distributedAds = [];
    approved = true;
    adViewEnabled = true;
  }

  static DocumentReference<Map<String, dynamic>> doc(String suffix) =>
      FirebaseFirestore.instance
          .collection('inventory_shared_v1')
          .doc('org_${orgId}__$suffix');

  static DocumentReference<Map<String, dynamic>> get stocksDoc => doc('stocks');
  static DocumentReference<Map<String, dynamic>> get stocksV2Doc =>
      doc('stocks_v2');
  static DocumentReference<Map<String, dynamic>> get baselineDoc =>
      doc('baseline');
  static DocumentReference<Map<String, dynamic>> get ordersDoc => doc('orders');

  static CollectionReference<Map<String, dynamic>> get orderBatches =>
      ordersDoc.collection('batches');
}

// 広告エントリ（スロット番号付き）
class _AdEntry {
  final String orgId;
  final String orgName;
  final String image;
  final String message;
  final String url;
  final int slotNumber;
  const _AdEntry({
    required this.orgId,
    required this.orgName,
    required this.image,
    required this.message,
    required this.url,
    required this.slotNumber,
  });
}

// ─────────────────────────────────────────────
// 広告ユーティリティ（グローバル）
// ─────────────────────────────────────────────

bool _orgHasAdContent(Map<String, dynamic> data) {
  final rawSlots = data['adSlots'];
  if (rawSlots is List) {
    return rawSlots.any(
      (s) =>
          s is Map &&
          (((s['image'] as String?) ?? '').isNotEmpty ||
              ((s['message'] as String?) ?? '').isNotEmpty),
    );
  }
  return ((data['adImage'] as String?) ?? '').isNotEmpty ||
      ((data['adMessage'] as String?) ?? '').isNotEmpty;
}

// ownOrgData: _UserLoader._load で既に読み込んだ自組織データ（再読み取り不要）
Future<void> _loadAllAdsImpl(
  FirebaseFirestore fs, {
  Map<String, dynamic>? ownOrgData,
}) async {
  final entries = <_AdEntry>[];
  int fallbackSlot = 10000;

  void addFromDoc(String docId, Map<String, dynamic> data) {
    final slotBase = (data['adSlotBase'] as int?) ?? -1;
    final orgName = (data['name'] as String?) ?? docId;
    bool addedAny = false;

    // 新形式: adSlots
    final rawSlots = data['adSlots'];
    if (rawSlots is List) {
      for (int i = 0; i < rawSlots.length; i++) {
        final slot = rawSlots[i];
        if (slot is! Map) continue;
        final image = (slot['image'] as String?) ?? '';
        final message = (slot['message'] as String?) ?? '';
        final url = (slot['url'] as String?) ?? '';
        if (image.isEmpty && message.isEmpty) continue;
        final base = slotBase >= 0 ? slotBase : fallbackSlot++;
        entries.add(
          _AdEntry(
            orgId: docId,
            orgName: orgName,
            image: image,
            message: message,
            url: url,
            slotNumber: base + i,
          ),
        );
        addedAny = true;
      }
    }

    // レガシー互換: adSlots に有効なエントリがない場合は adImage/adMessage を使用
    if (!addedAny) {
      final image = (data['adImage'] as String?) ?? '';
      final message = (data['adMessage'] as String?) ?? '';
      if (image.isNotEmpty || message.isNotEmpty) {
        final base = slotBase >= 0 ? slotBase : fallbackSlot++;
        entries.add(
          _AdEntry(
            orgId: docId,
            orgName: orgName,
            image: image,
            message: message,
            url: '',
            slotNumber: base,
          ),
        );
      }
    }
  }

  // ① 自組織（_load で読み込み済みのデータを使用 → Firestore 再読み取り不要）
  if (AppSession.orgId.isNotEmpty && ownOrgData != null) {
    addFromDoc(AppSession.orgId, ownOrgData);
  }

  // ② 他組織の広告を取得。
  // 全組織を読むと起動やトップ画面が重くなるため、配信ONの広告だけ読む。
  try {
    final snap = await fs
        .collection('orgs')
        .where('adDistribEnabled', isEqualTo: true)
        .limit(50)
        .get();
    for (final doc in snap.docs) {
      if (doc.id == AppSession.orgId) continue;
      if (entries.any((e) => e.orgId == doc.id)) continue;
      addFromDoc(doc.id, doc.data());
    }
  } catch (_) {}

  entries.sort((a, b) => a.slotNumber.compareTo(b.slotNumber));
  AppSession.distributedAds = entries;
}

Future<int> _assignAdSlotBase(
  FirebaseFirestore fs,
  String orgId,
  bool isSuperAdmin,
) async {
  if (isSuperAdmin) {
    await fs.collection('orgs').doc(orgId).update({
      'adSlotBase': 0,
      'adDistribEnabled': true,
    });
    return 0;
  }
  try {
    final snap = await fs
        .collection('orgs')
        .where('adSlotBase', isGreaterThanOrEqualTo: 5)
        .get();
    int maxBase = 2; // 初回割り当ては5になるよう
    for (final doc in snap.docs) {
      if (doc.id == orgId) continue;
      final base = (doc.data()['adSlotBase'] as int?) ?? 0;
      if (base > maxBase) maxBase = base;
    }
    final newBase = maxBase >= 5 ? maxBase + 3 : 5;
    await fs.collection('orgs').doc(orgId).update({'adSlotBase': newBase});
    return newBase;
  } catch (_) {
    return -1;
  }
}
