// ═══════════════════════════════════════════════════════════════════════
// CivicAI — Smart Governance Platform  (v2 — Auth + Roles + Live Tracking)
// Flutter + Firebase (Auth + Firestore) — single-file app
//
// Runs on: Android, iOS, and Web from the same codebase.
//
// ── PUBSPEC.YAML — add these under dependencies: ──────────────────────
//   firebase_core: ^3.6.0
//   firebase_auth: ^5.3.1
//   cloud_firestore: ^5.4.4
//   intl: ^0.19.0
//   animated_text_kit: ^4.2.2
//   http: ^1.2.2
//   google_fonts: ^6.2.1
//
// ── SETUP ─────────────────────────────────────────────────────────────
//   1. flutter create . --platforms=android,ios,web  (if not already)
//   2. dart pub global activate flutterfire_cli && flutterfire configure
//      (generates lib/firebase_options.dart with your real project keys)
//   3. In Firebase console → Authentication → enable "Email/Password".
//   4. flutter pub get
//   5. flutter run   (or flutter run -d chrome for web)
//
// ── FIRESTORE DATA MODEL ────────────────────────────────────────────────
//   users/{uid}:
//     { name, email, role: "citizen", createdAt }
//     (admin is NOT a Firestore user — it's a fixed local login, see below)
//
//   issues/{id}:
//     { title, description, category, priority, department, status,
//       userId, userName, createdAt }
//     status ∈ "PENDING" | "IN_PROGRESS" | "RESOLVED"
//
// ── ADMIN LOGIN ─────────────────────────────────────────────────────────
//   username: admin   |   password: 123456
//   Admin never registers — it's a fixed local gate that unlocks the
//   Admin Dashboard, which streams every citizen's issues in real time.
//
// ── IBM GRANITE (watsonx.ai) ─────────────────────────────────────────────
//   See IBMGraniteService below — drop your IBM Cloud API key + watsonx
//   project id into the two constants to switch the classifier from the
//   local keyword-matcher over to a real Granite model call. The app
//   works out of the box on the local matcher until you do.
// ═══════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:animated_text_kit/animated_text_kit.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    debugPrint('Firebase init skipped/failed: $e');
    // Demo-mode safety net: don't leave the app stuck on a spinner
    // forever if firebase_options.dart hasn't been configured yet.
    appState.forceReady();
  }
  runApp(const CivicAIApp());
}

// ═══════════════════════════════════════════════════════════════════════
// THEME
// ═══════════════════════════════════════════════════════════════════════
class AppColors {
  static const void_ = Color(0xFF04060D);
  static const void2 = Color(0xFF090E1C);
  static const navy = Color(0xFF0D1428);
  static const electric = Color(0xFF00D4FF);
  static const gold = Color(0xFFF5A623);
  static const rose = Color(0xFFFF4D8D);
  static const lime = Color(0xFF39E58C);
  static const violet = Color(0xFFA78BFA);
  static const magenta = Color(0xFFE84FFF);
  static const text1 = Color(0xFFF3F6FF);
  static const text2 = Color(0xFF9BAAC8);
  static const text3 = Color(0xFF5A6785);
  static const glass = Color(0x0FFFFFFF);
  static const glassLine = Color(0x1AFFFFFF);

  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [electric, violet, magenta],
  );
  static const goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gold, rose],
  );
}

Color statusColor(String s) {
  switch (s) {
    case 'RESOLVED':
      return AppColors.lime;
    case 'IN_PROGRESS':
      return AppColors.electric;
    default:
      return AppColors.gold; // PENDING
  }
}

String statusLabel(String s) {
  switch (s) {
    case 'RESOLVED':
      return 'Resolved';
    case 'IN_PROGRESS':
      return 'In Progress';
    default:
      return 'Pending';
  }
}

Color priorityColor(String p) {
  switch (p) {
    case 'CRITICAL':
      return AppColors.rose;
    case 'HIGH':
      return AppColors.gold;
    case 'MEDIUM':
      return AppColors.electric;
    default:
      return AppColors.lime;
  }
}

TextStyle heading(double size, {Color color = AppColors.text1, FontWeight w = FontWeight.w800, double letterSpacing = -0.5}) {
  return GoogleFonts.poppins(fontSize: size, fontWeight: w, color: color, letterSpacing: letterSpacing, height: 1.15);
}

