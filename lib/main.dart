import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'firebase_options.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:async';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await GoogleSignIn.instance.initialize(
    serverClientId: '422573084495-ebj4o7tpo5t19pg2h62u8n1bp0ccqmc2.apps.googleusercontent.com',
  );
  await AppState.instance.initialize();
  runApp(const SilentQueueApp());
}

/// Firebase authentication helper.
class AuthService {
  static final FirebaseAuth auth = FirebaseAuth.instance;
  static final GoogleSignIn google = GoogleSignIn.instance;

  static Future<UserCredential> signInWithGoogle() async {
    final GoogleSignInAccount googleUser;
    try {
      googleUser = await google.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw FirebaseAuthException(
          code: 'google-sign-in-cancelled',
          message: 'Google sign-in was cancelled.',
        );
      }
      throw FirebaseAuthException(
        code: 'google-sign-in-failed',
        message: e.description ?? 'Google sign-in could not be completed.',
      );
    }

    final GoogleSignInAuthentication googleAuth = googleUser.authentication;
    final String? idToken = googleAuth.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw FirebaseAuthException(
        code: 'google-id-token-missing',
        message: 'Google did not return an ID token. Check Firebase Google Sign-In configuration.',
      );
    }

    final credential = GoogleAuthProvider.credential(idToken: idToken);
    return auth.signInWithCredential(credential);
  }

  static Future<UserCredential> registerCustomer({
    required String name,
    required String email,
    required String password,
  }) async {
    final credential = await auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await credential.user?.updateDisplayName(name);
    await credential.user?.reload();
    return credential;
  }

  static Future<UserCredential> signInCustomer({
    required String email,
    required String password,
  }) {
    return auth.signInWithEmailAndPassword(email: email, password: password);
  }

  static Future<void> signOut() => auth.signOut();
}

class StaffAuthorizationResult {
  final bool authorized;
  final String message;

  const StaffAuthorizationResult({
    required this.authorized,
    required this.message,
  });
}

Future<StaffAuthorizationResult> checkStaffAuthorization() async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) {
    return const StaffAuthorizationResult(
      authorized: false,
      message: 'Please sign in first.',
    );
  }

  try {
    final snapshot = await FirebaseFirestore.instance
        .collection('staff')
        .doc(user.uid)
        .get();

    if (!snapshot.exists) {
      return StaffAuthorizationResult(
        authorized: false,
        message: 'This account is not registered as staff. UID: ${user.uid}',
      );
    }

    final data = snapshot.data() ?? <String, dynamic>{};
    final role = data['role']?.toString().toLowerCase();
    final active = data['active'] == true;

    if (role != 'staff') {
      return StaffAuthorizationResult(
        authorized: false,
        message: 'Staff role is missing or incorrect.',
      );
    }

    if (!active) {
      return const StaffAuthorizationResult(
        authorized: false,
        message: 'This staff account is inactive.',
      );
    }

    return const StaffAuthorizationResult(
      authorized: true,
      message: 'Staff authorization successful.',
    );
  } on FirebaseException catch (e) {
    return StaffAuthorizationResult(
      authorized: false,
      message: 'Staff authorization error (${e.code}).',
    );
  } catch (e) {
    return StaffAuthorizationResult(
      authorized: false,
      message: 'Could not verify staff authorization.',
    );
  }
}

/// Token Status Enum
enum TokenStatus { inQueue, inService, completed, cancelled }

/// Customer Ticket Model
class CustomerTicket {
  final String tokenId;
  final String pin;
  final String userEmail;
  final String userUid;
  final DateTime joinedTime;
  TokenStatus status;

  CustomerTicket({
    required this.tokenId,
    required this.pin,
    required this.userEmail,
    required this.userUid,
    required this.joinedTime,
    this.status = TokenStatus.inQueue,
  });
}

/// Central App State
class AppState extends ChangeNotifier {
  static final AppState instance = AppState();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final String _queueId = 'SQ-QUEUE-HOST-88219';
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _queueSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _ticketsSubscription;
  bool _syncStarted = false;

  bool isRegistered = false;
  bool isLoggedIn = false;
  String userName = "";
  String userEmail = "";
  String savedPin = "";

  int serviceTimePerPersonMinutes = 3;
  bool isQueueDelayed = false;
  int delayMinutes = 0;
  bool isQueueMovingQuickly = true;
  bool isQueueActive = true;

  int tokenCounter = 0;
  String activeQueueName = "General Service Queue";
  String activeQueueId = "SQ-QUEUE-HOST-88219";
  String? currentServingToken;

  List<CustomerTicket> tickets = [];

  DocumentReference<Map<String, dynamic>> get _queueRef =>
      _db.collection('queues').doc(_queueId);

  CollectionReference<Map<String, dynamic>> get _ticketRef =>
      _queueRef.collection('tickets');

  List<CustomerTicket> get activeQueue => tickets
      .where((t) => t.status == TokenStatus.inQueue || t.status == TokenStatus.inService)
      .toList()
    ..sort((a, b) => int.parse(a.tokenId).compareTo(int.parse(b.tokenId)));

