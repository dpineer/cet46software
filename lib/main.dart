import 'dart:convert';
import 'dart:math';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as path;
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';

// ==========================================
// 主题状态管理
// ==========================================
class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  ThemeProvider() { _loadTheme(); }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('is_dark_mode');
    if (isDark != null) {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
      notifyListeners();
    }
  }

  Future<void> toggleTheme(bool isDark) async {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_mode', isDark);
    notifyListeners();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && (io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LearningProvider()),
      ],
      // ↓ 用 builder 而不是 child，builder 的 context 已经在 Provider 树内
      builder: (context, _) => const CetLearningApp(),
    ),
  );
}

class CetLearningApp extends StatelessWidget {
  const CetLearningApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 现在这里的 context 能正确访问 ThemeProvider
    final themeProvider = context.watch<ThemeProvider>();

    return MaterialApp(
      title: '四六级 AI 词汇',
      theme: ThemeData(
        brightness: Brightness.light,
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
      themeMode: themeProvider.themeMode,
      home: const HomeScreen(),
    );
  }
}

// ==========================================
// 数据模型
// ==========================================
class Word {
  int id;
  String spelling;
  String translation;
  int reps;
  int interval;
  double easeFactor;
  int nextReviewDate;

  Word({
    required this.id, required this.spelling, required this.translation,
    this.reps = 0, this.interval = 0, this.easeFactor = 2.5, this.nextReviewDate = 0,
  });

  Map<String, dynamic> toMap() => {
    'id': id, 'spelling': spelling, 'translation': translation,
    'reps': reps, 'interval': interval, 'easeFactor': easeFactor,
    'nextReviewDate': nextReviewDate,
  };

  factory Word.fromMap(Map<String, dynamic> map) => Word(
    id: map['id'] != null ? int.parse(map['id'].toString()) : 0,
    spelling: map['spelling']?.toString() ?? 'Unknown',
    translation: map['translation']?.toString() ?? 'Unknown',
    reps: map['reps'] != null ? int.parse(map['reps'].toString()) : 0,
    interval: map['interval'] != null ? int.parse(map['interval'].toString()) : 0,
    easeFactor: map['easeFactor'] != null ? double.parse(map['easeFactor'].toString()) : 2.5,
    nextReviewDate: map['nextReviewDate'] != null ? int.parse(map['nextReviewDate'].toString()) : 0,
  );

  void updateSM2(int quality) {
    if (quality < 3) { reps = 0; interval = 1; }
    else {
      if (reps == 0) interval = 1;
      else if (reps == 1) interval = 6;
      else interval = (interval * easeFactor).round();
      reps++;
    }
    easeFactor = easeFactor + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
    if (easeFactor < 1.3) easeFactor = 1.3;
    nextReviewDate = DateTime.now().add(Duration(days: interval)).millisecondsSinceEpoch;
  }
}

// 收藏条目模型
class FavoriteEntry {
  final int wordId;
  final String spelling;
  final String translation;
  final String aiJson; // 存储完整AI解析JSON字符串
  final int savedAt;

  FavoriteEntry({
    required this.wordId, required this.spelling,
    required this.translation, required this.aiJson, required this.savedAt,
  });

  Map<String, dynamic> toMap() => {
    'wordId': wordId, 'spelling': spelling,
    'translation': translation, 'aiJson': aiJson, 'savedAt': savedAt,
  };

  factory FavoriteEntry.fromMap(Map<String, dynamic> map) => FavoriteEntry(
    wordId: map['wordId'] as int,
    spelling: map['spelling'] as String,
    translation: map['translation'] as String,
    aiJson: map['aiJson'] as String,
    savedAt: map['savedAt'] as int,
  );

  Map<String, dynamic> get aiData {
    try { return jsonDecode(aiJson) as Map<String, dynamic>; }
    catch (_) { return {}; }
  }
}

