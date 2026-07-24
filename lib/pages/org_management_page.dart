part of '../main.dart';

// ─────────────────────────────────────────────
// 組織管理ページ（管理者専用）
// ─────────────────────────────────────────────

class OrgManagementPage extends StatefulWidget {
  const OrgManagementPage({super.key});

  @override
  State<OrgManagementPage> createState() => _OrgManagementPageState();
}

class _OrgManagementPageState extends State<OrgManagementPage> {
  List<Map<String, dynamic>> _members = [];
  String _orgName = '';
  String _logoUrl = '';
  String _inviteCode = '';
  bool _loading = true;
  bool _logoUploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fs = FirebaseFirestore.instance;
      final orgDoc = await fs.collection('orgs').doc(AppSession.orgId).get();
      final od = orgDoc.data() ?? {};
      _orgName = od['name']?.toString() ?? AppSession.orgId;
      _logoUrl = od['logoBase64']?.toString() ?? '';
      _inviteCode = od['inviteCode']?.toString().isNotEmpty == true
          ? od['inviteCode'].toString()
          : AppSession.orgId;

      final membersSnap = await fs
          .collection('users')
          .where('orgId', isEqualTo: AppSession.orgId)
          .get();

      setState(() {
        _members =
            membersSnap.docs.map((d) {
              final data = Map<String, dynamic>.from(d.data());
              data['uid'] = d.id;
              return data;
            }).toList()..sort((a, b) {
              if (a['role'] == 'admin' && b['role'] != 'admin') return -1;
              if (a['role'] != 'admin' && b['role'] == 'admin') return 1;
              return (a['email'] ?? '').compareTo(b['email'] ?? '');
            });
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // 組織名変更
  Future<void> _renameOrg() async {
    final ctrl = TextEditingController(text: _orgName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('組織名を変更'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新しい組織名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == _orgName) return;
    try {
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'name': newName});
      AppSession.orgName = newName;
      setState(() => _orgName = newName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ロゴ画像をアップロード
  Future<void> _uploadLogo() async {
    final picker = ImagePicker();
    XFile? picked;
    try {
      picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('画像の選択に失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    if (picked == null) return;

    setState(() => _logoUploading = true);
    Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (e) {
      setState(() => _logoUploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('この画像は読み込めません。別の画像を選んでください。'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('画像のデコードに失敗しました');
      final resized = img.copyResize(decoded, width: 400, height: -1);
      final compressed = img.encodeJpg(resized, quality: 70);
      final b64 = base64Encode(compressed);
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'logoBase64': b64});
      AppSession.logoUrl = b64;
      setState(() {
        _logoUrl = b64;
        _logoUploading = false;
      });
    } catch (e) {
      setState(() => _logoUploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ロゴ削除
  Future<void> _deleteLogo() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ロゴを削除'),
        content: const Text('ロゴ画像を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'logoBase64': ''});
      AppSession.logoUrl = '';
      setState(() => _logoUrl = '');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _logoPlaceholder() => Container(
    width: 100,
    height: 100,
    decoration: BoxDecoration(
      color: Colors.deepPurple.shade50,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.deepPurple.shade100, width: 1.5),
    ),
    child: Icon(
      Icons.add_photo_alternate,
      size: 40,
      color: Colors.deepPurple.shade200,
    ),
  );

  // 全在庫が0かチェック（0以外があれば false）
  Future<bool> _checkAllStocksZero() async {
    final stocksDoc = await AppSession.stocksDoc.get();
    if (stocksDoc.exists) {
      for (final storeData in (stocksDoc.data() ?? {}).values) {
        if (storeData is Map) {
          for (final v in storeData.values) {
            final n = v is num ? v.toInt() : 0;
            if (n > 0) return false;
          }
        }
      }
    }
    final v2Doc = await AppSession.stocksV2Doc.get();
    if (v2Doc.exists) {
      for (final typeData in (v2Doc.data() ?? {}).values) {
        if (typeData is Map) {
          for (final storeData in typeData.values) {
            if (storeData is Map) {
              for (final v in storeData.values) {
                final n = v is num ? v.toInt() : 0;
                if (n > 0) return false;
              }
            }
          }
        }
      }
    }
    return true;
  }

  Future<void> _deleteOrg() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    // 在庫チェック
    final allZero = await _checkAllStocksZero();
    if (!allZero) {
      setState(() {
        _error = '在庫が残っている商品があります。\nすべての在庫を0にしてから組織を削除してください。';
        _loading = false;
      });
      return;
    }
    setState(() => _loading = false);

    // パスワード確認ダイアログ
    if (!mounted) return;
    final passCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('組織を削除'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'この操作は元に戻せません。\n組織・メンバー情報とあなたのアカウントをすべて削除します。',
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

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // パスワードで再認証
      final user = FirebaseAuth.instance.currentUser!;
      final credential = EmailAuthProvider.credential(
        email: AppSession.email,
        password: passCtrl.text,
      );
      await user.reauthenticateWithCredential(credential);

      final fs = FirebaseFirestore.instance;

      // 全メンバーの users ドキュメントを削除（自分以外）
      final membersSnap = await fs
          .collection('users')
          .where('orgId', isEqualTo: AppSession.orgId)
          .get();
      final batch = fs.batch();
      for (final doc in membersSnap.docs) {
        if (doc.id != AppSession.uid) batch.delete(doc.reference);
      }
      // orgs ドキュメントを削除
      batch.delete(fs.collection('orgs').doc(AppSession.orgId));
      await batch.commit();

      // 自分の users ドキュメントを削除
      await fs.collection('users').doc(AppSession.uid).delete();

      AppSession.clear();

      // Firebase Authアカウント削除（失敗してもサインアウトで確実にログアウト）
      try {
        await user.delete();
      } catch (deleteErr) {
        debugPrint('user.delete() failed: $deleteErr');
        await FirebaseAuth.instance.signOut();
      }

      // AuthGate を維持したまま最初のルートへ戻る
      // （AuthGate の StreamBuilder がログアウト状態を検知して LoginPage を表示する）
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = (e.code == 'wrong-password' || e.code == 'invalid-credential')
            ? 'パスワードが正しくありません'
            : '認証エラー: ${e.code}';
        _loading = false;
      });
    } catch (e) {
      debugPrint('_deleteOrg error: $e');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _removeMember(String uid, String email) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('メンバーを削除'),
        content: Text('$email をメンバーから削除しますか？\n削除後、そのユーザーは組織設定画面へ移動します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'orgId': '',
        'role': 'admin',
      });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changeInviteCode() async {
    final ctrl = TextEditingController(text: _inviteCode);
    String? dialogError;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('招待コードを変更'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'メンバーが参加時に入力するコードです。\n英小文字・数字・_のみ使用できます。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: '新しい招待コード',
                  border: OutlineInputBorder(),
                ),
                autocorrect: false,
                autofocus: true,
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 6),
                Text(
                  dialogError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
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
                final v = ctrl.text.trim();
                if (!RegExp(r'^[a-z0-9_]+$').hasMatch(v)) {
                  setS(() => dialogError = '英小文字・数字・_のみ使用できます');
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
    final newCode = ctrl.text.trim();
    if (newCode.isEmpty || newCode == _inviteCode) return;
    try {
      await FirebaseFirestore.instance
          .collection('orgs')
          .doc(AppSession.orgId)
          .update({'inviteCode': newCode});
      setState(() => _inviteCode = newCode);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('招待コードを変更しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('組織管理'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── ロゴ ──
                Center(
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      _logoUploading
                          ? const SizedBox(
                              width: 100,
                              height: 100,
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : GestureDetector(
                              onTap: _uploadLogo,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: _logoUrl.isNotEmpty
                                    ? Image.memory(
                                        base64Decode(_logoUrl),
                                        width: 100,
                                        height: 100,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                _logoPlaceholder(),
                                      )
                                    : _logoPlaceholder(),
                              ),
                            ),
                      if (_logoUrl.isNotEmpty && !_logoUploading)
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: IconButton(
                            icon: const Icon(
                              Icons.delete,
                              color: Colors.red,
                              size: 20,
                            ),
                            tooltip: 'ロゴを削除',
                            onPressed: _deleteLogo,
                          ),
                        ),
                    ],
                  ),
                ),
                Center(
                  child: TextButton.icon(
                    onPressed: _uploadLogo,
                    icon: const Icon(Icons.upload_file, size: 16),
                    label: Text(_logoUrl.isNotEmpty ? 'ロゴを変更' : 'ロゴをアップロード'),
                  ),
                ),
                const SizedBox(height: 8),
                // ── 組織名 ──
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.business),
                    title: Text(
                      _orgName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text('招待コード: $_inviteCode'),
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      onSelected: (v) async {
                        if (v == 'rename') {
                          _renameOrg();
                        } else if (v == 'copy') {
                          final messenger = ScaffoldMessenger.of(context);
                          await Clipboard.setData(
                            ClipboardData(text: _inviteCode),
                          );
                          messenger.showSnackBar(
                            const SnackBar(content: Text('招待コードをコピーしました')),
                          );
                        } else if (v == 'change_code') {
                          _changeInviteCode();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'rename',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 18),
                              SizedBox(width: 8),
                              Text('組織名を変更'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'copy',
                          child: Row(
                            children: [
                              Icon(Icons.copy, size: 18),
                              SizedBox(width: 8),
                              Text('招待コードをコピー'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'change_code',
                          child: Row(
                            children: [
                              Icon(Icons.key, size: 18),
                              SizedBox(width: 8),
                              Text('招待コードを変更'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'メンバー (${_members.length}名)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                for (final m in _members)
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: m['role'] == 'admin'
                            ? Colors.deepPurple.shade100
                            : Colors.grey.shade200,
                        child: Text(
                          m['role'] == 'admin' ? '管' : '員',
                          style: TextStyle(
                            fontSize: 12,
                            color: m['role'] == 'admin'
                                ? Colors.deepPurple
                                : Colors.grey.shade700,
                          ),
                        ),
                      ),
                      title: Text(
                        m['nickname']?.toString().isNotEmpty == true
                            ? m['nickname'].toString()
                            : m['email']?.toString() ?? m['uid'].toString(),
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '${m['role'] == 'admin' ? '管理者' : 'メンバー'}　${m['email'] ?? ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: m['uid'] == AppSession.uid
                          ? const Chip(label: Text('自分'))
                          : IconButton(
                              icon: const Icon(
                                Icons.person_remove,
                                color: Colors.red,
                              ),
                              tooltip: 'メンバーを削除',
                              onPressed: () => _removeMember(
                                m['uid'].toString(),
                                m['email']?.toString() ?? '',
                              ),
                            ),
                    ),
                  ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _deleteOrg,
                    icon: const Icon(Icons.delete_forever, color: Colors.red),
                    label: const Text(
                      '組織を削除する',
                      style: TextStyle(color: Colors.red),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.all(14),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '※ すべての在庫を0にしてから削除できます',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
            ),
    );
  }
}
