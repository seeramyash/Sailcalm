import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'screens/local_records_page.dart';
import 'screens/reports_page.dart';
import 'screens/profile_settings_page.dart';
import 'services/app_preferences.dart';
import 'screens/care_tools_page.dart';
import 'screens/live_glove_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const SailmCalmApp());
}

const Color sea = Color(0xFF4E8B87);
const Color deepSea = Color(0xFF163B45);
const Color sailGold = Color(0xFFE8B86D);

class SailmCalmApp extends StatefulWidget {
  const SailmCalmApp({super.key});

  @override
  State<SailmCalmApp> createState() => _SailmCalmAppState();
}

class _SailmCalmAppState extends State<SailmCalmApp> {
  @override
  void initState() {
    super.initState();
    AppPreferences.load().catchError((Object _) {});
  }

  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  ThemeData _makeTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: sea,
      brightness: brightness,
      primary: sea,
      secondary: sailGold,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF0C1620)
          : const Color(0xFFF4F7F4),
      appBarTheme: AppBarTheme(
        backgroundColor: brightness == Brightness.dark
            ? const Color(0xFF0C1620)
            : const Color(0xFFF4F7F4),
        foregroundColor: brightness == Brightness.dark
            ? const Color(0xFFEAF3F2)
            : const Color(0xFF18383D),
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: brightness == Brightness.dark
            ? const Color(0xFF14242F)
            : Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark
            ? const Color(0xFF192B36)
            : const Color(0xFFF0F4F1),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(
            color: brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.07),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(color: sea, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: AppPreferences.textScale,
        builder: (context, scale, child) => ValueListenableBuilder<bool>(
          valueListenable: AppPreferences.reduceMotion,
          builder: (context, reduceMotion, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduceMotion,
            ),
            child: child ?? const SizedBox.shrink(),
          ),
          child: child,
        ),
        child: child,
      ),
      title: 'SailmCalm',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _makeTheme(Brightness.light),
      darkTheme: _makeTheme(Brightness.dark),
      home: AuthGate(
        isDark: _themeMode == ThemeMode.dark,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

class AuthGate extends StatelessWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;

  const AuthGate({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

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

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not check your sign-in status. Please check your connection and restart SailmCalm.\n\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        final user = snapshot.data;
        if (user == null) {
          return AuthScreen(
            isDark: isDark,
            onToggleTheme: onToggleTheme,
          );
        }

        return AppShell(
          isDark: isDark,
          onToggleTheme: onToggleTheme,
          onLogout: () {
            FirebaseAuth.instance.signOut();
          },
        );
      },
    );
  }
}

class SailboatMark extends StatelessWidget {
  final double size;
  const SailboatMark({super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF78B8AE), Color(0xFF285C65)],
        ),
        boxShadow: [
          BoxShadow(
            color: sea.withValues(alpha: 0.24),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: CustomPaint(painter: SailboatPainter()),
    );
  }
}

class SailboatPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final mast = Paint()
      ..color = const Color(0xFFFFF7E8)
      ..strokeWidth = size.width * 0.035
      ..strokeCap = StrokeCap.round;
    final sail = Paint()..color = const Color(0xFFFFF7E8);
    final secondSail = Paint()..color = const Color(0xFFE8B86D);
    final hullPaint = Paint()..color = const Color(0xFF123B47);
    final wavePaint = Paint()
      ..color = const Color(0xFFB8E4DB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.035
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(w * .49, h * .16), Offset(w * .49, h * .70), mast);
    final leftSail = Path()
      ..moveTo(w * .43, h * .25)
      ..lineTo(w * .18, h * .63)
      ..lineTo(w * .43, h * .63)
      ..close();
    canvas.drawPath(leftSail, sail);
    final rightSail = Path()
      ..moveTo(w * .55, h * .28)
      ..lineTo(w * .83, h * .62)
      ..lineTo(w * .55, h * .62)
      ..close();
    canvas.drawPath(rightSail, secondSail);
    final hull = Path()
      ..moveTo(w * .14, h * .70)
      ..lineTo(w * .86, h * .70)
      ..lineTo(w * .70, h * .83)
      ..lineTo(w * .32, h * .83)
      ..close();
    canvas.drawPath(hull, hullPaint);
    final wave1 = Path()
      ..moveTo(w * .14, h * .89)
      ..quadraticBezierTo(w * .28, h * .83, w * .42, h * .89)
      ..quadraticBezierTo(w * .58, h * .95, w * .74, h * .89)
      ..quadraticBezierTo(w * .83, h * .86, w * .89, h * .89);
    canvas.drawPath(wave1, wavePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class AuthScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;
  const AuthScreen({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _register = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: SeaBackdropPainter(
                isDark: Theme.of(context).brightness == Brightness.dark,
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: widget.isDark ? 'Switch to light mode' : 'Switch to dark mode',
                onPressed: widget.onToggleTheme,
                icon: Icon(widget.isDark ? Icons.light_mode : Icons.dark_mode),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 52, 22, 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    children: [
                      AnimatedSlide(
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeInOutCubic,
                        offset: _register ? const Offset(0.12, 0) : const Offset(-0.12, 0),
                        child: const SailboatMark(size: 86),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'SailmCalm',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.1,
                            ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        'A steadier way to understand your day.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 30),
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: colors.surface.withValues(alpha: 0.94),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: colors.outlineVariant.withValues(alpha: .5)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: widget.isDark ? .12 : .05),
                              blurRadius: 32,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 420),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) {
                            final slide = Tween<Offset>(
                              begin: Offset(_register ? 0.12 : -0.12, 0),
                              end: Offset.zero,
                            ).animate(animation);
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(position: slide, child: child),
                            );
                          },
                          child: AuthForm(
                            key: ValueKey(_register),
                            isRegister: _register,
                            onSwitch: () => setState(() => _register = !_register),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'PRIVATE BY DESIGN  •  LOCAL-FIRST PROTOTYPE',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 10,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Firebase manages your sign-in. Health records will stay on this device.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AuthForm extends StatefulWidget {
  final bool isRegister;
  final VoidCallback onSwitch;
  const AuthForm({
    super.key,
    required this.isRegister,
    required this.onSwitch,
  });

  @override
  State<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<AuthForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _errorMessage;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      final email = _email.text.trim();
      final password = _password.text;

      if (widget.isRegister) {
        final credential = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
        final displayName = _name.text.trim();
        if (displayName.isNotEmpty) {
          await credential.user?.updateDisplayName(displayName);
        }
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
      // AuthGate observes authStateChanges() and opens the app automatically.
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = _friendlyAuthError(e));
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage =
          'Something went wrong. Check your internet connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorMessage =
          'Enter your account email above, then select Forgot password.');
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('If an account exists for this email, a password-reset email has been sent.')),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = _friendlyAuthError(e));
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Could not send the reset email. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return 'An account already exists for this email. Try signing in.';
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'weak-password':
        return 'Choose a stronger password with at least 6 characters.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email or password is incorrect.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again later.';
      case 'network-request-failed':
        return 'Network error. Check your internet connection.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is disabled in Firebase Console. Enable it under Authentication sign-in providers.';
      case 'user-disabled':
        return 'This account has been disabled. Contact support.';
      default:
        return e.message ?? 'Authentication failed. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Form(
      key: _formKey,
      child: Column(
        key: ValueKey(widget.isRegister),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isRegister ? 'Create your space' : 'Welcome aboard',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 7),
          Text(
            widget.isRegister
                ? 'Start with a private profile on this device.'
                : 'Continue to your personal wellness dashboard.',
            style: TextStyle(color: colors.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 22),
          if (widget.isRegister) ...[
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name or preferred nickname',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a name to continue'
                  : null,
            ),
            const SizedBox(height: 14),
          ],
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email address',
              prefixIcon: Icon(Icons.mail_outline),
            ),
            validator: (value) {
              final email = value?.trim() ?? '';
              if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
                return 'Enter a valid email address';
              }
              return null;
            },
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _password,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: widget.isRegister ? 'Create a password' : 'Password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              ),
            ),
            validator: (value) => value == null || value.length < 6
                ? 'Use at least 6 characters'
                : null,
          ),
          if (!widget.isRegister)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : _resetPassword,
                child: const Text('Forgot password?'),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Firebase manages your account. Health details will be stored separately on this device.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.errorContainer.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: colors.onErrorContainer, fontSize: 12),
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(widget.isRegister ? Icons.sailing : Icons.arrow_forward_rounded),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(_busy
                    ? 'Please wait…'
                    : (widget.isRegister ? 'Create account' : 'Sign in to SailmCalm')),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  widget.isRegister ? 'Already have a profile?' : 'New to SailmCalm?',
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
                ),
                TextButton(
                  onPressed: widget.onSwitch,
                  child: Text(widget.isRegister ? 'Sign in' : 'Create profile'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SeaBackdropPainter extends CustomPainter {
  final bool isDark;
  SeaBackdropPainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final color = isDark ? const Color(0xFF17323B) : const Color(0xFFDDEFE8);
    final paint = Paint()..color = color.withValues(alpha: .32);
    final path = Path()
      ..moveTo(0, size.height * .73)
      ..cubicTo(size.width * .22, size.height * .60, size.width * .38, size.height * .85, size.width * .58, size.height * .72)
      ..cubicTo(size.width * .76, size.height * .61, size.width * .88, size.height * .68, size.width, size.height * .58)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);

    final glow = Paint()
      ..shader = RadialGradient(
        colors: [sea.withValues(alpha: isDark ? .19 : .12), Colors.transparent],
      ).createShader(Rect.fromCircle(
        center: Offset(size.width * .5, size.height * .18),
        radius: size.width * .72,
      ));
    canvas.drawRect(Offset.zero & size, glow);
  }

  @override
  bool shouldRepaint(covariant SeaBackdropPainter oldDelegate) => oldDelegate.isDark != isDark;
}