  Future<void> initialize() async {
    _authSubscription ??= FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) {
        _stopFirestoreSync();
      } else {
        _startFirestoreSync();
      }
    });

    if (FirebaseAuth.instance.currentUser != null) {
      await _startFirestoreSync();
    }
  }

  Future<void> _startFirestoreSync() async {
    if (_syncStarted) return;
    _syncStarted = true;

    try {
      final initial = await _queueRef.get();
      if (!initial.exists) {
        final authorization = await checkStaffAuthorization();

        if (authorization.authorized) {
          await _queueRef.set({
            'queueId': _queueId,
            'name': activeQueueName,
            'isActive': true,
            'tokenCounter': 0,
            'currentServingToken': null,
            'serviceTimePerPersonMinutes': 3,
            'isQueueDelayed': false,
            'isQueueMovingQuickly': true,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }
    } catch (_) {
      // Rules may temporarily reject this before authentication finishes.
    }

    await _queueSubscription?.cancel();
    await _ticketsSubscription?.cancel();

    _queueSubscription = _queueRef.snapshots().listen((snapshot) {
      final data = snapshot.data();
      if (data == null) return;

      activeQueueName = (data['name'] ?? activeQueueName).toString();
      activeQueueId = (data['queueId'] ?? _queueId).toString();
      isQueueActive = data['isActive'] != false;
      tokenCounter = (data['tokenCounter'] as num?)?.toInt() ?? tokenCounter;
      currentServingToken = data['currentServingToken']?.toString();
      serviceTimePerPersonMinutes =
          (data['serviceTimePerPersonMinutes'] as num?)?.toInt() ?? serviceTimePerPersonMinutes;
      isQueueDelayed = data['isQueueDelayed'] == true;
      isQueueMovingQuickly = data['isQueueMovingQuickly'] != false;
      notifyListeners();
    });

    _ticketsSubscription = _ticketRef.snapshots().listen((snapshot) {
      final loaded = <CustomerTicket>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final joined = data['joinedTime'];
        DateTime joinedTime = DateTime.now();
        if (joined is Timestamp) joinedTime = joined.toDate();
        loaded.add(CustomerTicket(
          tokenId: (data['tokenId'] ?? doc.id).toString(),
          pin: (data['pin'] ?? '').toString(),
          userEmail: (data['userEmail'] ?? '').toString(),
          userUid: (data['userUid'] ?? '').toString(),
          joinedTime: joinedTime,
          status: _statusFromString((data['status'] ?? 'inQueue').toString()),
        ));
      }
      loaded.sort((a, b) => int.parse(a.tokenId).compareTo(int.parse(b.tokenId)));
      tickets = loaded;
      notifyListeners();
    });
  }

  void _stopFirestoreSync() {
    _syncStarted = false;
    _queueSubscription?.cancel();
    _ticketsSubscription?.cancel();
    _queueSubscription = null;
    _ticketsSubscription = null;
    tickets = [];
    tokenCounter = 0;
    currentServingToken = null;
    notifyListeners();
  }

  TokenStatus _statusFromString(String value) {
    switch (value) {
      case 'inService': return TokenStatus.inService;
      case 'completed': return TokenStatus.completed;
      case 'cancelled': return TokenStatus.cancelled;
      default: return TokenStatus.inQueue;
    }
  }

  String _statusToString(TokenStatus status) {
    switch (status) {
      case TokenStatus.inQueue: return 'inQueue';
      case TokenStatus.inService: return 'inService';
      case TokenStatus.completed: return 'completed';
      case TokenStatus.cancelled: return 'cancelled';
    }
  }

  CustomerTicket? getCurrentlyServingTicket() {
    for (final t in tickets) {
      if (t.status == TokenStatus.inService) return t;
    }
    return null;
  }

  bool hasActiveTicketsForEmail(String email) => tickets.any((t) =>
  t.userEmail.toLowerCase() == email.toLowerCase() &&
      (t.status == TokenStatus.inQueue || t.status == TokenStatus.inService));

  List<CustomerTicket> getActiveTicketsByPin(String pin) => tickets
      .where((t) => t.pin == pin &&
      (t.status == TokenStatus.inQueue || t.status == TokenStatus.inService))
      .toList();

  int getPeopleAhead(String tokenId) {
    final list = activeQueue;
    final index = list.indexWhere((t) => t.tokenId == tokenId);
    if (index <= 0) return 0;
    return index - 1;
  }

  int getEstimatedWaitMinutes(String tokenId) {
    final ahead = getPeopleAhead(tokenId);
    final perPerson = isQueueDelayed ? 7 : serviceTimePerPersonMinutes;
    var totalMinutes = ahead * perPerson;
    if (isQueueMovingQuickly && !isQueueDelayed) totalMinutes = (totalMinutes * 0.75).round();
    return totalMinutes <= 0 ? 0 : totalMinutes;
  }

  Future<void> stopQueue() async {
    try {
      await _queueRef.set({
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      isQueueActive = false;
      notifyListeners();
    } on FirebaseException catch (e) {
      throw StateError(
        'Could not stop queue (${e.code}): '
            '${e.message ?? 'Firestore rejected the update.'}',
      );
    }
  }

  Future<void> startQueue() async {
    try {
      await _queueRef.set({
        'isActive': true,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      isQueueActive = true;
      notifyListeners();
    } on FirebaseException catch (e) {
      throw StateError(
        'Could not start queue (${e.code}): '
            '${e.message ?? 'Firestore rejected the update.'}',
      );
    }
  }

  Future<Map<String, dynamic>> _reserveTokens(int count) async {
    if (count < 1 || count > 5) {
      throw ArgumentError('Invalid ticket count.');
    }

    try {
      return await _db.runTransaction<Map<String, dynamic>>((transaction) async {
        final queueSnapshot = await transaction.get(_queueRef);

        if (!queueSnapshot.exists) {
          throw StateError('Queue is not available yet.');
        }

        final data = queueSnapshot.data() ?? <String, dynamic>{};

        if (data['isActive'] == false) {
          throw StateError('Queue is stopped. New tickets cannot be created.');
        }

        final currentCounter =
            (data['tokenCounter'] as num?)?.toInt() ?? 0;
        final currentServingToken =
        data['currentServingToken']?.toString();

        final tokens = List.generate(
          count,
              (index) =>
              (currentCounter + index + 1).toString().padLeft(3, '0'),
        );

        final first =
            currentServingToken == null || currentServingToken.isEmpty;

        transaction.set(
          _queueRef,
          {
            'queueId': _queueId,
            'name': data['name'] ?? activeQueueName,
            'isActive': data['isActive'] != false,
            'tokenCounter': currentCounter + count,
            'currentServingToken': first ? tokens.first : currentServingToken,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        return {
          'tokens': tokens,
          'first': first,
        };
      });
    } on FirebaseException catch (e) {
      throw StateError(
        'Walk-in booking failed (${e.code}): ${e.message ?? 'Firestore rejected the reservation.'}',
      );
    }
  }

  Future<CustomerTicket> bookWalkInTicket() async {
    final reservation = await _reserveTokens(1);
    final tokenId = reservation['tokens']![0];
    final first = reservation['first'] == true;
    final ticket = CustomerTicket(
      tokenId: tokenId,
      pin: '9999',
      userEmail: 'walkin@location.com',
      userUid: FirebaseAuth.instance.currentUser?.uid ?? '',
      joinedTime: DateTime.now(),
      status: first ? TokenStatus.inService : TokenStatus.inQueue,
    );
    await _writeTicket(ticket);
    return ticket;
  }

  Future<List<CustomerTicket>> bookCustomerTickets(int count, String userPin, String email) async {
    if (count < 1 || count > 5) throw ArgumentError('Choose between 1 and 5 tickets.');
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Please sign in before booking a ticket.');

    final actualEmail = (email.isEmpty ? user.email : email) ?? '';
    final pin = userPin.isEmpty ? savedPin : userPin;
    if (actualEmail.isEmpty) throw StateError('Your signed-in email could not be found.');

    try {
      // Do the token reservation AND ticket creation in ONE Firestore transaction.
      // This prevents two phones from getting the same token and prevents a token
      // from being consumed when the ticket write fails.
      return await _db.runTransaction<List<CustomerTicket>>((transaction) async {
        final queueSnapshot = await transaction.get(_queueRef);
        final data = queueSnapshot.data() ?? <String, dynamic>{};

        if (!queueSnapshot.exists) {
          throw StateError('Queue is not available yet. Please try again.');
        }

        if (data['isActive'] == false) {
          throw StateError('Queue is stopped. New tickets cannot be booked.');
        }

        final current = (data['tokenCounter'] as num?)?.toInt() ?? 0;
        final serving = data['currentServingToken']?.toString();
        final tokens = List.generate(
          count,
              (i) => (current + i + 1).toString().padLeft(3, '0'),
        );
        final first = serving == null || serving.isEmpty;
        final now = DateTime.now();

        transaction.set(_queueRef, {
          'queueId': _queueId,
          'name': data['name'] ?? activeQueueName,
          'isActive': data['isActive'] != false,
          'tokenCounter': current + count,
          'currentServingToken': first ? tokens.first : serving,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        final created = <CustomerTicket>[];
        for (var i = 0; i < tokens.length; i++) {
          final ticket = CustomerTicket(
            tokenId: tokens[i],
            pin: pin,
            userEmail: actualEmail,
            userUid: user.uid,
            joinedTime: now.add(Duration(milliseconds: i)),
            status: i == 0 && first ? TokenStatus.inService : TokenStatus.inQueue,
          );
          created.add(ticket);

          transaction.set(_ticketRef.doc(ticket.tokenId), {
            'tokenId': ticket.tokenId,
            'pin': ticket.pin,
            'userEmail': ticket.userEmail,
            'userUid': ticket.userUid,
            'joinedTime': Timestamp.fromDate(ticket.joinedTime),
            'status': _statusToString(ticket.status),
          });
        }

        return created;
      });
    } on FirebaseException catch (e) {
      throw StateError('Booking failed (${e.code}): ${e.message ?? 'Firestore rejected the booking.'}');
    }
  }

  Future<void> _writeTicket(CustomerTicket ticket) async {
    await _ticketRef.doc(ticket.tokenId).set({
      'tokenId': ticket.tokenId,
      'pin': ticket.pin,
      'userEmail': ticket.userEmail,
      'userUid': ticket.userUid,
      'joinedTime': Timestamp.fromDate(ticket.joinedTime),
      'status': _statusToString(ticket.status),
    });
  }

  Future<void> cancelTicket(String tokenId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Please sign in first.');
    final ref = _ticketRef.doc(tokenId);
    final snapshot = await ref.get();
    if (!snapshot.exists) throw StateError('Ticket no longer exists.');
    final data = snapshot.data() ?? <String, dynamic>{};
    if ((data['userUid'] ?? '').toString() != user.uid) {
      throw StateError('You can only cancel your own ticket.');
    }
    final status = (data['status'] ?? '').toString();
    if (status == 'completed' || status == 'cancelled') {
      throw StateError('This ticket can no longer be cancelled.');
    }
    await ref.update({
      'status': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> hostCancelTicket(String tokenId) async {
    final authorization = await checkStaffAuthorization();

    if (!authorization.authorized) {
      throw StateError(authorization.message);
    }

    final ref = _ticketRef.doc(tokenId);
    final snapshot = await ref.get();

    if (!snapshot.exists) {
      throw StateError('Ticket no longer exists.');
    }

    final data = snapshot.data() ?? <String, dynamic>{};
    final status = (data['status'] ?? '').toString();

    if (status == 'completed') {
      throw StateError('Completed tickets cannot be cancelled.');
    }

    if (status == 'cancelled') {
      throw StateError('This ticket is already cancelled.');
    }

    await ref.update({
      'status': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
      'cancelledBy': 'staff',
    });
  }

  Future<void> advanceQueue() async {
    final current = getCurrentlyServingTicket();
    final waiting = activeQueue.where((t) => t.status == TokenStatus.inQueue).toList();
    final batch = _db.batch();

    if (current != null) {
      batch.set(_ticketRef.doc(current.tokenId), {'status': 'completed'}, SetOptions(merge: true));
    }

    final next = waiting.isEmpty ? null : waiting.first;
    batch.set(_queueRef, {
      'currentServingToken': next?.tokenId,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (next != null) {
      batch.set(_ticketRef.doc(next.tokenId), {'status': 'inService'}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  void setSignedInUser({required String name, required String email}) {
    userName = name; userEmail = email; isRegistered = true; isLoggedIn = true; notifyListeners();
  }

  void setTicketPin(String pin) { savedPin = pin; notifyListeners(); }

  void clearSession() { isRegistered = false; isLoggedIn = false; userName = ""; userEmail = ""; savedPin = ""; notifyListeners(); }

  void refresh() => notifyListeners();
}

class SilentQueueApp extends StatelessWidget {
  const SilentQueueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'SilentQueue',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFF1E1E1E),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0F766E),
              primary: const Color(0xFF0F766E),
            ),
          ),
          home: MobileFrame(
            child: FirebaseAuth.instance.currentUser != null
                ? const RoleSelectionScreen()
                : const WelcomeScreen(),
          ),
        );
      },
    );
  }
}

/// Mobile Frame Shell
class MobileFrame extends StatelessWidget {
  final Widget child;
  const MobileFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF18181C),
      body: Center(
        child: Container(
          width: 390,
          height: 844,
          decoration: BoxDecoration(
            color: const Color(0xFFF7FBF9),
            borderRadius: BorderRadius.circular(40),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 30,
                spreadRadius: 5,
                offset: const Offset(0, 10),
              ),
            ],
            border: Border.all(color: const Color(0xFF2D2D35), width: 8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 1. WELCOME SCREEN
// ==========================================
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FCFA),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  RichText(
                    text: const TextSpan(
                      children: [
                        TextSpan(text: 'silent', style: TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.bold)),
                        TextSpan(text: 'Queue', style: TextStyle(color: Color(0xFF10B981), fontSize: 20, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(16)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.circle, size: 6, color: Color(0xFF10B981)),
                        SizedBox(width: 4),
                        Text('Live', style: TextStyle(color: Color(0xFF047857), fontWeight: FontWeight.bold, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(color: const Color(0xFF10B981).withValues(alpha: 0.08), shape: BoxShape.circle),
                  ),
                  Container(
                    width: 170,
                    height: 170,
                    decoration: BoxDecoration(color: const Color(0xFF10B981).withValues(alpha: 0.18), shape: BoxShape.circle),
                  ),
                  Container(
                    width: 110,
                    height: 110,
                    decoration: const BoxDecoration(color: Color(0xFF0F766E), shape: BoxShape.circle),
                    child: const Center(
                      child: Text('000', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const Text('Your time is yours.', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.black)),
              const SizedBox(height: 8),
              const Text(
                'Join a queue and step away.\nWe\'ll tell you when it\'s time to return.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Color(0xFF6B7280), height: 1.4),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (context) => const RegisterScreen()));
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Text('Join a Queue', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward, color: Colors.white, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, height: 46, child: OutlinedButton(onPressed: () { Navigator.push(context, MaterialPageRoute(builder: (_) => const EmailLoginScreen())); }, child: const Text('Already have an account? Sign in'))),
              const SizedBox(height: 16),
              const Text(
                'No smartphone? That\'s okay.\nYour physical token still works.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 2. REGISTRATION SCREEN
// ==========================================
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _pinController = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _showError(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
  );

  Future<void> _handleRegistration() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final pin = _pinController.text.trim();
    final validEmail = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);

    if (name.isEmpty) return _showError('Please enter your name.');
    if (!validEmail) return _showError('Please enter a valid email address.');
    if (password.length < 6) return _showError('Password must be at least 6 characters.');
    if (pin.length != 4) return _showError('Please create a 4-digit ticket PIN.');

    setState(() => _loading = true);
    try {
      await AuthService.registerCustomer(name: name, email: email, password: password);
      AppState.instance.setSignedInUser(name: name, email: email);
      AppState.instance.setTicketPin(pin);
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
            (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? 'Could not create account.');
    } catch (_) {
      _showError('Could not create account. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _googleSignIn() async {
    setState(() => _loading = true);
    try {
      final result = await AuthService.signInWithGoogle();
      final user = result.user;
      if (user == null) throw Exception('Google account not available.');
      AppState.instance.setSignedInUser(
        name: user.displayName ?? 'Customer',
        email: user.email ?? '',
      );
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const TicketPinSetupScreen()),
            (_) => false,
      );
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? 'Google sign-in failed.');
    } catch (e) {
      _showError('Google sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FBF9),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)), const Spacer(), _BrandLogo()]),
            const SizedBox(height: 34),
            const Text('Create your account', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            const Text('Your Firebase account keeps sign-in secure.', style: TextStyle(color: Color(0xFF6B7280))),
            const SizedBox(height: 28),
            _InputLabel(label: 'Full name'),
            _StyledField(controller: _nameController, hint: 'Your name', icon: Icons.person_outline),
            const SizedBox(height: 16),
            _InputLabel(label: 'Email address'),
            _StyledField(controller: _emailController, hint: 'you@example.com', icon: Icons.mail_outline, keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 16),
            _InputLabel(label: 'Password'),
            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.lock_outline, size: 20),
                suffixIcon: IconButton(icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _obscurePassword = !_obscurePassword)),
                hintText: 'At least 6 characters',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              ),
            ),
            const SizedBox(height: 16),
            _InputLabel(label: '4-digit ticket PIN'),
            _StyledField(controller: _pinController, hint: '••••', icon: Icons.pin_outlined, keyboardType: TextInputType.number, obscureText: true, formatters: [LengthLimitingTextInputFormatter(4), FilteringTextInputFormatter.digitsOnly]),
            const SizedBox(height: 24),
            SizedBox(width: double.infinity, height: 52, child: FilledButton(onPressed: _loading ? null : _handleRegistration, child: _loading ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Create account', style: TextStyle(fontWeight: FontWeight.w700)))),
            const SizedBox(height: 18),
            Row(children: const [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('OR', style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)))), Expanded(child: Divider())]),
            const SizedBox(height: 18),
            SizedBox(width: double.infinity, height: 50, child: OutlinedButton.icon(onPressed: _loading ? null : _googleSignIn, icon: const Icon(Icons.account_circle_outlined), label: const Text('Continue with Google', style: TextStyle(fontWeight: FontWeight.w700)))),
            const SizedBox(height: 18),
            const Center(child: Text('The 4-digit PIN is for your SilentQueue tickets. It is not your Firebase password.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)))),
          ]),
        ),
      ),
    );
  }
}

class _InputLabel extends StatelessWidget {
  final String label;
  const _InputLabel({required this.label});
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 7), child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)));
}

class _StyledField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final bool obscureText;
  final List<TextInputFormatter>? formatters;
  const _StyledField({required this.controller, required this.hint, required this.icon, this.keyboardType, this.obscureText = false, this.formatters});
  @override
  Widget build(BuildContext context) => TextField(controller: controller, keyboardType: keyboardType, obscureText: obscureText, inputFormatters: formatters, decoration: InputDecoration(prefixIcon: Icon(icon, size: 20), hintText: hint, filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16), border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFFE5E7EB))), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFFE5E7EB))), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFF0F766E), width: 1.5))));
}

