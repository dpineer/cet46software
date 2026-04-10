import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ==========================================
// LM-Studio 适配器接口定义
// ==========================================
abstract class LMStudioAdapter {
  const LMStudioAdapter();
  
  /// 获取基础URL
  String get baseUrl;
  
  /// 获取Dio实例
  Dio get dio => Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
  ));
  
  /// 发送请求到LM-Studio
  Future<Map<String, dynamic>> request(String endpoint, Map<String, dynamic> data);
  
  /// 发送流式请求到LM-Studio
  Stream<Map<String, dynamic>> streamRequest(String endpoint, Map<String, dynamic> data);
  
  /// 获取可用模型列表
  Future<List<Map<String, dynamic>>> getModels();
  
  /// 检查LM-Studio服务是否可用
  Future<bool> isAvailable();
  
  /// 获取API Key（如果需要）
  Future<String> getApiKey();
  
  /// 保存API Key
  Future<void> saveApiKey(String key);
}

// ==========================================
// LM-Studio 本地服务器适配器实现
// ==========================================
class LMStudioLocalAdapter implements LMStudioAdapter {
  final String _host;
  final int _port;
  final String? _apiKey;
  
  LMStudioLocalAdapter({
    String host = 'localhost',
    int port = 1234,
    String? apiKey,
  }) : _host = host, _port = port, _apiKey = apiKey;
  
  @override
  String get baseUrl => 'http://$_host:$_port';
  
  @override
  Dio get dio {
    final dioInstance = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ));
    
    // 添加API Key到header（如果需要）
    if (_apiKey != null && _apiKey!.isNotEmpty) {
      dioInstance.options.headers['Authorization'] = 'Bearer $_apiKey';
    }
    
    return dioInstance;
  }
  
  @override
  Future<Map<String, dynamic>> request(String endpoint, Map<String, dynamic> data) async {
    try {
      final response = await dio.post(
        endpoint,
        data: data,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
          },
        ),
      );
      
      if (response.statusCode! >= 200 && response.statusCode! < 300) {
        return response.data;
      } else {
        throw Exception('HTTP 状态码：${response.statusCode}');
      }
    } catch (e) {
      print('LM-Studio请求错误: $e');
      rethrow;
    }
  }
  
  @override
  Stream<Map<String, dynamic>> streamRequest(String endpoint, Map<String, dynamic> data) async* {
    try {
      final response = await dio.post(
        endpoint,
        data: data,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          },
          responseType: ResponseType.stream,
        ),
      );
      
      final stream = response.data?.stream;
      if (stream == null) {
        throw Exception('无法获取流式响应');
      }
      
      String accumulated = '';
      await for (var chunk in stream.cast<List<int>>().transform(utf8.decoder)) {
        final lines = chunk.split('\n');
        for (var line in lines) {
          if (line.startsWith('data: ') && !line.contains('[DONE]')) {
            final jsonStr = line.substring(6);
            if (jsonStr.trim().isNotEmpty) {
              try {
                final jsonData = jsonDecode(jsonStr);
                final delta = jsonData['choices'][0]['delta']['content'];
                if (delta != null) {
                  accumulated += delta as String;
                  yield {'content': accumulated};
                }
              } catch (_) {
                // 忽略解析错误
              }
            }
          }
        }
      }
    } catch (e) {
      print('LM-Studio流式请求错误: $e');
      rethrow;
    }
  }
  
  @override
  Future<List<Map<String, dynamic>>> getModels() async {
    try {
      final response = await dio.get('/v1/models');
      
      if (response.statusCode! >= 200 && response.statusCode! < 300) {
        final data = response.data;
        if (data is Map && data.containsKey('data')) {
          return List<Map<String, dynamic>>.from(data['data']);
        }
        return [];
      } else {
        throw Exception('获取模型列表失败：${response.statusCode}');
      }
    } catch (e) {
      print('获取LM-Studio模型错误: $e');
      rethrow;
    }
  }
  
  @override
  Future<bool> isAvailable() async {
    try {
      final response = await dio.get('/health', options: Options(
        validateStatus: (status) => true, // 接受所有状态码
      ));
      
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
  
  @override
  Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('lm_studio_api_key') ?? '';
  }
  
  @override
  Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lm_studio_api_key', key);
  }
  
  /// 创建聊天补全请求
  Future<Map<String, dynamic>> createChatCompletion({
    required String model,
    required List<Map<String, String>> messages,
    double temperature = 0.7,
    int maxTokens = 2048,
    bool stream = false,
  }) async {
    final data = {
      'model': model,
      'messages': messages,
      'temperature': temperature,
      'max_tokens': maxTokens,
      'stream': stream,
    };
    
    return await request('/v1/chat/completions', data);
  }
  
  /// 流式聊天补全
  Stream<Map<String, dynamic>> createChatCompletionStream({
    required String model,
    required List<Map<String, String>> messages,
    double temperature = 0.7,
    int maxTokens = 2048,
  }) async* {
    final data = {
      'model': model,
      'messages': messages,
      'temperature': temperature,
      'max_tokens': maxTokens,
      'stream': true,
    };
    
    yield* streamRequest('/v1/chat/completions', data);
  }
}