class AppShell extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;
  final VoidCallback onLogout;

  const AppShell({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
    required this.onLogout,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isNotEmpty) AppPreferences.loadAvatar(uid);
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final pages = [
      HomePage(
        onOpenCare: () => setState(() => _index = 2),
        onConnectGlove: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const LiveGlovePage()),
          );
        },
      ),
      const HistoryPage(),
      CarePage(uid: uid),
      ReportsPage(uid: uid),
    ];

    final destinations = const [
      NavigationDestination(icon: Icon(Icons.waves_outlined), selectedIcon: Icon(Icons.waves), label: 'Today'),
      NavigationDestination(icon: Icon(Icons.show_chart_outlined), selectedIcon: Icon(Icons.show_chart), label: 'Trends'),
      NavigationDestination(icon: Icon(Icons.spa_outlined), selectedIcon: Icon(Icons.spa), label: 'Care'),
      NavigationDestination(icon: Icon(Icons.description_outlined), selectedIcon: Icon(Icons.description), label: 'Reports'),
    ];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 18,
        title: Row(
          children: [
            const SailboatMark(size: 38),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SailmCalm', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
                Text('A calmer view of your day', style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: widget.isDark ? 'Light mode' : 'Dark mode',
            onPressed: widget.onToggleTheme,
            icon: Icon(widget.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Profile menu',
            onSelected: (value) {
            if (value == 'logout') widget.onLogout();
            final uid = FirebaseAuth.instance.currentUser?.uid;
            if (uid == null) return;
            if (value == 'profile') {
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProfileSettingsPage(uid: uid)));
            }
            if (value == 'medical') {
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LocalRecordsPage(uid: uid, initialTab: 0)));
            }
          },
          itemBuilder: (context) => const [
              PopupMenuItem(value: 'profile', child: Text('Profile and accessibility')),
              PopupMenuItem(value: 'medical', child: Text('Medical background and medication')),
              PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
            child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: ValueListenableBuilder<ImageProvider?>(
              valueListenable: AppPreferences.avatarImage,
              builder: (context, image, _) => CircleAvatar(
                radius: 16,
                backgroundImage: image,
                child: image == null ? const Icon(Icons.person_outline, size: 18) : null,
              ),
            ),
          ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          return Row(
            children: [
              if (wide)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 20, 8, 20),
                  child: NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: (index) => setState(() => _index = index),
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(icon: Icon(Icons.waves_outlined), selectedIcon: Icon(Icons.waves), label: Text('Today')),
                      NavigationRailDestination(icon: Icon(Icons.show_chart_outlined), selectedIcon: Icon(Icons.show_chart), label: Text('Trends')),
                      NavigationRailDestination(icon: Icon(Icons.spa_outlined), selectedIcon: Icon(Icons.spa), label: Text('Care')),
                      NavigationRailDestination(icon: Icon(Icons.description_outlined), selectedIcon: Icon(Icons.description), label: Text('Reports')),
                    ],
                  ),
                ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(begin: const Offset(0.02, 0), end: Offset.zero).animate(animation),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(key: ValueKey(_index), child: pages[_index]),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 900
          ? NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              destinations: destinations,
            )
          : null,
    );
  }
}

