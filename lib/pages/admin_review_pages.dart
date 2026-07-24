part of '../main.dart';

// ─────────────────────────────────────────────
// 承認待ちページ
// ─────────────────────────────────────────────

class PendingApprovalPage extends StatefulWidget {
  const PendingApprovalPage({super.key});
  @override
  State<PendingApprovalPage> createState() => _PendingApprovalPageState();
}

class _PendingApprovalPageState extends State<PendingApprovalPage> {
  bool _checking = false;

  Future<void> _refresh() async {
    setState(() => _checking = true);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .get();
      final approved = (doc.data()?['approved'] as bool?) ?? false;
      AppSession.approved = approved;
      if (approved && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const StoreListPage()),
          (_) => false,
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('まだ承認されていません。しばらくお待ちください。')),
        );
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.hourglass_top_rounded,
                size: 72,
                color: Colors.deepPurple.shade300,
              ),
              const SizedBox(height: 24),
              const Text(
                '承認待ち',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Text(
                '組織「${AppSession.orgName.isNotEmpty ? AppSession.orgName : AppSession.orgId}」の管理者承認を申請中です。\n統括管理者の承認をお待ちください。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 8),
              Text(
                AppSession.email,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 32),
              _checking
                  ? const CircularProgressIndicator()
                  : ElevatedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('承認状況を確認'),
                      onPressed: _refresh,
                    ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () async {
                  await FirebaseAuth.instance.signOut();
                  AppSession.clear();
                  if (context.mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const AuthGate()),
                      (_) => false,
                    );
                  }
                },
                child: const Text(
                  'ログアウト',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 統括管理ページ（re.start.niigata@gmail.com 専用）
// ─────────────────────────────────────────────

class SuperAdminPage extends StatefulWidget {
  const SuperAdminPage({super.key});

  @override
  State<SuperAdminPage> createState() => _SuperAdminPageState();
}

class _SuperAdminPageState extends State<SuperAdminPage> {
  List<Map<String, dynamic>> _orgs = [];
  bool _loading = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('orgs')
          .orderBy('name')
          .get();
      setState(() {
        _orgs = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_search.isEmpty) return _orgs;
    final q = _search.toLowerCase();
    return _orgs.where((o) {
      final name = (o['name'] as String? ?? '').toLowerCase();
      final nick = (o['adminNickname'] as String? ?? '').toLowerCase();
      final mail = (o['adminEmail'] as String? ?? '').toLowerCase();
      final id = (o['id'] as String? ?? '').toLowerCase();
      return name.contains(q) ||
          nick.contains(q) ||
          mail.contains(q) ||
          id.contains(q);
    }).toList();
  }

  Future<void> _toggleApproval(String orgId, bool current) async {
    final newVal = !current;
    await FirebaseFirestore.instance.collection('orgs').doc(orgId).update({
      'approved': newVal,
    });
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) _orgs[idx]['approved'] = newVal;
    });
  }

  Future<void> _toggleAdView(String orgId, bool current) async {
    final newVal = !current;
    await FirebaseFirestore.instance.collection('orgs').doc(orgId).update({
      'adViewEnabled': newVal,
    });
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) _orgs[idx]['adViewEnabled'] = newVal;
    });
  }

  Future<void> _editLimits(
    String orgId,
    int currentMaxStores,
    int currentMaxUsers,
  ) async {
    final storesCtrl = TextEditingController(text: currentMaxStores.toString());
    final usersCtrl = TextEditingController(text: currentMaxUsers.toString());

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('店舗数・ユーザー数の上限変更'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: storesCtrl,
              decoration: const InputDecoration(labelText: '最大店舗数'),
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: usersCtrl,
              decoration: const InputDecoration(labelText: '最大ユーザー数'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != true) return;
    final newMaxStores =
        int.tryParse(storesCtrl.text.trim()) ?? currentMaxStores;
    final newMaxUsers = int.tryParse(usersCtrl.text.trim()) ?? currentMaxUsers;
    if (newMaxStores == currentMaxStores && newMaxUsers == currentMaxUsers) {
      return;
    }
    await FirebaseFirestore.instance.collection('orgs').doc(orgId).update({
      'maxStores': newMaxStores,
      'maxUsers': newMaxUsers,
    });
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) {
        _orgs[idx]['maxStores'] = newMaxStores;
        _orgs[idx]['maxUsers'] = newMaxUsers;
      }
    });
  }

  Future<void> _toggleAdDistrib(String orgId, bool current) async {
    final newVal = !current;
    await FirebaseFirestore.instance.collection('orgs').doc(orgId).update({
      'adDistribEnabled': newVal,
    });
    setState(() {
      final idx = _orgs.indexWhere((o) => o['id'] == orgId);
      if (idx != -1) _orgs[idx]['adDistribEnabled'] = newVal;
    });
  }

  Future<void> _syncAllAds() async {
    setState(() => _loading = true);
    try {
      final fs = FirebaseFirestore.instance;
      final snap = await fs.collection('orgs').get();
      final batch = fs.batch();
      for (final doc in snap.docs) {
        final data = doc.data();
        final hasAd = _orgHasAdContent(data);
        // 広告あり → 配信ON、なし → 配信OFFに統一
        batch.update(doc.reference, {'adDistribEnabled': hasAd});
      }
      await batch.commit();
      // 広告リストを再構築
      await _load();
      // AppSession の distributedAds も更新
      final orgDoc = await fs.collection('orgs').doc(AppSession.orgId).get();
      if (orgDoc.exists) {
        await _loadAllAdsImpl(fs, ownOrgData: orgDoc.data()!);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('全組織の広告配信状態を更新しました')));
      }
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _toggleChip(
    String label,
    bool value,
    Color activeColor,
    VoidCallback onTap, {
    Color? offColor,
  }) {
    final color = value ? activeColor : (offColor ?? Colors.grey);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.toggle_on : Icons.toggle_off,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrgTile(Map<String, dynamic> org) {
    final orgId = org['id'] as String;
    final name = (org['name'] as String?) ?? orgId;
    final adminNick = (org['adminNickname'] as String?) ?? '';
    final adminEmail = (org['adminEmail'] as String?) ?? '';
    final enabled = (org['adDistribEnabled'] as bool?) ?? false;
    final adView = (org['adViewEnabled'] as bool?) ?? true;
    final approved = (org['approved'] as bool?) ?? true;
    final maxStores = (org['maxStores'] as int?) ?? 5;
    final maxUsers = (org['maxUsers'] as int?) ?? 5;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 組織名 + 承認状態バッジ
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: approved
                      ? Colors.deepPurple.shade100
                      : Colors.orange.shade100,
                  radius: 18,
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: approved
                          ? Colors.deepPurple
                          : Colors.orange.shade800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        'ID: $orgId',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: approved
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: approved
                          ? Colors.green.shade300
                          : Colors.orange.shade300,
                    ),
                  ),
                  child: Text(
                    approved ? '承認済み' : '承認待ち',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: approved
                          ? Colors.green.shade700
                          : Colors.orange.shade700,
                    ),
                  ),
                ),
              ],
            ),
            // 管理者情報
            if (adminNick.isNotEmpty || adminEmail.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (adminNick.isNotEmpty)
                      Row(
                        children: [
                          Icon(
                            Icons.badge_outlined,
                            size: 13,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            adminNick,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    if (adminEmail.isNotEmpty)
                      Row(
                        children: [
                          Icon(
                            Icons.email_outlined,
                            size: 13,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            adminEmail,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            // 上限情報
            Text(
              '上限: 店舗 $maxStores / ユーザー $maxUsers',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            // トグル行
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                // 広告配信トグル
                _toggleChip(
                  '広告配信',
                  enabled,
                  Colors.teal,
                  () => _toggleAdDistrib(orgId, enabled),
                ),
                // 広告表示トグル
                _toggleChip(
                  '広告表示',
                  adView,
                  Colors.indigo,
                  () => _toggleAdView(orgId, adView),
                ),
                // 承認トグル
                _toggleChip(
                  '承認',
                  approved,
                  Colors.green,
                  () => _toggleApproval(orgId, approved),
                  offColor: Colors.orange,
                ),
                // 上限編集ボタン
                IconButton(
                  icon: const Icon(Icons.tune, size: 20),
                  tooltip: '上限を変更',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _editLimits(orgId, maxStores, maxUsers),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _filtered
        .where((o) => (o['approved'] as bool?) == false)
        .toList();
    final approved = _filtered
        .where((o) => (o['approved'] as bool?) != false)
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('統括管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.campaign),
            tooltip: '全組織の広告配信を同期',
            onPressed: _loading ? null : _syncAllAds,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 検索バー
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    onChanged: (v) => setState(() => _search = v),
                    decoration: InputDecoration(
                      hintText: '組織名・管理者名・メールで検索',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  child: _orgs.isEmpty
                      ? const Center(child: Text('組織が見つかりません'))
                      : ListView(
                          children: [
                            // 承認待ちセクション
                            if (pending.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.hourglass_top,
                                      size: 16,
                                      color: Colors.orange.shade700,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '承認待ち (${pending.length}件)',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.orange.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ...pending.map(_buildOrgTile),
                              const Divider(height: 24),
                            ],
                            // 承認済みセクション
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.check_circle_outline,
                                    size: 16,
                                    color: Colors.green.shade700,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '承認済み (${approved.length}件)',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ...approved.map(_buildOrgTile),
                            const SizedBox(height: 16),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────
// 特別発注・新規発注ページ
// 実装は lib/pages/special_order_page.dart に分離
// ─────────────────────────────────────────────