// ==========================================
// 3. PIN LOGIN SCREEN
// ==========================================
class EmailLoginScreen extends StatefulWidget {
  const EmailLoginScreen({super.key});

  @override
  State<EmailLoginScreen> createState() => _EmailLoginScreenState();
}

class _EmailLoginScreenState extends State<EmailLoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showError(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.redAccent));

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) return _showError('Enter your email and password.');
    setState(() => _loading = true);
    try {
      final result = await AuthService.signInCustomer(email: email, password: password);
      final user = result.user;
      if (user == null) throw Exception('Account not available.');
      AppState.instance.setSignedInUser(name: user.displayName ?? 'Customer', email: user.email ?? email);
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const RoleSelectionScreen()), (_) => false);
    } on FirebaseAuthException catch (e) {
      _showError(e.message ?? 'Sign-in failed.');
    } catch (_) {
      _showError('Sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _googleSignIn() async {
    setState(() => _loading = true);
    try {
      final result = await AuthService.signInWithGoogle();
      final user = result.user;
      if (user == null) throw Exception('Google account not available.');
      AppState.instance.setSignedInUser(name: user.displayName ?? 'Customer', email: user.email ?? '');
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const TicketPinSetupScreen()), (_) => false);
    } catch (_) {
      _showError('Google sign-in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FBF9),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)), const Spacer(), _BrandLogo()]),
            const SizedBox(height: 42),
            Center(child: Container(width: 76, height: 76, decoration: BoxDecoration(color: const Color(0xFFE6F4F1), borderRadius: BorderRadius.circular(24)), child: const Icon(Icons.lock_person_outlined, size: 38, color: Color(0xFF0F766E)))),
            const SizedBox(height: 22),
            Center(child: Text('Welcome back', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
            const SizedBox(height: 6),
            const Center(child: Text('Sign in with your Firebase account', style: TextStyle(color: Color(0xFF6B7280)))),
            const SizedBox(height: 30),
            _InputLabel(label: 'Email address'),
            _StyledField(controller: _emailController, hint: 'you@example.com', icon: Icons.mail_outline, keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 16),
            _InputLabel(label: 'Password'),
            TextField(controller: _passwordController, obscureText: _obscure, decoration: InputDecoration(prefixIcon: const Icon(Icons.lock_outline), suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _obscure = !_obscure)), hintText: 'Your password', filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFFE5E7EB))))),
            const SizedBox(height: 24),
            SizedBox(width: double.infinity, height: 50, child: FilledButton(onPressed: _loading ? null : _signIn, child: _loading ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Sign in', style: TextStyle(fontWeight: FontWeight.w700)))),
            const SizedBox(height: 18),
            Row(children: const [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('OR', style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)))), Expanded(child: Divider())]),
            const SizedBox(height: 18),
            SizedBox(width: double.infinity, height: 50, child: OutlinedButton.icon(onPressed: _loading ? null : _googleSignIn, icon: const Icon(Icons.account_circle_outlined), label: const Text('Continue with Google', style: TextStyle(fontWeight: FontWeight.w700)))),
            const SizedBox(height: 16),
            Center(child: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())), child: const Text('Create a new account'))),
          ]),
        ),
      ),
    );
  }
}

