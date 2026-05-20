import 'dart:convert';
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

// ==========================================
// 主导航 (直接展示背单词主页)
// ==========================================
class MainTabScreen extends StatelessWidget {
  const MainTabScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
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
      home: const MainTabScreen(),
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
    if (quality < 3) { 
      reps = 0; 
      interval = 1; 
    } else {
      if (reps == 0) interval = 1;
      else if (reps == 1) interval = 6;
      else interval = (interval * easeFactor).round();
      reps++;
    }
    
    // 动态调整权重：选错扣除权重，连续正确增加权重
    easeFactor = easeFactor + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
    
    // 【修改】权重阈值控制 (值越小复习越频繁)
    if (easeFactor < 1.3) easeFactor = 1.3; // 下限
    if (easeFactor > 3.0) easeFactor = 3.0; // 上限阈值
    
    // 【新增】如果本次全对(quality>=4)，且历史连续正确超过3次，标记为已彻底掌握 (-1)
    if (quality >= 4 && reps >= 3) {
      nextReviewDate = -1; 
    } else {
      nextReviewDate = DateTime.now().add(Duration(days: interval)).millisecondsSinceEpoch;
    }
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

    // 建同义词表（如不存在）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS synonyms (
        wordId INTEGER PRIMARY KEY,
        synonyms TEXT NOT NULL,
        antonyms TEXT NOT NULL
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
    
    // 1. 获取所有到期需要复习的旧词 (排除标记为 -1 已掌握的单词)
    final List<Map<String, dynamic>> dueMaps = await db.rawQuery(
      'SELECT * FROM words WHERE nextReviewDate > 0 AND nextReviewDate <= ? AND nextReviewDate != -1', 
      [now]
    );
    List<Word> words = dueMaps.map((map) => Word.fromMap(map)).toList();

    // 2. 随机抽取 20 个全新词汇 (保证乱序，完全随机)
    final List<Map<String, dynamic>> newMaps = await db.rawQuery(
      'SELECT * FROM words WHERE nextReviewDate IS NULL OR nextReviewDate = 0 ORDER BY RANDOM() LIMIT 20'
    );
    words.addAll(newMaps.map((map) => Word.fromMap(map)));
    
