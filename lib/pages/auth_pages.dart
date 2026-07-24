part of '../main.dart';

// ─────────────────────────────────────────────
// 認証ゲート
// ─────────────────────────────────────────────

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == null) {
          return const LoginPage();
        }
        return const _UserLoader();
      },
    );
  }
}

class _UserLoader extends StatefulWidget {
  const _UserLoader();

  @override
  State<_UserLoader> createState() => _UserLoaderState();
}

class _UserLoaderState extends State<_UserLoader> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final fs = FirebaseFirestore.instance;
      AppSession.uid = user.uid;
      AppSession.email = user.email ?? '';

      // 新システムの users/{uid} を確認
      final userDoc = await fs.collection('users').doc(user.uid).get();
      if (userDoc.exists) {
        final data = userDoc.data()!;
        AppSession.orgId = (data['orgId'] ?? '').toString();
        AppSession.role = (data['role'] ?? '').toString();
        AppSession.nickname = (data['nickname'] ?? '').toString();
      } else {
        // 旧システムの organizations コレクションから自動移行
        await _tryMigrateFromOrganizations(user.uid, fs);
      }

      // 組織名・ロゴURLを読み込む
      if (AppSession.orgId.isNotEmpty) {
        final orgDoc = await fs.collection('orgs').doc(AppSession.orgId).get();
        final od = orgDoc.data() ?? {};
        AppSession.orgName = od['name']?.toString() ?? AppSession.orgId;
        AppSession.logoUrl = od['logoBase64']?.toString() ?? '';
        AppSession.adSlotBase = (od['adSlotBase'] as int?) ?? -1;
        // 既存組織（approved フィールドなし）は承認済みとみなす
        AppSession.approved = (od['approved'] as bool?) ?? true;
        AppSession.adViewEnabled = (od['adViewEnabled'] as bool?) ?? true;
        // 管理者でadSlotBase未割り当ての場合は割り当てる
        if (AppSession.isAdmin && AppSession.adSlotBase == -1) {
          AppSession.adSlotBase = await _assignAdSlotBase(
            fs,
            AppSession.orgId,
            AppSession.isSuperAdmin,
          );
        }
        // 旧形式(adImage/adMessage)の広告があるがadDistribEnabledが未設定の場合は自動設定
        if (AppSession.isAdmin) {
          final hasAdContent = _orgHasAdContent(od);
          final distribEnabled = (od['adDistribEnabled'] as bool?) ?? false;
          if (hasAdContent && !distribEnabled) {
            try {
              await fs.collection('orgs').doc(AppSession.orgId).update({
                'adDistribEnabled': true,
              });
            } catch (_) {}
          }
        }
        // 広告読み込みでログイン・初期表示を待たせない。
        // 広告は店舗一覧側で背景読み込みする。
      }

      if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _tryMigrateFromOrganizations(
    String uid,
    FirebaseFirestore fs,
  ) async {
    try {
      // ownerUid が自分のUIDと一致する組織のみ自動移行
      final orgsSnap = await fs.collection('organizations').get();
      String? orgId;
      for (final doc in orgsSnap.docs) {
        final data = doc.data();
        final owner = (data['ownerUid'] ?? '').toString();
        if (owner != uid) continue;
        final storesDoc = await fs
            .collection('inventory_shared_v1')
            .doc('${doc.id}__stores')
            .get();
        if (storesDoc.exists) {
          orgId = doc.id;
          break;
        }
      }
      if (orgId == null) return;

      // orgs コレクションに登録（なければ作成）
      final orgsDoc = await fs.collection('orgs').doc(orgId).get();
      if (!orgsDoc.exists) {
        await fs.collection('orgs').doc(orgId).set({
          'name': orgId,
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': uid,
        });
      }

      // users コレクションに保存
      await fs.collection('users').doc(uid).set({
        'email': AppSession.email,
        'orgId': orgId,
        'role': 'admin',
        'createdAt': FieldValue.serverTimestamp(),
      });

      AppSession.orgId = orgId;
      AppSession.role = 'admin';
    } catch (_) {
      // 自動移行失敗時は OrgSetupPage で手動設定
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('読み込みエラー: $_error'),
          ),
        ),
      );
    }
    if (!AppSession.hasOrg) {
      return const OrgSetupPage();
    }
    if (AppSession.nickname.isEmpty) {
      return const NicknameSetupPage();
    }
    // 管理者が未承認の場合は承認待ち画面（統括管理者は除く）
    if (AppSession.isAdmin &&
        !AppSession.isSuperAdmin &&
        !AppSession.approved) {
      return const PendingApprovalPage();
    }
    return const StoreListPage();
  }
}