class TicketPinSetupScreen extends StatefulWidget {
  const TicketPinSetupScreen({super.key});
  @override
  State<TicketPinSetupScreen> createState() => _TicketPinSetupScreenState();
}

class _TicketPinSetupScreenState extends State<TicketPinSetupScreen> {
  final _pinController = TextEditingController();
  void _continue() {
    if (_pinController.text.length != 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please create a 4-digit ticket PIN.')));
      return;
    }
    AppState.instance.setTicketPin(_pinController.text);
    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const RoleSelectionScreen()), (_) => false);
  }
  @override
  void dispose() { _pinController.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF7FBF9),
    body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 40),
      const Text('Set your ticket PIN', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      const Text('This PIN is used to view your active SilentQueue tickets.', style: TextStyle(color: Color(0xFF6B7280))),
      const SizedBox(height: 28),
      _InputLabel(label: '4-digit ticket PIN'),
      _StyledField(controller: _pinController, hint: '••••', icon: Icons.pin_outlined, keyboardType: TextInputType.number, obscureText: true, formatters: [LengthLimitingTextInputFormatter(4), FilteringTextInputFormatter.digitsOnly]),
      const Spacer(),
      SizedBox(width: double.infinity, height: 52, child: FilledButton(onPressed: _continue, child: const Text('Continue'))),
    ]))),
  );
}