// ==========================================
// 数据库
// ==========================================
class DatabaseHelper {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await initDB();
    return _database!;
  }

  static Future<Database> initDB() async {
    String dbDir = await getDatabasesPath();
    String dbPath = path.join(dbDir, 'cet_words.db');
    final dir = io.Directory(dbDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    bool dbExists = await databaseExists(dbPath);
    if (!dbExists) {
      try {
        final data = await rootBundle.load('assets/cet_words.db');
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        await io.File(dbPath).writeAsBytes(bytes, flush: true);
      } catch (e) { debugPrint('加载默认数据库失败: $e'); }
    }

    final db = await openDatabase(dbPath);

    // 建收藏表（如不存在）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS favorites (
        wordId INTEGER PRIMARY KEY,
        spelling TEXT NOT NULL,
        translation TEXT NOT NULL,
        aiJson TEXT NOT NULL,
        savedAt INTEGER NOT NULL
      )
    ''');

    return db;
  }

  static Future<void> updateWord(Word word) async {
    final db = await database;
    await db.update('words', word.toMap(), where: 'id = ?', whereArgs: [word.id]);
  }

  static Future<List<String>> getRandomTranslations(String exclude, int limit) async {
    final db = await database;
    final maps = await db.rawQuery(
      'SELECT translation FROM words WHERE translation != ? ORDER BY RANDOM() LIMIT ?', [exclude, limit]);
    return maps.map((e) => e['translation'] as String).toList();
  }

  static Future<List<String>> getRandomSpellings(String exclude, int limit) async {
    final db = await database;
    final maps = await db.rawQuery(
      'SELECT spelling FROM words WHERE spelling != ? ORDER BY RANDOM() LIMIT ?', [exclude, limit]);
    return maps.map((e) => e['spelling'] as String).toList();
  }

  static Future<List<Word>> getWordsByIds(List<int> ids) async {
    if (ids.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final maps = await db.query('words', where: 'id IN ($placeholders)', whereArgs: ids);
    final wordMap = {for (var m in maps) m['id'] as int: Word.fromMap(m)};
    return ids.where(wordMap.containsKey).map((id) => wordMap[id]!).toList();
  }

  static Future<List<Word>> getTodayWords() async {
    final db = await database;
    int now = DateTime.now().millisecondsSinceEpoch;
    final maps = await db.rawQuery(
      'SELECT * FROM words WHERE nextReviewDate IS NULL OR nextReviewDate = 0 OR nextReviewDate <= ? LIMIT 20', [now]);
    return List.generate(maps.length, (i) => Word.fromMap(maps[i]));
  }

  static Future<bool> forceReimportDatabase() async {
    String dbDir = await getDatabasesPath();
    String dbPath = path.join(dbDir, 'cet_words.db');
    if (_database != null) { await _database!.close(); _database = null; }
    try {
      final dir = io.Directory(dbDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final data = await rootBundle.load('assets/cet_words.db');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await io.File(dbPath).writeAsBytes(bytes, flush: true);
      // 重新建收藏表
      final db = await database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS favorites (
          wordId INTEGER PRIMARY KEY, spelling TEXT NOT NULL,
          translation TEXT NOT NULL, aiJson TEXT NOT NULL, savedAt INTEGER NOT NULL
        )
      ''');
      return true;
    } catch (e) { return false; }
  }

  static Future<int> importDatabaseFromFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result != null && result.files.single.path != null) {
        io.File sourceFile = io.File(result.files.single.path!);
        String dbDir = await getDatabasesPath();
        String dbPath = path.join(dbDir, 'cet_words.db');
        final dir = io.Directory(dbDir);
        if (!await dir.exists()) await dir.create(recursive: true);
        if (_database != null) { await _database!.close(); _database = null; }
        await sourceFile.copy(dbPath);
        final db = await database;
        // 确保收藏表存在
        await db.execute('''
          CREATE TABLE IF NOT EXISTS favorites (
            wordId INTEGER PRIMARY KEY, spelling TEXT NOT NULL,
            translation TEXT NOT NULL, aiJson TEXT NOT NULL, savedAt INTEGER NOT NULL
          )
        ''');
        final countResult = await db.rawQuery('SELECT COUNT(*) as count FROM words');
        return countResult.first['count'] as int;
      }
    } catch (e) { debugPrint("导入失败: $e"); }
    return -1;
  }

  // ========== 收藏相关 ==========
  static Future<void> saveFavorite(FavoriteEntry entry) async {
    final db = await database;
    await db.insert('favorites', entry.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteFavorite(int wordId) async {
    final db = await database;
    await db.delete('favorites', where: 'wordId = ?', whereArgs: [wordId]);
  }

  static Future<bool> isFavorite(int wordId) async {
    final db = await database;
    final result = await db.query('favorites', where: 'wordId = ?', whereArgs: [wordId]);
    return result.isNotEmpty;
  }

  static Future<List<FavoriteEntry>> getAllFavorites() async {
    final db = await database;
    final maps = await db.query('favorites', orderBy: 'savedAt DESC');
    return maps.map((m) => FavoriteEntry.fromMap(m)).toList();
  }

  // 获取收藏单词用于练习
  static Future<List<Word>> getFavoriteWordsForPractice() async {
    final db = await database;
    final favs = await db.query('favorites');
    if (favs.isEmpty) return [];
    final ids = favs.map((f) => f['wordId'] as int).toList();
    return getWordsByIds(ids);
  }
}

// ==========================================
// AI 服务
// ==========================================
class AiService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const String _keyName = "deepseek_api_key";
  static const String _apiUrl = "https://api.deepseek.com/v1/chat/completions";

  static Future<String> getApiKey() async => await _storage.read(key: _keyName) ?? "";
  static Future<void> saveApiKey(String key) async => await _storage.write(key: _keyName, value: key);
  static Future<void> deleteApiKey() async => await _storage.delete(key: _keyName);

  static Future<void> getExplanationStream(
    Word word, String userInput, String qType,
    Function(String) onStreamUpdate, Function(String)? onError,
  ) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) {
      onStreamUpdate(jsonEncode({"error_analysis": "CONFIG_REQUIRED"}));
      return;
    }
    try {
      final dio = Dio();
      final prompt = """单词：${word.spelling}（${word.translation}）。学生在${qType}时输入：$userInput。
请用JSON返回以下字段（每个字段都必须是字符串，例句独立成字段）：
- error_analysis（一段话分析错误原因，不超过3句）
- etymology（词源词根分析）
- mnemonic（记忆法）
- example（3个例句，用\\n分隔）""";

      Response<ResponseBody> response = await dio.post<ResponseBody>(
        _apiUrl,
        data: {
          "model": "deepseek-chat",
          "messages": [
            {"role": "system", "content": "只返回合法JSON，不含markdown代码块，不含多余文字。"},
            {"role": "user", "content": prompt}
          ],
          "stream": true,
        },
        options: Options(
          headers: {'Authorization': 'Bearer $apiKey', 'Accept': 'text/event-stream'},
          responseType: ResponseType.stream,
        ),
      );

      final stream = response.data?.stream;
      if (stream == null) return;

      String accumulated = "";
      stream.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
        (String line) {
          if (line.startsWith('data: ') && !line.contains('[DONE]')) {
            final jsonStr = line.substring(6);
            try {
              if (jsonStr.trim().isNotEmpty) {
                final jsonData = jsonDecode(jsonStr);
                final delta = jsonData['choices'][0]['delta']['content'];
                if (delta != null) {
                  accumulated += delta as String;
                  // 清理markdown标记后实时推送
                  final cleaned = accumulated
                      .replaceAll(RegExp(r'^```json\s*', multiLine: false), '')
                      .replaceAll(RegExp(r'^```\s*', multiLine: false), '')
                      .replaceAll('```json', '').replaceAll('```', '');
                  onStreamUpdate(cleaned);
                }
              }
            } catch (_) {}
          }
        },
        onDone: () {
          final cleaned = accumulated
              .replaceAll(RegExp(r'```json\s*'), '').replaceAll('```', '').trim();
          onStreamUpdate(cleaned);
        },
        onError: (e) => onError?.call("API_ERROR: $e"),
      );
    } catch (e) { onError?.call("API_ERROR: $e"); }
  }

  static Future<Map<String, dynamic>> getDetailedExplanation(Word word) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) return {"error": "CONFIG_REQUIRED"};
    try {
      final dio = Dio();
      final prompt = """单词：${word.spelling}（${word.translation}）。
请用JSON返回（所有字段值均为字符串）：
- pronunciation（国际音标）
- partOfSpeech（词性说明）
- usage_level（使用频率：高/中/低，附说明）
- detailed_meanings（详细释义，多个含义用\\n分隔）
- etymology（词源与历史演变，详细版）
- collocations（5个常见搭配短语，每个附中文，用\\n分隔）
- synonyms_and_antonyms（同义词与反义词，格式：同义：x,y；反义：a,b）
- example（6个实用例句，用\\n分隔）""";

      final response = await dio.post(_apiUrl,
        options: Options(headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"}),
        data: {
          "model": "deepseek-chat",
          "messages": [
            {"role": "system", "content": "只返回合法JSON，不含markdown代码块。"},
            {"role": "user", "content": prompt}
          ],
        },
      );
      String content = response.data['choices'][0]['message']['content'];
      content = content.replaceAll(RegExp(r'```json\s*|\s*```'), '').trim();
      return jsonDecode(content);
    } catch (e) { return {"error": "API_ERROR: $e"}; }
  }

  // 进阶练习：生成填空段落
  static Future<Map<String, dynamic>> generateFillBlankParagraph(List<Word> words) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) return {"error": "CONFIG_REQUIRED"};
    try {
      final dio = Dio();
      final wordList = words.map((w) => "${w.spelling}（${w.translation}）").join("、");
      final prompt = """请用以下单词造一个连贯的英文小段落（3-5句话）：$wordList
要求：
1. 每个单词在段落中各出现一次
2. 段落语义自然连贯
3. 用JSON返回以下字段（值均为字符串）：
   - paragraph（完整段落，用于展示答案）
   - blanked_paragraph（将目标单词替换为____的版本，如有多个空用____1, ____2区分）
   - answers（答案列表，格式："word1,word2,word3"，与空格顺序对应）
   - analysis（段落解析，说明每个单词的用法）
   - translation（段落的中文翻译）""";

      final response = await dio.post(_apiUrl,
        options: Options(headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"}),
        data: {
          "model": "deepseek-chat",
          "messages": [
            {"role": "system", "content": "只返回合法JSON，不含markdown代码块。"},
            {"role": "user", "content": prompt}
          ],
        },
      );
      String content = response.data['choices'][0]['message']['content'];
      content = content.replaceAll(RegExp(r'```json\s*|\s*```'), '').trim();
      return jsonDecode(content);
    } catch (e) { return {"error": "API_ERROR: $e"}; }
  }
}

