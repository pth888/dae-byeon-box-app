// lib/router/app_router.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/home/main_page.dart';
import '../screens/mypage/mypage_screen.dart';
import '../screens/accident/accident_detection_screen.dart';
import '../screens/accident/first_response_screen.dart';
import '../screens/accident/accident_video_list_screen.dart';
import '../screens/analysis/analysis_screen.dart';
import '../screens/verdict/verdict_library_screen.dart';
import '../screens/chatbot/chatbot_screen.dart';
import '../screens/accident/timeline_dashboard_screen.dart';
import '../screens/report/my_reports_screen.dart';
import '../widgets/floating_chatbot_button.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/consent_screen.dart';
import '../screens/auth/profile_setup_screen.dart';
import '../screens/splash/splash_screen.dart';
import '../services/auth_service.dart';
import '../services/consent_service.dart';

// 현재 경로에 따라 챗봇에 넘길 컨텍스트를 결정
String _ctxFromLocation(String location) {
  if (location.startsWith('/accident-detected')) return 'accident';
  if (location.startsWith('/first-response')) return 'accident';
  if (location.startsWith('/analysis')) return 'analysis';
  return 'home';
}

// 플로팅 챗봇 버튼을 숨길 화면 경로
bool _hideFloating(String location) {
  // 챗봇 전체화면에서만 숨김 (그 외 모든 화면은 표시)
  if (location.startsWith('/chatbot')) return true;
  return false;
}

bool canAccessWithoutCollectionConsent(String location) =>
    location.startsWith('/consents') ||
    location.startsWith('/my-reports') ||
    location.startsWith('/mypage') ||
    location.startsWith('/analysis') ||
    location.startsWith('/timeline/');

class _RouterRefreshNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}

