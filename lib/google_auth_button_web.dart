import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

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
    // Configuration errors are surfaced by the widget when the button is used.
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
  StreamSubscription<GoogleSignInAuthenticationEvent>? _subscription;
  bool _handledThisFlow = false;

  @override
  void initState() {
    super.initState();
    _subscription = GoogleSignIn.instance.authenticationEvents.listen(
      (event) async {
        if (event is GoogleSignInAuthenticationEventSignIn && !_handledThisFlow) {
          _handledThisFlow = true;
          final user = event.user;
          await widget.onSuccess(
            GoogleAuthUser(
              email: user.email,
              displayName: user.displayName,
              id: user.id,
            ),
          );
        }
      },
      onError: (Object error) {
        _handledThisFlow = false;
        widget.onError('Google sign-in failed. Check your OAuth client ID and authorized domain.');
      },
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const SizedBox(
        width: double.infinity,
        height: 48,
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: web.renderButton(
          configuration: web.GSIButtonConfiguration(
            type: web.GSIButtonType.standard,
            size: web.GSIButtonSize.large,
            minimumWidth: 300,
          ),
        ),
      ),
    );
  }
}