// ==========================================
// 状态管理
// ==========================================
enum QuestionType { zhToEn, enToZh, spelling }

class LearningProvider extends ChangeNotifier {
  List<Word> _todayWords = [];
  int _currentIndex = 0;
  bool _isLoading = true;
  QuestionType _currentQType = QuestionType.enToZh;
  List<String> _options = [];

  String aiExplanation = "";
  bool isAiLoading = false;
  // 完整的AI解析（流结束后的最终JSON字符串，用于收藏）
  String aiFinalJson = "";

  bool get isLoading => _isLoading;
  bool get isFinished => _currentIndex >= _todayWords.length && !_isLoading;
  Word? get currentWord => _todayWords.isEmpty || isFinished ? null : _todayWords[_currentIndex];
  QuestionType get currentQType => _currentQType;
  List<String> get options => List.unmodifiable(_options);
  int get totalWords => _todayWords.length;
  int get progress => _currentIndex;
  List<Word> get todayWords => List.unmodifiable(_todayWords);

  bool _isTodayTaskDone = false;
  bool get isTodayTaskDone => _isTodayTaskDone;

  Future<void> checkDailyStatus() async {
    final prefs = await SharedPreferences.getInstance();
    String lastDate = prefs.getString('last_daily_date') ?? '';
    String today = DateTime.now().toIso8601String().split('T')[0];
    _isTodayTaskDone = (lastDate == today);
    notifyListeners();
  }

  Future<void> _markDailyTaskDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_daily_date', DateTime.now().toIso8601String().split('T')[0]);
    _isTodayTaskDone = true;
    notifyListeners();
  }

  Future<void> _saveSession(List<Word> words, int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('session_word_ids', words.map((w) => w.id.toString()).toList());
    await prefs.setInt('learning_progress', index);
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_word_ids');
    await prefs.remove('learning_progress');
  }

  Future<bool> hasUnfinishedLearning() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? ids = prefs.getStringList('session_word_ids');
    int prog = prefs.getInt('learning_progress') ?? 0;
    return ids != null && ids.isNotEmpty && prog > 0 && prog < ids.length;
  }

  Future<int> loadTodayTasks() async {
    _isLoading = true;
    notifyListeners();
    try {
      _todayWords = await DatabaseHelper.getTodayWords();
      _currentIndex = 0;
      await _saveSession(_todayWords, _currentIndex);
      if (_todayWords.isNotEmpty) await _generateQuestion();
      return _todayWords.length;
    } catch (e) { return 0; }
    finally { _isLoading = false; notifyListeners(); }
  }

  Future<void> continueLearning() async {
    _isLoading = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String>? idsStr = prefs.getStringList('session_word_ids');
      _currentIndex = prefs.getInt('learning_progress') ?? 0;
      if (idsStr != null && idsStr.isNotEmpty) {
        _todayWords = await DatabaseHelper.getWordsByIds(idsStr.map(int.parse).toList());
      } else {
        _todayWords = await DatabaseHelper.getTodayWords();
        _currentIndex = 0;
      }
      if (_currentIndex >= _todayWords.length) _currentIndex = 0;
      if (_todayWords.isNotEmpty) await _generateQuestion();
    } catch (e) { debugPrint("继续学习报错: $e"); }
    finally { _isLoading = false; notifyListeners(); }
  }

  Future<void> _generateQuestion() async {
    if (currentWord == null) return;
    final rand = Random().nextInt(3);
    _currentQType = QuestionType.values[rand];
    _options.clear();
    if (_currentQType == QuestionType.enToZh) {
      _options = await DatabaseHelper.getRandomTranslations(currentWord!.translation, 3);
      _options.add(currentWord!.translation);
    } else if (_currentQType == QuestionType.zhToEn) {
      _options = await DatabaseHelper.getRandomSpellings(currentWord!.spelling, 3);
      _options.add(currentWord!.spelling);
    }
    _options.shuffle();
  }

  /// 返回 null = 答对；返回 Map = 答错，需要显示AI解析
  /// 【修复】答错时先返回 sentinel，让UI立刻弹窗，再异步推送流式内容
  Future<Map<String, dynamic>?> checkAnswer(String userInput) async {
    if (currentWord == null) return null;

    bool isCorrect = _currentQType == QuestionType.enToZh
        ? userInput == currentWord!.translation
        : userInput.trim().toLowerCase() == currentWord!.spelling.toLowerCase();

    if (isCorrect) {
      currentWord!.updateSM2(4);
      await DatabaseHelper.updateWord(currentWord!);
      _nextWord();
      return null;
    } else {
      currentWord!.updateSM2(1);
      await DatabaseHelper.updateWord(currentWord!);

      // 【关键修复】先重置，再立刻返回 sentinel 让UI弹窗
      // 流式内容通过 notifyListeners 异步推入已打开的弹窗
      aiExplanation = "";
      aiFinalJson = "";
      isAiLoading = true;
      notifyListeners();

      // 异步启动流，不 await（让调用方立刻拿到 sentinel）
      _startAiStream(currentWord!, userInput,
          _currentQType == QuestionType.spelling ? "拼写" : "单选");

      // 返回空map作为sentinel，告诉UI"答错了，去弹窗"
      return {};
    }
  }

  void _startAiStream(Word word, String userInput, String qType) {
    AiService.getExplanationStream(
      word, userInput, qType,
      (String content) {
        if (content.contains('"error_analysis": "CONFIG_REQUIRED"')) {
          aiExplanation = "CONFIG_REQUIRED";
          isAiLoading = false;
        } else {
          aiExplanation = content;
        }
        notifyListeners();
      },
      (String error) {
        aiExplanation = '{"error_analysis": "网络请求失败，请检查网络或API Key"}';
        isAiLoading = false;
        notifyListeners();
      },
    ).then((_) {
      // 流结束
      aiFinalJson = aiExplanation;
      isAiLoading = false;
      notifyListeners();
    });
  }

  Future<void> loadWordsForPractice(List<Word> words) async {
    _isLoading = true;
    notifyListeners();
    _todayWords = words;
    _currentIndex = 0;
    _isLoading = false;
    if (_todayWords.isNotEmpty) await _generateQuestion();
    notifyListeners();
  }

  void _nextWord() async {
    _currentIndex++;
    if (isFinished) {
      await _clearSession();
      await _markDailyTaskDone();
    } else {
      await _saveSession(_todayWords, _currentIndex);
      await _generateQuestion();
    }
    notifyListeners();
  }

  void proceedToNext() => _nextWord();
  void nextWord() => _nextWord();
}