class StaffLoginScreen extends StatefulWidget {
  const StaffLoginScreen({super.key});
  @override
  State<StaffLoginScreen> createState() => _StaffLoginScreenState();
}

class _StaffLoginScreenState extends State<StaffLoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() { _emailController.dispose(); _passwordController.dispose(); super.dispose(); }
  void _error(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.redAccent));

  Future<void> _signInStaff() async {
    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) return _error('Enter staff email and password.');
    setState(() => _loading = true);
    try {
      final result = await AuthService.signInCustomer(email: email, password: password);
      final user = result.user;
      if (user == null) {
        await AuthService.signOut();
        return _error('Staff authorization failed.');
      }

      final authorization = await checkStaffAuthorization();
      if (!authorization.authorized) {
        await AuthService.signOut();
        return _error(authorization.message);
      }
      AppState.instance.setSignedInUser(name: user.displayName ?? 'Staff', email: user.email ?? email);
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const HostDashboardScreen()), (_) => false);
    } on FirebaseAuthException catch (e) {
      _error(e.message ?? 'Staff sign-in failed.');
    } catch (_) {
      _error('Staff sign-in failed.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _googleStaff() async {
    setState(() => _loading = true);
    try {
      final result = await AuthService.signInWithGoogle();
      final user = result.user;
      if (user == null) {
        await AuthService.signOut();
        return _error('Staff Google sign-in failed.');
      }

      final authorization = await checkStaffAuthorization();
      if (!authorization.authorized) {
        await AuthService.signOut();
        return _error(authorization.message);
      }
      AppState.instance.setSignedInUser(name: user.displayName ?? 'Staff', email: user.email ?? '');
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const HostDashboardScreen()), (_) => false);
    } catch (_) {
      _error('Staff Google sign-in failed.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF7FBF9),
    body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)), const Spacer(), _BrandLogo()]),
      const SizedBox(height: 36),
      const Text('Staff sign in', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      const Text('Only authorized staff accounts can open the Host Dashboard.', style: TextStyle(color: Color(0xFF6B7280))),
      const SizedBox(height: 28),
      _InputLabel(label: 'Staff email'),
      _StyledField(controller: _emailController, hint: 'staff@example.com', icon: Icons.badge_outlined, keyboardType: TextInputType.emailAddress),
      const SizedBox(height: 16),
      _InputLabel(label: 'Password'),
      _StyledField(controller: _passwordController, hint: 'Staff password', icon: Icons.lock_outline, obscureText: true),
      const SizedBox(height: 24),
      SizedBox(width: double.infinity, height: 52, child: FilledButton(onPressed: _loading ? null : _signInStaff, child: _loading ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Staff sign in'))),
      const SizedBox(height: 18),
      Row(children: const [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('OR', style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)))), Expanded(child: Divider())]),
      const SizedBox(height: 18),
      SizedBox(width: double.infinity, height: 50, child: OutlinedButton.icon(onPressed: _loading ? null : _googleStaff, icon: const Icon(Icons.account_circle_outlined), label: const Text('Staff with Google'))),
    ]))),
  );
}

class _BrandLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) => RichText(text: const TextSpan(children: [TextSpan(text: 'silent', style: TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.w800)), TextSpan(text: 'Queue', style: TextStyle(color: Color(0xFF10B981), fontSize: 20, fontWeight: FontWeight.w800))]));
}

