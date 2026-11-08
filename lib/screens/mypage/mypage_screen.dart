// lib/screens/mypage/mypage_screen.dart
// 테슬라 미니멀 스타일

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/auth_service.dart';
import '../../services/case_service.dart';
import '../../screens/chatbot/chatbot_screen.dart';
import '../../services/profile_service.dart';
import '../../services/device_service.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../utils/ocr_helper_io.dart'
    if (dart.library.html) '../../utils/ocr_helper_web.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../utils/theme.dart';
import '../../widgets/emergency_contact_card.dart';

class _DeviceConnectionRequest {
  const _DeviceConnectionRequest({
    required this.name,
    required this.serverUrl,
    required this.position,
  });

  final String name;
  final String serverUrl;
  final String position;
}

class MypageScreen extends ConsumerStatefulWidget {
  const MypageScreen({super.key});

  @override
  ConsumerState<MypageScreen> createState() => _MypageScreenState();
}

class _MypageScreenState extends ConsumerState<MypageScreen> {
  final _licenseController = TextEditingController();
  final _plateController = TextEditingController();
  final _insuranceController = TextEditingController();
  final _policyNumberController = TextEditingController();
  final _insurancePhoneController = TextEditingController();

  String _selectedVehicleType = '경차';
  bool _isOcrLoading = false;
  bool _isSaving = false;

  // 블랙박스 기기 등록 상태
  String? _registeredDeviceId;
  String? _registeredDeviceName;
  DeviceConnection? _deviceConnection;
  bool _isRegisteringDevice = false;

  // 서버 연결 상태 (null=확인 중, true=연결됨, false=서버 꺼짐)
  bool? _serverOnline;

  final _storage = const FlutterSecureStorage();
  final _imagePicker = ImagePicker();

  final List<String> _vehicleTypes = ['경차', 'SUV', '세단', '대형 화물차', '승합차', '기타'];

