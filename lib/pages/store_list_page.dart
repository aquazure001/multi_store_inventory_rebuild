part of '../main.dart';

// ─────────────────────────────────────────────
// 店舗一覧ページ
// ─────────────────────────────────────────────

class StoreListPage extends StatefulWidget {
  const StoreListPage({super.key});

  @override
  State<StoreListPage> createState() => _StoreListPageState();
}

class _StoreListPageState extends State<StoreListPage> {
  List<LegacyStore> _stores = [];
  bool _loading = true;
  String? _error;
  Timer? _adReloadTimer;

  @override
  void initState() {
    super.initState();
    _loadStores();
    // 広告は画面表示を待たせず、背景で読み込む。
    unawaited(
      _reloadAds().then((_) {
        if (mounted) setState(() {});
      }),
    );
    // 10分ごとに広告を再読み込み（削除済み組織の広告を除外するため）
    _adReloadTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      _reloadAds();
    });
  }

  @override
  void dispose() {
    _adReloadTimer?.cancel();
    super.dispose();
  }

  Future<void> _reloadAds() async {
    if (!AppSession.adViewEnabled || AppSession.orgId.isEmpty) return;
    try {
      final fs = FirebaseFirestore.instance;
      final orgDoc = await fs.collection('orgs').doc(AppSession.orgId).get();
      if (orgDoc.exists) {
        await _loadAllAdsImpl(fs, ownOrgData: orgDoc.data());
      }
    } catch (_) {}
  }

  Future<void> _loadStores() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final masterData = await _loadMasterData();
      setState(() {
        _stores = List<LegacyStore>.from(masterData.stores);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static Future<void> _showFullScreenAd(BuildContext context) async {
    // 現場の在庫操作を止めないため、店舗移動・発注リスト表示前の
    // 強制全画面広告は表示しない。広告は画面内カードと下部バナーで表示する。
    return;
  }

  Future<void> _addStore() async {
    final orgDoc = await FirebaseFirestore.instance
        .collection('orgs')
        .doc(AppSession.orgId)
        .get();
    final maxStores = (orgDoc.data()?['maxStores'] as int?) ?? 5;
    if (_stores.length >= maxStores) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('店舗数の上限（$maxStores店舗）に達しています'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final nameCtrl = TextEditingController();
    final codeCtrl = TextEditingController();
    final idCtrl = TextEditingController();

    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('店舗を追加'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '店舗名'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: codeCtrl,
              decoration: const InputDecoration(labelText: 'コード（表示用）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(labelText: '店舗ID（英数字）'),
              autocorrect: false,
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
            child: const Text('追加'),
          ),
        ],
      ),
    );
    if (result != true) return;

    final name = nameCtrl.text.trim();
    final code = codeCtrl.text.trim();
    final id = idCtrl.text.trim();
    if (name.isEmpty || id.isEmpty) return;

    try {
      await AppSession.doc('stores').update({
        'items': FieldValue.arrayUnion([
          {'id': id, 'code': code, 'name': name},
        ]),
      });
      _loadStores();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changeNickname() async {
    final ctrl = TextEditingController(text: AppSession.nickname);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ニックネームを変更'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'ニックネーム',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(AppSession.uid)
          .update({'nickname': result});
      AppSession.nickname = result;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ニックネームを変更しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changePassword() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? dialogError;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('パスワードを変更'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentCtrl,
                decoration: const InputDecoration(
                  labelText: '現在のパスワード',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newCtrl,
                decoration: const InputDecoration(
                  labelText: '新しいパスワード（6文字以上）',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                decoration: const InputDecoration(
                  labelText: '新しいパスワード（確認）',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 8),
                Text(
                  dialogError!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () {
                if (newCtrl.text != confirmCtrl.text) {
                  setS(() => dialogError = '新しいパスワードが一致しません');
                  return;
                }
                if (newCtrl.text.length < 6) {
                  setS(() => dialogError = 'パスワードは6文字以上で入力してください');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('変更'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    final current = currentCtrl.text;
    final newPass = newCtrl.text;
    try {
      final user = FirebaseAuth.instance.currentUser!;
      final cred = EmailAuthProvider.credential(
        email: user.email!,
        password: current,
      );
      await user.reauthenticateWithCredential(cred);
      await user.updatePassword(newPass);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('パスワードを変更しました')));
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        final msg =
            (e.code == 'wrong-password' || e.code == 'invalid-credential')
            ? '現在のパスワードが正しくありません'
            : 'エラー: ${e.code}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _leaveOrg() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('組織を脱退'),
        content: const Text('この組織から脱退しますか？\n脱退後は新しい組織を作成または別の組織に参加できます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('脱退', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(AppSession.uid)
          .update({'orgId': '', 'role': 'admin'});
      AppSession.orgId = '';
      AppSession.role = 'admin';
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const OrgSetupPage()),
          (_) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _goToReorder() {
    Navigator.of(context)
        .push<List<LegacyStore>>(
          MaterialPageRoute(builder: (_) => const StoreReorderPage()),
        )
        .then((result) {
          if (!mounted) return;
          if (result != null && result.isNotEmpty) {
            setState(() => _stores = result);
          } else {
            _loadStores();
          }
        });
  }

  Future<void> _openFeedback(String type) async {
    final labels = {
      'feature': ('機能追加依頼', Colors.blue, Icons.add_circle_outline),
      'fix': ('修正依頼', Colors.orange, Icons.build_outlined),
      'bug': ('バグ報告', Colors.red, Icons.bug_report_outlined),
    };
    final (label, color, icon) = labels[type]!;
    final contentCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (type == 'feature')
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: const Text(
                    '機能追加は無料で受け付けておりますが、確実に対応することをお約束するものではありません。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              Text(
                '送信者: ${AppSession.nickname.isNotEmpty ? AppSession.nickname : "（未設定）"}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              Text(
                'メール: ${FirebaseAuth.instance.currentUser?.email ?? ""}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentCtrl,
                maxLines: 5,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '内容',
                  hintText: type == 'bug'
                      ? 'どのような操作をしたときに、何が起きましたか？'
                      : '詳細を入力してください',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.send, size: 16),
            label: const Text('メールで送信'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    contentCtrl.dispose();
    if (confirmed != true || !mounted) return;

    final nick = AppSession.nickname.isNotEmpty ? AppSession.nickname : '未設定';
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final body = Uri.encodeComponent(
      'ニックネーム: $nick\nメールアドレス: $email\n\n--- 内容 ---\n${contentCtrl.text.trim()}',
    );
    final subject = Uri.encodeComponent('【$label】多店舗在庫管理システム');
    final uri = Uri.parse(
      'mailto:info@happy-bluebird.co.jp?subject=$subject&body=$body',
    );
    try {
      await launchUrl(uri);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'メールアプリが見つかりませんでした。info@happy-bluebird.co.jp までご連絡ください。',
            ),
          ),
        );
      }
    }
  }

  Future<void> _deleteAccount() async {
    final passCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アカウントを削除'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'この操作は元に戻せません。\nアカウントを完全に削除します。',
              style: TextStyle(color: Colors.red, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passCtrl,
              decoration: const InputDecoration(
                labelText: 'パスワードを入力して確認',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              autofocus: true,
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
            child: const Text('削除する', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || passCtrl.text.isEmpty) return;

    try {
      final user = FirebaseAuth.instance.currentUser!;
      final credential = EmailAuthProvider.credential(
        email: AppSession.email,
        password: passCtrl.text,
      );
      await user.reauthenticateWithCredential(credential);

      final fs = FirebaseFirestore.instance;
      await fs.collection('users').doc(AppSession.uid).delete();
      AppSession.clear();

      try {
        await user.delete();
      } catch (_) {
        await FirebaseAuth.instance.signOut();
      }

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AuthGate()),
          (_) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              (e.code == 'wrong-password' || e.code == 'invalid-credential')
                  ? 'パスワードが正しくありません'
                  : '認証エラー: ${e.code}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _manualUpdateApp() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アプリを最新の状態にしますか？'),
        content: const Text('最新のアプリを読み直します。\n入力途中の内容がある場合は、先に保存してください。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('更新する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      js.context.callMethod('eval', [
        r"""
(function() {
  var stamp = Date.now();
  var target = '/force_update.html?t=' + stamp;
  try {
    if (window.location && window.location.origin) {
      target = window.location.origin + target;
    }
  } catch (e) {}
  window.location.href = target;
})();
""",
      ]);
    } catch (_) {
      html.window.location.href =
          '/force_update.html?t=${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        leading: AppSession.logoUrl.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.all(8),
                child: ClipOval(
                  child: Image.memory(
                    base64Decode(AppSession.logoUrl),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.business),
                  ),
                ),
              )
            : null,
        title: Text(
          AppSession.orgName.isNotEmpty ? AppSession.orgName : '店舗一覧',
        ),
        actions: [
          if (AppSession.isSuperAdmin)
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('orgs')
                  .where('approved', isEqualTo: false)
                  .snapshots(),
              builder: (context, snap) {
                final count = snap.data?.docs.length ?? 0;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.notifications_outlined),
                      tooltip: '承認待ち管理者',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SuperAdminPage(),
                        ),
                      ),
                    ),
                    if (count > 0)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '$count',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'manual_update') {
                await _manualUpdateApp();
              } else if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SettingsPage(
                      onManualUpdate: _manualUpdateApp,
                      onChangeNickname: _changeNickname,
                      onChangePassword: _changePassword,
                      onLeaveOrg: _leaveOrg,
                      onDeleteAccount: _deleteAccount,
                    ),
                  ),
                );
              } else if (value == 'all_stores') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AllStoresInventoryPage(),
                  ),
                );
              } else if (value == 'history') {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const HistoryPage()));
              } else if (value == 'inventory_snapshot') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const InventorySnapshotPage(),
                  ),
                );
              } else if (value == 'items') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ItemMasterPage()),
                );
              } else if (value == 'special_order') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SpecialOrderPage()),
                );
              } else if (value == 'order') {
                final navigator = Navigator.of(context);
                await _showFullScreenAd(context);
                if (!mounted) return;
                navigator.push(
                  MaterialPageRoute(builder: (_) => const OrderListPage()),
                );
              } else if (value == 'delivery') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DeliveryProcessingPage(),
                  ),
                );
              } else if (value == 'past_orders') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PastOrderPdfPage()),
                );
              } else if (value == 'order_request_history') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const OrderRequestHistoryPage(),
                  ),
                );
              } else if (value == 'reorder') {
                _goToReorder();
              } else if (value == 'org') {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OrgManagementPage()),
                );
                if (mounted) {
                  await _reloadAds();
                  setState(() {});
                }
              } else if (value == 'ad') {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdManagementPage()),
                );
                if (mounted) {
                  await _reloadAds();
                  setState(() {});
                }
              } else if (value == 'superadmin') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SuperAdminPage()),
                );
              } else if (value == 'nickname') {
                _changeNickname();
              } else if (value == 'password') {
                _changePassword();
              } else if (value == 'leave') {
                _leaveOrg();
              } else if (value == 'terms') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LegalPage(
                      title: '利用規約',
                      content: _kTermsOfService,
                    ),
                  ),
                );
              } else if (value == 'privacy') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LegalPage(
                      title: 'プライバシーポリシー',
                      content: _kPrivacyPolicy,
                    ),
                  ),
                );
              } else if (value == 'feedback_feature') {
                _openFeedback('feature');
              } else if (value == 'feedback_fix') {
                _openFeedback('fix');
              } else if (value == 'feedback_bug') {
                _openFeedback('bug');
              } else if (value == 'logout') {
                FirebaseAuth.instance.signOut();
                AppSession.clear();
              } else if (value == 'delete_account') {
                _deleteAccount();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'manual_update',
                child: Row(
                  children: [
                    Icon(Icons.system_update_alt),
                    SizedBox(width: 12),
                    Text('最新の更新を反映'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings),
                    SizedBox(width: 12),
                    Text('設定'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'all_stores',
                child: Row(
                  children: [
                    Icon(Icons.table_chart),
                    SizedBox(width: 12),
                    Text('全店舗在庫確認'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'history',
                child: Row(
                  children: [
                    Icon(Icons.history),
                    SizedBox(width: 12),
                    Text('修正・追加履歴'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'inventory_snapshot',
                child: Row(
                  children: [
                    Icon(Icons.event_note),
                    SizedBox(width: 12),
                    Text('棚卸し一覧出力'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'items',
                child: Row(
                  children: [
                    Icon(Icons.inventory_2),
                    SizedBox(width: 12),
                    Text('商品マスタ管理'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'order',
                child: Row(
                  children: [
                    Icon(Icons.shopping_cart),
                    SizedBox(width: 12),
                    Text('発注リスト'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delivery',
                child: Row(
                  children: [
                    Icon(Icons.local_shipping_outlined),
                    SizedBox(width: 12),
                    Text('納品処理'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'past_orders',
                child: Row(
                  children: [
                    Icon(Icons.receipt_long),
                    SizedBox(width: 12),
                    Text('過去の発注表'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'order_request_history',
                child: Row(
                  children: [
                    Icon(Icons.history_edu),
                    SizedBox(width: 12),
                    Text('発注ボタン履歴'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'special_order',
                child: Row(
                  children: [
                    Icon(Icons.star_border),
                    SizedBox(width: 12),
                    Text('特別発注・新規発注'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'reorder',
                child: Row(
                  children: [
                    Icon(Icons.reorder),
                    SizedBox(width: 12),
                    Text('店舗の並び替え'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              if (AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'org',
                  child: Row(
                    children: [
                      Icon(Icons.manage_accounts),
                      SizedBox(width: 12),
                      Text('組織管理'),
                    ],
                  ),
                ),
              if (AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'ad',
                  child: Row(
                    children: [
                      Icon(Icons.campaign),
                      SizedBox(width: 12),
                      Text('広告スペース管理'),
                    ],
                  ),
                ),
              if (AppSession.isSuperAdmin)
                const PopupMenuItem(
                  value: 'superadmin',
                  child: Row(
                    children: [
                      Icon(
                        Icons.admin_panel_settings,
                        color: Colors.deepPurple,
                      ),
                      SizedBox(width: 12),
                      Text('統括管理', style: TextStyle(color: Colors.deepPurple)),
                    ],
                  ),
                ),
              if (!AppSession.isAdmin)
                const PopupMenuItem(
                  value: 'leave',
                  child: Row(
                    children: [
                      Icon(Icons.exit_to_app, color: Colors.orange),
                      SizedBox(width: 12),
                      Text('組織を脱退', style: TextStyle(color: Colors.orange)),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'nickname',
                child: Row(
                  children: [
                    Icon(Icons.badge_outlined),
                    SizedBox(width: 12),
                    Text('ニックネーム変更'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'password',
                child: Row(
                  children: [
                    Icon(Icons.lock_outline),
                    SizedBox(width: 12),
                    Text('パスワード変更'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'terms',
                child: Row(
                  children: [
                    Icon(Icons.article_outlined),
                    SizedBox(width: 12),
                    Text('利用規約'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'privacy',
                child: Row(
                  children: [
                    Icon(Icons.privacy_tip_outlined),
                    SizedBox(width: 12),
                    Text('プライバシーポリシー'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'feedback_feature',
                child: Row(
                  children: [
                    Icon(Icons.add_circle_outline, color: Colors.blue),
                    SizedBox(width: 12),
                    Text('機能追加依頼'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'feedback_fix',
                child: Row(
                  children: [
                    Icon(Icons.build_outlined, color: Colors.orange),
                    SizedBox(width: 12),
                    Text('修正依頼'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'feedback_bug',
                child: Row(
                  children: [
                    Icon(Icons.bug_report_outlined, color: Colors.red),
                    SizedBox(width: 12),
                    Text('バグ報告'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.red),
                    SizedBox(width: 12),
                    Text('ログアウト', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'delete_account',
                child: Row(
                  children: [
                    Icon(Icons.delete_forever, color: Colors.red),
                    SizedBox(width: 12),
                    Text('アカウント削除', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                enabled: false,
                child: Text(
                  'v$_appVersion',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: SelectableText('読み取りエラー\n\n$_error'),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: 6 + _stores.length,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return const Text(
                            '多店舗在庫管理システム',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          );
                        }
                        if (index == 1) return const SizedBox(height: 4);
                        if (index == 2) {
                          return Text(
                            '組織: ${AppSession.orgId.isEmpty ? "（未設定）" : AppSession.orgId}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppSession.orgId == 'legacy'
                                  ? Colors.green.shade700
                                  : Colors.orange.shade700,
                              fontSize: 13,
                            ),
                          );
                        }
                        if (index == 3) return const SizedBox(height: 24);
                        if (index == 4) {
                          return Card(
                            child: ListTile(
                              title: const Text('店舗数'),
                              trailing: Text(
                                '${_stores.length} 件',
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          );
                        }
                        if (index == 5) {
                          return const Column(
                            children: [
                              SizedBox(height: 8),
                              AdInlineCardWidget(),
                              SizedBox(height: 8),
                            ],
                          );
                        }

                        final store = _stores[index - 6];
                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text(
                                store.code.isEmpty ? '-' : store.code,
                              ),
                            ),
                            title: Text(
                              store.name,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(store.id),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              final navigator = Navigator.of(context);
                              await _showFullScreenAd(context);
                              if (!mounted) return;
                              navigator.push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      StoreInventoryPage(store: store),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: AppSession.isAdmin
          ? Padding(
              padding: const EdgeInsets.only(bottom: 88),
              child: FloatingActionButton(
                onPressed: _addStore,
                tooltip: '店舗を追加',
                child: const Icon(Icons.add),
              ),
            )
          : null,
    );
  }
}