class CivicAIApp extends StatelessWidget {
  const CivicAIApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CivicAI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.void_,
        fontFamily: GoogleFonts.inter().fontFamily,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.electric,
          secondary: AppColors.violet,
          surface: AppColors.void2,
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// RESPONSIVE HELPERS
// ═══════════════════════════════════════════════════════════════════════
enum DeviceType { mobile, tablet, desktop }

DeviceType deviceTypeOf(BuildContext context) {
  final w = MediaQuery.of(context).size.width;
  if (w < 640) return DeviceType.mobile;
  if (w < 1024) return DeviceType.tablet;
  return DeviceType.desktop;
}

double horizontalPadding(BuildContext context) {
  switch (deviceTypeOf(context)) {
    case DeviceType.mobile:
      return 20;
    case DeviceType.tablet:
      return 40;
    case DeviceType.desktop:
      return 64;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ISSUE CLASSIFICATION
// ═══════════════════════════════════════════════════════════════════════
class IssueType {
  final String key;
  final String label;
  final String icon;
  final String department;
  final String priority;
  final Color color;
  const IssueType(this.key, this.label, this.icon, this.department, this.priority, this.color);
}

const Map<String, IssueType> kIssueTypes = {
  'pothole': IssueType('pothole', 'Pothole', '🕳️', 'PWD Department', 'CRITICAL', AppColors.rose),
  'water': IssueType('water', 'No Water Supply', '💧', 'Jal Board', 'HIGH', AppColors.gold),
  'light': IssueType('light', 'Street Light Out', '💡', 'Electricity Dept', 'MEDIUM', AppColors.electric),
  'garbage': IssueType('garbage', 'Garbage Issue', '🗑️', 'Sanitation Dept', 'HIGH', AppColors.gold),
  'sewage': IssueType('sewage', 'Sewage Overflow', '🚿', 'Jal Board', 'CRITICAL', AppColors.rose),
  'other': IssueType('other', 'General Issue', '📋', 'Municipal Office', 'LOW', AppColors.lime),
};

IssueType classifyIssueLocally(String text) {
  final t = text.toLowerCase();
  if (RegExp(r'pothole|road|tar|crater|bump').hasMatch(t)) return kIssueTypes['pothole']!;
  if (RegExp(r'water|supply|pipeline|tap|leakage|burst').hasMatch(t)) return kIssueTypes['water']!;
  if (RegExp(r'light|lamp|dark|electricity|bulb').hasMatch(t)) return kIssueTypes['light']!;
  if (RegExp(r'garbage|trash|waste|rubbish|litter|dump').hasMatch(t)) return kIssueTypes['garbage']!;
  if (RegExp(r'sewage|drain|overflow|gutter|sewer').hasMatch(t)) return kIssueTypes['sewage']!;
  return kIssueTypes['other']!;
}

// ── IBM watsonx.ai Granite classifier hook ──────────────────────────────
// Fill in your IBM Cloud API key + watsonx project id below to switch the
// classifier from local keyword-matching to a live Granite model call.
// Get an API key at https://cloud.ibm.com/iam/apikeys and a project id
// from your watsonx.ai project. Until these are set, the app safely falls
// back to the local matcher above — nothing breaks.
class IBMGraniteService {
  static const String ibmApiKey = ''; // <-- put your IBM Cloud API key here
  static const String ibmProjectId = ''; // <-- put your watsonx.ai project id here
  static const String ibmModelId = 'ibm/granite-13b-instruct-v2';
  static const String ibmUrl =
      'https://us-south.ml.cloud.ibm.com/ml/v1/text/generation?version=2023-05-29';

  static Future<IssueType> classify(String description) async {
    if (ibmApiKey.isEmpty || ibmProjectId.isEmpty) {
      return classifyIssueLocally(description);
    }
    try {
      final token = await _iamToken();
      final prompt =
          'Classify this civic complaint into exactly one word from: '
          'pothole, water, light, garbage, sewage, other.\n'
          'Complaint: "$description"\nCategory:';
      final res = await http
          .post(
        Uri.parse(ibmUrl),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({
          'model_id': ibmModelId,
          'project_id': ibmProjectId,
          'input': prompt,
          'parameters': {'max_new_tokens': 6, 'temperature': 0},
        }),
      )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final out = (data['results']?[0]?['generated_text'] ?? '').toString().toLowerCase();
        for (final key in kIssueTypes.keys) {
          if (out.contains(key)) return kIssueTypes[key]!;
        }
      }
    } catch (e) {
      debugPrint('IBM Granite classification failed, using local fallback: $e');
    }
    return classifyIssueLocally(description);
  }

  static Future<String> _iamToken() async {
    final res = await http.post(
      Uri.parse('https://iam.cloud.ibm.com/identity/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'urn:ibm:params:oauth:grant-type:apikey',
        'apikey': ibmApiKey,
      },
    );
    final data = jsonDecode(res.body);
    return data['access_token'] as String;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// AUTH / APP STATE
// ═══════════════════════════════════════════════════════════════════════
class AppUserProfile {
  final String uid;
  final String name;
  final String email;
  final String role;
  AppUserProfile({required this.uid, required this.name, required this.email, required this.role});

  factory AppUserProfile.fromMap(String uid, Map<String, dynamic> map) => AppUserProfile(
    uid: uid,
    name: (map['name'] ?? '').toString(),
    email: (map['email'] ?? '').toString(),
    role: (map['role'] ?? 'citizen').toString(),
  );
}

class AppState extends ChangeNotifier {
  User? firebaseUser;
  AppUserProfile? profile;
  bool isAdmin = false;
  bool initializing = true;

  AppState() {
    FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
    // Safety net for demo/dev mode: if Firebase never fires an event
    // (e.g. firebase_options.dart not configured), don't hang forever.
    Timer(const Duration(seconds: 4), () {
      if (initializing) forceReady();
    });
  }

  void forceReady() {
    initializing = false;
    notifyListeners();
  }

  Future<void> _onAuthChanged(User? user) async {
    firebaseUser = user;
    profile = null;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        if (doc.exists) profile = AppUserProfile.fromMap(user.uid, doc.data()!);
      } catch (e) {
        debugPrint('Failed to load profile: $e');
      }
    }
    initializing = false;
    notifyListeners();
  }

  Future<String?> register(String name, String email, String password) async {
    try {
      final cred = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email.trim(), password: password);
      await FirebaseFirestore.instance.collection('users').doc(cred.user!.uid).set({
        'name': name.trim(),
        'email': email.trim(),
        'role': 'citizen',
        'createdAt': FieldValue.serverTimestamp(),
      });
      profile = AppUserProfile(uid: cred.user!.uid, name: name.trim(), email: email.trim(), role: 'citizen');
      firebaseUser = cred.user;
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      debugPrint('REGISTER FirebaseAuthException → code: ${e.code}, message: ${e.message}');
      return _friendlyAuthError(e);
    } catch (e, st) {
      debugPrint('REGISTER unexpected error: $e\n$st');
      return 'Could not reach Firebase. Check your internet connection and firebase_options.dart setup. ($e)';
    }
  }

  Future<String?> login(String email, String password) async {
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: email.trim(), password: password);
      return null;
    } on FirebaseAuthException catch (e) {
      debugPrint('LOGIN FirebaseAuthException → code: ${e.code}, message: ${e.message}');
      return _friendlyAuthError(e);
    } catch (e, st) {
      debugPrint('LOGIN unexpected error: $e\n$st');
      return 'Could not reach Firebase. Check your internet connection and firebase_options.dart setup. ($e)';
    }
  }

  String? loginAdmin(String username, String password) {
    if (username.trim().toLowerCase() == 'admin' && password == '123456') {
      isAdmin = true;
      notifyListeners();
      return null;
    }
    return 'Invalid admin credentials';
  }

  Future<void> logout() async {
    isAdmin = false;
    profile = null;
    if (FirebaseAuth.instance.currentUser != null) {
      await FirebaseAuth.instance.signOut();
    }
    notifyListeners();
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return 'An account already exists for that email — try logging in.';
      case 'invalid-email':
        return 'That email address looks invalid.';
      case 'weak-password':
        return 'Please use a stronger password (6+ characters).';
      case 'user-not-found':
      case 'invalid-credential':
      case 'wrong-password':
        return 'Incorrect email or password.';
      case 'operation-not-allowed':
        return 'Email/Password sign-in isn\'t enabled yet.\nFix: Firebase Console → Authentication → Sign-in method → enable "Email/Password".';
      case 'configuration-not-found':
      case 'invalid-api-key':
      case 'api-key-not-valid.-please-pass-a-valid-api-key.':
        return 'Firebase isn\'t configured correctly for this app.\nFix: run "flutterfire configure" again and make sure firebase_options.dart has your real project keys.';
      case 'network-request-failed':
        return 'Network error — check your internet connection and try again.';
      case 'unknown':
      // Flutter-web sometimes wraps a bare JS "Error" here with no
      // useful message — this almost always means Email/Password
      // sign-in is disabled, or the Web app config is wrong.
        return 'Firebase rejected the request (code: unknown, message: "${e.message}").\n'
            'Most common fix: Firebase Console → Authentication → Sign-in method → '
            'enable "Email/Password", and confirm firebase_options.dart matches your project\'s Web app.';
      default:
        return '${e.message ?? "Authentication failed"} (code: ${e.code})';
    }
  }
}

final appState = AppState();

// ═══════════════════════════════════════════════════════════════════════
// FIRESTORE ISSUE SERVICE
// ═══════════════════════════════════════════════════════════════════════
class IssueService {
  final _col = FirebaseFirestore.instance.collection('issues');

  // NOTE: intentionally no .orderBy() here — combining where() + orderBy()
  // on different fields requires a Firestore composite index to be created
  // manually in the console. We sort client-side instead (see _MyReportsSection)
  // so this works instantly with zero Firestore console setup.
  Stream<QuerySnapshot<Map<String, dynamic>>> myIssuesStream(String uid) {
    return _col.where('userId', isEqualTo: uid).snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> allIssuesStream() {
    return _col.orderBy('createdAt', descending: true).snapshots();
  }

  Future<IssueType> reportIssue(String description, {required String uid, required String userName}) async {
    final type = await IBMGraniteService.classify(description);
    await _col.add({
      'title': type.label,
      'description': description,
      'category': type.key,
      'priority': type.priority,
      'department': type.department,
      'status': 'PENDING',
      'userId': uid,
      'userName': userName,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return type;
  }

  Future<void> updateStatus(String docId, String status) => _col.doc(docId).update({'status': status});
}

final issueService = IssueService();

// ═══════════════════════════════════════════════════════════════════════
// SPLASH SCREEN
// ═══════════════════════════════════════════════════════════════════════
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  // Slow ambient rotation for the glow ring behind the logo.
  late final AnimationController _ringController;
  // Gentle pulse-glow behind the logo mark.
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.85, end: 1.0)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _controller.forward();

    _ringController = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);