// ─────────────────────────────────────────────
// ログインページ
// ─────────────────────────────────────────────

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = _errMsg(e.code);
        _loading = false;
      });
    }
  }

  Future<void> _sendResetEmail() async {
    final emailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('パスワードの再設定'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '登録済みのメールアドレスに再設定用のリンクを送信します。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(
                labelText: 'メールアドレス',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
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
            child: const Text('送信'),
          ),
        ],
      ),
    );
    if (result != true) return;
    final email = emailCtrl.text.trim();
    if (email.isEmpty) return;
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('再設定メールを送信しました。メールをご確認ください。')),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errMsg(e.code)), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _errMsg(String code) {
    switch (code) {
      case 'user-not-found':
        return 'メールアドレスが登録されていません';
      case 'wrong-password':
      case 'invalid-credential':
        return 'メールアドレスまたはパスワードが正しくありません';
      case 'invalid-email':
        return 'メールアドレスの形式が正しくありません';
      case 'too-many-requests':
        return 'しばらくしてから再試行してください';
      default:
        return 'ログインに失敗しました ($code)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '多店舗在庫管理',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 48),
                TextField(
                  controller: _emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'メールアドレス',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordCtrl,
                  decoration: const InputDecoration(
                    labelText: 'パスワード',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _login,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('ログイン'),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const SignupPage())),
                  child: const Text('新規登録はこちら'),
                ),
                TextButton(
                  onPressed: _loading ? null : _sendResetEmail,
                  child: const Text(
                    'パスワードをお忘れの方',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 新規登録ページ
// ─────────────────────────────────────────────

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    if (_passCtrl.text != _confirmCtrl.text) {
      setState(() => _error = 'パスワードが一致しません');
      return;
    }
    if (_passCtrl.text.length < 6) {
      setState(() => _error = 'パスワードは6文字以上で設定してください');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      );
      AppSession.uid = cred.user!.uid;
      AppSession.email = cred.user!.email ?? '';
      if (!mounted) return;
      // スタックを完全クリアして OrgSetupPage へ
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OrgSetupPage()),
        (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = _errMsg(e.code);
        _loading = false;
      });
    }
  }

  String _errMsg(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'このメールアドレスは既に登録されています';
      case 'invalid-email':
        return 'メールアドレスの形式が正しくありません';
      case 'weak-password':
        return 'パスワードが弱すぎます（6文字以上）';
      default:
        return '登録に失敗しました ($code)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('新規登録')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              TextField(
                controller: _emailCtrl,
                decoration: const InputDecoration(
                  labelText: 'メールアドレス',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passCtrl,
                decoration: const InputDecoration(
                  labelText: 'パスワード（6文字以上）',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _confirmCtrl,
                decoration: const InputDecoration(
                  labelText: 'パスワード（確認）',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                onSubmitted: (_) => _signup(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _signup,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('次へ（組織設定）'),
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
// 組織設定ページ（新規登録後 / 脱退後）
// ─────────────────────────────────────────────

class OrgSetupPage extends StatefulWidget {
  const OrgSetupPage({super.key});

  @override
  State<OrgSetupPage> createState() => _OrgSetupPageState();
}

class _OrgSetupPageState extends State<OrgSetupPage> {
  String? _mode; // null=選択, 'create', 'join'
  final _orgNameCtrl = TextEditingController();
  final _orgCodeCtrl = TextEditingController();
  final _joinCodeCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  bool _loading = false;
  bool _agreedToTerms = false;
  String? _error;

  @override
  void dispose() {
    _orgNameCtrl.dispose();
    _orgCodeCtrl.dispose();
    _joinCodeCtrl.dispose();
    _nicknameCtrl.dispose();
    super.dispose();
  }

  Future<void> _createOrg() async {
    final name = _orgNameCtrl.text.trim();
    final code = _orgCodeCtrl.text.trim().toLowerCase();
    final nickname = _nicknameCtrl.text.trim();
    if (name.isEmpty || code.isEmpty) {
      setState(() => _error = '組織名とコードを入力してください');
      return;
    }
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(code)) {
      setState(() => _error = 'コードは英小文字・数字・アンダースコアのみ使用できます');
      return;
    }
    if (nickname.isEmpty) {
      setState(() => _error = 'ニックネームを入力してください');
      return;
    }
    if (!_agreedToTerms) {
      setState(() => _error = '利用規約とプライバシーポリシーへの同意が必要です');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fs = FirebaseFirestore.instance;
      final orgDoc = await fs.collection('orgs').doc(code).get();
      if (orgDoc.exists) {
        setState(() {
          _error = 'このコードは既に使用されています';
          _loading = false;
        });
        return;
      }
      await fs.collection('orgs').doc(code).set({
        'name': name,
        'inviteCode': code,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': AppSession.uid,
        'maxStores': 5,
        'maxUsers': 5,
        'approved': false,
        'adminEmail': AppSession.email,
        'adminNickname': nickname,
      });
      await fs.collection('users').doc(AppSession.uid).set({
        'email': AppSession.email,
        'orgId': code,
        'role': 'admin',
        'nickname': nickname,
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppSession.orgId = code;
      AppSession.role = 'admin';
      AppSession.nickname = nickname;
      AppSession.approved = false;
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const PendingApprovalPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _joinOrg() async {
    final code = _joinCodeCtrl.text.trim().toLowerCase();
    final nickname = _nicknameCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'コードを入力してください');
      return;
    }
    if (nickname.isEmpty) {
      setState(() => _error = 'ニックネームを入力してください');
      return;
    }
    if (!_agreedToTerms) {
      setState(() => _error = '利用規約とプライバシーポリシーへの同意が必要です');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fs = FirebaseFirestore.instance;
      // まず orgId で直接検索、なければ inviteCode フィールドで検索
      DocumentSnapshot<Map<String, dynamic>>? orgDoc;
      String? resolvedOrgId;
      final direct = await fs.collection('orgs').doc(code).get();
      if (direct.exists) {
        orgDoc = direct;
        resolvedOrgId = code;
      } else {
        final snap = await fs
            .collection('orgs')
            .where('inviteCode', isEqualTo: code)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) {
          orgDoc = snap.docs.first;
          resolvedOrgId = snap.docs.first.id;
        }
      }
      if (orgDoc == null || resolvedOrgId == null) {
        setState(() {
          _error = '組織が見つかりません';
          _loading = false;
        });
        return;
      }
      final maxUsers = (orgDoc.data()?['maxUsers'] as int?) ?? 5;
      final userSnap = await fs
          .collection('users')
          .where('orgId', isEqualTo: resolvedOrgId)
          .get();
      if (userSnap.docs.length >= maxUsers) {
        setState(() {
          _error = 'この組織のユーザー数が上限（$maxUsers人）に達しています';
          _loading = false;
        });
        return;
      }
      await fs.collection('users').doc(AppSession.uid).set({
        'email': AppSession.email,
        'orgId': resolvedOrgId,
        'role': 'member',
        'nickname': nickname,
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppSession.orgId = resolvedOrgId;
      AppSession.role = 'member';
      AppSession.nickname = nickname;
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const StoreListPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('組織の設定'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              AppSession.clear();
            },
            child: const Text('ログアウト', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      body: SafeArea(
        child: _mode == null
            ? _buildSelectMode()
            : _mode == 'create'
            ? _buildCreateMode()
            : _buildJoinMode(),
      ),
    );
  }

  Future<void> _connectToLegacy() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fs = FirebaseFirestore.instance;

      // ownerUid が自分のUIDと一致する組織のみ移行可能
      final orgsSnap = await fs.collection('organizations').get();
      String? orgId;
      for (final doc in orgsSnap.docs) {
        final data = doc.data();
        final owner = (data['ownerUid'] ?? '').toString();
        if (owner != AppSession.uid) continue; // 自分が所有者の組織のみ
        final storesDoc = await fs
            .collection('inventory_shared_v1')
            .doc('${doc.id}__stores')
            .get();
        if (storesDoc.exists) {
          orgId = doc.id;
          break;
        }
      }
      if (orgId == null) {
        setState(() {
          _error = 'あなたのアカウントに対応する既存データが見つかりませんでした。\n組織コードを入力して参加してください。';
          _loading = false;
        });
        return;
      }

      // orgs コレクションに登録（なければ作成）
      final orgDoc = await fs.collection('orgs').doc(orgId).get();
      if (!orgDoc.exists) {
        await fs.collection('orgs').doc(orgId).set({
          'name': orgId,
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': AppSession.uid,
        });
      }
      await fs.collection('users').doc(AppSession.uid).set({
        'email': AppSession.email,
        'orgId': orgId,
        'role': 'admin',
        'createdAt': FieldValue.serverTimestamp(),
      });
      AppSession.orgId = orgId;
      AppSession.role = 'admin';
      AppSession.nickname = '';
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const NicknameSetupPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Widget _buildAgreementRow(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Checkbox(
          value: _agreedToTerms,
          onChanged: (v) => setState(() => _agreedToTerms = v ?? false),
        ),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LegalPage(
                      title: '利用規約',
                      content: _kTermsOfService,
                    ),
                  ),
                ),
                child: const Text(
                  '利用規約',
                  style: TextStyle(
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                    fontSize: 13,
                  ),
                ),
              ),
              const Text('と', style: TextStyle(fontSize: 13)),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LegalPage(
                      title: 'プライバシーポリシー',
                      content: _kPrivacyPolicy,
                    ),
                  ),
                ),
                child: const Text(
                  'プライバシーポリシー',
                  style: TextStyle(
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                    fontSize: 13,
                  ),
                ),
              ),
              const Text('に同意する', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSelectMode() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '組織の設定',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'ログイン中: ${AppSession.email}',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 32),
            // 既存データ引き継ぎ（移行ユーザー向け）
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.deepOrange.shade200),
                borderRadius: BorderRadius.circular(8),
                color: Colors.deepOrange.shade50,
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '以前から使用していた方',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.deepOrange,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: (_loading || !_agreedToTerms)
                          ? null
                          : _connectToLegacy,
                      icon: _loading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.restore),
                      label: const Text('既存データを引き継ぐ'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepOrange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              '新しく始める方',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: (_loading || !_agreedToTerms)
                    ? null
                    : () => setState(() {
                        _mode = 'create';
                        _error = null;
                      }),
                icon: const Icon(Icons.add_business),
                label: const Text('新しい組織を作成する'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (_loading || !_agreedToTerms)
                    ? null
                    : () => setState(() {
                        _mode = 'join';
                        _error = null;
                      }),
                icon: const Icon(Icons.group_add),
                label: const Text('既存の組織に参加する'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildAgreementRow(context),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCreateMode() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '新しい組織を作成',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _orgNameCtrl,
            decoration: const InputDecoration(
              labelText: '組織名',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _orgCodeCtrl,
            decoration: const InputDecoration(
              labelText: '組織コード（参加用）',
              helperText: '英小文字・数字・_のみ。例: myshop\n※既存データを引き継ぐ場合は legacy と入力',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nicknameCtrl,
            decoration: const InputDecoration(
              labelText: 'ニックネーム（必須）',
              helperText: '履歴に表示される名前です',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          _buildAgreementRow(context),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _mode = null;
                    _error = null;
                  }),
                  child: const Text('戻る'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _loading ? null : _createOrg,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('作成'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildJoinMode() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '既存の組織に参加',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _joinCodeCtrl,
            decoration: const InputDecoration(
              labelText: '組織コード',
              helperText: '管理者から教えてもらったコードを入力してください',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nicknameCtrl,
            decoration: const InputDecoration(
              labelText: 'ニックネーム（必須）',
              helperText: '履歴に表示される名前です',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _joinOrg(),
          ),
          const SizedBox(height: 12),
          _buildAgreementRow(context),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _mode = null;
                    _error = null;
                  }),
                  child: const Text('戻る'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _loading ? null : _joinOrg,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('参加'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ニックネーム設定ページ（既存ユーザー向け）
// ─────────────────────────────────────────────

class NicknameSetupPage extends StatefulWidget {
  const NicknameSetupPage({super.key});

  @override
  State<NicknameSetupPage> createState() => _NicknameSetupPageState();
}

class _NicknameSetupPageState extends State<NicknameSetupPage> {
  final _ctrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final nick = _ctrl.text.trim();
    if (nick.isEmpty) {
      setState(() => _error = 'ニックネームを入力してください');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(AppSession.uid)
          .update({'nickname': nick});
      AppSession.nickname = nick;
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const StoreListPage()),
          (_) => false,
        );
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(
        title: const Text('ニックネームの設定'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              AppSession.clear();
            },
            child: const Text('ログアウト', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ニックネームを設定してください',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '在庫の修正・追加履歴に表示される名前です。',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _ctrl,
                decoration: const InputDecoration(
                  labelText: 'ニックネーム',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
                onSubmitted: (_) => _save(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('設定して続ける'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
