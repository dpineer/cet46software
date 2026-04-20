import 'package:shared_preferences/shared_preferences.dart';
import 'lm_studio_adapter.dart' as lmStudio;

// ==========================================
// AI服务类型枚举
// ==========================================
enum AIServiceType {
  deepseek('DeepSeek', '使用DeepSeek在线API服务'),
  lmStudio('LM-Studio', '使用本地LM-Studio服务');
  
  final String name;
  final String description;
  
  const AIServiceType(this.name, this.description);
}

// ==========================================
// AI服务管理器
// ==========================================
class AIServiceManager {
  static const String _serviceTypeKey = 'ai_service_type';
  static const String _defaultServiceType = 'deepseek';
  
  /// 获取当前使用的AI服务类型
  static Future<AIServiceType> getCurrentServiceType() async {
    final prefs = await SharedPreferences.getInstance();
    final typeString = prefs.getString(_serviceTypeKey) ?? _defaultServiceType;
    
    switch (typeString) {
      case 'lmStudio':
        return AIServiceType.lmStudio;
      case 'deepseek':
      default:
        return AIServiceType.deepseek;
    }
  }
  
  /// 设置AI服务类型
  static Future<void> setServiceType(AIServiceType type) async {
    final prefs = await SharedPreferences.getInstance();
    String typeString;
    
    switch (type) {
      case AIServiceType.lmStudio:
        typeString = 'lmStudio';
        break;
      case AIServiceType.deepseek:
      default:
        typeString = 'deepseek';
        break;
    }
    
    await prefs.setString(_serviceTypeKey, typeString);
  }
  
  /// 获取当前服务的显示名称
  static Future<String> getCurrentServiceName() async {
    final type = await getCurrentServiceType();
    return type.name;
  }
  
  /// 获取当前服务的描述
  static Future<String> getCurrentServiceDescription() async {
    final type = await getCurrentServiceType();
    return type.description;
  }
  
  /// 检查是否使用LM-Studio
  static Future<bool> isUsingLMStudio() async {
    final type = await getCurrentServiceType();
    return type == AIServiceType.lmStudio;
  }
  
  /// 检查是否使用DeepSeek
  static Future<bool> isUsingDeepSeek() async {
    final type = await getCurrentServiceType();
    return type == AIServiceType.deepseek;
  }
  
  /// 获取所有可用的服务类型
  static List<AIServiceType> getAvailableServiceTypes() {
    return AIServiceType.values;
  }
  
  /// 获取服务的详细配置信息
  static Future<Map<String, dynamic>> getServiceConfig(AIServiceType type) async {
    final prefs = await SharedPreferences.getInstance();
    
    switch (type) {
      case AIServiceType.lmStudio:
        return {
          'type': 'lmStudio',
          'name': 'LM-Studio',
          'description': '本地AI服务，保护隐私，无需网络',
          'host': prefs.getString('lm_studio_host') ?? 'localhost',
          'port': prefs.getInt('lm_studio_port') ?? 1234,
          'hasApiKey': prefs.getString('lm_studio_api_key')?.isNotEmpty ?? false,
          'model': prefs.getString('lm_studio_model') ?? 'default',
          'isConfigured': await _isLMStudioConfigured(),
        };
        
      case AIServiceType.deepseek:
      default:
        return {
          'type': 'deepseek',
          'name': 'DeepSeek',
          'description': '在线AI服务，功能强大，需要网络',
          'hasApiKey': prefs.getString('deepseek_api_key')?.isNotEmpty ?? false,
          'isConfigured': await _isDeepSeekConfigured(),
        };
    }
  }
  
  /// 检查LM-Studio是否已配置
  static Future<bool> _isLMStudioConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('lm_studio_host');
    final port = prefs.getInt('lm_studio_port');
    final model = prefs.getString('lm_studio_model');
    
    // 基本配置检查：host和port是必需的，model可以有默认值
    final hasHost = host != null && host.isNotEmpty;
    final hasPort = port != null;
    
    // 如果host和port都有，就认为已配置
    // 即使model为空，也可以使用默认模型
    final isConfigured = hasHost && hasPort;
    
    // 调试：打印配置状态
    print('LM-Studio配置检查: host=$host, port=$port, model=$model, hasHost=$hasHost, hasPort=$hasPort, isConfigured=$isConfigured');
    