    Timer(const Duration(milliseconds: 2800), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 500),
            pageBuilder: (_, __, ___) => const AuthGate(),
            transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _ringController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.2),
                radius: 1.2,
                colors: [AppColors.navy, AppColors.void_],
              ),
            ),
          ),
          const _BackgroundOrbs(),
          Center(
            child: FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                scale: _scale,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Rotating gradient halo + pulsing glow behind the logo mark.
                    SizedBox(
                      width: 168,
                      height: 168,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_ringController, _pulseController]),
                        builder: (context, _) {
                          final pulse = 0.85 + (_pulseController.value * 0.25);
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              Transform.rotate(
                                angle: _ringController.value * 2 * math.pi,
                                child: Container(
                                  width: 168,
                                  height: 168,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: SweepGradient(
                                      colors: [
                                        AppColors.electric,
                                        AppColors.violet,
                                        AppColors.magenta,
                                        AppColors.gold,
                                        AppColors.electric,
                                      ],
                                    ),
                                  ),
                                  child: Center(
                                    child: Container(
                                      width: 156,
                                      height: 156,
                                      decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.void_),
                                    ),
                                  ),
                                ),
                              ),
                              Transform.scale(
                                scale: pulse,
                                child: Container(
                                  width: 118,
                                  height: 118,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(color: AppColors.electric.withOpacity(0.35), blurRadius: 44, spreadRadius: 4),
                                    ],
                                  ),
                                ),
                              ),
                              const CivicAILogo(size: 96),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 30),
                    const _ShimmerText(text: 'CivicAI'),
                    const SizedBox(height: 6),
                    Text('Smart Governance for Jammu', style: GoogleFonts.inter(color: AppColors.text3, fontSize: 12.5, letterSpacing: 0.4)),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 26,
                      child: DefaultTextStyle(
                        style: GoogleFonts.inter(color: AppColors.text2, fontSize: 15, fontWeight: FontWeight.w500),
                        child: AnimatedTextKit(
                          repeatForever: true,
                          animatedTexts: [
                            FadeAnimatedText('AI Powered Smart Governance'),
                            FadeAnimatedText('Voice • Image • Text Complaints'),
                            FadeAnimatedText('Powered by IBM Granite'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 44),
                    const _DotLoader(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Animated gradient-shimmer wordmark for the splash screen.
class _ShimmerText extends StatefulWidget {
  final String text;
  const _ShimmerText({required this.text});
  @override
  State<_ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<_ShimmerText> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return ShaderMask(
          shaderCallback: (r) => LinearGradient(
            colors: const [AppColors.electric, AppColors.violet, AppColors.magenta, AppColors.electric],
            stops: const [0.0, 0.35, 0.65, 1.0],
            begin: Alignment(-1 + _c.value * 3, 0),
            end: Alignment(1 + _c.value * 3, 0),
          ).createShader(r),
          child: Text(widget.text, style: heading(42, color: Colors.white)),
        );
      },
    );
  }
}

// Three softly bouncing dots used in place of a plain spinner.
class _DotLoader extends StatefulWidget {
  const _DotLoader();
  @override
  State<_DotLoader> createState() => _DotLoaderState();
}

class _DotLoaderState extends State<_DotLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  static const _colors = [AppColors.electric, AppColors.violet, AppColors.rose];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_c.value - i * 0.2) % 1.0;
            final bounce = math.sin(phase * math.pi).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Transform.translate(
                offset: Offset(0, -8 * bounce),
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: _colors[i].withOpacity(0.55 + 0.45 * bounce)),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class CivicAILogo extends StatelessWidget {
  final double size;
  const CivicAILogo({super.key, this.size = 40});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: AppColors.heroGradient,
        boxShadow: [BoxShadow(color: AppColors.electric.withOpacity(0.45), blurRadius: size * 0.5)],
      ),
      alignment: Alignment.center,
      child: Text('CA', style: heading(size * 0.36, color: AppColors.void_, letterSpacing: 0)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// AUTH GATE — decides Splash → Login/Register → Citizen/Admin home
// ═══════════════════════════════════════════════════════════════════════
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool showRegister = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        if (appState.initializing) return _loading();
        if (appState.isAdmin) return const AdminHomeScreen();
        if (appState.firebaseUser != null && appState.profile != null) return const CitizenHomeScreen();
        if (appState.firebaseUser != null && appState.profile == null) return _loading();
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          child: showRegister
              ? RegisterScreen(key: const ValueKey('reg'), onSwitchToLogin: () => setState(() => showRegister = false))
              : LoginScreen(key: const ValueKey('login'), onSwitchToRegister: () => setState(() => showRegister = true)),
        );
      },
    );
  }

  Widget _loading() => const Scaffold(
    backgroundColor: AppColors.void_,
    body: Center(child: CircularProgressIndicator(color: AppColors.electric)),
  );
}

// ─────────────────────────────────────────────
// SHARED AUTH SCREEN CHROME
// ─────────────────────────────────────────────
class _AuthScaffold extends StatefulWidget {
  final Widget child;
  const _AuthScaffold({required this.child});
  @override
  State<_AuthScaffold> createState() => _AuthScaffoldState();
}

