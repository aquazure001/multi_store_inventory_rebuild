part of '../main.dart';

// ─────────────────────────────────────────────
// 設定ページ
// ─────────────────────────────────────────────

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.onManualUpdate,
    required this.onChangeNickname,
    required this.onChangePassword,
    required this.onLeaveOrg,
    required this.onDeleteAccount,
    required this.onFeedbackFeature,
    required this.onFeedbackFix,
    required this.onFeedbackBug,
  });

  final Future<void> Function() onManualUpdate;
  final Future<void> Function() onChangeNickname;
  final Future<void> Function() onChangePassword;
  final Future<void> Function() onLeaveOrg;
  final Future<void> Function() onDeleteAccount;
  final Future<void> Function() onFeedbackFeature;
  final Future<void> Function() onFeedbackFix;
  final Future<void> Function() onFeedbackBug;

  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.bold,
        color: Colors.deepPurple,
        letterSpacing: 0.5,
      ),
    ),
  );

  Future<void> _openManual(BuildContext context) async {
    final origin = html.window.location.origin;
    final uri = Uri.parse('$origin/help/manual.html');
    try {
      await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('マニュアルを開けませんでした。')));
      }
    }
  }

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログアウト'),
        content: const Text('ログアウトしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ログアウト'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await FirebaseAuth.instance.signOut();
    AppSession.clear();
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7FF),
      appBar: AppBar(title: const Text('設定')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _sectionLabel('アカウント'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('ニックネーム変更'),
                    onTap: onChangeNickname,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('パスワード変更'),
                    onTap: onChangePassword,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _sectionLabel('ヘルプ・サポート'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: const Text('マニュアル・使い方'),
                    onTap: () => _openManual(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('利用規約'),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LegalPage(
                            title: '利用規約',
                            content: _kTermsOfService,
                          ),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.privacy_tip_outlined),
                    title: const Text('プライバシーポリシー'),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LegalPage(
                            title: 'プライバシーポリシー',
                            content: _kPrivacyPolicy,
                          ),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.add_circle_outline,
                      color: Colors.blue,
                    ),
                    title: const Text('機能追加依頼'),
                    onTap: onFeedbackFeature,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.build_outlined,
                      color: Colors.orange,
                    ),
                    title: const Text('修正依頼'),
                    onTap: onFeedbackFix,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.bug_report_outlined,
                      color: Colors.red,
                    ),
                    title: const Text('バグ報告'),
                    onTap: onFeedbackBug,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _sectionLabel('アプリ'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.system_update_alt),
                    title: const Text('アプリを最新にする'),
                    subtitle: const Text('最新の画面を手動で読み直します'),
                    onTap: onManualUpdate,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _sectionLabel('アカウント操作'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('ログアウト'),
                    onTap: () => _logout(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.group_remove_outlined),
                    title: const Text('組織から退出'),
                    onTap: onLeaveOrg,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.delete_forever,
                      color: Colors.red,
                    ),
                    title: const Text(
                      'アカウント削除',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: onDeleteAccount,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