// ==========================================
// 主页
// ==========================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _hasUnfinished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<LearningProvider>().checkDailyStatus();
      _checkUnfinished();
    });
  }

  Future<void> _checkUnfinished() async {
    if (!mounted) return;
    final has = await context.read<LearningProvider>().hasUnfinishedLearning();
    if (mounted) setState(() => _hasUnfinished = has);
  }

  @override
  Widget build(BuildContext context) {
    final isTodayDone = context.watch<LearningProvider>().isTodayTaskDone;
    return Scaffold(
      appBar: AppBar(
        title: const Text("四六级突击"),
        actions: [
          IconButton(icon: const Icon(Icons.star_outline), onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => const FavoritesScreen()))),
          IconButton(icon: const Icon(Icons.settings), onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
        ],
      ),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(isTodayDone ? Icons.emoji_events : Icons.school,
              size: 80, color: isTodayDone ? Colors.orange : Colors.indigo),
          const SizedBox(height: 20),

          if (isTodayDone) ...[
            const Text("🎉 今日基础任务已达标！",
                style: TextStyle(fontSize: 20, color: Colors.green, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
          ],

          if (_hasUnfinished)
            _buildButton(Icons.restore, "恢复学习 (继续上次进度)", Colors.blueGrey, () async {
              await context.read<LearningProvider>().continueLearning();
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const LearningScreen()));
              _checkUnfinished();
            })
          else if (isTodayDone)
            _buildButton(Icons.local_fire_department, "继续学习 (超额学习新词)", Colors.deepOrange, () async {
              await context.read<LearningProvider>().loadTodayTasks();
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const LearningScreen()));
              _checkUnfinished();
            })
          else
            _buildButton(Icons.play_arrow, "开始今日任务", Colors.indigo, () async {
              await context.read<LearningProvider>().loadTodayTasks();
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const LearningScreen()));
              _checkUnfinished();
            }),

          const SizedBox(height: 12),

          // 进阶练习入口
          OutlinedButton.icon(
            icon: const Icon(Icons.edit_note),
            label: const Text("进阶练习 (填空段落)"),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
              side: const BorderSide(color: Colors.deepPurple),
              foregroundColor: Colors.deepPurple,
            ),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdvancedPracticeScreen())),
          ),

          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
            child: const Text("配置 AI 密钥 (首次使用必填)"),
          ),
        ]),
      ),
    );
  }

  Widget _buildButton(IconData icon, String label, Color color, VoidCallback onPressed) =>
    ElevatedButton.icon(
      icon: Icon(icon), label: Text(label),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
        backgroundColor: color, foregroundColor: Colors.white,
      ),
      onPressed: onPressed,
    );
}

// ==========================================
// 学习页
// ==========================================
class LearningScreen extends StatefulWidget {
  const LearningScreen({super.key});
  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  final TextEditingController _spellController = TextEditingController();

  @override
  void dispose() { _spellController.dispose(); super.dispose(); }

  Future<void> _handleAnswer(String answer) async {
    final provider = context.read<LearningProvider>();

    final overlayState = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (_) => const Material(color: Colors.black38,
          child: Center(child: CircularProgressIndicator())));
    overlayState.insert(overlayEntry);

    Map<String, dynamic>? result;
    try { result = await provider.checkAnswer(answer); }
    finally { overlayEntry.remove(); }

    if (!mounted) return;
    _spellController.clear();

    if (result == null) return; // 答对

    // CONFIG_REQUIRED 检查（流式还没到，先检查 sentinel）
    if (provider.aiExplanation == "CONFIG_REQUIRED") {
      _showConfigDialog();
      return;
    }