// ==========================================
// 适配器工厂
// ==========================================
class AdapterFactory {
  static Future<LMStudioAdapter> createLMStudioAdapter() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('lm_studio_host') ?? 'localhost';
    final port = prefs.getInt('lm_studio_port') ?? 1234;
    final apiKey = prefs.getString('lm_studio_api_key');
    
    return LMStudioLocalAdapter(
      host: host,
      port: port,
      apiKey: apiKey,
    );
  }
  
  /// 测试连接
  static Future<bool> testConnection({
    String host = 'localhost',
    int port = 1234,
    String? apiKey,
  }) async {
    try {
      final adapter = LMStudioLocalAdapter(
        host: host,
        port: port,
        apiKey: apiKey,
      );
      return await adapter.isAvailable();
    } catch (e) {
      return false;
    }
  }
}

// ==========================================
// 与现有AiService完全兼容的包装器
// ==========================================
class LMStudioAiService {
  static LMStudioLocalAdapter? _adapter;
  static const String _keyName = "lm_studio_api_key";
  
  /// 获取适配器实例（延迟初始化）
  static Future<LMStudioLocalAdapter> _getAdapter() async {
    if (_adapter == null) {
      final settings = await getCurrentSettings();
      final host = settings['host'] as String;
      final port = settings['port'] as int;
      final apiKey = await getApiKey();
      
      _adapter = LMStudioLocalAdapter(
        host: host,
        port: port,
        apiKey: apiKey.isNotEmpty ? apiKey : null,
      );
    }
    return _adapter!;
  }
  
