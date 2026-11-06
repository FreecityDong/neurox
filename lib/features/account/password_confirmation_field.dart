import 'package:neurox/l10n/app_language.dart';
import 'package:flutter/material.dart';

/// Validates on leaving either password input, without submitting the form.
class PasswordConfirmationField extends StatefulWidget {
  const PasswordConfirmationField({
    super.key,
    required this.password,
    required this.controller,
    required this.passwordFocus,
    required this.label,
  });
  final TextEditingController password;
  final TextEditingController controller;
  final FocusNode passwordFocus;
  final String label;

  @override
  State<PasswordConfirmationField> createState() =>
      _PasswordConfirmationFieldState();
}

class _PasswordConfirmationFieldState extends State<PasswordConfirmationField>
    with LanguageAware<PasswordConfirmationField> {
  final field = GlobalKey<FormFieldState<String>>();

  @override
  void initState() {
    super.initState();
    widget.passwordFocus.addListener(_passwordBlurred);
  }

  @override
  void didUpdateWidget(covariant PasswordConfirmationField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.passwordFocus != widget.passwordFocus) {
      oldWidget.passwordFocus.removeListener(_passwordBlurred);
      widget.passwordFocus.addListener(_passwordBlurred);
    }
  }

  void _passwordBlurred() {
    if (!widget.passwordFocus.hasFocus && widget.controller.text.isNotEmpty) {
      field.currentState?.validate();
    }
  }

  @override
  void dispose() {
    widget.passwordFocus.removeListener(_passwordBlurred);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    key: field,
    controller: widget.controller,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    autovalidateMode: AutovalidateMode.onUnfocus,
    onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
    decoration: InputDecoration(labelText: widget.label),
    validator: (value) => value == widget.password.text ? null : tr("两次密码不一致"),
  );
}