    // 答错 → 立刻弹窗（此时流式可能还在传输，弹窗内 Consumer 会自动刷新）
    _showAiFeedback(provider);
  }

  void _showConfigDialog() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("需要配置 API Key"),
      content: const Text("您尚未配置 DeepSeek API Key，无法使用 AI 纠错功能。"),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("稍后")),
        ElevatedButton(
          onPressed: () {
            Navigator.pop(ctx);
            Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
          },
          child: const Text("去配置"),
        ),
      ],
    ));
  }

  // 从流式raw string中提取字段（容忍不完整JSON）
  String _extract(String raw, String key) {
    final match = RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)', dotAll: true).firstMatch(raw);
    if (match == null) return '';
    return (match.group(1) ?? '')
        .replaceAll(r'\n', '\n').replaceAll(r'\"', '"').replaceAll(r'\\', '\\').trimRight();
  }

  Widget _buildSection(IconData icon, String title, String content, Color color) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
        ]),
        const SizedBox(height: 5),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Text(content, style: const TextStyle(fontSize: 14, height: 1.6)),
        ),
      ]),
    );

  Widget _buildAiContent(LearningProvider prov) {
    if (prov.aiExplanation == "CONFIG_REQUIRED") {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text("未配置 API Key，请前往设置页面配置。"),
      );
    }

    // 没有内容时显示加载圈
    if (prov.aiExplanation.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: CircularProgressIndicator(),
      ));
    }

    final raw = prov.aiExplanation;

    // 流结束后尝试完整JSON解析
    if (!prov.isAiLoading) {
      try {
        final data = jsonDecode(raw.replaceAll(RegExp(r'```json\s*'), '').replaceAll('```', '').trim())
            as Map<String, dynamic>;
        // AI诊断弹窗只显示3个字段（例句放在详细讲解里）
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((data['error_analysis'] ?? '').toString().isNotEmpty)
            _buildSection(Icons.info_outline, "错误分析", data['error_analysis'].toString(), Colors.blueGrey),
          if ((data['etymology'] ?? '').toString().isNotEmpty)
            _buildSection(Icons.search, "词源词根", data['etymology'].toString(), Colors.indigo),
          if ((data['mnemonic'] ?? '').toString().isNotEmpty)
            _buildSection(Icons.lightbulb_outline, "记忆法", data['mnemonic'].toString(), Colors.orange),
        ]);
      } catch (_) {}
    }

    // 流式过程中逐字段渲染
    final errorText = _extract(raw, 'error_analysis');
    final etymologyText = _extract(raw, 'etymology');
    final mnemonicText = _extract(raw, 'mnemonic');

    if (errorText.isEmpty && etymologyText.isEmpty && mnemonicText.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: CircularProgressIndicator(),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (errorText.isNotEmpty)
        _buildSection(Icons.info_outline, "错误分析", errorText, Colors.blueGrey),
      if (etymologyText.isNotEmpty)
        _buildSection(Icons.search, "词源词根", etymologyText, Colors.indigo),
      if (mnemonicText.isNotEmpty)
        _buildSection(Icons.lightbulb_outline, "记忆法", mnemonicText, Colors.orange),
      if (prov.isAiLoading)
        const Padding(padding: EdgeInsets.only(top: 6),
          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
    ]);
  }

  void _showAiFeedback(LearningProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55, minChildSize: 0.35, maxChildSize: 0.9, expand: false,
        builder: (_, sc) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Consumer<LearningProvider>(
            builder: (context, prov, _) => Column(children: [
              Row(children: [
                const Icon(Icons.smart_toy, color: Colors.blue),
                const SizedBox(width: 8),
                Text("AI 助教诊断", style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                // 收藏按钮
                _FavoriteButton(word: prov.currentWord, aiJson: prov.aiFinalJson),
              ]),
              const Divider(),
              Expanded(child: SingleChildScrollView(controller: sc, child: _buildAiContent(prov))),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: ElevatedButton(
                  onPressed: prov.isAiLoading ? null : () { Navigator.pop(ctx); prov.proceedToNext(); },
                  child: const Text("记住了，下一个"),
                )),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  icon: const Icon(Icons.expand_more), label: const Text("详细讲解"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  onPressed: prov.isAiLoading ? null : () {
                    Navigator.pop(ctx);
                    _showDetailedExplanation(prov.currentWord!);
                  },
                ),
              ]),
              const SizedBox(height: 20),
            ]),
          ),
        ),
      ),
    );
  }

  void _showDetailedExplanation(Word word) async {
    final overlayState = Overlay.of(context);
    final entry = OverlayEntry(builder: (_) => const Material(
        color: Colors.black38, child: Center(child: CircularProgressIndicator())));
    overlayState.insert(entry);
    final detailed = await AiService.getDetailedExplanation(word);
    entry.remove();
    if (!mounted) return;

    if (detailed['error'] != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("错误：${detailed['error']}")));
      return;
    }

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75, minChildSize: 0.4, maxChildSize: 0.95, expand: false,
        builder: (_, sc) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.school, color: Colors.indigo),
              const SizedBox(width: 8),
              Text("深度讲解：${word.spelling}", style: Theme.of(context).textTheme.titleLarge),
            ]),
            const Divider(),
            Expanded(child: SingleChildScrollView(controller: sc, child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDetailRow("🔊", "音标", detailed['pronunciation']),
                _buildDetailRow("📌", "词性", detailed['partOfSpeech']),
                _buildDetailRow("📊", "使用频率", detailed['usage_level']),
                _buildDetailRow("📖", "详细释义", detailed['detailed_meanings']),
                _buildDetailRow("🌱", "词源演变", detailed['etymology']),
                _buildDetailRow("🔗", "常见搭配", detailed['collocations']),
                _buildDetailRow("🔄", "同反义词", detailed['synonyms_and_antonyms']),
                // 例句放在详细讲解
                if (detailed['example'] != null && detailed['example'].toString().isNotEmpty)
                  _buildExamplesSection(detailed['example'].toString()),
                const SizedBox(height: 10),
              ],
            ))),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx), child: const Text("关闭"),
              )),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String emoji, String title, dynamic value) {
    if (value == null || value.toString().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("$emoji $title", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 4),
        Text(value.toString().replaceAll(r'\n', '\n'),
            style: const TextStyle(fontSize: 14, height: 1.6)),
      ]),
    );
  }

  // 例句渲染：按\n拆分，逐条带序号显示
  Widget _buildExamplesSection(String raw) {
    final lines = raw.replaceAll(r'\n', '\n').split('\n')
        .map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("📝 例句", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 6),
        ...lines.asMap().entries.map((e) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.teal.withOpacity(0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.teal.withOpacity(0.2)),
            ),
            child: Text("${e.key + 1}. ${e.value}", style: const TextStyle(fontSize: 14, height: 1.5)),
          ),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("学习中")),
      body: Consumer<LearningProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading) return const Center(child: CircularProgressIndicator());

          if (provider.isFinished) {
            return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text("🎉 恭喜！这一组单词已完成",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                icon: const Icon(Icons.local_fire_department), label: const Text("继续学习 (再来一组)"),
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
                    backgroundColor: Colors.deepOrange, foregroundColor: Colors.white),
                onPressed: () async {
                  int count = await provider.loadTodayTasks();
                  if (count == 0 && mounted) {
                    showDialog(context: context, builder: (ctx) => AlertDialog(
                      title: const Text("没有新词啦"),
                      content: const Text("今天到期的复习任务已全部完成。"),
                      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("好的"))],
                    ));
                  }
                },
              ),
              const SizedBox(height: 15),
              OutlinedButton.icon(
                icon: const Icon(Icons.home), label: const Text("返回主页"),
                onPressed: () => Navigator.pop(context),
              ),
            ]));
          }

          final word = provider.currentWord!;
          final questionText = (provider.currentQType == QuestionType.enToZh
              ? word.spelling : word.translation).replaceAll(r'\n', '\n');

          return SafeArea(child: Column(children: [
            LinearProgressIndicator(
              value: provider.totalWords > 0 ? provider.progress / provider.totalWords : 0,
              minHeight: 4,
            ),
            Expanded(child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${provider.progress + 1} / ${provider.totalWords}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 28),

                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(questionText,
                    key: ValueKey('${word.id}_${provider.currentQType}'),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, height: 1.5),
                    textAlign: TextAlign.center),
                ),
                const SizedBox(height: 36),

                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: provider.currentQType == QuestionType.spelling
                    ? Column(key: ValueKey('spell_${word.id}'), children: [
                        TextField(
                          controller: _spellController, autofocus: true,
                          decoration: const InputDecoration(
                              border: OutlineInputBorder(), labelText: "请输入对应的英文单词"),
                          onSubmitted: _handleAnswer,
                        ),
                        const SizedBox(height: 14),
                        SizedBox(width: double.infinity, child: ElevatedButton(
                          onPressed: () => _handleAnswer(_spellController.text),
                          child: const Text("提交"),
                        )),
                      ])
                    : Column(
                        key: ValueKey('options_${word.id}_${provider.options.hashCode}'),
                        children: provider.options.map((opt) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.all(16),
                              ),
                              onPressed: () => _handleAnswer(opt),
                              child: Text(opt.replaceAll(r'\n', '\n'),
                                  style: const TextStyle(fontSize: 15), textAlign: TextAlign.center),
                            ),
                          ),
                        )).toList(),
                      ),
                ),
              ]),
            )),
          ]));
        },
      ),
    );
  }
}

