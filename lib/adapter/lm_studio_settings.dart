import 'package:flutter/material.dart';
import 'lm_studio_adapter.dart';

// ==========================================
// LM-Studio 设置界面
// ==========================================
class LMStudioSettingsScreen extends StatefulWidget {
  const LMStudioSettingsScreen({super.key});

  @override
  State<LMStudioSettingsScreen> createState() => _LMStudioSettingsScreenState();
}

class _LMStudioSettingsScreenState extends State<LMStudioSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  
  bool _isTesting = false;
  bool _testResult = false;
  String _testMessage = '';
  
  @override
  void initState() {
    super.initState();
    _loadSettings();
  }
  
  Future<void> _loadSettings() async {
    final settings = await LMStudioAiService.getCurrentSettings();
    
    setState(() {
      _hostController.text = settings['host'] ?? 'localhost';
      _portController.text = settings['port'].toString();
      _modelController.text = settings['model'] ?? 'default';
      // API Key不显示明文，只显示是否有设置
      _apiKeyController.text = settings['hasApiKey'] == true ? '********' : '';
    });
  }
  
  Future<void> _saveSettings() async {
    if (_formKey.currentState!.validate()) {
      final host = _hostController.text.trim();
      final port = int.tryParse(_portController.text.trim()) ?? 1234;
      final model = _modelController.text.trim().isEmpty ? 'default' : _modelController.text.trim();
      
      // 如果API Key是********，表示用户没有修改，不更新
      final apiKey = _apiKeyController.text.trim() == '********' 
          ? null 
          : _apiKeyController.text.trim();
      
      await LMStudioAiService.saveModelSettings(
        host: host,
        port: port,
        apiKey: apiKey,
        model: model,
      );
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存')),
      );
    }
  }
  
  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testResult = false;
      _testMessage = '正在测试连接...';
    });
    
    try {
      final host = _hostController.text.trim();
      final port = int.tryParse(_portController.text.trim()) ?? 1234;
      final apiKey = _apiKeyController.text.trim() == '********' 
          ? null 
          : _apiKeyController.text.trim();
      
      final result = await AdapterFactory.testConnection(
        host: host,
        port: port,
        apiKey: apiKey,
      );
      
      setState(() {
        _testResult = result;
        _testMessage = result 
            ? '连接成功！LM-Studio服务可用。'
            : '连接失败，请检查：\n1. LM-Studio是否正在运行\n2. 主机和端口是否正确\n3. 防火墙设置';
      });
    } catch (e) {
      setState(() {
        _testResult = false;
        _testMessage = '测试连接时出错：$e';
      });
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }
  
  Future<void> _getAvailableModels() async {
    setState(() {
      _isTesting = true;
      _testMessage = '正在获取可用模型...';
    });
    
    try {
      final adapter = await AdapterFactory.createLMStudioAdapter();
      final models = await adapter.getModels();
      
      if (models.isEmpty) {
        setState(() {
          _testResult = false;
          _testMessage = '未找到可用模型，请确保LM-Studio已加载模型。';
        });
      } else {
        final modelNames = models.map((m) => m['id'] ?? '未知模型').toList();
        setState(() {
          _testResult = true;
          _testMessage = '找到 ${models.length} 个可用模型：\n${modelNames.join('\n')}';
        });
        
        // 如果有模型，设置第一个为默认
        if (modelNames.isNotEmpty && _modelController.text.isEmpty) {
          _modelController.text = modelNames.first;
        }
      }
    } catch (e) {
      setState(() {
        _testResult = false;
        _testMessage = '获取模型列表失败：$e';
      });
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LM-Studio 设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveSettings,
            tooltip: '保存设置',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              // 主机设置
              TextFormField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: '主机地址',
                  hintText: 'localhost',
                  prefixIcon: Icon(Icons.computer),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入主机地址';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // 端口设置
              TextFormField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: '端口',
                  hintText: '1234',
                  prefixIcon: Icon(Icons.numbers),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return '请输入端口号';
                  }
                  final port = int.tryParse(value);
                  if (port == null || port < 1 || port > 65535) {
                    return '请输入有效的端口号 (1-65535)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // API Key设置
              TextFormField(
                controller: _apiKeyController,
                decoration: const InputDecoration(
                  labelText: 'API Key (可选)',
                  hintText: '如果需要认证，请输入API Key',
                  prefixIcon: Icon(Icons.key),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              
              // 模型设置
              TextFormField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: '模型名称',
                  hintText: 'default',
                  prefixIcon: Icon(Icons.model_training),
                ),
              ),
              const SizedBox(height: 24),
              
              // 测试连接按钮
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: _isTesting 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label: const Text('测试连接'),
                      onPressed: _isTesting ? null : _testConnection,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.list),
                      label: const Text('获取模型'),
                      onPressed: _isTesting ? null : _getAvailableModels,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              
              // 测试结果
              if (_testMessage.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _testResult ? Colors.green.shade50 : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _testResult ? Colors.green.shade200 : Colors.red.shade200,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _testResult ? Icons.check_circle : Icons.error,
                            color: _testResult ? Colors.green : Colors.red,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _testResult ? '连接成功' : '连接失败',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _testResult ? Colors.green : Colors.red,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _testMessage,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              
              const SizedBox(height: 32),
              
              // 使用说明
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '使用说明',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '1. 下载并安装 LM-Studio (https://lmstudio.ai/)',
                        style: TextStyle(fontSize: 14),
                      ),
                      const Text(
                        '2. 启动 LM-Studio 并加载模型',
                        style: TextStyle(fontSize: 14),
                      ),
                      const Text(
                        '3. 在 LM-Studio 中启动本地服务器',
                        style: TextStyle(fontSize: 14),
                      ),
                      const Text(
                        '4. 填写正确的地址和端口（默认：localhost:1234）',
                        style: TextStyle(fontSize: 14),
                      ),
                      const Text(
                        '5. 点击"测试连接"验证配置',
                        style: TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          // 这里可以添加打开LM-Studio官网的链接
                        },
                        child: const Text('访问 LM-Studio 官网'),
                      ),
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
  
  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }
}

// ==========================================
// 快捷方式：在主程序中添加设置入口
// ==========================================
void showLMStudioSettings(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (context) => const LMStudioSettingsScreen(),
    ),
  );
}