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
  static List<AdEntry> distributedAds = [];
  static bool approved = true; // 既存組織はデフォルト承認済み
  static bool adViewEnabled = true; // 広告表示（デフォルトON）
  static List<String> storeIds = []; // 閲覧を許可されている店舗（空＝閲覧可能な店舗なし）

  static bool get isAdmin => role == 'admin';
  static bool get hasOrg => orgId.isNotEmpty;
  static bool get isSuperAdmin => email == 're.start.niigata@gmail.com';

  static void clear() {
    uid = orgId = role = email = orgName = logoUrl = nickname = '';
    adSlotBase = -1;
    distributedAds = [];
    approved = true;
    adViewEnabled = true;
    storeIds = [];
  }

  // 閲覧可能な店舗IDの一覧を返す。
  // 管理者・統括管理者はstoreIdsの設定に関わらず全店舗（allStoreIds）を閲覧可能。
  // それ以外は自分のstoreIdsのみ（空なら閲覧できる店舗なし）。
  static List<String> viewableStoreIds(List<String> allStoreIds) {
    if (isAdmin || isSuperAdmin) return allStoreIds;
    return storeIds;
  }

  // 在庫数・発注リスト・特別発注・納品処理用。
  // billing_visibility は請求・受領・領収書だけを隠す設定なので、
  // 通常業務画面ではこの判定だけを使い、請求非開示の店舗も表示する。
  static List<String> operationalStoreIds(List<String> allStoreIds) =>
      viewableStoreIds(allStoreIds);

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

  static CollectionReference<Map<String, dynamic>> get billingInvoices =>
      doc('billing_invoices').collection('entries');

  static CollectionReference<Map<String, dynamic>> get billingInvoicePdfs =>
      doc('billing_invoice_pdfs').collection('entries');

  static CollectionReference<Map<String, dynamic>> get billingReceipts =>
      doc('billing_receipts').collection('entries');

  static CollectionReference<Map<String, dynamic>> get billingReceiptPdfs =>
      doc('billing_receipt_pdfs').collection('entries');

  static CollectionReference<Map<String, dynamic>> get posSales =>
      doc('pos_sales').collection('entries');

  static CollectionReference<Map<String, dynamic>> get posRegisterSessions =>
      doc('pos_register_sessions').collection('entries');

  static CollectionReference<Map<String, dynamic>> get posReceiptPdfs =>
      doc('pos_receipt_pdfs').collection('entries');

  static DocumentReference<Map<String, dynamic>> get posStripeSettingsDoc =>
      doc('pos_stripe_settings');

  static DocumentReference<Map<String, dynamic>> get storeQuantityLimitsDoc =>
      doc('store_quantity_limits');
}

// 広告エントリ（スロット番号付き）
class AdEntry {
  final String orgId;
  final String orgName;
  final String image;
  final String message;
  final String url;
  final int slotNumber;
  const AdEntry({
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
  final entries = <AdEntry>[];
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
          AdEntry(
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
          AdEntry(
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