// ==========================================
// 收藏按钮组件
// ==========================================
class _FavoriteButton extends StatefulWidget {
  final Word? word;
  final String aiJson;
  const _FavoriteButton({required this.word, required this.aiJson});

  @override
  State<_FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<_FavoriteButton> {
  bool _isFav = false;
  bool _checked = false;

  @override
  void didUpdateWidget(_FavoriteButton old) {
    super.didUpdateWidget(old);
    if (old.word?.id != widget.word?.id) { _checked = false; _checkFav(); }
    // AI加载完成后才能收藏，更新状态
  }

  @override
  void initState() { super.initState(); _checkFav(); }

  Future<void> _checkFav() async {
    if (widget.word == null) return;
    final fav = await DatabaseHelper.isFavorite(widget.word!.id);
    if (mounted) setState(() { _isFav = fav; _checked = true; });
  }

  Future<void> _toggle() async {
    if (widget.word == null) return;
    if (_isFav) {
      await DatabaseHelper.deleteFavorite(widget.word!.id);
      if (mounted) setState(() => _isFav = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已取消收藏")));
    } else {
      // aiJson为空时（流还在传）给个提示
      if (widget.aiJson.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("AI解析完成后再收藏哦～")));
        return;
      }
      await DatabaseHelper.saveFavorite(FavoriteEntry(
        wordId: widget.word!.id,
        spelling: widget.word!.spelling,
        translation: widget.word!.translation,
        aiJson: widget.aiJson,
        savedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      if (mounted) setState(() => _isFav = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("✅ 已收藏，可在主页查看"), backgroundColor: Colors.green));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) return const SizedBox(width: 24);
    return IconButton(
      icon: Icon(_isFav ? Icons.star : Icons.star_outline,
          color: _isFav ? Colors.amber : null),
      tooltip: _isFav ? "取消收藏" : "收藏此单词",
      onPressed: _toggle,
    );
  }
}

// ==========================================
// 收藏夹页面
// ==========================================
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});
  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<FavoriteEntry> _favorites = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final favs = await DatabaseHelper.getAllFavorites();
    if (mounted) setState(() { _favorites = favs; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("收藏夹 (${_favorites.length})"),
        actions: [
          if (_favorites.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.fitness_center, size: 18),
              label: const Text("针对练习"),
              onPressed: () async {
                final words = await DatabaseHelper.getFavoriteWordsForPractice();
                if (words.isEmpty) return;
                final provider = context.read<LearningProvider>();
                await provider.loadWordsForPractice(words);
                if (mounted) Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const LearningScreen()));
              },
            ),
        ],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _favorites.isEmpty
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.star_outline, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text("暂无收藏", style: TextStyle(color: Colors.grey, fontSize: 16)),
              const SizedBox(height: 8),
              const Text("在AI诊断弹窗中点击⭐即可收藏单词",
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
            ]))
          : ListView.builder(
              itemCount: _favorites.length,
              itemBuilder: (context, i) {
                final fav = _favorites[i];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    title: Text(fav.spelling,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    subtitle: Text(fav.translation.replaceAll(r'\n', '\n'),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.visibility_outlined),
                        onPressed: () => _showDetail(fav),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () async {
                          await DatabaseHelper.deleteFavorite(fav.wordId);
                          _load();
                        },
                      ),
                    ]),
                    onTap: () => _showDetail(fav),
                  ),
                );
              },
            ),
    );
  }

  void _showDetail(FavoriteEntry fav) {
    final data = fav.aiData;
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.65, minChildSize: 0.4, maxChildSize: 0.9, expand: false,
        builder: (_, sc) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.star, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(child: Text("${fav.spelling} — ${fav.translation}",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  overflow: TextOverflow.ellipsis)),
            ]),
            const Divider(),
            Expanded(child: SingleChildScrollView(controller: sc, child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((data['error_analysis'] ?? '').toString().isNotEmpty)
                  _favSection("错误分析", data['error_analysis'].toString(), Colors.blueGrey),
                if ((data['etymology'] ?? '').toString().isNotEmpty)
                  _favSection("词源词根", data['etymology'].toString(), Colors.indigo),
                if ((data['mnemonic'] ?? '').toString().isNotEmpty)
                  _favSection("记忆法", data['mnemonic'].toString(), Colors.orange),
                if ((data['example'] ?? '').toString().isNotEmpty)
                  _favSection("例句", data['example'].toString().replaceAll(r'\n', '\n'), Colors.teal),
                const SizedBox(height: 10),
              ],
            ))),
            Padding(padding: const EdgeInsets.symmetric(vertical: 14),
              child: SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx), child: const Text("关闭"),
              ))),
          ]),
        ),
      ),
    );
  }

  Widget _favSection(String title, String content, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
      const SizedBox(height: 5),
      Container(
        width: double.infinity, padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07), borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Text(content, style: const TextStyle(fontSize: 14, height: 1.6)),
      ),
    ]),
  );
}