    return isConfigured;
  }
  
  /// 检查DeepSeek是否已配置
  static Future<bool> _isDeepSeekConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('deepseek_api_key');
    return apiKey != null && apiKey.isNotEmpty;
  }
  
  /// 获取当前服务的配置状态
  static Future<Map<String, dynamic>> getCurrentServiceStatus() async {
    final type = await getCurrentServiceType();
    final config = await getServiceConfig(type);
    final isConfigured = config['isConfigured'] as bool;
    
    return {
      'type': type,
      'name': config['name'],
      'description': config['description'],
      'isConfigured': isConfigured,
      'status': isConfigured ? '已配置' : '未配置',
      'statusColor': isConfigured ? 'green' : 'red',
      'config': config,
    };
  }
  
  /// 切换到下一个可用的服务
  static Future<AIServiceType> toggleService() async {
    final currentType = await getCurrentServiceType();
    final availableTypes = getAvailableServiceTypes();
    final currentIndex = availableTypes.indexOf(currentType);
    final nextIndex = (currentIndex + 1) % availableTypes.length;
    final nextType = availableTypes[nextIndex];
    
    await setServiceType(nextType);
    return nextType;
  }
}

// ==========================================
// 统一的AI服务接口
// ==========================================
class UnifiedAiService {
  /// 获取单词详细解释（自动选择后端）
  static Future<Map<String, dynamic>> getDetailedExplanation(String spelling, String translation) async {
    final serviceType = await AIServiceManager.getCurrentServiceType();
    
    if (serviceType == AIServiceType.lmStudio) {
      // 使用LM-Studio适配器
      try {
        return await lmStudio.LMStudioAiService.getDetailedExplanation(spelling, translation);
      } catch (e) {
        return {'error': 'LM_STUDIO_ERROR', 'message': 'LM-Studio服务未配置: $e'};
      }
    } else {
      // 使用现有的AiService
      // 这里需要从main.dart导入AiService
      // 为了编译通过，返回模拟数据
      return {'error': 'DEEPSEEK_NOT_IMPLEMENTED', 'message': '请使用现有的AiService'};
    }
  }
  
  /// 流式解释（自动选择后端）
  static Future<void> getExplanationStream(
    String spelling, String translation, String userInput, String qType,
    Function(String) onStreamUpdate, Function(String)? onError,
  ) async {
    final serviceType = await AIServiceManager.getCurrentServiceType();
    
    if (serviceType == AIServiceType.lmStudio) {
      // 使用LM-Studio适配器
      try {
        await lmStudio.LMStudioAiService.getExplanationStream(
          spelling, translation, userInput, qType, onStreamUpdate, onError);
      } catch (e) {
        onError?.call('LM_STUDIO_ERROR: $e');
      }
    } else {
      // 使用现有的AiService
      // 这里需要从main.dart导入AiService
      onError?.call('DEEPSEEK_NOT_IMPLEMENTED: 请使用现有的AiService');
    }
  }
  
  /// 获取当前服务的API Key
  static Future<String> getApiKey() async {
    final serviceType = await AIServiceManager.getCurrentServiceType();
    final prefs = await SharedPreferences.getInstance();
    
    if (serviceType == AIServiceType.lmStudio) {
      final key = prefs.getString('lm_studio_api_key');
      // [FIX] 核心修复逻辑：
      // 大多网络库(如OpenAI SDK)在序列化层具有强校验机制，ApiKey为空串会引发 CONFIG_REQUIRED 拦截报错。
      // LM-Studio由于是本地服务通常无需鉴权，因此若用户未配置，系统应默认注入一个占位符以通过拦截器校验。
      return (key != null && key.isNotEmpty) ? key : 'lm-studio-local-dummy-key';
    } else {
      return prefs.getString('deepseek_api_key') ?? '';
    }
  }
  
  /// 保存当前服务的API Key
  static Future<void> saveApiKey(String key) async {
    final serviceType = await AIServiceManager.getCurrentServiceType();
    final prefs = await SharedPreferences.getInstance();
    
    if (serviceType == AIServiceType.lmStudio) {
      await prefs.setString('lm_studio_api_key', key);
    } else {
      await prefs.setString('deepseek_api_key', key);
    }
  }
  
  /// 删除当前服务的API Key
  static Future<void> deleteApiKey() async {
    final serviceType = await AIServiceManager.getCurrentServiceType();
    final prefs = await SharedPreferences.getInstance();
    
    if (serviceType == AIServiceType.lmStudio) {
      await prefs.remove('lm_studio_api_key');
    } else {
      await prefs.remove('deepseek_api_key');
    }
  }
}