class HomePage extends StatelessWidget {
  final VoidCallback onOpenCare;
  final VoidCallback onConnectGlove;
  const HomePage({
    super.key,
    required this.onOpenCare,
    required this.onConnectGlove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 30),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 12,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SATURDAY, OCTOBER 24', style: TextStyle(color: colors.primary, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
                const SizedBox(height: 9),
                Text('Find your rhythm.', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1.0)),
                const SizedBox(height: 5),
                Text('A simple picture of today, one moment at a time.', style: TextStyle(color: colors.onSurfaceVariant)),
              ],
            ),
            OutlinedButton.icon(
              onPressed: onConnectGlove,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Connect glove'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: theme.brightness == Brightness.dark
                  ? const [Color(0xFF21434A), Color(0xFF142630), Color(0xFF172334)]
                  : const [Color(0xFFD8EEE6), Color(0xFFF4F5E9), Color(0xFFDDECF0)],
            ),
            border: Border.all(color: colors.primary.withValues(alpha: .18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(color: colors.primary.withValues(alpha: .14), borderRadius: BorderRadius.circular(99)),
                    child: Row(children: [Icon(Icons.circle, size: 7, color: colors.primary), const SizedBox(width: 7), const Text('PREVIEW MODE', style: TextStyle(fontSize: 10, letterSpacing: 1.1, fontWeight: FontWeight.bold))]),
                  ),
                  const Spacer(),
                  const SailboatMark(size: 58),
                ],
              ),
              const SizedBox(height: 22),
              const Text('TODAY’S TREMOR SUMMARY', style: TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Your data will find its way here.', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 7),
              Text('The glove is not connected to this app yet. No live prediction is being shown.', style: TextStyle(color: colors.onSurfaceVariant, height: 1.45)),
              const SizedBox(height: 18),
              Row(
                children: [
                  Icon(Icons.lock_outline, size: 15, color: colors.primary),
                  const SizedBox(width: 7),
                  Text('Designed for private, on-device monitoring', style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 17),
        Row(
          children: const [
            Expanded(child: MetricCard(icon: Icons.waves, title: 'Frequency', value: '—', unit: 'Hz', caption: 'Waiting for signal')),
            SizedBox(width: 12),
            Expanded(child: MetricCard(icon: Icons.graphic_eq, title: 'Amplitude', value: '—', unit: 'Sensor units', caption: 'Waiting for signal')),
          ],
        ),
        const SizedBox(height: 26),
        const SectionHeader(title: 'YOUR DAY', subtitle: 'Small habits make useful records.'),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: MiniAction(icon: Icons.edit_note_rounded, title: 'Daily log', subtitle: 'How was today?', onTap: onOpenCare)),
            const SizedBox(width: 12),
            Expanded(child: MiniAction(icon: Icons.alarm_rounded, title: 'Medication', subtitle: 'Your schedule', onTap: onOpenCare)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: MiniAction(icon: Icons.self_improvement, title: 'Care tools', subtitle: 'Relaxation & activity', onTap: onOpenCare)),
            const SizedBox(width: 12),
            Expanded(child: MiniAction(icon: Icons.description_outlined, title: 'Doctor report', subtitle: 'Review your history', onTap: () => _showPrototypeMessage(context, 'Reports will be enabled after local records are implemented.'))),
          ],
        ),
        const SizedBox(height: 24),
        Text('SailmCalm is a monitoring prototype, not a diagnostic device. The local Random Forest reproduces status labels from the glove workbook; it is experimental and not an independent clinical severity assessment.', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11, height: 1.5)),
      ],
    );
  }
}

class MetricCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String unit;
  final String caption;
  const MetricCard({super.key, required this.icon, required this.title, required this.value, required this.unit, required this.caption});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(color: Theme.of(context).cardTheme.color, borderRadius: BorderRadius.circular(20), border: Border.all(color: colors.outlineVariant.withValues(alpha: .35))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: colors.primary, size: 21),
        const SizedBox(height: 14),
        Text(title, style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: colors.primary)),
        Text(unit, style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10)),
        const SizedBox(height: 10),
        Text(caption, style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10)),
      ]),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const SectionHeader({super.key, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: TextStyle(color: Theme.of(context).colorScheme.primary, letterSpacing: 1.6, fontSize: 11, fontWeight: FontWeight.w800)),
    const SizedBox(height: 4),
    Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
  ]);
}

class MiniAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const MiniAction({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).cardTheme.color,
      borderRadius: BorderRadius.circular(19),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(19),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(width: 40, height: 40, decoration: BoxDecoration(color: colors.primary.withValues(alpha: .12), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: colors.primary)),
            const SizedBox(width: 11),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              const SizedBox(height: 4),
              Text(subtitle, style: TextStyle(color: colors.onSurfaceVariant, fontSize: 10)),
            ])),
          ]),
        ),
      ),
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});
  @override
  Widget build(BuildContext context) => _SectionPage(
    title: 'Your trends',
    subtitle: 'Patterns become clearer over time.',
    icon: Icons.show_chart_rounded,
    content: const [
      InfoPanel(title: 'No episodes recorded yet', body: 'When the wearable data connection and local storage are ready, episodes and measurements will appear here.', icon: Icons.timeline),
      InfoPanel(title: 'What we plan to track', body: 'Episode time, duration, measured frequency and amplitude, and the model estimate with its confidence status.', icon: Icons.insights_outlined),
    ],
  );
}

class CarePage extends StatelessWidget {
  final String uid;
  const CarePage({super.key, required this.uid});

  void _openRecords(BuildContext context, int tab) {
    if (uid.isEmpty) {
      _showPrototypeMessage(context, 'Please sign in again to access local records.');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalRecordsPage(uid: uid, initialTab: tab),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _SectionPage(
    title: 'Care and routine',
    subtitle: 'Tools to support the routine you choose with your care team.',
    icon: Icons.spa_outlined,
    content: [
      ActionPanel(title: 'Medical profile', body: 'Save optional tremor-related history and an emergency contact in the encrypted local database on this phone.', icon: Icons.person_outline, buttonLabel: 'Edit profile', onTap: () => _openRecords(context, 0)),
      ActionPanel(title: 'Daily symptom log', body: 'Record your perceived symptom intensity, approximate duration, activity, possible triggers and notes for your doctor.', icon: Icons.edit_note, buttonLabel: 'Create daily log', onTap: () => _openRecords(context, 1)),
      ActionPanel(title: 'Medication schedule', body: 'Store the medication name, prescribed instructions and times. A Severe-status check-in can open this list while Live glove readings is open.', icon: Icons.alarm, buttonLabel: 'Manage medication', onTap: () => _openRecords(context, 2)),
      ActionPanel(title: 'Relaxation and exercises', body: 'Open paced breathing and gentle seated relaxation activities.', icon: Icons.self_improvement, buttonLabel: 'View exercises', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CareToolsPage()))),
      ActionPanel(title: 'Emergency contact', body: 'Set an optional contact in your local profile. SOS and its cancellable countdown are not enabled yet.', icon: Icons.contact_emergency_outlined, buttonLabel: 'Edit contact', onTap: () => _openRecords(context, 0)),
    ],
  );
}

// ReportsPage is implemented in screens/reports_page.dart.

class _SectionPage extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Widget> content;
  const _SectionPage({required this.title, required this.subtitle, required this.icon, required this.content});
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
    children: [
      Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 18),
      Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 7),
      Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 24),
      ...content.map((widget) => Padding(padding: const EdgeInsets.only(bottom: 13), child: widget)),
    ],
  );
}

class InfoPanel extends StatelessWidget {
  final String title;
  final String body;
  final IconData icon;
  const InfoPanel({super.key, required this.title, required this.body, required this.icon});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Theme.of(context).cardTheme.color, borderRadius: BorderRadius.circular(21), border: Border.all(color: colors.outlineVariant.withValues(alpha: .4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 44, height: 44, decoration: BoxDecoration(color: colors.primary.withValues(alpha: .12), borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: colors.primary)),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 7),
          Text(body, style: TextStyle(color: colors.onSurfaceVariant, height: 1.45, fontSize: 13)),
        ])),
      ]),
    );
  }
}

class ActionPanel extends StatelessWidget {
  final String title;
  final String body;
  final IconData icon;
  final String buttonLabel;
  final VoidCallback onTap;
  const ActionPanel({super.key, required this.title, required this.body, required this.icon, required this.buttonLabel, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Theme.of(context).cardTheme.color, borderRadius: BorderRadius.circular(21), border: Border.all(color: colors.outlineVariant.withValues(alpha: .4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, color: colors.primary), const SizedBox(width: 10), Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)))]),
        const SizedBox(height: 10),
        Text(body, style: TextStyle(color: colors.onSurfaceVariant, height: 1.45, fontSize: 13)),
        const SizedBox(height: 13),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: onTap, icon: const Icon(Icons.arrow_forward, size: 16), label: Text(buttonLabel))),
      ]),
    );
  }
}

void _showPrototypeMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