  @override
  void initState() {
    super.initState();
    // 첫 프레임 이후에 provider 접근/비동기 로드를 수행해 렌더 중 예외를 방지
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadProfileData();
      _loadRegisteredDevice();
      _checkServer();
    });
  }

  Future<void> _loadProfileData() async {
    await _loadSavedData();
    await _loadBackendProfile();
  }

  // 서버 연결 상태 확인 (계정 카드 배지에 반영)
  Future<void> _checkServer() async {
    final online = await ref.read(profileServiceProvider).pingServer();
    if (!mounted) return;
    setState(() => _serverOnline = online);
  }

  // 등록된 블랙박스 정보 불러오기
  Future<void> _loadRegisteredDevice() async {
    final session = _deviceSessionSnapshot();
    try {
      final dev = await ref.read(deviceServiceProvider).savedDevice();
      if (!mounted) return;
      if (!_isCurrentDeviceSession(session)) {
        _clearDeviceState();
        return;
      }
      setState(() {
        _registeredDeviceId = dev.id;
        _registeredDeviceName = dev.name;
      });
      final connection =
          await ref.read(deviceServiceProvider).fetchConnection();
      if (!mounted) return;
      if (!_isCurrentDeviceSession(session)) {
        _clearDeviceState();
        return;
      }
      if (connection == null) return;
      setState(() {
        _registeredDeviceId = connection.deviceId;
        _registeredDeviceName = connection.deviceName;
        _deviceConnection = connection;
      });
    } on DeviceConnectionException catch (error) {
      if (mounted && _isCurrentDeviceSession(session)) {
        _showSnackbar(error.message, isError: true);
      }
    } catch (_) {
      if (mounted && _isCurrentDeviceSession(session)) {
        _showSnackbar(
          '블랙박스 연결 정보를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.',
          isError: true,
        );
      }
    }
  }

  ({int generation, String? owner}) _deviceSessionSnapshot() {
    final auth = ref.read(authProvider.notifier);
    return (
      generation: auth.sessionGeneration,
      owner: _normalizeDeviceOwner(ref.read(authProvider).email),
    );
  }

  bool _isCurrentDeviceSession(({int generation, String? owner}) session) {
    final auth = ref.read(authProvider.notifier);
    return auth.sessionGeneration == session.generation &&
        _normalizeDeviceOwner(ref.read(authProvider).email) == session.owner;
  }

  String? _normalizeDeviceOwner(String? owner) {
    final normalized = owner?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  void _clearDeviceState() {
    setState(() {
      _registeredDeviceId = null;
      _registeredDeviceName = null;
      _deviceConnection = null;
    });
  }

  Future<void> _loadSavedData() async {
    final license = await _storage.read(key: 'license_number');
    final plate = await _storage.read(key: 'license_plate');
    final insurance = await _storage.read(key: 'insurance_company');
    final policy = await _storage.read(key: 'policy_number');
    final phone = await _storage.read(key: 'insurance_phone');
    final vehicleType = await _storage.read(key: 'vehicle_type');
    if (!mounted) return;
    setState(() {
      _licenseController.text = license ?? '';
      _plateController.text = plate ?? '';
      _insuranceController.text = insurance ?? '';
      _policyNumberController.text = policy ?? '';
      _insurancePhoneController.text = phone ?? '';
      if (vehicleType != null) _selectedVehicleType = vehicleType;
    });
  }

  // 로컬 값은 오프라인 폴백이며, 연결되면 서버 프로필을 기준으로 표시한다.
  Future<void> _loadBackendProfile() async {
    try {
      final profile = await ref.read(profileServiceProvider).fetchProfile();
      if (!mounted || profile == null) return;
      setState(() {
        _licenseController.text = profile.licenseNumber ?? '';
        _plateController.text = profile.licensePlate ?? '';
        _insuranceController.text = profile.insuranceCompany ?? '';
        _policyNumberController.text = profile.policyNumber ?? '';
        _insurancePhoneController.text = profile.insurancePhone ?? '';
        if ((profile.vehicleType ?? '').isNotEmpty &&
            _vehicleTypes.contains(profile.vehicleType)) {
          _selectedVehicleType = profile.vehicleType!;
        }
      });
    } catch (_) {
      // 서버 연결 실패해도 화면은 유지
    }
  }

  Future<void> _scanLicense() async {
    // 웹: ML Kit OCR 미지원 — 직접 입력 안내
    if (!kOcrSupported) {
      _showSnackbar('웹에서는 면허증 자동 인식을 지원하지 않습니다. 직접 입력해 주세요.',
          isError: true);
      return;
    }

    final picked = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );
    if (picked == null) return;
    setState(() => _isOcrLoading = true);

    try {
      final text = await recognizeKoreanText(picked.path);

      final licenseRegex = RegExp(r'\d{2}-\d{6}-\d{2}');
      final match = licenseRegex.firstMatch(text);

      if (match != null) {
        setState(() => _licenseController.text = match.group(0)!);
        _showSnackbar('면허증 인식 완료', isError: false);
      } else {
        _showSnackbar('OCR 인식 실패. 직접 입력해 주세요.', isError: true);
      }
    } catch (e) {
      _showSnackbar('인식 중 오류 발생', isError: true);
    } finally {
      if (mounted) setState(() => _isOcrLoading = false);
    }
  }

  Future<void> _saveData() async {
    setState(() => _isSaving = true);
    final auth = ref.read(authProvider);
    final displayName = (auth.name ?? '').trim();
    final saved = displayName.isEmpty
        ? null
        : await ref.read(profileServiceProvider).saveProfile(
              displayName: displayName,
              licenseNumber: _emptyAsNull(_licenseController.text),
              licensePlate: _emptyAsNull(_plateController.text),
              insuranceCompany: _emptyAsNull(_insuranceController.text),
              policyNumber: _emptyAsNull(_policyNumberController.text),
              insurancePhone: _emptyAsNull(_insurancePhoneController.text),
              vehicleType: _emptyAsNull(_selectedVehicleType),
            );

    if (saved != null) {
      await _writeLocalProfile(saved);
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    _showSnackbar(
      saved != null ? '저장 완료' : '서버 저장에 실패했습니다. 다시 시도해 주세요.',
      isError: saved == null,
    );
  }

  String? _emptyAsNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _writeLocalProfile(UserProfile profile) async {
    final values = <String, String?>{
      'license_number': profile.licenseNumber,
      'license_plate': profile.licensePlate,
      'insurance_company': profile.insuranceCompany,
      'policy_number': profile.policyNumber,
      'insurance_phone': profile.insurancePhone,
      'vehicle_type': profile.vehicleType,
    };
    for (final entry in values.entries) {
      if (entry.value == null) {
        await _storage.delete(key: entry.key);
      } else {
        await _storage.write(key: entry.key, value: entry.value);
      }
    }
  }

  Future<void> _confirmAccountDeletion() async {
    final passwordController = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text('계정 삭제 요청',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '비밀번호 확인 후 계정 접근이 즉시 종료됩니다. 데이터 삭제는 서버에서 순차 처리됩니다.',
              style:
                  TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: '비밀번호',
                labelStyle: TextStyle(color: AppTheme.textSub),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, passwordController.text),
            child:
                const Text('삭제 요청', style: TextStyle(color: AppTheme.errorRed)),
          ),
        ],
      ),
    );
    passwordController.dispose();
    if (password == null || password.isEmpty || !mounted) return;

    final result =
        await ref.read(authProvider.notifier).requestAccountDeletion(password);
    if (result == AccountDeletionResult.accepted) {
      _clearSessionState();
      return;
    }
    if (!mounted) return;
    _showSnackbar('계정 삭제 요청에 실패했습니다. 비밀번호를 확인해 주세요.', isError: true);
  }

  void _clearSessionState() {
    ref.read(activeCaseProvider.notifier).state = null;
    ref.invalidate(chatbotProvider);
  }

  void _showSnackbar(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppTheme.surfaceDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBlack,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('내 정보', style: AppTheme.h1),
                    const SizedBox(height: 8),
                    const Text(
                      '사고 발생 시 자동으로 사용됩니다',
                      style: TextStyle(
                        color: AppTheme.textSub,
                        fontSize: 14,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── 로그인 계정 ──────────────────────────
                    _buildAccountCard(),

                    const SizedBox(height: 36),

                    // ── 블랙박스 기기 ────────────────────────
                    _buildSectionLabel('블랙박스'),
                    const SizedBox(height: 16),
                    _buildDeviceCard(),

                    const SizedBox(height: 40),

                    // ── 비상 연락처 (사고 후 무응답 시 위치 문자) ──
                    _buildSectionLabel('비상 연락처'),
                    const SizedBox(height: 16),
                    const EmergencyContactCard(),

                    const SizedBox(height: 40),

                    // ── 운전면허 ────────────────────────────
                    _buildSectionLabel('운전면허'),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: _isOcrLoading ? null : _scanLicense,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            _isOcrLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.camera_alt_outlined,
                                    color: Colors.white, size: 22),
                            const SizedBox(width: 14),
                            Text(
                              _isOcrLoading ? '인식 중...' : '면허증 촬영으로 자동 입력',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w300,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildField('면허번호', _licenseController, '00-000000-00'),

                    const SizedBox(height: 40),

                    // ── 차량 정보 ────────────────────────────
                    _buildSectionLabel('차량 정보'),
                    const SizedBox(height: 20),
                    _buildField('차량 번호', _plateController, '12가 3456'),
                    const SizedBox(height: 24),
                    _buildVehicleTypeSelector(),

                    const SizedBox(height: 40),

                    // ── 보험 정보 ────────────────────────────
                    _buildSectionLabel('보험 정보'),
                    const SizedBox(height: 20),
                    _buildField('보험사', _insuranceController, '삼성화재'),
                    const SizedBox(height: 24),
                    _buildField('증권번호', _policyNumberController, '선택 입력'),
                    const SizedBox(height: 24),
                    _buildField(
                        '보험사 전화', _insurancePhoneController, '1588-0000'),

                    const SizedBox(height: 48),

                    // ── 저장 버튼 ────────────────────────────
                    GestureDetector(
                      onTap: _isSaving ? null : _saveData,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          color: AppTheme.pointWhite,
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: Center(
                          child: Text(
                            _isSaving ? '저장 중...' : '저장하기',
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── 동의 관리 버튼 ────────────────────────
                    GestureDetector(
                      onTap: () => context.push('/consents'),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFF3A3A3E)),
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.privacy_tip_outlined,
                                color: Colors.white, size: 18),
                            SizedBox(width: 8),
                            Text(
                              '개인정보 및 외부 AI 동의 관리',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── 로그아웃 버튼 ─────────────────────────
                    GestureDetector(
                      onTap: () async {
                        await ref.read(authProvider.notifier).logout();
                        _clearSessionState();
                        // 라우터 redirect 가 자동으로 로그인 화면으로 보냄
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFF3A3A3E)),
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: const Center(
                          child: Text(
                            '로그아웃',
                            style: TextStyle(
                              color: AppTheme.textSub,
                              fontSize: 15,
                              fontWeight: FontWeight.w400,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '로그아웃 시 이 앱이 저장한 사진, 녹음, 영상, PDF가 기기에서 삭제됩니다. 서버 원본은 유지됩니다.',
                      style: TextStyle(
                        color: AppTheme.textHint,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _confirmAccountDeletion,
                      child: const Text(
                        '계정 삭제',
                        style: TextStyle(
                          color: AppTheme.errorRed,
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 20, color: Colors.white),
          ),
          const Spacer(),
          const Text(
            'MY',
            style: TextStyle(
              color: AppTheme.textSub,
              fontSize: 13,
              fontWeight: FontWeight.w400,
              letterSpacing: 1.5,
            ),
          ),
          const Spacer(),
          const SizedBox(width: 20),
        ],
      ),
    );
  }

  // ── 로그인 계정 카드 (백엔드 인증 연동) ──────────────────
  Widget _buildAccountCard() {
    final auth = ref.watch(authProvider);
    final name = (auth.name ?? '').trim();
    final email = (auth.email ?? '').trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.divider, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.surfaceDark,
            ),
            child: const Icon(Icons.person_outline_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? '로그인 사용자' : name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  email.isEmpty ? '-' : email,
                  style: const TextStyle(
                    color: AppTheme.textHint,
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ],
            ),
          ),
          _buildServerBadge(),
        ],
      ),
    );
  }

  // 서버 연결 상태 배지 (실제 /health/live 핑 결과 반영)
  Widget _buildServerBadge() {
    final String label;
    final Color color;
    if (_serverOnline == null) {
      label = '확인 중';
      color = AppTheme.textHint;
    } else if (_serverOnline == true) {
      label = '연결됨';
      color = AppTheme.textSub;
    } else {
      label = '서버 꺼짐';
      color = AppTheme.errorRed;
    }
    return GestureDetector(
      // 서버 꺼짐일 때 탭하면 다시 확인
      onTap: _serverOnline == false
          ? () {
              setState(() => _serverOnline = null);
              _checkServer();
            }
          : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  // ── 블랙박스 기기 카드 ───────────────────────────────────
  Widget _buildDeviceCard() {
    final registered = _registeredDeviceId != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.divider, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.surfaceDark,
            ),
            child: Icon(
              registered ? Icons.videocam_rounded : Icons.videocam_off_outlined,
              color: registered ? Colors.white : AppTheme.textHint,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  registered
                      ? (_registeredDeviceName ?? '등록된 블랙박스')
                      : '등록된 블랙박스 없음',
                  style: TextStyle(
                    color: registered ? Colors.white : AppTheme.textSub,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _deviceConnection != null
                      ? '${_deviceConnection!.position == 'front' ? '전방' : '후방'} · ${_deviceConnection!.serverUrl}'
                      : registered
                          ? '기기 등록됨 · 영상 수신 연결은 별도 설정이 필요합니다'
                          : '블랙박스를 등록해 사고 영상을 연동하세요',
                  style: const TextStyle(
                    color: AppTheme.textHint,
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: registered ? '블랙박스 설정' : '블랙박스 등록',
            child: GestureDetector(
              onTap: _isRegisteringDevice ? null : _startDeviceRegistration,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: registered ? Colors.transparent : AppTheme.pointWhite,
                  border: Border.all(
                    color: registered ? AppTheme.divider : AppTheme.pointWhite,
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: _isRegisteringDevice
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(
                        registered ? '설정' : '등록',
                        style: TextStyle(
                          color: registered ? AppTheme.textSub : Colors.black,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 연결 방식 선택
  Future<void> _startDeviceRegistration() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text(
          '블랙박스 설정',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cloud_outlined, color: Colors.white),
              title: const Text('서버 연결',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('전방 또는 후방 영상 수신 연결',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'connect'),
            ),
            ListTile(
              leading: const Icon(Icons.label_outline, color: Colors.white),
              title: const Text('이름만 등록',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('영상 서버 연결 없이 기기 정보만 등록',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'register'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'connect') {
      await _startDeviceConnection();
    } else if (action == 'register') {
      await _registerDeviceNameOnly();
    }
  }

  Future<void> _registerDeviceNameOnly() async {
    var nameDraft = _registeredDeviceName ?? '내 블랙박스';
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text('블랙박스 등록',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '기기 이름을 입력하세요',
              style: TextStyle(color: AppTheme.textSub, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: nameDraft,
              onChanged: (value) => nameDraft = value,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              cursorColor: Colors.white,
              decoration: const InputDecoration(
                hintText: '예: 내 차 블랙박스',
                hintStyle: TextStyle(color: AppTheme.textHint),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppTheme.divider),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, nameDraft.trim()),
            child: const Text('등록', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    final session = _deviceSessionSnapshot();
    setState(() => _isRegisteringDevice = true);
    final result = await ref.read(deviceServiceProvider).registerDevice(name);
    if (!mounted) return;
    if (!_isCurrentDeviceSession(session)) {
      setState(() => _isRegisteringDevice = false);
      return;
    }
    setState(() {
      _isRegisteringDevice = false;
      if (result != null) {
        _registeredDeviceId = result.deviceId;
        _registeredDeviceName = result.deviceName;
        _deviceConnection = null;
      }
    });

    if (result == null) {
      _showSnackbar('등록 실패 — 서버 연결을 확인하세요', isError: true);
      return;
    }
    _showSnackbar('기기가 등록되었습니다. 영상 수신 연결은 별도 설정이 필요합니다.', isError: false);
  }

  Future<void> _startDeviceConnection() async {
    var nameDraft = _registeredDeviceName ?? '내 블랙박스';
    var serverDraft =
        _deviceConnection?.serverUrl ?? 'https://project-box.life';
    var position = _deviceConnection?.position ?? 'front';
    final request = await showDialog<_DeviceConnectionRequest>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.surfaceDark,
          title: const Text(
            '영상 수신 연결',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  initialValue: nameDraft,
                  onChanged: (value) => nameDraft = value,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: '기기 이름',
                    labelStyle: TextStyle(color: AppTheme.textSub),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: serverDraft,
                  onChanged: (value) => serverDraft = value,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: '수집 서버',
                    labelStyle: TextStyle(color: AppTheme.textSub),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  '카메라 위치',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Semantics(
                  label: '카메라 위치 선택',
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'front',
                        icon: Icon(Icons.arrow_upward_rounded),
                        label: Text('전방'),
                      ),
                      ButtonSegment(
                        value: 'rear',
                        icon: Icon(Icons.arrow_downward_rounded),
                        label: Text('후방'),
                      ),
                    ],
                    selected: {position},
                    onSelectionChanged: (selection) =>
                        setDialogState(() => position = selection.first),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text('취소', style: TextStyle(color: AppTheme.textSub)),
            ),
            TextButton(
              onPressed: () {
                final name = nameDraft.trim();
                final serverUrl = serverDraft.trim();
                if (name.isEmpty || serverUrl.isEmpty) return;
                Navigator.pop(
                  ctx,
                  _DeviceConnectionRequest(
                    name: name,
                    serverUrl: serverUrl,
                    position: position,
                  ),
                );
              },
              child: const Text('연결', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    if (request == null || !mounted) return;

    setState(() => _isRegisteringDevice = true);
    DeviceConnection? result;
    try {
      result = await ref.read(deviceServiceProvider).connectDevice(
            request.name,
            request.serverUrl,
            request.position,
          );
    } on DeviceConnectionException catch (error) {
      if (!mounted) return;
      setState(() => _isRegisteringDevice = false);
      _showSnackbar(error.message, isError: true);
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _isRegisteringDevice = false);
      _showSnackbar(
        '블랙박스 연결 정보를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.',
        isError: true,
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _isRegisteringDevice = false;
      if (result != null) {
        _registeredDeviceId = result.deviceId;
        _registeredDeviceName = result.deviceName;
        _deviceConnection = result;
      }
    });
    if (result == null) {
      _showSnackbar(
        '서버 연결에 실패했습니다. 설정과 계정 권한을 확인해 주세요.',
        isError: true,
      );
      return;
    }
    _showSnackbar('블랙박스가 영상 수신 서버에 연결되었습니다.', isError: false);
  }

  Widget _buildSectionLabel(String text) {
    return Text(text.toUpperCase(), style: AppTheme.label);
  }

  Widget _buildField(
      String label, TextEditingController controller, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSub,
            fontSize: 13,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w300,
          ),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              color: AppTheme.textHint,
              fontSize: 16,
              fontWeight: FontWeight.w300,
            ),
            isDense: true,
            contentPadding: const EdgeInsets.only(bottom: 10),
            border: const UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.divider),
            ),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: AppTheme.divider),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVehicleTypeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '차종',
          style: TextStyle(
            color: AppTheme.textSub,
            fontSize: 13,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _vehicleTypes.map((type) {
            final selected = _selectedVehicleType == type;
            return GestureDetector(
              onTap: () => setState(() => _selectedVehicleType = type),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? AppTheme.pointWhite : Colors.transparent,
                  border: Border.all(
                    color: selected ? AppTheme.pointWhite : AppTheme.divider,
                  ),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  type,
                  style: TextStyle(
                    color: selected ? Colors.black : AppTheme.textSub,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w300,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _licenseController.dispose();
    _plateController.dispose();
    _insuranceController.dispose();
    _policyNumberController.dispose();
    _insurancePhoneController.dispose();
    super.dispose();
  }
}