// ==========================================
// 4. ROLE SELECTION SCREEN
// ==========================================
class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FCFA),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  RichText(
                    text: const TextSpan(
                      children: [
                        TextSpan(text: 'silent', style: TextStyle(color: Colors.black, fontSize: 22, fontWeight: FontWeight.bold)),
                        TextSpan(text: 'Queue', style: TextStyle(color: Color(0xFF10B981), fontSize: 22, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(16)),
                    child: Row(
                      children: const [
                        Icon(Icons.circle, size: 6, color: Color(0xFF10B981)),
                        SizedBox(width: 4),
                        Text('Live', style: TextStyle(color: Color(0xFF047857), fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                width: 90,
                height: 90,
                decoration: const BoxDecoration(color: Color(0xFFCCFBF1), shape: BoxShape.circle),
                child: const Icon(Icons.person_outline, size: 46, color: Color(0xFF0F766E)),
              ),
              const SizedBox(height: 16),
              Text('Hello, ${AppState.instance.userName}!', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('Select option to join or host a queue', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
              const Spacer(),

              GestureDetector(
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const JoinQueueScreen()));
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: const Color(0xFFE6F4F1), borderRadius: BorderRadius.circular(20)),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: const Icon(Icons.qr_code_scanner, color: Color(0xFF0F766E), size: 24),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text("Scan & Join Queue", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          SizedBox(height: 2),
                          Text('Scan location QR code', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                        ],
                      ),
                      const Spacer(),
                      const Icon(Icons.chevron_right, color: Colors.black54),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              GestureDetector(
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const StaffLoginScreen()));
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: const Color(0xFFE6F4F1), borderRadius: BorderRadius.circular(20)),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: const Icon(Icons.admin_panel_settings_outlined, color: Color(0xFF0F766E), size: 24),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text("Host Dashboard", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          SizedBox(height: 2),
                          Text('Manage queue & calls', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                        ],
                      ),
                      const Spacer(),
                      const Icon(Icons.chevron_right, color: Colors.black54),
                    ],
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 5. SCAN QR SCREEN (Enforces Single Active Booking Rule)
// ==========================================
class JoinQueueScreen extends StatefulWidget {
  const JoinQueueScreen({super.key});

  @override
  State<JoinQueueScreen> createState() => _JoinQueueScreenState();
}

class _JoinQueueScreenState extends State<JoinQueueScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _hasScanned = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;

    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final String? code = barcode.rawValue;
      if (code != null && code.startsWith("SQ-QUEUE-HOST")) {
        setState(() {
          _hasScanned = true;
        });

        if (!AppState.instance.isQueueActive) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This queue is currently stopped by the host.'),
              backgroundColor: Colors.redAccent,
            ),
          );
          setState(() => _hasScanned = false);
          return;
        }

        if (!AppState.instance.isQueueActive) {
          showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text('Queue stopped'), content: const Text('This queue is currently stopped. New customers cannot join.'), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))]));
          return;
        }

        // RULE: Check if email already has active tickets
        if (AppState.instance.hasActiveTicketsForEmail(AppState.instance.userEmail)) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Active Booking Exists'),
              content: const Text('You already have active tickets for this email address. You can only book once at a time.'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) => TicketStatusScreen(pin: AppState.instance.savedPin),
                      ),
                    );
                  },
                  child: const Text('View Active Tickets'),
                ),
              ],
            ),
          );
          return;
        }

        // Prompt user for ticket count
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const TicketQuantityScreen()),
        );
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FCFA),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.black),
                    onPressed: () => Navigator.pop(context),
                  ),
                  RichText(
                    text: const TextSpan(
                      children: [
                        TextSpan(text: 'silent', style: TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.bold)),
                        TextSpan(text: 'Queue', style: TextStyle(color: Color(0xFF10B981), fontSize: 20, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(16)),
                    child: const Text('• Live', style: TextStyle(color: Color(0xFF047857), fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text('JOIN A QUEUE', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
              const Spacer(),

              Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(color: const Color(0xFFE6F4F1), borderRadius: BorderRadius.circular(24)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: MobileScanner(
                    controller: _scannerController,
                    onDetect: _onDetect,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Scan the QR code provided at the location.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),

              const Spacer(),

              GestureDetector(
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const CheckTicketPinScreen()));
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(20)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: const Color(0xFF0F766E), borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.confirmation_number, color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('Already have token?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black)),
                          Text('ENTER PIN →', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF0F766E))),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 6. TICKET QUANTITY SELECTION SCREEN
// ==========================================
class TicketQuantityScreen extends StatefulWidget {
  const TicketQuantityScreen({super.key});

  @override
  State<TicketQuantityScreen> createState() => _TicketQuantityScreenState();
}

class _TicketQuantityScreenState extends State<TicketQuantityScreen> {
  int _selectedQuantity = 1;

  Future<void> _confirmAndBook() async {
    if (!AppState.instance.isQueueActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This queue has been stopped by the host.'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    try {
      List<CustomerTicket> booked = await AppState.instance.bookCustomerTickets(
        _selectedQuantity,
        AppState.instance.savedPin,
        AppState.instance.userEmail,
      );

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => TokenVerificationScreen(tickets: booked)),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'Queue is unavailable'), backgroundColor: Colors.redAccent));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', '')), backgroundColor: Colors.redAccent, duration: const Duration(seconds: 6)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FCFA),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            children: [
              const SizedBox(height: 10),
              const Text('Select Number of Tickets', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('How many people are joining with you?', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              const Spacer(),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 40,
                    icon: const Icon(Icons.remove_circle_outline, color: Color(0xFF0F766E)),
                    onPressed: _selectedQuantity > 1 ? () => setState(() => _selectedQuantity--) : null,
                  ),
                  const SizedBox(width: 24),
                  Text('$_selectedQuantity', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w800, color: Color(0xFF0F766E))),
                  const SizedBox(width: 24),
                  IconButton(
                    iconSize: 40,
                    icon: const Icon(Icons.add_circle_outline, color: Color(0xFF0F766E)),
                    onPressed: _selectedQuantity < 5 ? () => setState(() => _selectedQuantity++) : null,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Maximum 5 tickets per booking session', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),

              const Spacer(),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _confirmAndBook,
                  child: Text('Confirm $_selectedQuantity Ticket(s)', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 7. TOKEN VERIFICATION SCREEN (Batch Generated)
// ==========================================
class TokenVerificationScreen extends StatelessWidget {
  final List<CustomerTicket> tickets;
  const TokenVerificationScreen({super.key, required this.tickets});

  @override
  Widget build(BuildContext context) {
    String tokenRange = tickets.length > 1
        ? "${tickets.first.tokenId} - ${tickets.last.tokenId}"
        : tickets.first.tokenId;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FCFA),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.black),
                  onPressed: () => Navigator.pop(context),
                ),
                RichText(
                  text: const TextSpan(
                    children: [
                      TextSpan(text: 'silent', style: TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.bold)),
                      TextSpan(text: 'Queue', style: TextStyle(color: Color(0xFF10B981), fontSize: 20, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(16)),
                  child: const Text('• Live', style: TextStyle(color: Color(0xFF047857), fontWeight: FontWeight.bold, fontSize: 11)),
                ),
              ],
            ),
            const Spacer(),

            Container(
              width: 140,
              height: 100,
              decoration: BoxDecoration(color: const Color(0xFFCCFBF1), borderRadius: BorderRadius.circular(24)),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF10B981))),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(tokenRange, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F766E))),
                      const SizedBox(width: 6),
                      const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 18),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            const Text('Tokens Verified!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('${tickets.length} digital token(s) linked to your email and PIN.', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),

            const SizedBox(height: 24),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFFE6F4F1), borderRadius: BorderRadius.circular(16)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('YOUR QUEUE TOKEN(S)', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF0F766E))),
                      const SizedBox(height: 4),
                      Text(tokenRange, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Color(0xFF0F766E))),
                    ],
                  ),
                  const Icon(Icons.local_activity_outlined, color: Color(0xFF0F766E), size: 36),
                ],
              ),
            ),

            const Spacer(),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F766E),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (context) => TicketStatusScreen(pin: tickets.first.pin)),
                  );
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Text('Continue to Queue Tracker', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                    SizedBox(width: 8),
                    Icon(Icons.arrow_forward, color: Colors.white, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
      ),
    );
  }
}

// ==========================================
// 8. QUEUE STATUS SCREEN (Displays ALL Tokens Linked To PIN)
// ==========================================
class TicketStatusScreen extends StatelessWidget {
  final String pin;
  const TicketStatusScreen({super.key, required this.pin});

