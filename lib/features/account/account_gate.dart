import '../../ui/neurox_brand.dart';
import 'package:neurox/l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'local_account.dart';
import 'password_confirmation_field.dart';

class AccountGate extends StatefulWidget {
  const AccountGate({super.key, required this.account});
  final LocalAccount account;
  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate>
    with LanguageAware<AccountGate> {
  final name = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();
  final form = GlobalKey<FormState>();
  String? languageError;
  final passwordFocus = FocusNode();
  @override
  void dispose() {
    passwordFocus.dispose();
    name.dispose();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final register = a.state == 'register';
    if (name.text.isEmpty && a.name.isNotEmpty && !register) name.text = a.name;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(28),
              child: Form(
                key: form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const NeuroxMark(size: 96),
                        Flexible(
                          child: PopupMenuButton<String>(
                            key: const Key('accountLanguage'),
                            tooltip: tr('选择界面语言'),
                            enabled: !a.busy && !AppLanguage.instance.busy,
                            initialValue: AppLanguage.instance.code,
                            onSelected: (value) async {
                              setState(() => languageError = null);
                              try {
                                await AppLanguage.instance.select(value);
                              } catch (_) {
                                if (mounted) {
                                  setState(
                                    () => languageError = '语言设置未保存，请重试。',
                                  );
                                }
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'zh', child: Text('简体中文')),
                              PopupMenuItem(
                                value: 'en',
                                child: Text('English'),
                              ),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 14,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (AppLanguage.instance.busy)
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  else
                                    const Icon(Icons.language, size: 20),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      AppLanguage.instance.english
                                          ? 'EN'
                                          : '中文',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const Icon(Icons.arrow_drop_down, size: 18),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (languageError != null)
                      Text(
                        tr(languageError!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    SizedBox(height: 20),
                    Text(
                      'NeuroX',
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 2,
                          ),
                    ),
                    if (a.state == 'error' || register) ...[
                      const SizedBox(height: 12),
                      Text(
                        a.state == 'error' ? tr("本机存储需要处理") : tr("创建本机账号"),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                    SizedBox(height: 24),
                    if (a.state == 'loading')
                      Center(child: CircularProgressIndicator())
                    else if (a.state != 'error') ...[
                      TextFormField(
                        key: Key('accountName'),
                        controller: name,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: tr("账号"),
                          helperText: tr("3–32位字母、数字或下划线"),
                        ),
                        validator: (v) =>
                            RegExp(
                              r'^[a-zA-Z0-9_]{3,32}$',
                            ).hasMatch(v?.trim() ?? '')
                            ? null
                            : tr("请输入有效账号"),
                      ),
                      SizedBox(height: 16),
                      TextFormField(
                        key: Key('accountPassword'),
                        focusNode: passwordFocus,
                        controller: password,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: tr("密码"),
                          helperText: tr("6–128个字符；连续5次错误后等待60秒"),
                        ),
                        validator: (v) =>
                            (v?.runes.length ?? 0) >= 6 &&
                                (v?.runes.length ?? 0) <= 128
                            ? null
                            : tr("密码须为6–128个字符"),
                      ),
                      if (register) ...[
                        SizedBox(height: 16),
                        PasswordConfirmationField(
                          key: Key('confirmPassword'),
                          password: password,
                          controller: confirmation,
                          passwordFocus: passwordFocus,
                          label: tr("确认密码"),
                        ),
                      ],
                      SizedBox(height: 24),
                      FilledButton(
                        key: Key('submitAccount'),
                        onPressed: a.busy
                            ? null
                            : () async {
                                if (!form.currentState!.validate()) return;
                                final ok = await a.authenticate(
                                  name.text,
                                  password.text,
                                );
                                if (ok) {
                                  password.clear();
                                  confirmation.clear();
                                }
                              },
                        child: Text(
                          a.busy
                              ? tr("正在验证…")
                              : register
                              ? tr("注册并进入")
                              : tr("登录"),
                        ),
                      ),
                    ],
                    if (a.state == 'register' || a.state == 'login')
                      TextButton(
                        key: Key('switchAccountMode'),
                        onPressed: a.busy
                            ? null
                            : () {
                                password.clear();
                                confirmation.clear();
                                name.clear();
                                a.showRegistration(!register);
                              },
                        child: Text(
                          register ? tr("已有账号，返回登录") : tr("注册其他本机账号"),
                        ),
                      ),
                    if (a.recordingActive)
                      Text(tr("诊断记录仍在后台保存。请登录原账号后停止记录，才能注册或切换账号。")),
                    if (a.error != null)
                      Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text(
                          trSource(a.error!),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (a.state == 'error' || a.error != null)
                      TextButton(
                        onPressed: a.busy ? null : a.check,
                        child: Text(tr("重新检查本机存储")),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
