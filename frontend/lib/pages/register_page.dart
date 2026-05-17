import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class RegisterPage extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onRegister;

  const RegisterPage({
    super.key,
    required this.onBack,
    required this.onRegister,
  });

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _phoneController = TextEditingController(text: '13812345678');
  final _codeController = TextEditingController(text: '123456');
  final _passwordController = TextEditingController(text: '123456');
  bool _agreedToTerms = true;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: widget.onBack,
        ),
        title: const Text('注册'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInputGroup(
              label: '手机号',
              child: TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  hintText: '请输入手机号码',
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildInputGroup(
              label: '验证码',
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        hintText: '请输入验证码',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 110,
                    child: OutlinedButton(
                      onPressed: () {},
                      child: const Text('获取验证码'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _buildInputGroup(
              label: '设置密码',
              child: TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: '请设置登录密码',
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildTermsCheckbox(),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                _showToast('注册成功');
                Future.delayed(const Duration(milliseconds: 500), widget.onRegister);
              },
              child: const Text('注册'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputGroup({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  Widget _buildTermsCheckbox() {
    return GestureDetector(
      onTap: () {
        setState(() {
          _agreedToTerms = !_agreedToTerms;
        });
      },
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: _agreedToTerms ? AppTheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _agreedToTerms ? AppTheme.primary : AppTheme.border,
                width: 1.5,
              ),
            ),
            child: _agreedToTerms
                ? const Icon(
                    Icons.check,
                    size: 14,
                    color: Colors.white,
                  )
                : null,
          ),
          const SizedBox(width: 8),
          const Text(
            '我已阅读并同意',
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.textSecondary,
            ),
          ),
          const Text(
            '《用户服务协议》',
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.primary,
            ),
          ),
          const Text(
            '和',
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.textSecondary,
            ),
          ),
          const Text(
            '《隐私政策》',
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