// ==========================================
// 进阶练习页（填空段落）
// ==========================================
class AdvancedPracticeScreen extends StatefulWidget {
  const AdvancedPracticeScreen({super.key});
  @override
  State<AdvancedPracticeScreen> createState() => _AdvancedPracticeScreenState();
}

class _AdvancedPracticeScreenState extends State<AdvancedPracticeScreen> {
  List<Word> _pool = []; // 可选词池（今日词 + 收藏词）
  List<Word> _selectedWords = [];
  Map<String, dynamic>? _exerciseData;
  bool _generating = false;
  bool _submitted = false;
  String _source = 'today'; // 'today' | 'favorites'

  // 填空答案控制器
  final List<TextEditingController> _answerControllers = [];
  List<String> _correctAnswers = [];

  @override
  void initState() { super.initState(); _loadPool(); }

  @override
  void dispose() {
    for (var c in _answerControllers) { c.dispose(); }
    super.dispose();
  }

  Future<void> _loadPool() async {
    final provider = context.read<LearningProvider>();
    List<Word> pool = [];
    if (_source == 'today') {
      pool = provider.todayWords.toList();
      if (pool.isEmpty) pool = await DatabaseHelper.getTodayWords();
    } else {
      pool = await DatabaseHelper.getFavoriteWordsForPractice();
    }
    if (mounted) setState(() { _pool = pool; _selectedWords = []; _exerciseData = null; });
  }

  void _toggleWord(Word w) {
    setState(() {
      if (_selectedWords.any((s) => s.id == w.id)) {
        _selectedWords.removeWhere((s) => s.id == w.id);
      } else if (_selectedWords.length < 5) {
        _selectedWords.add(w);
      }
    });
  }

  Future<void> _generate() async {
    if (_selectedWords.isEmpty) return;
    setState(() { _generating = true; _submitted = false; _exerciseData = null; });
    for (var c in _answerControllers) { c.dispose(); }
    _answerControllers.clear();

    final data = await AiService.generateFillBlankParagraph(_selectedWords);

    if (data['error'] != null) {
      if (mounted) {
        setState(() => _generating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("生成失败：${data['error']}")));
      }
      return;
    }

    // 解析答案列表
    final answersRaw = (data['answers'] ?? '') as String;
    _correctAnswers = answersRaw.split(',').map((s) => s.trim()).toList();
    for (var _ in _correctAnswers) { _answerControllers.add(TextEditingController()); }