// go_router 인스턴스를 Riverpod provider로 노출
final appRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = _RouterRefreshNotifier();
  ref.listen<AuthState>(authProvider, (_, __) => refreshNotifier.refresh());
  ref.listen<ConsentState>(
    consentControllerProvider,
    (_, __) => refreshNotifier.refresh(),
  );

  final router = GoRouter(
    initialLocation: '/',
    debugLogDiagnostics: true,
    refreshListenable: refreshNotifier,
    // 인증 상태에 따라 접근 제어
    redirect: (ctx, state) {
      final auth = ref.read(authProvider);
      final consent = ref.read(consentControllerProvider);
      final loc = state.uri.toString();
      final goingToLogin = loc.startsWith('/login');
      final goingToSplash = loc.startsWith('/splash');
      final goingToConsent = loc.startsWith('/consents');

      // 아직 토큰 확인 중(unknown)이면 로딩(스플래시) 화면을 보여준다.
      // 확인이 끝나면 아래 분기로 알맞은 화면으로 다시 보낸다.
      if (auth.status == AuthStatus.unknown) {
        return goingToSplash ? null : '/splash';
      }

      final loggedIn = auth.status == AuthStatus.authenticated;
      // 미로그인 → 로그인 화면으로
      if (!loggedIn && !goingToLogin) return '/login';
      if (!loggedIn) return null;

      // 명시적으로 연 동의 관리 화면은 저장 전 초안 변경으로 이탈시키지 않는다.
      if (goingToConsent) return null;

      // 기존 기록과 계정 관리 등 수집 동의가 필요 없는 경로는 API 장애 중에도 유지한다.
      if (canAccessWithoutCollectionConsent(loc)) return null;

      // 인증 직후에는 저장된 동의가 확인될 때까지 앱이나 동의서를 추측하지 않는다.
      if (consent.status == ConsentLoadStatus.idle ||
          consent.status == ConsentLoadStatus.loading) {
        return goingToSplash ? null : '/splash';
      }
      if (consent.status == ConsentLoadStatus.error) return '/consents';

      // 스플래시와 로그인은 저장된 필수 동의에 따라 시작 화면을 결정한다.
      if (goingToSplash || goingToLogin) {
        return consent.canCollect ? '/' : '/consents';
      }
      if (!consent.canCollect) return '/consents';
      return null;
    },
    routes: [
      // ── 스플래시 / 로딩 (Shell 밖, 토큰 확인 중) ─────────────
      GoRoute(
        path: '/splash',
        name: 'splash',
        builder: (ctx, state) => const SplashScreen(),
      ),

      // ── 로그인 / 회원가입 (Shell 밖, 챗봇 버튼 없음) ──────────
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (ctx, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/consents',
        name: 'consents',
        builder: (ctx, state) => const ConsentScreen(),
      ),
      GoRoute(
        path: '/profile-setup',
        name: 'profile-setup',
        builder: (ctx, state) => const ProfileSetupScreen(),
      ),

      // ── 모든 화면을 감싸는 Shell: 드래그 가능한 플로팅 챗봇 상시 표시 ──
      ShellRoute(
        builder: (ctx, state, child) {
          final location = state.uri.toString();
          final screenCtx = _ctxFromLocation(location);
          return Stack(
            children: [
              child,
              if (!_hideFloating(location))
                DraggableChatbotButton(screenContext: screenCtx),
            ],
          );
        },
        routes: [
          // ── 메인 (상황 인지형 반응형 인터페이스) ─────────────────
          GoRoute(
            path: '/',
            name: 'home',
            builder: (ctx, state) => const MainPage(),
          ),

          // ── 마이페이지 (차량 및 운전자 정형 데이터 관리) ──────────
          GoRoute(
            path: '/mypage',
            name: 'mypage',
            builder: (ctx, state) => const MypageScreen(),
          ),

          // ── 내 리포트 (저장된 사고 분석 PDF 목록) ─────────────────
          GoRoute(
            path: '/my-reports',
            name: 'my-reports',
            builder: (ctx, state) => MyReportsScreen(
              initialCaseId: state.extra as String?,
            ),
          ),

          // ── 사고 감지 화면 (E-Call 가상화, 충격 감지) ─────────────
          GoRoute(
            path: '/accident-detected',
            name: 'accident-detected',
            builder: (ctx, state) {
              final extra = state.extra;
              if (extra is Map) {
                final triggeredAt = extra['triggered_at'];
                return AccidentDetectionScreen(
                  caseId: extra['case_id'] as String?,
                  impactG: (extra['impact_g'] as num?)?.toDouble(),
                  deviceName: extra['device_name'] as String?,
                  eventId: extra['event_id'] as String?,
                  deviceId: extra['device_id'] as String?,
                  triggeredAt: triggeredAt is DateTime ? triggeredAt : null,
                  isTestEvent: extra['test_event'] == true,
                  manual: extra['manual'] == true,
                );
              }
              return AccidentDetectionScreen(caseId: extra as String?);
            },
          ),

          // ── 초동 대처 가이드 (사고 접수 활성화) ───────────────────
          GoRoute(
            path: '/first-response',
            name: 'first-response',
            builder: (ctx, state) {
              final extra = state.extra;
              final accidentId = extra is Map<String, dynamic>
                  ? extra['case_id'] as String? ?? ''
                  : extra as String? ?? '';
              final initialVideoStep = extra is Map<String, dynamic> &&
                  extra['initial_video_step'] == true;
              return FirstResponseScreen(
                key: ValueKey(accidentId),
                accidentId: accidentId,
                initialVideoStep: initialVideoStep,
                hardwareEventId: extra is Map ? extra['hardware_event_id'] as String? : null,
                hardwareDeviceId: extra is Map ? extra['hardware_device_id'] as String? : null,
                hardwareTriggerUtc: extra is Map ? extra['hardware_trigger_utc'] as DateTime? : null,
              );
            },
          ),

          // ── 사고 영상 기록 (업로드된 블랙박스 영상 목록 / 보기) ──────
          GoRoute(
            path: '/accident-videos',
            name: 'accident-videos',
            builder: (ctx, state) => const AccidentVideoListScreen(),
          ),
          GoRoute(
            path: '/accident-video',
            name: 'accident-video',
            builder: (ctx, state) {
              final caseId = state.extra as String? ?? '';
              return AccidentVideoViewScreen(
                key: ValueKey('video-$caseId'),
                caseId: caseId,
              );
            },
          ),

          // ── 분석 페이지 (Multimodal AI 과실 산정 리포트) ──────────
          GoRoute(
            path: '/analysis',
            name: 'analysis',
            builder: (ctx, state) {
              final extra = state.extra;
              if (extra is Map<String, dynamic>) {
                return AnalysisScreen(
                  accidentId: extra['case_id'] as String? ?? '',
                  initialJobId: extra['job_id'] as String?,
                  initialReportId: extra['report_id'] as String?,
                  initialError: extra['error'] as String?,
                );
              }
              return AnalysisScreen(accidentId: extra as String? ?? '');
            },
          ),

          // ── 판결 도서관 (역사적 사법 데이터 검색 엔진) ────────────
          GoRoute(
            path: '/verdict-library',
            name: 'verdict-library',
            builder: (ctx, state) {
              final q = state.extra as String?;
              return VerdictLibraryScreen(initialQuery: q);
            },
          ),

          // ── 플로팅 챗봇 문처리 (전체화면 라우트, 유지) ────────────
          GoRoute(
            path: '/chatbot',
            name: 'chatbot',
            builder: (ctx, state) {
              final context = state.extra as Map<String, dynamic>?;
              return ChatbotScreen(initialContext: context);
            },
          ),

          // ── 사고 처리 타임라인 대시보드 (D-Day 뷰) ───────────────
          GoRoute(
            path: '/timeline/:accidentId',
            name: 'timeline',
            builder: (ctx, state) {
              final accidentId = state.pathParameters['accidentId']!;
              return TimelineDashboardScreen(accidentId: accidentId);
            },
          ),
        ],
      ),
    ],

    // 에러 화면
    errorBuilder: (ctx, state) => Scaffold(
      body: Center(child: Text('페이지를 찾을 수 없습니다: ${state.error}')),
    ),
  );
  ref.onDispose(() {
    router.dispose();
    refreshNotifier.dispose();
  });
  return router;
});