    return words;
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
      // 重新建收藏表和同义词表
      final db = await database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS favorites (
          wordId INTEGER PRIMARY KEY, spelling TEXT NOT NULL,
          translation TEXT NOT NULL, aiJson TEXT NOT NULL, savedAt INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS synonyms (
          wordId INTEGER PRIMARY KEY, synonyms TEXT NOT NULL, antonyms TEXT NOT NULL
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
        // 确保收藏表和同义词表存在
        await db.execute('''
          CREATE TABLE IF NOT EXISTS favorites (
            wordId INTEGER PRIMARY KEY, spelling TEXT NOT NULL,
            translation TEXT NOT NULL, aiJson TEXT NOT NULL, savedAt INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS synonyms (
            wordId INTEGER PRIMARY KEY, synonyms TEXT NOT NULL, antonyms TEXT NOT NULL
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

  // ========== 搜索相关 ==========
  /// 根据拼写或翻译搜索单词
  static Future<List<Word>> searchWords(String query) async {
    if (query.trim().isEmpty) return [];
    final db = await database;
    final pattern = '%${query.trim()}%';
    final maps = await db.rawQuery(
      'SELECT * FROM words WHERE spelling LIKE ? OR translation LIKE ? LIMIT 50',
      [pattern, pattern]
    );
    return maps.map((m) => Word.fromMap(m)).toList();
  }

  // ========== 同义词相关 ==========
  /// 获取缓存的同义词
  static Future<Map<String, String>?> getSynonyms(int wordId) async {
    final db = await database;
    final maps = await db.query('synonyms', where: 'wordId = ?', whereArgs: [wordId]);
    if (maps.isEmpty) return null;
    return {
      'synonyms': maps.first['synonyms'] as String,
      'antonyms': maps.first['antonyms'] as String,
    };
  }

  /// 保存同义词到缓存
  static Future<void> saveSynonyms(int wordId, String synonyms, String antonyms) async {
    final db = await database;
    await db.insert('synonyms', {
      'wordId': wordId,
      'synonyms': synonyms,
      'antonyms': antonyms,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

// ==========================================
// AI 服务 (DeepSeek 在线API)
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

  /// 流式解释
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
      final prompt = """单词：${word.spelling}（${word.translation}）。学生在${qType}时输入了错误答案：$userInput。
请用JSON返回以下字段（每个字段都必须是字符串，例句独立成字段）：
- mnemonic（记忆法：注重使用语义、词汇来源、谐音、等最贴切、接地气的方法来帮助记忆，挑选最合适的）
- etymology（单词说明与词源分析）
- example（3个例句，用\\n分隔）""";

      Response<ResponseBody> response = await dio.post<ResponseBody>(
        _apiUrl,
        data: {
          "model": "deepseek-chat",
          "messages":[
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

  /// 详细解释
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
          "messages":[
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

  /// 获取同义词和反义词（AI生成）
  static Future<Map<String, String>> getSynonyms(Word word) async {
    // 先查本地缓存
    final cached = await DatabaseHelper.getSynonyms(word.id);
    if (cached != null) return cached;

    // 缓存未命中，请求AI
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) {
      return {'synonyms': '请配置API Key后使用', 'antonyms': '请配置API Key后使用'};
    }
    try {
      final dio = Dio();
      final prompt = """单词：${word.spelling}（${word.translation}）。
请用JSON返回以下字段（值均为字符串）：
- synonyms（列出5-8个同义词/近义词，格式：word1,word2,word3...，附带中文解释）
- antonyms（列出3-5个反义词，格式：word1,word2,word3...，附带中文解释）""";

      final response = await dio.post(_apiUrl,
        options: Options(headers: {"Authorization": "Bearer $apiKey", "Content-Type": "application/json"}),
        data: {
          "model": "deepseek-chat",
          "messages":[
            {"role": "system", "content": "只返回合法JSON，不含markdown代码块。"},
            {"role": "user", "content": prompt}
          ],
        },
      );
      String content = response.data['choices'][0]['message']['content'];
      content = content.replaceAll(RegExp(r'```json\s*|\s*```'), '').trim();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final result = {
        'synonyms': (data['synonyms'] ?? '').toString(),
        'antonyms': (data['antonyms'] ?? '').toString(),
      };
      // 缓存结果
      await DatabaseHelper.saveSynonyms(word.id, result['synonyms']!, result['antonyms']!);
      return result;
    } catch (e) {
      return {'synonyms': '获取失败：$e', 'antonyms': '获取失败：$e'};
    }
  }

  /// 生成填空段落
  static Future<Map<String, dynamic>> generateFillBlankParagraph(List<Word> words) async {
    final apiKey = await getApiKey();
    if (apiKey.isEmpty) return {"error": "CONFIG_REQUIRED"};
    try {
      final dio = Dio();
      final wordListStr = words.map((w) => "${w.spelling}（${w.translation}）").join("、");
      final prompt = """请用以下单词造一个连贯的英文小段落（3-5句话）：$wordListStr
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
          "messages":[
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

enum AppMode { test, study }

class LearningTask {
  final Word word;
  final QuestionType qType;
  LearningTask(this.word, this.qType);
}

class WordSessionState {
  int remainingTasks = 3;
  int mistakes = 0;
}

/// 测试模式中每个单词的答题结果
class TestWordResult {
  bool hasDontKnow = false;
  bool hasWrong = false;
  bool skipped = false;
}

class LearningProvider extends ChangeNotifier {
  AppMode _mode = AppMode.test;
  AppMode get mode => _mode;
  bool get isTestMode => _mode == AppMode.test;
  bool get isStudyMode => _mode == AppMode.study;

  List<Word> _todayWords =[];
  int _currentIndex = 0; // 现在指代 Task 队列的索引
  bool _isLoading = true;
  List<String> _options =[];

  // 【新增】任务队列与单词状态记录
  List<LearningTask> _tasks =[];
  Map<int, WordSessionState> _wordStates = {};
  // 【新增】测试模式结果追踪
  Map<int, TestWordResult> _testResults = {};
  Map<int, TestWordResult> get testResults => Map.unmodifiable(_testResults);
  // 学习模式中待复习的单词ID列表（来自测试结果，通过 getTestWrongWords 获取）

  String aiExplanation = "";
  bool isAiLoading = false;
  String aiFinalJson = "";
  
  // 【新增】保存用户最后一次输入的答案，用于UI层差异比对
  String lastUserInput = "";
  // 【新增】测试模式下显示的正确答案（短暂展示后自动跳转）
  String testCorrectAnswer = "";
  bool testShowAnswer = false;

  bool get isLoading => _isLoading;
  bool get isFinished => _currentIndex >= _tasks.length && !_isLoading;
  
  // 【新增】判断是否允许退回到上一题
  bool get canGoPrevious => _currentIndex > 0;

  // 【新增】上一题（状态回溯）功能
  Future<void> goPrevious() async {
    if (canGoPrevious) {
      _currentIndex--;
      await _saveSession();
      await _generateQuestion();
      notifyListeners();
    }
  }
  
  // 获取当前题目的信息
  LearningTask? get currentTask => _currentIndex < _tasks.length ? _tasks[_currentIndex] : null;
  Word? get currentWord => currentTask?.word;
  QuestionType get currentQType => currentTask?.qType ?? QuestionType.enToZh;
  List<String> get options => List.unmodifiable(_options);
  
  // UI 进度计算 (基于完全掌握的单词数量)
  int get totalWords => _todayWords.length;
  int get progress {
    // 计算已完成的单词数量，但不超过总单词数，防止进度条超过100%
    int completed = _wordStates.values.where((s) => s.remainingTasks == 0).length;
    return completed > totalWords ? totalWords : completed;
  }
  List<Word> get todayWords => _todayWords;

  bool _isTodayTaskDone = false;
  bool get isTodayTaskDone => _isTodayTaskDone;

  // ===== 日常打卡与会话保存 =====
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

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    // 保存剩余还未完成的题目队列
    List<String> remaining =[];
    for (int i = _currentIndex; i < _tasks.length; i++) {
      remaining.add('${_tasks[i].word.id}_${_tasks[i].qType.index}');
    }
    await prefs.setStringList('remaining_tasks', remaining);
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('remaining_tasks');
  }

  Future<bool> hasUnfinishedLearning() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? tasks = prefs.getStringList('remaining_tasks');
    return tasks != null && tasks.isNotEmpty;
  }

  // ===== 加载与生成任务 =====
  void _buildTasksQueue() {
    _tasks.clear();
    _wordStates.clear();
    for (var w in _todayWords) {
      _wordStates[w.id] = WordSessionState();
      if (isTestMode) {
        // 测试模式：仅选择题（zhToEn + enToZh），无拼写
        _tasks.add(LearningTask(w, QuestionType.zhToEn));
        _tasks.add(LearningTask(w, QuestionType.enToZh));
      } else {
        // 学习模式：全部3种题型
        _tasks.add(LearningTask(w, QuestionType.zhToEn));
        _tasks.add(LearningTask(w, QuestionType.enToZh));
        _tasks.add(LearningTask(w, QuestionType.spelling));
      }
    }
    // 【核心】彻底打乱任务队列，将复习词、新词、不同题型完全混合！
    _tasks.shuffle(); 
  }

  /// 开始测试模式
  Future<int> startTestMode() async {
    _mode = AppMode.test;
    _testResults = {};
    testShowAnswer = false;
    testCorrectAnswer = "";
    _isLoading = true;
    notifyListeners();
    try {
      _todayWords = await DatabaseHelper.getTodayWords();
      _currentIndex = 0;
      // 初始化测试结果
      for (var w in _todayWords) {
        _testResults[w.id] = TestWordResult();
      }
      if (_todayWords.isNotEmpty) {
        _buildTasksQueue();
        await _saveSession();
        await _generateQuestion();
      }
      return _todayWords.length;
    } catch (e) { return 0; }
    finally { _isLoading = false; notifyListeners(); }
  }

  /// 测试完成后，收集错词进入学习模式
  Future<List<Word>> getTestWrongWords() async {
    List<Word> wrongWords = [];
    for (var w in _todayWords) {
      final r = _testResults[w.id];
      if (r != null && (r.hasWrong || r.hasDontKnow) && !r.skipped) {
        wrongWords.add(w);
      }
    }
    return wrongWords;
  }

  /// 开始学习模式（复习测试中的错词）
  Future<void> startStudyMode(List<Word> studyWords) async {
    _mode = AppMode.study;
    _todayWords = studyWords;
    _currentIndex = 0;
    testShowAnswer = false;
    testCorrectAnswer = "";
    if (_todayWords.isNotEmpty) {
      _buildTasksQueue();
      await _saveSession();
      await _generateQuestion();
    }
    notifyListeners();
  }

  Future<int> loadTodayTasks() async {
    // 保留原方法：默认为学习模式
    _mode = AppMode.study;
    _testResults = {};
    _isLoading = true;
    notifyListeners();
    try {
      _todayWords = await DatabaseHelper.getTodayWords();
      _currentIndex = 0;
      if (_todayWords.isNotEmpty) {
        _buildTasksQueue();
        await _saveSession();
        await _generateQuestion();
      }
      return _todayWords.length;
    } catch (e) { return 0; }
    finally { _isLoading = false; notifyListeners(); }
  }

  Future<void> continueLearning() async {
    _isLoading = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String>? remaining = prefs.getStringList('remaining_tasks');
      if (remaining != null && remaining.isNotEmpty) {
        Set<int> ids = remaining.map((s) => int.parse(s.split('_')[0])).toSet();
        _todayWords = await DatabaseHelper.getWordsByIds(ids.toList());
        
        _tasks.clear();
        _wordStates.clear();
        for (var w in _todayWords) _wordStates[w.id] = WordSessionState();

        for (String s in remaining) {
          var parts = s.split('_');
          int wId = int.parse(parts[0]);
          int qIdx = int.parse(parts[1]);
          var word = _todayWords.firstWhere((w) => w.id == wId);
          _tasks.add(LearningTask(word, QuestionType.values[qIdx]));
        }
        
        // 恢复剩余任务数
        for (var w in _todayWords) {
          _wordStates[w.id]!.remainingTasks = _tasks.where((t) => t.word.id == w.id).length;
        }
        _currentIndex = 0;
        await _generateQuestion();
      } else {
        await loadTodayTasks();
      }
    } catch (e) { debugPrint("继续学习报错: $e"); }
    finally { _isLoading = false; notifyListeners(); }
  }

  Future<void> _generateQuestion() async {
    if (currentWord == null) return;
    _options.clear();
    if (currentQType == QuestionType.enToZh) {
      _options = await DatabaseHelper.getRandomTranslations(currentWord!.translation, 3);
      _options.add(currentWord!.translation);
    } else if (currentQType == QuestionType.zhToEn) {
      _options = await DatabaseHelper.getRandomSpellings(currentWord!.spelling, 3);
      _options.add(currentWord!.spelling);
    }
    if (currentQType != QuestionType.spelling) _options.shuffle();
  }

  // ===== 答题判定 =====
  Future<Map<String, dynamic>?> checkAnswer(String userInput) async {
    if (currentWord == null) return null;
    
    var task = currentTask!;
    var word = task.word;
    lastUserInput = userInput;

    bool isCorrect = task.qType == QuestionType.enToZh
        ? userInput == word.translation
        : userInput.trim().toLowerCase() == word.spelling.toLowerCase();

    if (isTestMode) {
      // === 测试模式：无AI，显示答案后自动跳转 ===
      if (isCorrect) {
        // 答对 → 短促提示后自动下一题
        testCorrectAnswer = "";
        testShowAnswer = false;
        if (_wordStates[word.id]!.remainingTasks > 0) {
          _wordStates[word.id]!.remainingTasks--;
        }
        _nextWord();
        return null;
      } else {
        // 答错 → 记录错误，显示正确答案
        _wordStates[word.id]!.mistakes++;
        _testResults[word.id]?.hasWrong = true;
        final correctAns = task.qType == QuestionType.enToZh
            ? word.translation : word.spelling;
        testCorrectAnswer = correctAns;
        testShowAnswer = true;
        notifyListeners();
        // 延迟后自动跳转
        Future.delayed(const Duration(milliseconds: 1500), () {
          testShowAnswer = false;
          testCorrectAnswer = "";
          _nextWord();
        });
        return {};
      }
    }

    // === 学习模式：现有逻辑（含AI） ===
    if (isCorrect) {
      if (_wordStates[word.id]!.remainingTasks > 0) {
        _wordStates[word.id]!.remainingTasks--;
        
        if (_wordStates[word.id]!.remainingTasks == 0) {
          int mistakes = _wordStates[word.id]!.mistakes;
          int quality = 4;
          if (mistakes == 1) quality = 3;
          else if (mistakes == 2) quality = 2;
          else if (mistakes >= 3) quality = 1;

          word.updateSM2(quality);
          await DatabaseHelper.updateWord(word);
        }
      }
      _nextWord();
      return null;
    } else {
      _wordStates[word.id]!.mistakes++;
      
      _tasks.add(LearningTask(word, task.qType));
      await _saveSession();

      aiExplanation = "";
      aiFinalJson = "";
      isAiLoading = true;
      notifyListeners();

      _startAiStream(word, userInput, task.qType == QuestionType.spelling ? "拼写" : "单选");
      return {};
    }
  }

  /// 测试模式中用户点击「我不会」
  void dontKnow() {
    if (currentWord == null || !isTestMode) return;
    var task = currentTask!;
    var word = task.word;
    _testResults[word.id]?.hasDontKnow = true;
    _wordStates[word.id]!.mistakes++;
    final correctAns = task.qType == QuestionType.enToZh
        ? word.translation : word.spelling;
    testCorrectAnswer = correctAns;
    testShowAnswer = true;
    notifyListeners();
    // 延迟后自动跳转
    Future.delayed(const Duration(milliseconds: 1500), () {
      testShowAnswer = false;
      testCorrectAnswer = "";
      _nextWord();
    });
  }

  void _startAiStream(Word word, String userInput, String qType) {
    AiService.getExplanationStream(
      word, userInput, qType,
      (String content) {
        // 兼容原有的 error_analysis 与新的 mnemonic 占位符
        if (content.contains('"error_analysis": "CONFIG_REQUIRED"') || 
            content.contains('"mnemonic": "CONFIG_REQUIRED"')) {
          aiExplanation = "CONFIG_REQUIRED";
          isAiLoading = false;
        } else {
          aiExplanation = content;
        }
        notifyListeners();
      },
      (String error) {
        aiExplanation = '{"mnemonic": "网络请求失败，请检查网络或API Key"}';
        isAiLoading = false;
        notifyListeners();
      },
    ).then((_) {
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

  /// 跳过当前题
  Future<void> skipWord() async {
    if (currentWord == null) return;
    var task = currentTask!;
    if (isTestMode) {
      // 测试模式：标记为跳过，不放回队列
      _testResults[task.word.id]?.skipped = true;
    } else if (isStudyMode) {
      // 学习模式：跳过即放弃，不放回队列
      // 不做任何入队操作
    } else {
      // 兼容旧逻辑：放回队列末尾
      _tasks.add(LearningTask(task.word, task.qType));
    }
    await _saveSession();
    _currentIndex++;
    if (!isFinished) {
      await _generateQuestion();
    }
    notifyListeners();
  }

  /// "我已经会了" — 跳过当前单词所有题型
  Future<void> markAsKnown() async {
    if (currentWord == null) return;
    var word = currentWord!;
    // 移除队列中所有该单词的任务
    _tasks.removeWhere((t) => t.word.id == word.id);
    // 将该单词标记为已完成
    _wordStates[word.id]?.remainingTasks = 0;
    word.updateSM2(5); // 以最高质量标记
    await DatabaseHelper.updateWord(word);
    // 如果当前索引已经无效，修正
    if (_currentIndex >= _tasks.length) {
      _currentIndex = _tasks.length;
      await _clearSession();
      await _markDailyTaskDone();
    } else {
      await _saveSession();
      await _generateQuestion();
    }
    notifyListeners();
  }

  void _nextWord() async {
    _currentIndex++;
    if (isFinished) {
      await _clearSession();
      if (isTestMode) {
        // 测试完成：检查是否有错词需要进入学习模式
        // 标记位由 LearningScreen 检测后触发
      } else if (isStudyMode) {
        await _markDailyTaskDone();
      } else {
        await _markDailyTaskDone();
      }
    } else {
      await _saveSession();
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
          IconButton(icon: const Icon(Icons.menu_book), onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => const WordListScreen()))),
          IconButton(icon: const Icon(Icons.search), onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen()))),
          IconButton(icon: const Icon(Icons.star_outline), onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => const FavoritesScreen()))),
          IconButton(icon: const Icon(Icons.settings), onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
        ],
      ),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.quiz, size: 80, color: Colors.indigo),
          const SizedBox(height: 8),
          const Text("今日测试", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo)),
          const SizedBox(height: 20),

          if (_hasUnfinished)
            _buildButton(Icons.restore, "恢复学习 (继续上次进度)", Colors.blueGrey, () async {
              await context.read<LearningProvider>().continueLearning();
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const LearningScreen()));
              _checkUnfinished();
            }),

          _buildButton(Icons.play_arrow, "开始今日测试", Colors.indigo, () async {
            await context.read<LearningProvider>().startTestMode();
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const LearningScreen()));
            _checkUnfinished();
          }),

          if (isTodayDone) ...[
            const SizedBox(height: 10),
            const Text("🎉 今日学习任务已达标！",
                style: TextStyle(fontSize: 16, color: Colors.green, fontWeight: FontWeight.bold)),
          ],

          const SizedBox(height: 16),

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

  // 【新增问题2】差异比对富文本生成器
  List<InlineSpan> _buildComparisonSpans(String input, String correct, QuestionType type) {
    List<InlineSpan> spans =[];
    if (type == QuestionType.spelling) {
      // 拼写题：逐个字母比对，错误标红（带删除线），正确标绿
      for (int i = 0; i < input.length; i++) {
        bool isMatch = i < correct.length && input[i].toLowerCase() == correct[i].toLowerCase();
        spans.add(TextSpan(
          text: input[i],
          style: TextStyle(
            color: isMatch ? Colors.green : Colors.red,
            fontWeight: FontWeight.bold,
            decoration: isMatch ? TextDecoration.none : TextDecoration.lineThrough,
          ),
        ));
      }
    } else {
      // 单选题：直接划掉错误释义
      spans.add(TextSpan(
        text: input.replaceAll(r'\n', ' '), 
        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, decoration: TextDecoration.lineThrough)
      ));
    }
    
    // 中间箭头
    spans.add(const TextSpan(
      text: " ➔ ", 
      style: TextStyle(color: Colors.grey, fontSize: 18, decoration: TextDecoration.none)
    ));
    
    // 正确答案
    spans.add(TextSpan(
      text: correct.replaceAll(r'\n', ' '), 
      style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, decoration: TextDecoration.none)
    ));
    return spans;
  }

  // 【修复问题1和问题2】优化底层弹窗交互及标题显示
  void _showAiFeedback(LearningProvider provider) {
    final currentWord = provider.currentWord!;
    final qType = provider.currentQType;
    final lastInput = provider.lastUserInput;
    final correctWord = qType == QuestionType.enToZh ? currentWord.translation : currentWord.spelling;

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
            builder: (context, prov, _) => Column(children:[
              Row(children:[
                const Icon(Icons.compare_arrows, color: Colors.blueGrey),
                const SizedBox(width: 8),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18),
                      children: _buildComparisonSpans(lastInput, correctWord, qType),
                    ),
                  ),
                ),
                _FavoriteButton(word: currentWord, aiJson: prov.aiFinalJson),
              ]),
              const Divider(),
              Expanded(child: SingleChildScrollView(controller: sc, child: _buildAiContent(prov))),
              const SizedBox(height: 10),
              Row(children:[
                Expanded(child: ElevatedButton(
                  onPressed: prov.isAiLoading ? null : () { 
                    Navigator.pop(ctx);
                    // "我知道了" — 仅关闭弹窗，不自动切换下一题
                  },
                  child: const Text("我知道了"),
                )),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  icon: const Icon(Icons.expand_more), label: const Text("详细讲解"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  onPressed: prov.isAiLoading ? null : () {
                    Navigator.pop(ctx);
                    _showDetailedExplanation(currentWord);
                  },
                ),
              ]),
              const SizedBox(height: 20),
            ]),
          ),
        ),
      ),
    ).then((_) {
      // 【修改】不再自动推进到下一题，用户需手动点击"下一题"或"跳过"等按钮
    });
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
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.compare_arrows, size: 18),
                    label: const Text("同义词 / 反义词"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.indigo,
                      side: const BorderSide(color: Colors.indigo),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showSynonymsDialog(word);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text("关闭"),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  void _showSynonymsDialog(Word word) async {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));

    final data = await AiService.getSynonyms(word);

    if (!mounted) return;
    Navigator.pop(context); // 关掉加载弹窗

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55, minChildSize: 0.35, maxChildSize: 0.85, expand: false,
        builder: (_, sc) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.compare_arrows, color: Colors.indigo),
              const SizedBox(width: 8),
              Expanded(child: Text("同义词 / 反义词：${word.spelling}",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  overflow: TextOverflow.ellipsis)),
            ]),
            const Divider(),
            Expanded(child: SingleChildScrollView(
              controller: sc,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text("📖 同义词 / 近义词",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.green.withOpacity(0.2)),
                  ),
                  child: Text(data['synonyms'] ?? '暂无数据',
                      style: const TextStyle(fontSize: 14, height: 1.6)),
                ),
                const SizedBox(height: 24),
                const Text("🔄 反义词",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.withOpacity(0.2)),
                  ),
                  child: Text(data['antonyms'] ?? '暂无数据',
                      style: const TextStyle(fontSize: 14, height: 1.6)),
                ),
                const SizedBox(height: 20),
              ]),
            )),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo, foregroundColor: Colors.white,
                ),
                child: const Text("关闭"),
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
    return Consumer<LearningProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          appBar: AppBar(
            title: Text(provider.isTestMode ? "测试模式" : "学习模式"),
            actions: [
              if (provider.canGoPrevious && !provider.isLoading && !provider.isFinished && provider.isStudyMode)
                TextButton.icon(
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text("上一题"),
                  onPressed: () => provider.goPrevious(),
                ),
            ],
          ),
          body: Builder(
            builder: (context) {
              if (provider.isLoading) return const Center(child: CircularProgressIndicator());

              if (provider.isFinished) {
                return _buildFinishedView(provider);
              }

              final word = provider.currentWord!;
              final questionText = (provider.currentQType == QuestionType.enToZh
                  ? word.spelling : word.translation).replaceAll(r'\n', '\n');

              return SafeArea(
                child: Focus(
                  autofocus: true,
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && provider.currentQType != QuestionType.spelling) {
                      final key = event.logicalKey.keyLabel;
                      if (['1', '2', '3', '4'].contains(key)) {
                        final index = int.parse(key) - 1;
                        if (index < provider.options.length) {
                          _handleAnswer(provider.options[index]);
                          return KeyEventResult.handled;
                        }
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Column(children: [
                    LinearProgressIndicator(
                      value: provider.totalWords > 0 ? provider.progress / provider.totalWords : 0,
                      minHeight: 4,
                    ),
                    Expanded(child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        // 进度文字
                        Text(
                          provider.isTestMode
                              ? '测试进度：${provider.progress} / ${provider.totalWords}'
                              : '学习进度：${provider.progress} / ${provider.totalWords}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey, fontSize: 13)),
                        const SizedBox(height: 28),

                        // 问题文本
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: Text(questionText,
                            key: ValueKey('${word.id}_${provider.currentQType}'),
                            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, height: 1.5),
                            textAlign: TextAlign.center),
                        ),
                        const SizedBox(height: 36),

                        // 答题区域
                        _buildAnswerArea(provider, word),

                        // 测试模式正确答案提示
                        if (provider.isTestMode && provider.testShowAnswer)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.orange.withOpacity(0.4)),
                              ),
                              child: Column(children: [
                                const Text("正确答案：",
                                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 14)),
                                const SizedBox(height: 6),
                                Text(provider.testCorrectAnswer,
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green)),
                              ]),
                            ),
                          ),

                        // 操作按钮（仅学习模式显示）
                        if (provider.isStudyMode) ...[
                          const SizedBox(height: 20),
                          Row(children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.skip_next, size: 18),
                                label: const Text("跳过"),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.orange,
                                  side: const BorderSide(color: Colors.orange),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                onPressed: () async {
                                  await provider.skipWord();
                                  _spellController.clear();
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.check_circle_outline, size: 18),
                                label: const Text("我已经会了"),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.green,
                                  side: const BorderSide(color: Colors.green),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                onPressed: () async {
                                  await provider.markAsKnown();
                                  _spellController.clear();
                                },
                              ),
                            ),
                          ]),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.arrow_forward, size: 18),
                              label: const Text("下一题"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.indigo,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: () {
                                provider.proceedToNext();
                                _spellController.clear();
                              },
                            ),
                          ),
                        ],
                      ]),
                    )),
                  ]),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// 测试/学习完成时的视图
  Widget _buildFinishedView(LearningProvider provider) {
    if (provider.isTestMode) {
      // 测试完成：显示结果 + 进入学习模式的入口
      final results = provider.testResults;
      int total = results.length;
      int correct = 0;
      int wrong = 0;
      int dontKnow = 0;
      int skipped = 0;
      results.forEach((id, r) {
        if (r.skipped) skipped++;
        else if (r.hasDontKnow) dontKnow++;
        else if (r.hasWrong) wrong++;
        else correct++;
      });

      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.assignment_turned_in, size: 64, color: Colors.indigo),
        const SizedBox(height: 16),
        const Text("📋 测试完成！", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        Text("共 $total 个单词", style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        Text("✅ 全对：$correct", style: const TextStyle(fontSize: 15, color: Colors.green)),
        Text("❌ 答错：$wrong", style: const TextStyle(fontSize: 15, color: Colors.red)),
        Text("🤷 不会：$dontKnow", style: const TextStyle(fontSize: 15, color: Colors.orange)),
        Text("⏭ 跳过：$skipped", style: const TextStyle(fontSize: 15, color: Colors.grey)),
        const SizedBox(height: 30),
        if (wrong + dontKnow > 0)
          ElevatedButton.icon(
            icon: const Icon(Icons.replay),
            label: Text("进入学习模式 (复习 ${wrong + dontKnow} 个单词)"),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
              backgroundColor: Colors.deepOrange, foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final wrongWords = await provider.getTestWrongWords();
              if (wrongWords.isNotEmpty) {
                await provider.startStudyMode(wrongWords);
              }
            },
          ),
        const SizedBox(height: 12),
        if (wrong + dontKnow == 0)
          ElevatedButton.icon(
            icon: const Icon(Icons.celebration),
            label: const Text("全部正确！返回主页"),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
              backgroundColor: Colors.green, foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.home),
          label: const Text("返回主页"),
          onPressed: () => Navigator.pop(context),
        ),
      ]));
    }

    // 学习模式完成
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Text("🎉 学习完成！",
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 30),
      ElevatedButton.icon(
        icon: const Icon(Icons.home),
        label: const Text("返回主页"),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
          backgroundColor: Colors.indigo, foregroundColor: Colors.white,
        ),
        onPressed: () => Navigator.pop(context),
      ),
    ]));
  }

  /// 构建答题区域（测试模式隐藏拼写，学习模式显示全部）
  Widget _buildAnswerArea(LearningProvider provider, Word word) {
    if (provider.isTestMode) {
      // 测试模式：仅选择题
      return Column(
        key: ValueKey('options_${word.id}_${provider.options.hashCode}'),
        children: [
          ...provider.options.map((opt) => Padding(
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
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.help_outline, size: 20),
              label: const Text("我不会", style: TextStyle(fontSize: 16)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey,
                side: const BorderSide(color: Colors.grey),
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.grey.withOpacity(0.05),
              ),
              onPressed: () => provider.dontKnow(),
            ),
          ),
        ],
      );
    }

    // 学习模式：选择题 + 拼写题
    return AnimatedSwitcher(
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
                if ((data['mnemonic'] ?? '').toString().isNotEmpty)
                  _favSection("记忆法", data['mnemonic'].toString(), Colors.orange),
                if ((data['etymology'] ?? '').toString().isNotEmpty)
                  _favSection("单词说明", data['etymology'].toString(), Colors.indigo),
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
              
              // 【修改】将词汇阵列移到这个 if 内部，生成结果后才显示
              const SizedBox(height: 30),
              const Divider(),
              const Text("词汇阵列：", style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 10),
              SizedBox(
                height: 40,
                child: Consumer<LearningProvider>(
                  builder: (context, provider, child) {
                    if (provider.todayWords.isEmpty) {
                      return const Center(
                        child: Text("暂无今日词汇", style: TextStyle(color: Colors.grey, fontSize: 12)),
                      );
                    }
                    return ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: provider.todayWords.length,
                      itemBuilder: (context, index) {
                        final w = provider.todayWords[index];
                        final isCurrent = index == provider.progress;
                        final isPassed = index < provider.progress;
                        return Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isCurrent ? Colors.indigo : (isPassed ? Colors.green : Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Center(
                            child: Text(
                              w.spelling, 
                              style: TextStyle(
                                color: (isCurrent || isPassed) ? Colors.white : Colors.black54, 
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal
                              )
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ], // 这里是 if (_exerciseData != null) 的闭合括号

          const SizedBox(height: 40),
        ]),
      ),
    );
  }
}

// ==========================================
// 单词表页（查看与手动编辑单词状态）
// ==========================================
class WordListScreen extends StatefulWidget {
  const WordListScreen({super.key});
  @override
  State<WordListScreen> createState() => _WordListScreenState();
}

class _WordListScreenState extends State<WordListScreen> {
  List<Word> _allWords = [];
  List<Word> _filteredWords = [];
  bool _loading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() { super.initState(); _loadWords(); }

  @override
  void dispose() { _searchController.dispose(); super.dispose(); }

  Future<void> _loadWords() async {
    setState(() => _loading = true);
    try {
      // 从数据库获取所有单词
      final db = await DatabaseHelper.database;
      final maps = await db.query('words', orderBy: 'spelling ASC', limit: 500);
      _allWords = maps.map((m) => Word.fromMap(m)).toList();
      _filteredWords = List.from(_allWords);
    } catch (e) { debugPrint("加载单词表失败: $e"); }
    if (mounted) setState(() => _loading = false);
  }

  void _filter(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredWords = List.from(_allWords);
      } else {
        final q = query.toLowerCase();
        _filteredWords = _allWords.where((w) =>
          w.spelling.toLowerCase().contains(q) ||
          w.translation.toLowerCase().contains(q)
        ).toList();
      }
    });
  }

  String _wordStatus(Word w) {
    if (w.nextReviewDate == -1) return '已掌握';
    if (w.nextReviewDate == 0) return '新词';
    if (w.nextReviewDate <= DateTime.now().millisecondsSinceEpoch) return '待复习';
    return '学习中';
  }

  Color _statusColor(String status) {
    switch (status) {
      case '已掌握': return Colors.green;
      case '新词': return Colors.blue;
      case '待复习': return Colors.orange;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("单词表")),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: "筛选单词...",
              prefixIcon: const Icon(Icons.filter_list),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(icon: const Icon(Icons.clear), onPressed: () {
                    _searchController.clear();
                    _filter('');
                  })
                : null,
            ),
            onChanged: _filter,
          ),
        ),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView.builder(
              itemCount: _filteredWords.length,
              itemBuilder: (context, i) {
                final w = _filteredWords[i];
                final status = _wordStatus(w);
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  child: ListTile(
                    title: Text(w.spelling,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    subtitle: Text(w.translation.replaceAll(r'\n', '\n'),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _statusColor(status).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(status,
                          style: TextStyle(
                            color: _statusColor(status),
                            fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    onTap: () => _editWord(w),
                  ),
                );
              },
            ),
          ),
      ]),
    );
  }

  void _editWord(Word word) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _WordEditSheet(
        word: word,
        onSaved: () {
          Navigator.pop(ctx);
          _loadWords(); // 刷新列表
        },
      ),
    );
  }
}

/// 单词编辑 BottomSheet
class _WordEditSheet extends StatefulWidget {
  final Word word;
  final VoidCallback onSaved;

  const _WordEditSheet({required this.word, required this.onSaved});

  @override
  State<_WordEditSheet> createState() => _WordEditSheetState();
}

class _WordEditSheetState extends State<_WordEditSheet> {
  late TextEditingController _repsController;
  late TextEditingController _intervalController;
  late double _easeFactor;
  late bool _isMastered;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _repsController = TextEditingController(text: widget.word.reps.toString());
    _intervalController = TextEditingController(text: widget.word.interval.toString());
    _easeFactor = widget.word.easeFactor;
    _isMastered = widget.word.nextReviewDate == -1;
  }

  @override
  void dispose() {
    _repsController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final word = widget.word;
    word.reps = int.tryParse(_repsController.text) ?? word.reps;
    word.interval = int.tryParse(_intervalController.text) ?? word.interval;
    word.easeFactor = _easeFactor;
    word.nextReviewDate = _isMastered ? -1 : DateTime.now().millisecondsSinceEpoch;
    await DatabaseHelper.updateWord(word);
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("✅ 已保存"), backgroundColor: Colors.green));
      widget.onSaved();
    }
  }

  Future<void> _reset() async {
    final word = widget.word;
    word.reps = 0;
    word.interval = 0;
    word.easeFactor = 2.5;
    word.nextReviewDate = 0;
    await DatabaseHelper.updateWord(word);
    if (mounted) {
      setState(() {
        _repsController.text = '0';
        _intervalController.text = '0';
        _easeFactor = 2.5;
        _isMastered = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("🔄 已重置为未学习状态"), backgroundColor: Colors.blue));
      widget.onSaved();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.edit, color: Colors.indigo),
          const SizedBox(width: 8),
          Expanded(
            child: Text("编辑：${widget.word.spelling}",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ),
        ]),
        const Divider(),
        // 单词信息（只读）
        Text("释义：${widget.word.translation}", style: const TextStyle(fontSize: 14, color: Colors.grey)),
        const SizedBox(height: 16),

        // 编辑字段
        TextField(
          controller: _repsController,
          decoration: const InputDecoration(labelText: "复习次数 (reps)", border: OutlineInputBorder()),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _intervalController,
          decoration: const InputDecoration(labelText: "复习间隔 (interval, 天)", border: OutlineInputBorder()),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Text("难度系数 (easeFactor)：" , style: TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Text(_easeFactor.toStringAsFixed(2),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        ]),
        Slider(
          value: _easeFactor,
          min: 1.3,
          max: 3.0,
          divisions: 34,
          label: _easeFactor.toStringAsFixed(2),
          onChanged: (v) => setState(() => _easeFactor = v),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text("已掌握"),
          subtitle: const Text("开启后此单词不再出现在复习中"),
          value: _isMastered,
          onChanged: (v) => setState(() => _isMastered = v),
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 16),

        // 操作按钮
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text("重置"),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _reset,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
              label: const Text("保存"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _saving ? null : _save,
            ),
          ),
        ]),
        const SizedBox(height: 10),
      ]),
    );
  }
}

// ==========================================
// 搜索页
// ==========================================
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Word> _results = [];
  bool _isSearching = false;
  bool _hasSearched = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    setState(() { _isSearching = true; _hasSearched = true; });
    final results = await DatabaseHelper.searchWords(query);
    if (mounted) setState(() { _results = results; _isSearching = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("搜索单词")),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            autofocus: true,
            decoration: InputDecoration(
              hintText: "输入单词拼写或中文释义...",
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(icon: const Icon(Icons.clear), onPressed: () {
                    _searchController.clear();
                    setState(() { _results = []; _hasSearched = false; });
                  })
                : null,
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        if (_isSearching)
          const Center(child: Padding(
            padding: EdgeInsets.all(40),
            child: CircularProgressIndicator(),
          ))
        else if (_hasSearched && _results.isEmpty)
          const Expanded(child: Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.search_off, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text("未找到匹配的单词", style: TextStyle(color: Colors.grey, fontSize: 16)),
            ]),
          ))
        else
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final word = _results[i];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: ListTile(
                    title: Text(word.spelling,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    subtitle: Text(word.translation.replaceAll(r'\n', '\n'),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton.icon(
                        icon: const Icon(Icons.compare_arrows, size: 16),
                        label: const Text("同义词"),
                        style: TextButton.styleFrom(foregroundColor: Colors.indigo),
                        onPressed: () => _showSynonyms(word),
                      ),
                    ]),
                    onTap: () => _showWordDetail(word),
                  ),
                );
              },
            ),
          ),
      ]),
    );
  }

  void _showWordDetail(Word word) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5, minChildSize: 0.3, maxChildSize: 0.85, expand: false,
        builder: (_, sc) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.menu_book, color: Colors.indigo),
              const SizedBox(width: 8),
              Expanded(child: Text("${word.spelling} — ${word.translation}",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  overflow: TextOverflow.ellipsis)),
            ]),
            const Divider(),
            Expanded(child: SingleChildScrollView(
              controller: sc,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _buildInfoRow("拼写", word.spelling),
                _buildInfoRow("释义", word.translation),
                _buildInfoRow("复习次数", "${word.reps}"),
                _buildInfoRow("SM2难度", word.easeFactor.toStringAsFixed(2)),
                _buildInfoRow("掌握状态",
                    word.nextReviewDate == -1 ? "✅ 已掌握" : "学习中"),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.compare_arrows),
                    label: const Text("查看同义词 / 反义词"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showSynonyms(word);
                    },
                  ),
                ),
                const SizedBox(height: 20),
              ]),
            )),
          ]),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 80, child: Text("$label：",
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey))),
      Expanded(child: Text(value, style: const TextStyle(fontSize: 15))),
    ]),
  );

  void _showSynonyms(Word word) async {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));

    final data = await AiService.getSynonyms(word);

    if (!mounted) return;
    Navigator.pop(context); // 关掉加载弹窗

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55, minChildSize: 0.35, maxChildSize: 0.85, expand: false,
        builder: (_, sc) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.compare_arrows, color: Colors.indigo),
              const SizedBox(width: 8),
              Expanded(child: Text("同义词 / 反义词：${word.spelling}",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  overflow: TextOverflow.ellipsis)),
            ]),
            const Divider(),
            Expanded(child: SingleChildScrollView(
              controller: sc,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text("📖 同义词 / 近义词",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.green.withOpacity(0.2)),
                  ),
                  child: Text(data['synonyms'] ?? '暂无数据',
                      style: const TextStyle(fontSize: 14, height: 1.6)),
                ),
                const SizedBox(height: 24),
                const Text("🔄 反义词",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.withOpacity(0.2)),
                  ),
                  child: Text(data['antonyms'] ?? '暂无数据',
                      style: const TextStyle(fontSize: 14, height: 1.6)),
                ),
                const SizedBox(height: 20),
              ]),
            )),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo, foregroundColor: Colors.white,
                ),
                child: const Text("关闭"),
              )),
            ),
          ]),
        ),
      ),
    );
  }
}

// ==========================================
// 设置页 (简化版，仅保留DeepSeek API配置)
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

        // DeepSeek API配置
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
        const SizedBox(height: 20),
      ]),
    );
  }
}