  Future<void> _cancel(BuildContext context, CustomerTicket ticket) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel ticket?'),
        content: Text('Cancel token ${ticket.tokenId}? You will lose your place in the queue.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Ticket')),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel Ticket'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;
    try {
      await AppState.instance.cancelTicket(ticket.tokenId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ticket ${ticket.tokenId} cancelled.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.instance,
      builder: (context, _) {
        final state = AppState.instance;
        final email = FirebaseAuth.instance.currentUser?.email ?? state.userEmail;
        final allMine = state.tickets
            .where((t) => t.userEmail.toLowerCase() == email.toLowerCase() && (pin.isEmpty || t.pin == pin))
            .toList();
        final active = allMine.where((t) => t.status == TokenStatus.inQueue || t.status == TokenStatus.inService).toList();
        final completed = allMine.where((t) => t.status == TokenStatus.completed).toList();
        final cancelled = allMine.where((t) => t.status == TokenStatus.cancelled).toList();
        final serving = state.currentServingToken ?? '000';
        final waiting = state.tickets.where((t) => t.status == TokenStatus.inQueue).length;
        final flow = state.isQueueDelayed ? 'Delayed' : (state.isQueueMovingQuickly ? 'Moving Fast' : 'Normal');

        return Scaffold(
          backgroundColor: const Color(0xFFF8FCFA),
          appBar: AppBar(
            backgroundColor: const Color(0xFFF8FCFA),
            elevation: 0,
            title: const Text('Track My Ticket', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              state.refresh();
              await Future<void>.delayed(const Duration(milliseconds: 300));
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: state.isQueueActive ? const Color(0xFF0F766E) : const Color(0xFF374151),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(state.activeQueueName, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))),
                          Text(state.isQueueActive ? 'LIVE' : 'STOPPED', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(child: _TrackStat(label: 'NOW SERVING', value: serving)),
                          Expanded(child: _TrackStat(label: 'WAITING', value: '$waiting')),
                          Expanded(child: _TrackStat(label: 'FLOW', value: flow)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (active.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                    child: const Text('You have no active tickets.', style: TextStyle(fontWeight: FontWeight.w600)),
                  )
                else ...[
                  const Text('Your Active Tickets', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  ...active.map((ticket) {
                    final ahead = state.getPeopleAhead(ticket.tokenId);
                    final wait = state.getEstimatedWaitMinutes(ticket.tokenId);
                    final servingNow = ticket.status == TokenStatus.inService;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: servingNow ? const Color(0xFFD1FAE5) : Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: servingNow ? const Color(0xFF10B981) : const Color(0xFFE5E7EB)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Text(ticket.tokenId, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
                              const SizedBox(width: 12),
                              Expanded(child: Text(servingNow ? 'YOUR TURN — NOW SERVING' : 'WAITING', style: TextStyle(color: servingNow ? const Color(0xFF047857) : const Color(0xFF6B7280), fontWeight: FontWeight.w800, fontSize: 12))),
                              IconButton(
                                tooltip: 'Cancel ticket',
                                onPressed: servingNow ? null : () => _cancel(context, ticket),
                                icon: const Icon(Icons.cancel_outlined),
                                color: Colors.redAccent,
                              ),
                            ],
                          ),
                          const Divider(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _MiniStat(icon: Icons.people_outline, label: 'People ahead', value: '$ahead'),
                              _MiniStat(icon: Icons.schedule, label: 'Est. wait', value: '$wait min'),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                ],
                const SizedBox(height: 8),
                const Text('Queue Progress', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE5E7EB))),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Completed: ${completed.isEmpty ? 'None yet' : completed.map((t) => t.tokenId).join(', ')}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text('Serving now: $serving', style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0F766E))),
                      const SizedBox(height: 8),
                      Text('Waiting: ${state.activeQueue.where((t) => t.status == TokenStatus.inQueue).map((t) => t.tokenId).join(', ')}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (cancelled.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('Cancelled: ${cancelled.map((t) => t.tokenId).join(', ')}', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFE6F4F1), borderRadius: BorderRadius.circular(16)),
                  child: const Row(
                    children: [
                      Icon(Icons.sync, color: Color(0xFF0F766E)),
                      SizedBox(width: 10),
                      Expanded(child: Text('This page updates automatically when the queue moves.', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TrackStat extends StatelessWidget {
  final String label;
  final String value;
  const _TrackStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
    ],
  );
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _MiniStat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: const Color(0xFF0F766E)),
      const SizedBox(width: 6),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
      ]),
    ],
  );
}

// ==========================================
// 9. ENTER PIN CHECK SCREEN
// ==========================================
class CheckTicketPinScreen extends StatefulWidget {
  const CheckTicketPinScreen({super.key});

  @override
  State<CheckTicketPinScreen> createState() => _CheckTicketPinScreenState();
}

class _CheckTicketPinScreenState extends State<CheckTicketPinScreen> {
  final List<TextEditingController> _pinControllers = List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _nodes = List.generate(4, (_) => FocusNode());

  void _verifyAndProceed() {
    String enteredPin = _pinControllers.map((e) => e.text).join();

    if (enteredPin.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter full 4-digit PIN.'), backgroundColor: Colors.orangeAccent),
      );
      return;
    }

    List<CustomerTicket> tickets = AppState.instance.getActiveTicketsByPin(enteredPin);

    if (tickets.isNotEmpty) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => TicketStatusScreen(pin: enteredPin)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active tickets found for this PIN.'), backgroundColor: Colors.redAccent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FCFA),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.black),
                    onPressed: () => Navigator.pop(context),
                  ),
                  RichText(
                    text: const TextSpan(
                      children: [
                        TextSpan(text: 'silent', style: TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.bold)),
                        TextSpan(text: 'Queue', style: TextStyle(color: Color(0xFF10B981), fontSize: 20, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(16)),
                    child: const Text('• Live', style: TextStyle(color: Color(0xFF047857), fontSize: 11, fontWeight: FontWeight.bold)),
                  )
                ],
              ),
              const Spacer(),
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(color: Color(0xFF0F766E), shape: BoxShape.circle),
                child: const Icon(Icons.lock_outline, size: 36, color: Colors.white),
              ),
              const SizedBox(height: 20),
              const Text('Enter Security PIN', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('Enter your 4 digit PIN to track all active tokens', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(height: 28),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (index) {
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(14)),
                    child: TextField(
                      controller: _pinControllers[index],
                      focusNode: _nodes[index],
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      obscureText: true,
                      obscuringCharacter: '•',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      inputFormatters: [LengthLimitingTextInputFormatter(1), FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(border: InputBorder.none, counterText: ''),
                      onChanged: (val) {
                        if (val.isNotEmpty && index < 3) {
                          _nodes[index + 1].requestFocus();
                        } else if (val.isEmpty && index > 0) {
                          _nodes[index - 1].requestFocus();
                        }
                      },
                    ),
                  );
                }),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _verifyAndProceed,
                  child: const Text('Check Tickets', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 10. HOST DASHBOARD SCREEN
// ==========================================
class HostDashboardScreen extends StatefulWidget {
  const HostDashboardScreen({super.key});

  @override
  State<HostDashboardScreen> createState() => _HostDashboardScreenState();
}

class _HostDashboardScreenState extends State<HostDashboardScreen> {
  final TextEditingController _timeController = TextEditingController(text: '3');

  @override
  void dispose() {
    _timeController.dispose();
    super.dispose();
  }

  bool _queueActionRunning = false;

  Future<void> _toggleQueue() async {
    if (_queueActionRunning) return;

    final state = AppState.instance;

    if (state.isQueueActive) {
      final shouldStop = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Stop Queue?'),
          content: const Text(
            'New customers will not be able to join. '
                'Existing tickets will remain available for service.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop Queue'),
            ),
          ],
        ),
      );

      if (shouldStop != true) return;
    }

    setState(() => _queueActionRunning = true);

    try {
      if (state.isQueueActive) {
        await state.stopQueue();
      } else {
        await state.startQueue();
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state.isQueueActive
                ? 'Queue started successfully.'
                : 'Queue stopped successfully.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Bad state: ', ''),
          ),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _queueActionRunning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StaffAuthorizationResult>(
      future: checkStaffAuthorization(),
      builder: (context, authorizationSnapshot) {
        if (authorizationSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final authorization = authorizationSnapshot.data;
        if (authorization == null || !authorization.authorized) {
          return const StaffLoginScreen();
        }

        return AnimatedBuilder(
          animation: AppState.instance,
          builder: (context, _) {
            final state = AppState.instance;
            final activeList = state.activeQueue;
            final serving = state.getCurrentlyServingTicket();

            return Scaffold(
              backgroundColor: const Color(0xFFF7FBF9),
              appBar: AppBar(
                backgroundColor: const Color(0xFFF7FBF9),
                elevation: 0,
                title: const Text('Queue Dashboard', style: TextStyle(fontWeight: FontWeight.w700)),
                actions: [
                  IconButton(
                    tooltip: 'Show QR',
                    icon: const Icon(Icons.qr_code_2),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HostQRDisplayScreen())),
                  ),
                  IconButton(
                    tooltip: 'Sign out',
                    icon: const Icon(Icons.logout),
                    onPressed: () async {
                      await AuthService.signOut();
                      AppState.instance.clearSession();
                      if (!context.mounted) return;
                      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const WelcomeScreen()), (_) => false);
                    },
                  ),
                ],
              ),
              body: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: state.isQueueActive ? const Color(0xFF0F766E) : const Color(0xFF374151),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(state.activeQueueName, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700))),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(color: Colors.white.withValues(alpha: .16), borderRadius: BorderRadius.circular(20)),
                                child: Text(state.isQueueActive ? 'ACTIVE' : 'STOPPED', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(child: _InfoStat(label: 'NOW SERVING', value: serving?.tokenId ?? '000')),
                              Expanded(child: _InfoStat(label: 'WAITING', value: '${activeList.where((t) => t.status == TokenStatus.inQueue).length}')),
                              Expanded(child: _InfoStat(label: 'FLOW', value: state.isQueueDelayed ? 'Delayed' : 'Fast')),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: state.isQueueActive ? () async {
                              try {
                                final t = await state.bookWalkInTicket();
                                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Token ${t.tokenId} added')));
                              } catch (e) {
                                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
                              }
                            } : null,
                            icon: const Icon(Icons.person_add_alt_1),
                            label: const Text('Add Walk-In'),
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: const Color(0xFF0F766E)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: activeList.isNotEmpty ? () => state.advanceQueue() : null,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Call Next'),
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _queueActionRunning ? null : _toggleQueue,
                            icon: _queueActionRunning
                                ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                                : Icon(
                              state.isQueueActive
                                  ? Icons.stop_circle_outlined
                                  : Icons.play_circle_outline,
                            ),
                            label: Text(
                              _queueActionRunning
                                  ? 'Updating...'
                                  : (state.isQueueActive
                                  ? 'Stop Queue'
                                  : 'Start Queue'),
                            ),
                            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE5E7EB))),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Queue Flow', style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(child: ChoiceChip(label: const Text('Fast Flow'), selected: !state.isQueueDelayed, onSelected: (_) { state.isQueueDelayed = false; state.isQueueMovingQuickly = true; state.serviceTimePerPersonMinutes = 3; _timeController.text = '3'; state.refresh(); })),
                              const SizedBox(width: 8),
                              Expanded(child: ChoiceChip(label: const Text('Delayed Flow'), selected: state.isQueueDelayed, onSelected: (_) { state.isQueueDelayed = true; state.isQueueMovingQuickly = false; state.serviceTimePerPersonMinutes = 7; _timeController.text = '7'; state.refresh(); })),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('Custom mins/person', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                              const Spacer(),
                              SizedBox(width: 58, height: 38, child: TextField(controller: _timeController, keyboardType: TextInputType.number, textAlign: TextAlign.center, decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.zero), onChanged: (v) { final n = int.tryParse(v); if (n != null && n > 0) { state.serviceTimePerPersonMinutes = n; state.delayMinutes = 0; state.refresh(); } })),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerLeft, child: Text('Queue Tokens', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                    const SizedBox(height: 6),
                    Expanded(
                      child: activeList.isEmpty
                          ? const Center(child: Text('No active tokens yet.'))
                          : ListView.separated(
                        itemCount: activeList.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, index) {
                          final ticket = activeList[index];
                          final servingNow = ticket.status == TokenStatus.inService;
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(color: servingNow ? const Color(0xFFD1FAE5) : Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: servingNow ? const Color(0xFF10B981) : const Color(0xFFE5E7EB))),
                            child: Row(children: [
                              Text(ticket.tokenId, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                              const SizedBox(width: 10),
                              Text(servingNow ? 'Serving now' : 'Waiting', style: TextStyle(fontSize: 12, color: servingNow ? const Color(0xFF047857) : const Color(0xFF6B7280), fontWeight: FontWeight.w600)),
                              const Spacer(),
                              IconButton(
                                onPressed: () async {
                                  try {
                                    await state.hostCancelTicket(ticket.tokenId);
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Token ${ticket.tokenId} cancelled successfully.',
                                        ),
                                      ),
                                    );
                                  } catch (e) {
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          e.toString().replaceFirst('Bad state: ', ''),
                                        ),
                                        backgroundColor: Colors.redAccent,
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(
                                  Icons.close,
                                  size: 19,
                                  color: Colors.redAccent,
                                ),
                              ),
                            ]),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _InfoStat extends StatelessWidget {
  final String label;
  final String value;
  const _InfoStat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.w600)), const SizedBox(height: 3), Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))]);
}