  /// 获取API Key
  static Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyName) ?? '';
  }
  
  /// 保存API Key
  static Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyName, key);
  }
  
  /// 删除API Key
  static Future<void> deleteApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyName);
  }
  
  /// 流式解释（与DeepSeek接口完全一致）
  static Future<void> getExplanationStream(
    String spelling, String translation, String userInput, String qType,
    Function(String) onStreamUpdate, Function(String)? onError,
  ) async {
    // 检查LM-Studio是否已配置（host和port）
    final settings = await getCurrentSettings();
    final host = settings['host'] as String;
    final port = settings['port'] as int;
    
    if (host.isEmpty || port <= 0) {
      onStreamUpdate(jsonEncode({"error_analysis": "CONFIG_REQUIRED"}));
      return;
    }
    
    final apiKey = await getApiKey();
    
    try {
      final prompt = """单词：$spelling（$translation）。学生在$qType时输入：$userInput。
请用JSON返回以下字段（每个字段都必须是字符串，例句独立成字段）：
- error_analysis（一段话分析错误原因，不超过3句）
- etymology（词源词根分析）
- mnemonic（记忆法）
- example（3个例句，用\\n分隔）""";

      final messages = [
        {"role": "system", "content": "只返回合法JSON，不含markdown代码块，不含多余文字。"},
        {"role": "user", "content": prompt}
      ];
      
      final adapter = await _getAdapter();
      final stream = adapter.createChatCompletionStream(
        model: await _getDefaultModel(),
        messages: messages,
      );
      
      String accumulated = "";
      await for (var chunk in stream) {
        if (chunk.containsKey('content')) {
          accumulated = chunk['content'];
          // 清理markdown标记后实时推送
          final cleaned = accumulated
              .replaceAll(RegExp(r'^```json\s*', multiLine: false), '')
              .replaceAll(RegExp(r'^```\s*', multiLine: false), '')
              .replaceAll('```json', '').replaceAll('```', '');
          onStreamUpdate(cleaned);
        }
      }
      
      final cleaned = accumulated
          .replaceAll(RegExp(r'```json\s*'), '').replaceAll('```', '').trim();
      onStreamUpdate(cleaned);
    } catch (e) {
      onError?.call("LM_STUDIO_ERROR: $e");
    }
  }
  
  /// 获取单词详细解释（与DeepSeek接口完全一致）
  static Future<Map<String, dynamic>> getDetailedExplanation(String spelling, String translation) async {
    // 检查LM-Studio是否已配置（host和port）
    final settings = await getCurrentSettings();
    final host = settings['host'] as String;
    final port = settings['port'] as int;
    
    if (host.isEmpty || port <= 0) {
      return {"error": "CONFIG_REQUIRED"};
    }
    
    final apiKey = await getApiKey();
    
    try {
      final prompt = """单词：$spelling（$translation）。
请用JSON返回（所有字段值均为字符串）：
- pronunciation（国际音标）
- partOfSpeech（词性说明）
- usage_level（使用频率：高/中/低，附说明）
- detailed_meanings（详细释义，多个含义用\\n分隔）
- etymology（词源与历史演变，详细版）
- collocations（5个常见搭配短语，每个附中文，用\\n分隔）
- synonyms_and_antonyms（同义词与反义词，格式：同义：x,y；反义：a,b）
- example（6个实用例句，用\\n分隔）""";

      final messages = [
        {"role": "system", "content": "只返回合法JSON，不含markdown代码块。"},
        {"role": "user", "content": prompt}
      ];
      
      final adapter = await _getAdapter();
      final response = await adapter.createChatCompletion(
        model: await _getDefaultModel(),
        messages: messages,
      );
      
      String content = response['choices'][0]['message']['content'];
      content = content.replaceAll(RegExp(r'```json\s*|\s*```'), '').trim();
      return jsonDecode(content);
    } catch (e) {
      return {"error": "LM_STUDIO_ERROR: $e"};
    }
  }
  
  /// 生成填空段落（与DeepSeek接口完全一致）
  static Future<Map<String, dynamic>> generateFillBlankParagraph(List<Map<String, String>> wordList) async {
    // 检查LM-Studio是否已配置（host和port）
    final settings = await getCurrentSettings();
    final host = settings['host'] as String;
    final port = settings['port'] as int;
    
    if (host.isEmpty || port <= 0) {
      return {"error": "CONFIG_REQUIRED"};
    }
    
    final apiKey = await getApiKey();
    
    try {
      final wordsString = wordList.map((w) => "${w['spelling']}（${w['translation']}）").join("、");
      final prompt = """请用以下单词造一个连贯的英文小段落（3-5句话）：$wordsString
要求：
1. 每个单词在段落中各出现一次
2. 段落语义自然连贯
3. 用JSON返回以下字段（值均为字符串）：
   - paragraph（完整段落，用于展示答案）
   - blanked_paragraph（将目标单词替换为____的版本，如有多个空用____1, ____2区分）
   - answers（答案列表，格式："word1,word2,word3"，与空格顺序对应）
   - analysis（段落解析，说明每个单词的用法）
   - translation（段落的中文翻译）""";

      final messages = [
        {"role": "system", "content": "只返回合法JSON，不含markdown代码块。"},
        {"role": "user", "content": prompt}
      ];
      
      final adapter = await _getAdapter();
      final response = await adapter.createChatCompletion(
        model: await _getDefaultModel(),
        messages: messages,
      );
      
      String content = response['choices'][0]['message']['content'];
      content = content.replaceAll(RegExp(r'```json\s*|\s*```'), '').trim();
      return jsonDecode(content);
    } catch (e) {
      return {"error": "LM_STUDIO_ERROR: $e"};
    }
  }
  
  /// 分析文本（翻译/作文批改）（与DeepSeek接口完全一致）
  static Future<String> analyzeText(String input, bool isEssay) async {
    // 检查LM-Studio是否已配置（host和port）
    final settings = await getCurrentSettings();
    final host = settings['host'] as String;
    final port = settings['port'] as int;
    
    if (host.isEmpty || port <= 0) {
      return "请先在设置中配置 LM-Studio 服务";
    }
    
    final apiKey = await getApiKey();

    try {
      String prompt = isEssay 
          ? "你是一个严厉且专业的英语四六级阅卷老师。请对以下作文进行批改：1. 纠正语法错误 2. 给出四六级高级词汇替换建议 3. 给出评分(满分15) 4. 提供一段高分范文。作文内容：\n$input"
          : "你是一个精准的翻译引擎。请对以下文本进行中英互译。如果输入英文，请翻译成优美的中文并提取里面的四六级核心词汇；如果输入中文，请翻译成地道的英文：\n$input";

      final messages = [
        {"role": "system", "content": "你是一个英语学习助手，请直接使用Markdown排版输出结果。"},
        {"role": "user", "content": prompt}
      ];
      
      final adapter = await _getAdapter();
      final response = await adapter.createChatCompletion(
        model: await _getDefaultModel(),
        messages: messages,
      );
      
      return response['choices'][0]['message']['content'];
    } catch (e) {
      return "LM-Studio请求失败，请检查服务是否运行：$e";
    }
  }
  
  /// 分析图片内容（新增：支持图片输入）
  static Future<String> analyzeImage(String imageBase64, String? promptText) async {
    // 检查LM-Studio是否已配置（host和port）
    final settings = await getCurrentSettings();
    final host = settings['host'] as String;
    final port = settings['port'] as int;
    
    if (host.isEmpty || port <= 0) {
      return "请先在设置中配置 LM-Studio 服务";
    }
    
    final apiKey = await getApiKey();

    try {
      // 构建多模态消息
      final userMessage = {
        "role": "user",
        "content": [
          {
            "type": "image_url",
            "image_url": {
              "url": "data:image/jpeg;base64,$imageBase64"
            }
          },
          {
            "type": "text",
            "text": promptText ?? "请描述这张图片的内容。"
          }
        ]
      };
      
      final messages = [
        {
          "role": "system",
          "content": "你是一个视觉助手，可以分析图片内容并回答问题。"
        },
        userMessage
      ];
      
      // 使用更通用的请求方法，因为消息结构复杂
      final data = {
        'model': await _getDefaultModel(),
        'messages': messages,
        'temperature': 0.7,
        'max_tokens': 2048,
      };
      
      final adapter = await _getAdapter();
      final response = await adapter.request('/v1/chat/completions', data);
      
      return response['choices'][0]['message']['content'];
    } catch (e) {
      return "图片分析失败：$e";
    }
  }
  
  /// 分析图片中的文本（OCR增强）
  static Future<String> analyzeImageText(String imageBase64) async {
    return await analyzeImage(imageBase64, "请提取图片中的所有文本内容，保持原格式。");
  }
  
  /// 分析图片中的英语学习内容
  static Future<String> analyzeImageForLearning(String imageBase64) async {
    return await analyzeImage(imageBase64, 
        "这是一张英语学习相关的图片，请分析其中的英语内容，包括：\n"
        "1. 识别所有英语单词和句子\n"
        "2. 解释难词和短语\n"
        "3. 分析语法结构\n"
        "4. 提供学习建议");
  }
  
  /// 获取默认模型
  static Future<String> _getDefaultModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('lm_studio_model') ?? 'default';
  }
  
  /// 保存模型设置
  static Future<void> saveModelSettings({
    required String host,
    required int port,
    String? apiKey,
    String model = 'default',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    
    // 确保host不为空
    if (host.trim().isEmpty) {
      throw Exception('主机地址不能为空');
    }
    
    // 确保port有效
    if (port <= 0 || port > 65535) {
      throw Exception('端口号必须在1-65535之间');
    }
    
    await prefs.setString('lm_studio_host', host.trim());
    await prefs.setInt('lm_studio_port', port);
    
    // 处理API Key：如果为空字符串，则删除现有Key
    if (apiKey == null || apiKey.trim().isEmpty) {
      await prefs.remove('lm_studio_api_key');
    } else {
      await prefs.setString('lm_studio_api_key', apiKey.trim());
    }
    
    // 确保model不为空
    if (model.trim().isEmpty) {
      model = 'default';
    }
    await prefs.setString('lm_studio_model', model.trim());
    
    // 重置适配器，以便下次使用新配置
    _adapter = null;
    
    // 调试：打印保存的配置
    print('LM-Studio配置已保存: host=$host, port=$port, model=$model, hasApiKey=${apiKey != null && apiKey.isNotEmpty}');
  }
  
  /// 获取当前设置
  static Future<Map<String, dynamic>> getCurrentSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'host': prefs.getString('lm_studio_host') ?? 'localhost',
      'port': prefs.getInt('lm_studio_port') ?? 1234,
      'hasApiKey': prefs.getString('lm_studio_api_key')?.isNotEmpty ?? false,
      'model': prefs.getString('lm_studio_model') ?? 'default',
    };
  }
}