class _AuthScaffoldState extends State<_AuthScaffold> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.void_,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(center: Alignment(0.8, -0.6), radius: 1.4, colors: [AppColors.navy, AppColors.void_]),
        ),
        child: Stack(
          children: [
            const _BackgroundOrbs(),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: AnimatedBuilder(
                      animation: _c,
                      builder: (context, cardChild) {
                        final angle = _c.value * 2 * math.pi;
                        return Container(
                          padding: const EdgeInsets.all(1.4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(27),
                            gradient: SweepGradient(
                              transform: GradientRotation(angle),
                              colors: [
                                AppColors.electric.withOpacity(0.55),
                                AppColors.violet.withOpacity(0.15),
                                AppColors.magenta.withOpacity(0.45),
                                AppColors.gold.withOpacity(0.15),
                                AppColors.electric.withOpacity(0.55),
                              ],
                            ),
                          ),
                          child: cardChild,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(28, 34, 28, 28),
                        decoration: BoxDecoration(
                          color: AppColors.void2.withOpacity(0.92),
                          borderRadius: BorderRadius.circular(26),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 44, offset: const Offset(0, 22))],
                        ),
                        child: widget.child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

InputDecoration _fieldDeco(String label, IconData icon) => InputDecoration(
  labelText: label,
  labelStyle: const TextStyle(color: AppColors.text3),
  floatingLabelStyle: const TextStyle(color: AppColors.electric),
  prefixIcon: Padding(
    padding: const EdgeInsets.only(left: 4, right: 4),
    child: Icon(icon, color: AppColors.text3, size: 20),
  ),
  filled: true,
  fillColor: Colors.white.withOpacity(0.045),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(15),
    borderSide: BorderSide(color: Colors.white.withOpacity(0.06)),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(15),
    borderSide: const BorderSide(color: AppColors.electric, width: 1.6),
  ),
  contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
);

// ─────────────────────────────────────────────
// LOGIN SCREEN
// ─────────────────────────────────────────────
class LoginScreen extends StatefulWidget {
  final VoidCallback onSwitchToRegister;
  const LoginScreen({super.key, required this.onSwitchToRegister});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(vsync: this, duration: const Duration(milliseconds: 550))..forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Please fill in both fields.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    // Admin shortcut: username "admin", password "123456" — no Firebase call.
    if (email.toLowerCase() == 'admin') {
      final err = appState.loginAdmin(email, pass);
      setState(() {
        _loading = false;
        _error = err;
      });
      return;
    }

    final err = await appState.login(email, pass);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      child: FadeTransition(
        opacity: _entrance,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero)
              .animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _AuthBadge(icon: Icons.waving_hand_rounded),
              const SizedBox(height: 20),
              ShaderMask(
                shaderCallback: (r) => AppColors.heroGradient.createShader(r),
                child: Text('Welcome back', style: heading(27, color: Colors.white)),
              ),
              const SizedBox(height: 7),
              Text('Log in to track your civic reports in real time.',
                  style: GoogleFonts.inter(color: AppColors.text2, fontSize: 13.5, height: 1.5)),
              const SizedBox(height: 28),
              TextField(
                controller: _emailCtrl,
                style: const TextStyle(color: AppColors.text1),
                decoration: _fieldDeco('Email (or "admin")', Icons.mail_outline),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passCtrl,
                obscureText: _obscure,
                style: const TextStyle(color: AppColors.text1),
                decoration: _fieldDeco('Password', Icons.lock_outline).copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: AppColors.text3, size: 19),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                child: _error != null
                    ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _ErrorBanner(message: _error!),
                )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 22),
              _GradientButton(loading: _loading, label: 'Log In', onTap: _submit),
              const SizedBox(height: 20),
              Center(
                child: GestureDetector(
                  onTap: widget.onSwitchToRegister,
                  child: RichText(
                    text: TextSpan(
                      style: GoogleFonts.inter(color: AppColors.text2, fontSize: 13),
                      children: const [
                        TextSpan(text: "New here? "),
                        TextSpan(text: 'Create an account', style: TextStyle(color: AppColors.electric, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.gold.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(100),
                    border: Border.all(color: AppColors.gold.withOpacity(0.25)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.shield_outlined, size: 13, color: AppColors.gold),
                      const SizedBox(width: 6),
                      Text('Admin? Log in with username "admin"',
                          style: GoogleFonts.inter(color: AppColors.gold, fontSize: 11.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Small rounded icon badge used at the top of auth screens, with a soft glow.
class _AuthBadge extends StatelessWidget {
  final IconData icon;
  const _AuthBadge({required this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: AppColors.electric.withOpacity(0.35), blurRadius: 22, offset: const Offset(0, 8))],
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: AppColors.void_, size: 26),
    );
  }
}

// Friendlier error banner instead of a plain line of red text.
class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.rose.withOpacity(0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.rose.withOpacity(0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.rose, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(color: AppColors.rose, fontSize: 12.5, height: 1.4))),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// REGISTER SCREEN
// ─────────────────────────────────────────────
class RegisterScreen extends StatefulWidget {
  final VoidCallback onSwitchToLogin;
  const RegisterScreen({super.key, required this.onSwitchToLogin});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> with SingleTickerProviderStateMixin {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(vsync: this, duration: const Duration(milliseconds: 550))..forward();
    _passCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  double get _passwordStrength {
    final p = _passCtrl.text;
    if (p.isEmpty) return 0;
    double s = 0;
    if (p.length >= 6) s += 0.34;
    if (p.length >= 10) s += 0.22;
    if (RegExp(r'[0-9]').hasMatch(p)) s += 0.22;
    if (RegExp(r'[A-Z]').hasMatch(p) || RegExp(r'[!@#\$%^&*]').hasMatch(p)) s += 0.22;
    return s.clamp(0, 1);
  }

  Color get _strengthColor {
    final s = _passwordStrength;
    if (s >= 0.8) return AppColors.lime;
    if (s >= 0.5) return AppColors.gold;
    return AppColors.rose;
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    final confirm = _confirmCtrl.text;

    if (name.isEmpty || email.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Please fill in every field.');
      return;
    }
    if (pass.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (pass != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    final err = await appState.register(name, email, pass);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      child: FadeTransition(
        opacity: _entrance,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero)
              .animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const _AuthBadge(icon: Icons.auto_awesome_rounded),
              const SizedBox(height: 20),
              ShaderMask(
                shaderCallback: (r) => AppColors.heroGradient.createShader(r),
                child: Text('Create your account', style: heading(25, color: Colors.white)),
              ),
              const SizedBox(height: 7),
              Text('Register once to start reporting civic issues.',
                  style: GoogleFonts.inter(color: AppColors.text2, fontSize: 13.5, height: 1.5)),
              const SizedBox(height: 28),
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: AppColors.text1),
                decoration: _fieldDeco('Full name', Icons.person_outline),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _emailCtrl,
                style: const TextStyle(color: AppColors.text1),
                decoration: _fieldDeco('Email', Icons.mail_outline),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passCtrl,
                obscureText: _obscure,
                style: const TextStyle(color: AppColors.text1),
                decoration: _fieldDeco('Password', Icons.lock_outline).copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: AppColors.text3, size: 19),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (_passCtrl.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: _passwordStrength),
                          duration: const Duration(milliseconds: 250),
                          builder: (context, value, _) => LinearProgressIndicator(
                            value: value,
                            minHeight: 5,
                            backgroundColor: Colors.white.withOpacity(0.06),
                            valueColor: AlwaysStoppedAnimation(_strengthColor),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _passwordStrength >= 0.8 ? 'Strong' : (_passwordStrength >= 0.5 ? 'Okay' : 'Weak'),
                      style: TextStyle(color: _strengthColor, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: _confirmCtrl,
                obscureText: _obscure,
                style: const TextStyle(color: AppColors.text1),
                decoration: _fieldDeco('Confirm password', Icons.lock_outline),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                child: _error != null
                    ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _ErrorBanner(message: _error!),
                )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 22),
              _GradientButton(loading: _loading, label: 'Create Account', onTap: _submit),
              const SizedBox(height: 20),
              Center(
                child: GestureDetector(
                  onTap: widget.onSwitchToLogin,
                  child: RichText(
                    text: TextSpan(
                      style: GoogleFonts.inter(color: AppColors.text2, fontSize: 13),
                      children: const [
                        TextSpan(text: 'Already have an account? '),
                        TextSpan(text: 'Log in', style: TextStyle(color: AppColors.electric, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GradientButton extends StatefulWidget {
  final String label;
  final bool loading;
  final VoidCallback onTap;
  const _GradientButton({required this.label, required this.loading, required this.onTap});
  @override
  State<_GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<_GradientButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.loading ? null : (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: AppColors.heroGradient,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppColors.electric.withOpacity(_pressed ? 0.15 : 0.32),
                  blurRadius: _pressed ? 10 : 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: widget.loading ? null : widget.onTap,
                child: Center(
                  child: widget.loading
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.void_))
                      : Text(widget.label, style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.void_)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// BACKGROUND ORBS — slow drifting glow for ambient depth
// ═══════════════════════════════════════════════════════════════════════
class _BackgroundOrbs extends StatefulWidget {
  const _BackgroundOrbs();
  @override
  State<_BackgroundOrbs> createState() => _BackgroundOrbsState();
}

class _BackgroundOrbsState extends State<_BackgroundOrbs> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 14))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value * 2 * math.pi;
          return Stack(
            children: [
              _orb(top: -150 + math.sin(t) * 18, left: -150 + math.cos(t * 0.8) * 22, size: 500, color: AppColors.electric.withOpacity(0.16)),
              _orb(top: -120 + math.cos(t * 0.6) * 20, right: -150 + math.sin(t * 0.9) * 24, size: 450, color: AppColors.violet.withOpacity(0.14)),
              _orb(bottom: -150 + math.sin(t * 1.1) * 16, left: 40 + math.cos(t * 0.7) * 20, size: 400, color: AppColors.rose.withOpacity(0.09)),
              _orb(top: 140 + math.sin(t * 1.3) * 30, right: 60 + math.cos(t * 1.2) * 26, size: 220, color: AppColors.gold.withOpacity(0.07)),
            ],
          );
        },
      ),
    );
  }

  Widget _orb({double? top, double? right, double? left, double? bottom, required double size, required Color color}) {
    return Positioned(
      top: top,
      right: right,
      left: left,
      bottom: bottom,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [color, color.withOpacity(0)])),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════
// SHARED: STATUS STEPPER (used in success dialog + issue cards)
// ═══════════════════════════════════════════════════════════════════════
class StatusStepper extends StatelessWidget {
  final String status;
  const StatusStepper({super.key, required this.status});

  static const _stages = ['PENDING', 'IN_PROGRESS', 'RESOLVED'];
  static const _labels = ['Reported', 'In Progress', 'Resolved'];
  static const _icons = [Icons.flag_outlined, Icons.build_outlined, Icons.check_circle_outline];

  @override
  Widget build(BuildContext context) {
    final currentIndex = _stages.indexOf(status).clamp(0, 2);
    return Row(
      children: List.generate(_stages.length * 2 - 1, (i) {
        if (i.isOdd) {
          final leftDone = (i - 1) ~/ 2 < currentIndex;
          return Expanded(
            child: Container(height: 2, color: leftDone ? AppColors.electric : AppColors.glassLine),
          );
        }
        final idx = i ~/ 2;
        final done = idx <= currentIndex;
        final isCurrent = idx == currentIndex;
        final color = done ? statusColor(_stages[idx]) : AppColors.text3;
        return Column(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? color.withOpacity(0.18) : Colors.white.withOpacity(0.03),
                border: Border.all(color: isCurrent ? color : (done ? color.withOpacity(0.6) : AppColors.glassLine), width: isCurrent ? 2 : 1),
              ),
              alignment: Alignment.center,
              child: Icon(_icons[idx], size: 16, color: color),
            ),
            const SizedBox(height: 6),
            Text(_labels[idx], style: TextStyle(fontSize: 9.5, color: done ? AppColors.text1 : AppColors.text3, fontWeight: FontWeight.w600)),
          ],
        );
      }),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// CITIZEN HOME SCREEN
// ═══════════════════════════════════════════════════════════════════════
class CitizenHomeScreen extends StatefulWidget {
  const CitizenHomeScreen({super.key});
  @override
  State<CitizenHomeScreen> createState() => _CitizenHomeScreenState();
}

class _CitizenHomeScreenState extends State<CitizenHomeScreen> {
  Future<void> _openReportSheet() async {
    final profile = appState.profile!;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReportIssueSheet(uid: profile.uid, userName: profile.name),
    );
    if (result != null && mounted) {
      showDialog(
        context: context,
        builder: (_) => SubmissionSuccessDialog(
          type: result['type'] as IssueType,
          description: result['description'] as String,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = deviceTypeOf(context);
    final hPad = horizontalPadding(context);
    final profile = appState.profile;

    return Scaffold(
      backgroundColor: AppColors.void_,
      appBar: _buildAppBar(context, profile),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openReportSheet,
        backgroundColor: AppColors.electric,
        icon: const Icon(Icons.report_problem_outlined, color: AppColors.void_),
        label: Text('Report Issue', style: GoogleFonts.inter(color: AppColors.void_, fontWeight: FontWeight.w700)),
      ),
      body: Stack(
        children: [
          const _BackgroundOrbs(),
          SafeArea(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _HeroSection(device: device, hPad: hPad, onReport: _openReportSheet, userName: profile?.name ?? 'there'),
                _StatsSection(hPad: hPad),
                _MyReportsSection(hPad: hPad, uid: profile?.uid ?? ''),
                _ProcessSection(hPad: hPad, device: device),
                _FeaturesSection(hPad: hPad, device: device),
                _ContactSection(hPad: hPad, device: device),
                _Footer(hPad: hPad),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, AppUserProfile? profile) {
    final isMobile = deviceTypeOf(context) == DeviceType.mobile;
    return AppBar(
      backgroundColor: AppColors.void_.withOpacity(0.85),
      elevation: 0,
      titleSpacing: horizontalPadding(context) - 12,
      title: Row(
        children: [
          const CivicAILogo(size: 32),
          const SizedBox(width: 10),
          if (!isMobile)
            RichText(
              text: TextSpan(
                style: GoogleFonts.poppins(fontWeight: FontWeight.w800, fontSize: 17, color: AppColors.text1),
                children: const [TextSpan(text: 'Civic'), TextSpan(text: 'AI', style: TextStyle(color: AppColors.electric))],
              ),
            ),
        ],
      ),
      actions: [
        _UserBadge(name: profile?.name ?? '?'),
        IconButton(
          tooltip: 'Log out',
          onPressed: appState.logout,
          icon: const Icon(Icons.logout_rounded, color: AppColors.text2, size: 20),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _UserBadge extends StatelessWidget {
  final String name;
  const _UserBadge({required this.name});
  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: AppColors.glassLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(radius: 10, backgroundColor: AppColors.electric, child: Text(initial, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppColors.void_))),
          const SizedBox(width: 8),
          Text(name, style: GoogleFonts.inter(color: AppColors.text1, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// HERO SECTION
// ─────────────────────────────────────────────
class _HeroSection extends StatelessWidget {
  final DeviceType device;
  final double hPad;
  final VoidCallback onReport;
  final String userName;
  const _HeroSection({required this.device, required this.hPad, required this.onReport, required this.userName});

  @override
  Widget build(BuildContext context) {
    final isNarrow = device == DeviceType.mobile;

    final textCol = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: AppColors.glass, borderRadius: BorderRadius.circular(100), border: Border.all(color: AppColors.glassLine)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.circle, size: 8, color: AppColors.electric),
              const SizedBox(width: 8),
              Text('Welcome back, $userName', style: GoogleFonts.inter(color: AppColors.electric, fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Text.rich(
          TextSpan(
            style: heading(isNarrow ? 32 : 50, letterSpacing: -1.5),
            children: const [
              TextSpan(text: 'Governance that\nactually '),
              TextSpan(text: 'moves fast.', style: TextStyle(color: AppColors.electric)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Report civic issues in seconds. CivicAI classifies, prioritises, and routes every complaint to the right government department — instantly, intelligently, automatically.',
          style: GoogleFonts.inter(color: AppColors.text2, fontSize: 15, height: 1.7),
        ),
        const SizedBox(height: 30),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            ElevatedButton.icon(
              onPressed: onReport,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.electric,
                foregroundColor: AppColors.void_,
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Text('🏙️'),
              label: Text('Report a Civic Issue', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
            ),
            OutlinedButton(
              onPressed: () {},
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text1,
                side: const BorderSide(color: AppColors.glassLine),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('See how it works →'),
            ),
          ],
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, isNarrow ? 24 : 60, hPad, 40),
      child: Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1240), child: textCol),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// STATS SECTION
// ─────────────────────────────────────────────
class _StatsSection extends StatelessWidget {
  final double hPad;
  const _StatsSection({required this.hPad});
  @override
  Widget build(BuildContext context) {
    final stats = [
      ('94%', 'Resolution accuracy', [AppColors.electric, AppColors.violet]),
      ('3.2h', 'Avg. response time', [AppColors.gold, AppColors.rose]),
      ('48K+', 'Issues resolved', [AppColors.violet, AppColors.rose]),
      ('12', 'Departments linked', [AppColors.lime, AppColors.electric]),
    ];
    final cols = deviceTypeOf(context) == DeviceType.mobile ? 2 : 4;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1240),
          child: GridView.count(
            crossAxisCount: cols,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 1.3,
            children: stats
                .map((s) => Container(
              decoration: BoxDecoration(color: AppColors.glass, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.glassLine)),
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ShaderMask(
                    shaderCallback: (r) => LinearGradient(colors: s.$3).createShader(r),
                    child: Text(s.$1, style: heading(28, color: Colors.white)),
                  ),
                  const SizedBox(height: 6),
                  Text(s.$2, style: GoogleFonts.inter(color: AppColors.text3, fontSize: 12)),
                ],
              ),
            ))
                .toList(),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// MY REPORTS SECTION (citizen sees ONLY their own issues)
// ─────────────────────────────────────────────
class _MyReportsSection extends StatelessWidget {
  final double hPad;
  final String uid;
  const _MyReportsSection({required this.hPad, required this.uid});

  @override
  Widget build(BuildContext context) {
    return _SectionWrap(
      hPad: hPad,
      eyebrow: 'My Reports',
      title: 'Track your submitted issues',
      subtitle: 'Only you can see this list — every report you submit updates here in real time.',
      child: Container(
        constraints: const BoxConstraints(minHeight: 200, maxHeight: 460),
        decoration: BoxDecoration(color: AppColors.void2, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.glassLine)),
        child: uid.isEmpty
            ? _emptyMsg('Log in to see your reports.')
            : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: issueService.myIssuesStream(uid),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _emptyMsg('⚠️ Could not load your reports.\n${snapshot.error}');
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator(color: AppColors.electric));
            }
            final docs = [...snapshot.data!.docs];
            docs.sort((a, b) {
              final ta = a.data()['createdAt'];
              final tb = b.data()['createdAt'];
              if (ta is! Timestamp || tb is! Timestamp) return 0;
              return tb.compareTo(ta); // newest first
            });
            if (docs.isEmpty) {
              return _emptyMsg('No issues reported yet.\nTap "Report Issue" to submit your first one!');
            }
            return ListView.separated(
              padding: const EdgeInsets.all(14),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final d = docs[i].data();
                return _MyReportCard(data: d);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _emptyMsg(String msg) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(msg, textAlign: TextAlign.center, style: GoogleFonts.inter(color: AppColors.text3, fontSize: 12.5)),
    ),
  );
}

class _MyReportCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _MyReportCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final type = kIssueTypes[data['category']] ?? kIssueTypes['other']!;
    final priority = (data['priority'] ?? type.priority) as String;
    final status = (data['status'] ?? 'PENDING') as String;
    final ts = data['createdAt'];
    String timeLabel = 'just now';
    if (ts is Timestamp) timeLabel = DateFormat('MMM d, h:mm a').format(ts.toDate());

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.glassLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: priorityColor(priority).withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                alignment: Alignment.center,
                child: Text(type.icon, style: const TextStyle(fontSize: 17)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(data['title'] ?? type.label, style: GoogleFonts.inter(color: AppColors.text1, fontWeight: FontWeight.w700, fontSize: 13.5)),
                    const SizedBox(height: 2),
                    Text('→ ${data['department'] ?? type.department} · $timeLabel', style: GoogleFonts.inter(color: AppColors.text3, fontSize: 10.5)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: statusColor(status).withOpacity(0.15), borderRadius: BorderRadius.circular(7)),
                child: Text(statusLabel(status), style: TextStyle(color: statusColor(status), fontSize: 9.5, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          StatusStepper(status: status),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// PROCESS SECTION
// ─────────────────────────────────────────────
class _ProcessSection extends StatelessWidget {
  final double hPad;
  final DeviceType device;
  const _ProcessSection({required this.hPad, required this.device});
  @override
  Widget build(BuildContext context) {
    final steps = [
      ('01', '📝', 'Report', 'Submit via text, voice, or image in any language.', AppColors.electric),
      ('02', '🔍', 'Classify', 'IBM Granite categorises instantly — roads, water, electricity.', AppColors.violet),
      ('03', '⚡', 'Prioritise', 'Dynamic urgency scoring escalates critical issues.', AppColors.gold),
      ('04', '🚀', 'Route', 'Auto-assigned to the right department, with audit trail.', AppColors.lime),
    ];
    final cols = device == DeviceType.desktop ? 4 : device == DeviceType.tablet ? 2 : 1;

    return _SectionWrap(
      hPad: hPad,
      eyebrow: 'How it works',
      title: 'Four steps to resolution',
      subtitle: 'CivicAI removes every friction point between a citizen and a government response.',
      child: GridView.count(
        crossAxisCount: cols,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: cols == 1 ? 2.6 : 1.05,
        children: steps
            .map((s) => Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: AppColors.void2, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.glassLine)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('STEP ${s.$1}', style: GoogleFonts.inter(color: AppColors.text3, fontSize: 10, letterSpacing: 1)),
              const SizedBox(height: 12),
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: s.$5.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: Text(s.$2, style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(height: 14),
              Text(s.$3, style: GoogleFonts.inter(color: AppColors.text1, fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 6),
              Text(s.$4, style: GoogleFonts.inter(color: AppColors.text2, fontSize: 12.5, height: 1.5)),
            ],
          ),
        ))
            .toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// FEATURES SECTION
// ─────────────────────────────────────────────
class _FeaturesSection extends StatelessWidget {
  final double hPad;
  final DeviceType device;
  const _FeaturesSection({required this.hPad, required this.device});
  @override
  Widget build(BuildContext context) {
    final feats = [
      ('🧠', 'IBM Granite Classification', 'Watsonx-powered NLP identifies issue type, location and severity in real time.', AppColors.violet),
      ('📍', 'Geo-tagged Routing', 'Location intelligence maps complaints to the correct ward & officer.', AppColors.lime),
      ('⚠️', 'Priority Scoring', 'Dynamic urgency levels keep critical issues visible & escalated.', AppColors.gold),
      ('📊', 'Real-time Dashboard', 'Live analytics, resolution heat maps, and SLA tracking for admins.', AppColors.rose),
    ];
    final cols = device == DeviceType.mobile ? 1 : 2;

    return _SectionWrap(
      hPad: hPad,
      eyebrow: 'Features',
      title: 'Built for modern governance',
      subtitle: 'Enterprise-grade AI tools for municipal bodies, NGOs, and government departments at scale.',
      child: GridView.count(
        crossAxisCount: cols,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: cols == 1 ? 2.3 : 1.7,
        children: feats
            .map((f) => Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: AppColors.glass, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.glassLine)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: f.$4.withOpacity(0.15), borderRadius: BorderRadius.circular(14)),
                alignment: Alignment.center,
                child: Text(f.$1, style: const TextStyle(fontSize: 22)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.$2, style: GoogleFonts.inter(color: AppColors.text1, fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 6),
                    Text(f.$3, style: GoogleFonts.inter(color: AppColors.text2, fontSize: 12.5, height: 1.6)),
                  ],
                ),
              ),
            ],
          ),
        ))
            .toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// REPORT ISSUE BOTTOM SHEET
// ─────────────────────────────────────────────
class ReportIssueSheet extends StatefulWidget {
  final String uid;
  final String userName;
  const ReportIssueSheet({super.key, required this.uid, required this.userName});
  @override
  State<ReportIssueSheet> createState() => _ReportIssueSheetState();
}

class _ReportIssueSheetState extends State<ReportIssueSheet> {
  final _controller = TextEditingController();
  bool _submitting = false;
  IssueType? _preview;

  final _quickChips = [
    'There is a large pothole on Residency Road, cars are getting damaged',
    'No water supply in Ward 9 since yesterday',
    'Street light on Gandhi Nagar road has been out for 3 days',
    'Garbage not collected from Baker Road for 5 days',
    'Sewage overflow flooding the footpath near our street',
  ];

  void _onChanged(String v) {
    setState(() => _preview = v.trim().isEmpty ? null : classifyIssueLocally(v));
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _submitting = true);
    try {
      final type = await issueService.reportIssue(text, uid: widget.uid, userName: widget.userName);
      if (mounted) {
        Navigator.pop(context, {'type': type, 'description': text});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not submit — check Firebase setup ($e)'), backgroundColor: AppColors.rose.withOpacity(0.9)),
        );
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        decoration: const BoxDecoration(
          color: AppColors.void2,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.fromBorderSide(BorderSide(color: AppColors.glassLine)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: AppColors.glassLine, borderRadius: BorderRadius.circular(4))),
            ),
            Row(
              children: [
                const CivicAILogo(size: 32),
                const SizedBox(width: 10),
                Text('Report a Civic Issue', style: heading(17)),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              onChanged: _onChanged,
              maxLines: 4,
              style: const TextStyle(color: AppColors.text1),
              decoration: InputDecoration(
                hintText: 'Describe the issue — e.g. "Pothole on Residency Road near the hospital"',
                hintStyle: GoogleFonts.inter(color: AppColors.text3, fontSize: 13),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _quickChips
                  .map((q) => ActionChip(
                label: Text(q.length > 26 ? '${q.substring(0, 26)}…' : q, style: const TextStyle(fontSize: 11)),
                backgroundColor: AppColors.electric.withOpacity(0.1),
                labelStyle: const TextStyle(color: AppColors.electric),
                onPressed: () {
                  _controller.text = q;
                  _onChanged(q);
                },
              ))
                  .toList(),
            ),
            if (_preview != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: priorityColor(_preview!.priority).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: priorityColor(_preview!.priority).withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Text(_preview!.icon, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${_preview!.label} → ${_preview!.department}', style: const TextStyle(color: AppColors.text1, fontSize: 12.5))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: priorityColor(_preview!.priority), borderRadius: BorderRadius.circular(6)),
                      child: Text(_preview!.priority, style: const TextStyle(color: AppColors.void_, fontSize: 9, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            _GradientButton(loading: _submitting, label: 'Submit Report', onTap: _submit),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SUBMISSION SUCCESS DIALOG
// ─────────────────────────────────────────────
class SubmissionSuccessDialog extends StatelessWidget {
  final IssueType type;
  final String description;
  const SubmissionSuccessDialog({super.key, required this.type, required this.description});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: AppColors.void2,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.glassLine),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 40)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: AppColors.lime.withOpacity(0.15), shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Icon(Icons.check_rounded, color: AppColors.lime, size: 34),
            ),
            const SizedBox(height: 18),
            Text('Your issue has been submitted!', textAlign: TextAlign.center, style: heading(19)),
            const SizedBox(height: 8),
            Text(description, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(color: AppColors.text2, fontSize: 13)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: priorityColor(type.priority).withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(type.icon, style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 8),
                  Text('${type.label} → ${type.department}', style: GoogleFonts.inter(color: AppColors.text1, fontSize: 12.5, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const StatusStepper(status: 'PENDING'),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: _GradientButton(loading: false, label: 'Track it below', onTap: () => Navigator.pop(context)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CONTACT SECTION
// ─────────────────────────────────────────────
class _ContactSection extends StatelessWidget {
  final double hPad;
  final DeviceType device;
  const _ContactSection({required this.hPad, required this.device});
  @override
  Widget build(BuildContext context) {
    return _SectionWrap(
      hPad: hPad,
      eyebrow: 'Get in touch',
      title: "Let's talk CivicAI",
      subtitle: 'Questions, collaboration, or a demo walkthrough for your department — reach out directly.',
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: AppColors.glass, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.glassLine)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Builder & Maintainer', style: GoogleFonts.inter(color: AppColors.rose, fontSize: 11)),
            const SizedBox(height: 6),
            Text('Vidhita Arora', style: heading(20)),
            const SizedBox(height: 10),
            Text('AI/ML Engineer & Full-Stack Developer building civic and cultural technology rooted in Jammu.',
                style: GoogleFonts.inter(color: AppColors.text2, fontSize: 13, height: 1.6)),
            const SizedBox(height: 18),
            _contactRow('✉️', 'Email', 'vidhitaarora12@gmail.com'),
            const SizedBox(height: 10),
            _contactRow('📍', 'Location', 'Jammu, Jammu & Kashmir, India'),
          ],
        ),
      ),
    );
  }

  Widget _contactRow(String icon, String label, String value) => Row(
    children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: AppColors.electric.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
        alignment: Alignment.center,
        child: Text(icon, style: const TextStyle(fontSize: 16)),
      ),
      const SizedBox(width: 12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: GoogleFonts.inter(color: AppColors.text3, fontSize: 9.5)),
          Text(value, style: GoogleFonts.inter(color: AppColors.text1, fontSize: 13.5, fontWeight: FontWeight.w600)),
        ],
      ),
    ],
  );
}

// ─────────────────────────────────────────────
// FOOTER
// ─────────────────────────────────────────────
class _Footer extends StatelessWidget {
  final double hPad;
  const _Footer({required this.hPad});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 24),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.glassLine))),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CivicAILogo(size: 26),
              const SizedBox(width: 8),
              Text('CivicAI', style: heading(15)),
            ],
          ),
          const SizedBox(height: 8),
          Text('© 2026 CivicAI · Built with Flutter, Firebase & IBM Granite.', style: GoogleFonts.inter(color: AppColors.text3, fontSize: 11.5)),
          const SizedBox(height: 4),
          Text('Developed with ♥ by Vidhita Arora', style: GoogleFonts.inter(color: AppColors.text3, fontSize: 11)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SHARED SECTION WRAPPER
// ─────────────────────────────────────────────
class _SectionWrap extends StatelessWidget {
  final double hPad;
  final String eyebrow;
  final String title;
  final String subtitle;
  final Widget child;
  const _SectionWrap({required this.hPad, required this.eyebrow, required this.title, required this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 20, hPad, 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1240),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('// $eyebrow'.toUpperCase(), style: GoogleFonts.inter(color: AppColors.electric, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(title, style: heading(25)),
              const SizedBox(height: 10),
              Text(subtitle, style: GoogleFonts.inter(color: AppColors.text2, fontSize: 14, height: 1.7)),
              const SizedBox(height: 24),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ADMIN DASHBOARD — sees EVERY citizen's issues
// ═══════════════════════════════════════════════════════════════════════
class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});
  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  String _filter = 'ALL';

  @override
  Widget build(BuildContext context) {
    final hPad = horizontalPadding(context);
    return Scaffold(
      backgroundColor: AppColors.void_,
      appBar: AppBar(
        backgroundColor: AppColors.void_.withOpacity(0.85),
        elevation: 0,
        titleSpacing: hPad - 12,
        title: Row(
          children: [
            const CivicAILogo(size: 32),
            const SizedBox(width: 10),
            Text('Admin Dashboard', style: heading(17)),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 10),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: AppColors.gold.withOpacity(0.12), borderRadius: BorderRadius.circular(100), border: Border.all(color: AppColors.gold.withOpacity(0.3))),
            child: Row(mainAxisSize: MainAxisSize.min, children: const [
              Icon(Icons.shield_outlined, size: 13, color: AppColors.gold),
              SizedBox(width: 6),
              Text('Admin', style: TextStyle(color: AppColors.gold, fontSize: 12, fontWeight: FontWeight.w700)),
            ]),
          ),
          IconButton(onPressed: appState.logout, icon: const Icon(Icons.logout_rounded, color: AppColors.text2, size: 20)),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          const _BackgroundOrbs(),
          SafeArea(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: issueService.allIssuesStream(),
              builder: (context, snapshot) {
                final docs = snapshot.data?.docs ?? [];
                final counts = <String, int>{'PENDING': 0, 'IN_PROGRESS': 0, 'RESOLVED': 0};
                for (final d in docs) {
                  final s = (d.data()['status'] ?? 'PENDING') as String;
                  counts[s] = (counts[s] ?? 0) + 1;
                }
                final filtered = _filter == 'ALL' ? docs : docs.where((d) => (d.data()['status'] ?? 'PENDING') == _filter).toList();

                return ListView(
                  padding: EdgeInsets.fromLTRB(hPad, 20, hPad, 40),
                  children: [
                    Text('Every issue, from every citizen', style: heading(24)),
                    const SizedBox(height: 8),
                    Text('Update statuses as departments make progress — citizens see the change instantly.',
                        style: GoogleFonts.inter(color: AppColors.text2, fontSize: 13.5)),
                    const SizedBox(height: 22),
                    _AdminStatsRow(total: docs.length, counts: counts),
                    const SizedBox(height: 24),
                    _AdminFilterChips(current: _filter, onChanged: (f) => setState(() => _filter = f)),
                    const SizedBox(height: 18),
                    if (snapshot.hasError)
                      _emptyCard('⚠️ Could not load issues.\n${snapshot.error}')
                    else if (!snapshot.hasData)
                      const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: AppColors.electric)))
                    else if (filtered.isEmpty)
                        _emptyCard('No issues in this category yet.')
                      else
                        ...filtered.map((doc) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _AdminIssueCard(docId: doc.id, data: doc.data()),
                        )),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyCard(String msg) => Container(
    padding: const EdgeInsets.all(30),
    decoration: BoxDecoration(color: AppColors.glass, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.glassLine)),
    alignment: Alignment.center,
    child: Text(msg, textAlign: TextAlign.center, style: GoogleFonts.inter(color: AppColors.text3, fontSize: 12.5)),
  );
}

class _AdminStatsRow extends StatelessWidget {
  final int total;
  final Map<String, int> counts;
  const _AdminStatsRow({required this.total, required this.counts});
  @override
  Widget build(BuildContext context) {
    final cols = deviceTypeOf(context) == DeviceType.mobile ? 2 : 4;
    final items = [
      ('Total Reports', total.toString(), AppColors.violet),
      ('Pending', (counts['PENDING'] ?? 0).toString(), AppColors.gold),
      ('In Progress', (counts['IN_PROGRESS'] ?? 0).toString(), AppColors.electric),
      ('Resolved', (counts['RESOLVED'] ?? 0).toString(), AppColors.lime),
    ];
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      childAspectRatio: 1.5,
      children: items
          .map((it) => Container(
        decoration: BoxDecoration(color: AppColors.glass, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.glassLine)),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(it.$2, style: heading(26, color: it.$3)),
            const SizedBox(height: 4),
            Text(it.$1, style: GoogleFonts.inter(color: AppColors.text3, fontSize: 11.5)),
          ],
        ),
      ))
          .toList(),
    );
  }
}

class _AdminFilterChips extends StatelessWidget {
  final String current;
  final ValueChanged<String> onChanged;
  const _AdminFilterChips({required this.current, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final options = ['ALL', 'PENDING', 'IN_PROGRESS', 'RESOLVED'];
    return Wrap(
      spacing: 8,
      children: options.map((o) {
        final selected = o == current;
        return ChoiceChip(
          label: Text(o == 'ALL' ? 'All' : statusLabel(o)),
          selected: selected,
          onSelected: (_) => onChanged(o),
          backgroundColor: AppColors.glass,
          selectedColor: AppColors.electric.withOpacity(0.2),
          labelStyle: TextStyle(color: selected ? AppColors.electric : AppColors.text2, fontWeight: FontWeight.w600, fontSize: 12.5),
          side: BorderSide(color: selected ? AppColors.electric.withOpacity(0.5) : AppColors.glassLine),
        );
      }).toList(),
    );
  }
}

class _AdminIssueCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  const _AdminIssueCard({required this.docId, required this.data});

  @override
  Widget build(BuildContext context) {
    final type = kIssueTypes[data['category']] ?? kIssueTypes['other']!;
    final priority = (data['priority'] ?? type.priority) as String;
    final status = (data['status'] ?? 'PENDING') as String;
    final userName = (data['userName'] ?? 'Unknown') as String;
    final ts = data['createdAt'];
    String timeLabel = 'just now';
    if (ts is Timestamp) timeLabel = DateFormat('MMM d, h:mm a').format(ts.toDate());

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.glass, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.glassLine)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: priorityColor(priority).withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
                alignment: Alignment.center,
                child: Text(type.icon, style: const TextStyle(fontSize: 18)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(data['title'] ?? type.label, style: GoogleFonts.inter(color: AppColors.text1, fontWeight: FontWeight.w700, fontSize: 14.5)),
                    const SizedBox(height: 3),
                    Text(data['description'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(color: AppColors.text2, fontSize: 12.5)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: priorityColor(priority).withOpacity(0.15), borderRadius: BorderRadius.circular(7)),
                child: Text(priority, style: TextStyle(color: priorityColor(priority), fontSize: 9.5, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _metaChip(Icons.person_outline, userName),
              _metaChip(Icons.apartment_outlined, (data['department'] ?? type.department).toString()),
              _metaChip(Icons.schedule, timeLabel),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: statusColor(status).withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                child: Text(statusLabel(status), style: TextStyle(color: statusColor(status), fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              const Spacer(),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: status,
                  dropdownColor: AppColors.void2,
                  icon: const Icon(Icons.arrow_drop_down, color: AppColors.text2, size: 20),
                  style: GoogleFonts.inter(color: AppColors.text1, fontSize: 12.5, fontWeight: FontWeight.w600),
                  items: const [
                    DropdownMenuItem(value: 'PENDING', child: Text('Pending')),
                    DropdownMenuItem(value: 'IN_PROGRESS', child: Text('In Progress')),
                    DropdownMenuItem(value: 'RESOLVED', child: Text('Resolved')),
                  ],
                  onChanged: (v) {
                    if (v != null) issueService.updateStatus(docId, v);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metaChip(IconData icon, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: AppColors.text3),
      const SizedBox(width: 5),
      Text(text, style: GoogleFonts.inter(color: AppColors.text3, fontSize: 11.5)),
    ],
  );
}