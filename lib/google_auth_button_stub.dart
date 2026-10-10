import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

class GoogleAuthUser {
  final String email;
  final String? displayName;
  final String id;

  const GoogleAuthUser({required this.email, required this.displayName, required this.id});
}

Future<void> initializeGoogleAuthentication() async {
  try {
    await GoogleSignIn.instance.initialize();
  } catch (_) {
    // The button will report a useful error if the platform is not configured.
  }
}

class GoogleAuthButton extends StatefulWidget {
  final bool loading;
  final Future<void> Function(GoogleAuthUser user) onSuccess;
  final void Function(String message) onError;

  const GoogleAuthButton({
    super.key,
    required this.loading,
    required this.onSuccess,
    required this.onError,
  });

  @override
  State<GoogleAuthButton> createState() => _GoogleAuthButtonState();
}

class _GoogleAuthButtonState extends State<GoogleAuthButton> {
  bool _busy = false;

  Future<void> _signIn() async {
    if (_busy || widget.loading) return;
    setState(() => _busy = true);
    try {
      final signIn = GoogleSignIn.instance;
      if (!signIn.supportsAuthenticate()) {
        widget.onError('Google Sign-In is not supported on this platform.');
        return;
      }

      final account = await signIn.authenticate();
      await widget.onSuccess(
        GoogleAuthUser(
          email: account.email,
          displayName: account.displayName,
          id: account.id,
        ),
      );
    } on GoogleSignInException catch (e) {
      widget.onError('Google sign-in failed: ${e.description ?? e.code.name}.');
    } catch (e) {
      widget.onError('Google sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _busy || widget.loading;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton(
        onPressed: disabled ? null : _signIn,
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFFD1D5DB), width: 1.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: disabled
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.account_circle, size: 22, color: Color(0xFF4285F4)),
                  SizedBox(width: 8),
                  Text('Continue with Google', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1F2937))),
                ],
              ),
      ),
    );
  }
}