    if (mounted) setState(() { _exerciseData = data; _generating = false; });
  }

  void _submit() {
    setState(() => _submitted = true);
  }

  void _reset() {
    setState(() {
      _submitted = false;
      _exerciseData = null;
      _selectedWords = [];
      for (var c in _answerControllers) { c.dispose(); }
      _answerControllers.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("进阶练习 · 填空段落")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

          // 词源选择
          Row(children: [
            const Text("词汇来源：", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text("今日词汇"), selected: _source == 'today',
                onSelected: (_) { _source = 'today'; _loadPool(); }),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text("收藏词汇"), selected: _source == 'favorites',
                onSelected: (_) { _source = 'favorites'; _loadPool(); }),
          ]),
          const SizedBox(height: 12),

          // 词汇选择区
          if (_pool.isEmpty)
            const Padding(padding: EdgeInsets.all(16),
              child: Text("当前词池为空，请先完成今日任务或收藏单词", textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey)))
          else ...[
            Text("选择 1-5 个单词生成填空题（已选 ${_selectedWords.length}/5）：",
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: _pool.map((w) {
              final selected = _selectedWords.any((s) => s.id == w.id);
              return FilterChip(
                label: Text(w.spelling),
                selected: selected,
                onSelected: (_) => _toggleWord(w),
                selectedColor: Colors.indigo.withOpacity(0.2),
                checkmarkColor: Colors.indigo,
              );
            }).toList()),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              icon: _generating
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_awesome),
              label: Text(_generating ? "AI 生成中…" : "生成填空练习"),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: (_generating || _selectedWords.isEmpty) ? null : _generate,
            ),
          ],

          // 练习区
          if (_exerciseData != null) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),

            // 填空段落
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                (_exerciseData!['blanked_paragraph'] ?? '').toString(),
                style: const TextStyle(fontSize: 16, height: 1.8),
              ),
            ),
            const SizedBox(height: 16),

            // 答题区
            if (!_submitted) ...[
              Text("请填写 ${_correctAnswers.length} 个空格中的单词：",
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
              const SizedBox(height: 10),
              ...List.generate(_correctAnswers.length, (i) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: _answerControllers[i],
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: "第 ${i + 1} 个空",
                    prefixText: "${i + 1}. ",
                  ),
                ),
              )),
              ElevatedButton(
                onPressed: _submit,
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                child: const Text("提交答案"),
              ),
            ] else ...[
              // 答案对比
              const Text("答案对比：", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 8),
              ...List.generate(_correctAnswers.length, (i) {
                final userAns = _answerControllers[i].text.trim().toLowerCase();
                final correct = _correctAnswers[i].toLowerCase();
                final isRight = userAns == correct;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isRight ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isRight ? Colors.green : Colors.red, width: 0.8),
                    ),
                    child: Row(children: [
                      Icon(isRight ? Icons.check_circle : Icons.cancel,
                          color: isRight ? Colors.green : Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(
                        "第${i + 1}空：你的答案「${_answerControllers[i].text.trim()}」  "
                        "正确答案「${_correctAnswers[i]}」",
                        style: TextStyle(color: isRight ? Colors.green.shade700 : Colors.red.shade700),
                      )),
                    ]),
                  ),
                );
              }),

              const SizedBox(height: 14),

              // 完整段落
              const Text("完整段落：", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.indigo.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text((_exerciseData!['paragraph'] ?? '').toString(),
                    style: const TextStyle(fontSize: 15, height: 1.7)),
              ),
              const SizedBox(height: 10),

              // 中文翻译
              if ((_exerciseData!['translation'] ?? '').toString().isNotEmpty) ...[
                const Text("中文翻译：", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 6),
                Text((_exerciseData!['translation'] ?? '').toString(),
                    style: const TextStyle(fontSize: 14, color: Colors.grey, height: 1.6)),
                const SizedBox(height: 10),
              ],

              // 单词解析
              if ((_exerciseData!['analysis'] ?? '').toString().isNotEmpty) ...[
                const Text("用法解析：", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text((_exerciseData!['analysis'] ?? '').toString(),
                      style: const TextStyle(fontSize: 14, height: 1.6)),
                ),
              ],

              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: _reset, child: const Text("重新选词"))),
                const SizedBox(width: 12),
                Expanded(child: ElevatedButton(
                  onPressed: _generate,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
                  child: const Text("同词再来一次"),
                )),
              ]),
            ],
          ],

          const SizedBox(height: 40),
        ]),
      ),
    );
  }
}

// ==========================================
// 设置页
// ==========================================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _keyController = TextEditingController();
  bool _isLoading = true;
  bool _isSaved = false;

  @override
  void initState() { super.initState(); _loadKey(); }

  Future<void> _loadKey() async {
    final key = await AiService.getApiKey();
    if (mounted) { _keyController.text = key; setState(() => _isLoading = false); }
  }

  Future<void> _saveKey() async {
    if (_keyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("API Key 不能为空")));
      return;
    }
    setState(() => _isLoading = true);
    await AiService.saveApiKey(_keyController.text.trim());
    if (mounted) {
      setState(() { _isLoading = false; _isSaved = true; });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ API Key 已安全保存"), backgroundColor: Colors.green));
      Future.delayed(const Duration(seconds: 2), () { if (mounted) setState(() => _isSaved = false); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    bool isDarkMode = themeProvider.themeMode == ThemeMode.dark ||
        (themeProvider.themeMode == ThemeMode.system &&
         MediaQuery.of(context).platformBrightness == Brightness.dark);

    return Scaffold(
      appBar: AppBar(title: const Text("系统设置")),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text("界面设置", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo)),
        const SizedBox(height: 10),
        SwitchListTile(
          title: const Text("暗黑模式"),
          subtitle: const Text("开启后将自动保存你的偏好"),
          secondary: Icon(isDarkMode ? Icons.dark_mode : Icons.light_mode),
          value: isDarkMode,
          onChanged: (v) => themeProvider.toggleTheme(v),
        ),

        const Divider(height: 40),
        const Text("数据与词库管理", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo)),
        const SizedBox(height: 10),

        ListTile(
          leading: const Icon(Icons.cloud_download, color: Colors.blue),
          title: const Text("重新导入词库"),
          subtitle: const Text("若一直提示没有新词，请点击此项覆盖数据库"),
          onTap: () async {
            showDialog(context: context, barrierDismissible: false,
                builder: (_) => const Center(child: CircularProgressIndicator()));
            bool success = await DatabaseHelper.forceReimportDatabase();
            if (mounted) {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(success ? "✅ 词库已成功载入！" : "❌ 导入失败，请检查assets路径")));
            }
          },
        ),

        const Divider(height: 20),

        ListTile(
          leading: const Icon(Icons.folder_open, color: Colors.blue),
          title: const Text("从文件导入词库"),
          subtitle: const Text("选择本地 .db 文件覆盖当前词库"),
          onTap: () async {
            showDialog(context: context, barrierDismissible: false,
                builder: (_) => const Center(child: CircularProgressIndicator()));
            int count = await DatabaseHelper.importDatabaseFromFile();
            if (mounted) {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
                count > 0 ? "✅ 导入成功！共载入 $count 个单词" :
                count == 0 ? "❌ 导入的数据库似乎是空的" : "已取消或导入失败")));
            }
          },
        ),

        const Divider(height: 40),
        const Text("DeepSeek API 配置",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo)),
        const SizedBox(height: 10),
        const Text("密钥将加密存储在本地设备，不会上传到任何第三方服务器。",
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 20),
        TextField(
          controller: _keyController, obscureText: true,
          decoration: const InputDecoration(
              labelText: "API Key", border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.key), hintText: "sk-..."),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _isLoading ? null : _saveKey,
          style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(15),
              backgroundColor: _isSaved ? Colors.green : Colors.indigo,
              foregroundColor: Colors.white),
          child: _isLoading
              ? const SizedBox(height: 20, width: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : Text(_isSaved ? "保存成功" : "保存配置"),
        ),
        if (_keyController.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TextButton.icon(
              icon: const Icon(Icons.delete, color: Colors.red),
              label: const Text("清除已保存的 Key", style: TextStyle(color: Colors.red)),
              onPressed: () async {
                await AiService.deleteApiKey();
                _keyController.clear();
                setState(() {});
                if (context.mounted)
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已清除 Key")));
              },
            ),
          ),
      ]),
    );
  }
}