// ==========================================
// 11. HOST DISPLAY QR SCREEN
// ==========================================
class HostQRDisplayScreen extends StatelessWidget {
  const HostQRDisplayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.instance,
      builder: (context, _) {
        final state = AppState.instance;
        return Scaffold(
          backgroundColor: const Color(0xFFF7FBF9),
          appBar: AppBar(backgroundColor: const Color(0xFFF7FBF9), elevation: 0, title: const Text('Queue QR', style: TextStyle(fontWeight: FontWeight.w700))),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(state.isQueueActive ? 'Scan to Join' : 'Queue Stopped', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(state.activeQueueName, style: const TextStyle(color: Color(0xFF6B7280))),
                  const SizedBox(height: 24),
                  Opacity(
                    opacity: state.isQueueActive ? 1 : .25,
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .06), blurRadius: 20)]),
                      child: QrImageView(data: state.activeQueueId, version: QrVersions.auto, size: 230, foregroundColor: const Color(0xFF0F766E)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: state.isQueueActive ? const Color(0xFFD1FAE5) : const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(20)), child: Text(state.isQueueActive ? 'QUEUE IS ACTIVE' : 'QUEUE IS STOPPED', style: TextStyle(color: state.isQueueActive ? const Color(0xFF047857) : const Color(0xFFB91C1C), fontWeight: FontWeight.w700, fontSize: 11))),
                  const SizedBox(height: 12),
                  Text(state.isQueueActive ? 'Customers can scan this QR to join.' : 'Customers cannot join until the host starts the queue again.', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
